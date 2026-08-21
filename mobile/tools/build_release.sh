#!/usr/bin/env bash
#
# Build Mirrich for release.
#
#   --altstore    (default) an UNSIGNED bundle plus an AltStore source manifest.
#                 AltStore re-signs on install, so no certificate is needed.
#   --testflight  a SIGNED .ipa for App Store Connect. Needs signing set up
#                 (BUILDING.md §3). Add --upload to hand it to Apple.
#
# Output goes to dist_altstore/ or dist_testflight/ (--out to change):
#   all/     every build so far, plus source.json and icon.png for AltStore.
#            Mirrors what the server should hold; rsync it whole, and don't
#            prune it by hand — the manifest drops entries whose IPA is gone.
#   latest/  just this build, as Mirrich.ipa with no version in the name, and a
#            source.json listing only it. Rewritten every run; rsync it WITHOUT
#            --delete.
#
# The two can be served from different places: ALTSTORE_LATEST_BASE_URL gives
# latest/ its own base URL, and the URLs in each manifest are written to match
# where that manifest is served from. Unset, both point at ALTSTORE_BASE_URL, in
# which case latest/ is a partial upload over all/ rather than a source of its own.
#
# Each route reads a gitignored config beside this script, copied from the
# .example next to it: tools/altstore.env names the host you serve from,
# tools/testflight.env the account to upload as. The Team ID comes from
# ios/Signing.local.xcconfig.
#
#   ./tools/build_release.sh [--altstore|--testflight] [--upload] [--notes TEXT]
#       [--build-number N] [--out DIR] [--env FILE] [--skip-checkout] [--skip-analyze]
#
# Every run gets a fresh build number (a UTC timestamp), so AltStore sees it as
# newer than what is installed and App Store Connect accepts it as a new build.
# pubspec.yaml and ios/Runner/Info.plist are never written to, so the fork's diff
# stays at zero.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="tools/altstore.env"
NOTES=""
OUT=""
BUILD_NUMBER=""
SKIP_CHECKOUT=0
SKIP_ANALYZE=0
TARGET="altstore"
UPLOAD=0

usage() {
  awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)          NOTES="${2:?}";          shift 2 ;;
    --build-number)   BUILD_NUMBER="${2:?}";   shift 2 ;;
    --env)            ENV_FILE="${2:?}";       shift 2 ;;
    --out)            OUT="${2:?}";            shift 2 ;;
    --skip-checkout)  SKIP_CHECKOUT=1;         shift ;;
    --skip-analyze)   SKIP_ANALYZE=1;          shift ;;
    --altstore)       TARGET="altstore";       shift ;;
    --testflight|--signed) TARGET="testflight"; shift ;;
    --upload)         UPLOAD=1;                shift ;;
    -h|--help)        usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

if (( UPLOAD )) && [[ $TARGET != testflight ]]; then
  echo "error: --upload only applies to --testflight" >&2
  exit 1
fi

# A directory per route: a signed bundle means nothing to AltStore and an
# unsigned one is rejected long after upload, so the two must not mix.
OUT="${OUT:-dist_$TARGET}"
ALL="${OUT%/}/all"
LATEST="${OUT%/}/latest"

# ---------------------------------------------------------------------------
# Configuration and preflight
# ---------------------------------------------------------------------------
[[ $(uname) == Darwin ]] || { echo "error: iOS builds require macOS" >&2; exit 1; }
command -v mise >/dev/null || { echo "error: mise not on PATH — see BUILDING.md §1.3" >&2; exit 1; }
[[ $(xcode-select -p 2>/dev/null) == *Xcode.app* ]] || {
  echo "error: xcode-select does not point at a full Xcode install:" >&2
  echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
}

# The openapi generator opens more files than the default 256.
ulimit -n 8192 2>/dev/null || true

if [[ -f $ENV_FILE ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
elif [[ $TARGET == altstore ]]; then
  echo "error: $ENV_FILE not found — cp tools/altstore.env.example $ENV_FILE, then edit it" >&2
  exit 1
fi

APP_NAME="${ALTSTORE_APP_NAME:-Mirrich}"

if [[ $TARGET == altstore ]]; then
  : "${ALTSTORE_DEVELOPER:?not set in $ENV_FILE}"
  : "${ALTSTORE_BUNDLE_ID:?not set in $ENV_FILE}"
  : "${ALTSTORE_BASE_URL:?not set in $ENV_FILE}"
  BASE_URL="${ALTSTORE_BASE_URL%/}"
  # The two directories can be served from different places, so latest/ gets its
  # own base URL and the URLs inside each manifest are written to match where
  # that manifest is served from. Unset means both go to the same host.
  LATEST_BASE_URL="${ALTSTORE_LATEST_BASE_URL:-$BASE_URL}"
  LATEST_BASE_URL="${LATEST_BASE_URL%/}"
  # AltStore refuses plain HTTP, so fail now rather than after the build.
  for url in "$BASE_URL" "$LATEST_BASE_URL"; do
    [[ $url == https://* ]] || { echo "error: AltStore base URLs must be https:// (got: $url)" >&2; exit 1; }
  done
else
  # Credentials come from the environment when it has them, so a one-off run
  # needs no file. Neither form holds a secret: @keychain:NAME names a password
  # in the login keychain, and an API key is a .p8 the tool finds by id.
  TESTFLIGHT_ENV="tools/testflight.env"
  # shellcheck source=/dev/null
  [[ -f $TESTFLIGHT_ENV ]] && source "$TESTFLIGHT_ENV"

  # Signing configuration lives in the xcconfig Xcode reads, not in a second
  # file that could disagree with it.
  TEAM_ID=$(sed -n 's|^[[:space:]]*IMMICH_TEAM_ID[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*|\1|p' \
    ios/Signing.local.xcconfig 2>/dev/null | tail -1)
  [[ -n ${TEAM_ID:-} && $TEAM_ID != REPLACE* ]] || {
    echo "error: IMMICH_TEAM_ID is not set in ios/Signing.local.xcconfig — see BUILDING.md §3" >&2
    exit 1
  }

  UPLOAD_AUTH=()
  if (( UPLOAD )); then
    if [[ -n ${MIRRICH_API_KEY:-} ]]; then
      : "${MIRRICH_API_ISSUER:?not set — the Issuer ID above the key list in App Store Connect}"
      UPLOAD_AUTH=(--apiKey "$MIRRICH_API_KEY" --apiIssuer "$MIRRICH_API_ISSUER")
    else
      : "${MIRRICH_APPLE_ID:?not set — the Apple Account to upload as}"
      : "${MIRRICH_APP_PASSWORD:?not set — an app-specific password, or @keychain:NAME}"
      UPLOAD_AUTH=(-u "$MIRRICH_APPLE_ID" -p "$MIRRICH_APP_PASSWORD")
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Generate, analyze, version
#
# The openapi client and every *.g.dart / *.drift.dart / *.freezed.dart are
# generated and not committed; without them the build fails with hundreds of
# "undefined class" errors. The analyzer then reports all Dart errors in seconds,
# where a release build reports one at a time over minutes.
# ---------------------------------------------------------------------------
if (( SKIP_CHECKOUT )); then
  echo "==> Skipping code generation"
else
  echo "==> Generating code (mise run //mobile:checkout)"
  mise run //mobile:checkout
fi

if (( SKIP_ANALYZE )); then
  echo "==> Skipping analysis"
else
  echo "==> Analyzing"
  dart analyze --no-fatal-warnings || { echo "error: fix the errors above before building" >&2; exit 1; }
fi

BUILD_NAME=$(sed -n 's/^version:[[:space:]]*\([0-9.]*\)+.*$/\1/p' pubspec.yaml)
[[ -n $BUILD_NAME ]] || { echo "error: could not parse 'version: X.Y.Z+BUILD' from pubspec.yaml" >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
# Named after the app as well as the version, so two apps served from one
# directory cannot overwrite each other's IPAs.
SLUG="${APP_NAME//[^A-Za-z0-9]/-}"
IPA_NAME="${SLUG:-app}-$BUILD_NAME-$BUILD_NUMBER.ipa"
# In latest/ the version is dropped: that directory holds one build by
# definition, so a stable name gives a link that does not change between builds.
LATEST_IPA_NAME="${SLUG:-app}.ipa"

mkdir -p "$ALL"

# ---------------------------------------------------------------------------
# Signed route
#
# The version reaches the bundle through ios/Runner/Info.plist, whose version
# keys the fork points at $(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER). With a
# literal there these flags are silently ignored and every upload carries the
# same build number, which App Store Connect refuses hours later by email — so
# it is read back out of the export below.
# ---------------------------------------------------------------------------
if [[ $TARGET == testflight ]]; then
  # Generated rather than committed: it carries the Team ID.
  PLIST="build/ios/mirrich-export-options.plist"
  mkdir -p build/ios
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${MIRRICH_EXPORT_METHOD:-app-store-connect}</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>${MIRRICH_SIGNING_STYLE:-automatic}</string>
  <key>uploadSymbols</key><true/>
  <key>stripSwiftSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST_EOF

  echo "==> Building (release, signed for ${MIRRICH_EXPORT_METHOD:-app-store-connect}, team $TEAM_ID)"
  flutter build ipa --release \
    --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER" \
    --export-options-plist "$PLIST"

  BUILT=$(find build/ios/ipa -maxdepth 1 -name '*.ipa' -print -quit)
  [[ -n $BUILT ]] || {
    echo "error: no .ipa in build/ios/ipa. The archive usually succeeds and the export" >&2
    echo "fails on signing: missing distribution certificate, no provisioning profile" >&2
    echo "for this bundle ID, or a Team ID the profile was not issued to. BUILDING.md §3." >&2
    exit 1
  }

  # Checked before either copy, so a bundle whose filename would lie about its
  # build number never reaches all/, and a failed run leaves latest/ as it was.
  STAMPED=$(python3 -c '
import plistlib, re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
print(plistlib.loads(z.read(name)).get("CFBundleVersion", ""))' "$BUILT" 2>/dev/null || true)
  if [[ $STAMPED != "$BUILD_NUMBER" ]]; then
    echo "error: the bundle says build '${STAMPED:-?}', not $BUILD_NUMBER. Check that" >&2
    echo "ios/Runner/Info.plist carries \$(FLUTTER_BUILD_NUMBER) as CFBundleVersion." >&2
    exit 1
  fi

  SIGNED_IPA="$ALL/$IPA_NAME"
  cp "$BUILT" "$SIGNED_IPA"
  rm -rf "$LATEST"; mkdir -p "$LATEST"
  cp "$SIGNED_IPA" "$LATEST/$LATEST_IPA_NAME"

  if (( UPLOAD )); then
    echo "==> Uploading to App Store Connect"
    # Validate first: rejected here in seconds, or by email in twenty minutes.
    xcrun altool --validate-app -f "$SIGNED_IPA" -t ios "${UPLOAD_AUTH[@]}"
    xcrun altool --upload-app -f "$SIGNED_IPA" -t ios "${UPLOAD_AUTH[@]}"
  fi

  cat <<DONE

Done. $BUILD_NAME ($BUILD_NUMBER):
  $ALL/$IPA_NAME
  $LATEST/$LATEST_IPA_NAME
$(if (( UPLOAD )); then
  echo "
Uploaded. It shows as Processing in TestFlight for a few minutes, then becomes
assignable to testers. Internal testers need no review; external groups need
Beta App Review once per version."
else
  echo "
Nothing was uploaded. Hand it to Apple with --upload on the next run, with
  xcrun altool --upload-app -f $SIGNED_IPA -t ios -u <apple-id> -p @keychain:MIRRICH_APP_PASSWORD
or by dragging it into Transporter.app. See BUILDING.md §5."
fi)
DONE
  exit 0
fi

# ---------------------------------------------------------------------------
# Unsigned route
#
# An .ipa is a zip with the bundle under Payload/. The bundle is Immich.app, not
# Mirrich.app: the fork leaves PRODUCT_NAME alone because fastlane references it,
# and rebrands CFBundleDisplayName only. The version and name are stamped onto
# the staged copy rather than into the tree — safe because AltStore signs on
# install, so there is no signature to void.
# ---------------------------------------------------------------------------
echo "==> Building (release, unsigned)"
flutter build ios --release --no-codesign

APP=$(find build/ios/iphoneos -maxdepth 1 -name '*.app' -print -quit)
[[ -n $APP ]] || { echo "error: no .app in build/ios/iphoneos" >&2; exit 1; }

echo "==> Packaging $(basename "$APP")"
rm -rf build/ios/Payload
mkdir -p build/ios/Payload
cp -R "$APP" build/ios/Payload/

STAGED_PLIST="build/ios/Payload/$(basename "$APP")/Info.plist"
plutil -replace CFBundleShortVersionString -string "$BUILD_NAME"   "$STAGED_PLIST"
plutil -replace CFBundleVersion            -string "$BUILD_NUMBER" "$STAGED_PLIST"
plutil -replace CFBundleDisplayName        -string "$APP_NAME"     "$STAGED_PLIST"

# Zipped where it is staged and moved afterwards, because zip runs from build/ios
# and cannot be handed a path relative to the repo root — nor an absolute --out.
(cd build/ios && rm -f staged.ipa && zip -qry staged.ipa Payload)
mv build/ios/staged.ipa "$ALL/.staged.ipa"
rm -rf build/ios/Payload

# Wiped only now that there is something to put in it, so a failed run leaves
# the previous build intact.
rm -rf "$LATEST"; mkdir -p "$LATEST"
cp assets/mirrich-logo.png "$ALL/icon.png"
cp assets/mirrich-logo.png "$LATEST/icon.png"

echo "==> Writing $ALL/source.json"
BASE_URL="$BASE_URL" LATEST_BASE_URL="$LATEST_BASE_URL" \
BUNDLE_ID="$ALTSTORE_BUNDLE_ID" APP_NAME="$APP_NAME" \
SOURCE_NAME="${ALTSTORE_SOURCE_NAME:-}" DEVELOPER="$ALTSTORE_DEVELOPER" NOTES="$NOTES" \
IPA_NAME="$IPA_NAME" LATEST_IPA_NAME="$LATEST_IPA_NAME" ALL="$ALL" LATEST="$LATEST" \
python3 - <<'PY'
import json, os, plistlib, re, shutil, sys, zipfile
from datetime import date
from pathlib import Path

base, latest_base = os.environ["BASE_URL"], os.environ["LATEST_BASE_URL"]
bundle, app_name = os.environ["BUNDLE_ID"], os.environ["APP_NAME"]
all_dir, latest_dir = Path(os.environ["ALL"]), Path(os.environ["LATEST"])
manifest = all_dir / "source.json"
filename, latest_filename = os.environ["IPA_NAME"], os.environ["LATEST_IPA_NAME"]

# The version is read out of the bundle, never typed: AltStore compares the
# manifest against the IPA's CFBundleVersion and refuses the install on any
# disagreement.
staged = all_dir / ".staged.ipa"
with zipfile.ZipFile(staged) as z:
    name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
    info = plistlib.loads(z.read(name))
version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
if not version or not build:
    sys.exit(f"{staged} carries no version")

ipa = all_dir / filename
shutil.move(str(staged), ipa)
shutil.copy2(ipa, latest_dir / latest_filename)

entry = {
    "version": version,
    "buildVersion": build,
    "date": date.today().isoformat(),
    "localizedDescription": os.environ["NOTES"] or f"{app_name} {version} ({build}).",
    "downloadURL": f"{base}/{filename}",
    "size": ipa.stat().st_size,
    "minOSVersion": "17.0",   # Runner's deployment target
}

source = {}
if manifest.exists():
    try:
        source = json.loads(manifest.read_text())
    except ValueError:
        print(f"    warning: {manifest} unreadable, starting fresh", file=sys.stderr)

# Two sources served from two URLs need two names, or the only thing telling them apart in AltStore is a URL nobody
# sees. The full one takes a suffix rather than a setting of its own: one name to configure, and nothing to keep in step.
#
# Stripped before it is re-applied, because the name is read back from the manifest this same run wrote last time —
# without that, every build would add another "(all builds)".
kAllSuffix = " (all builds)"
stored_name = source.get("name")
if stored_name and stored_name.endswith(kAllSuffix):
    stored_name = stored_name[: -len(kAllSuffix)]
latest_name = os.environ["SOURCE_NAME"] or stored_name or app_name
all_name = latest_name + (kAllSuffix if latest_base != base else "")

# A source can list several apps, so only our own entry is touched.
apps = [a for a in source.get("apps", []) if isinstance(a, dict)]
mine = next((a for a in apps if a.get("bundleIdentifier") == bundle), None)
if mine is None:
    mine = {"bundleIdentifier": bundle}
    apps.append(mine)

versions = [v for v in mine.get("versions", [])
            if (v.get("version"), v.get("buildVersion")) != (version, build)] + [entry]


def newest_first(v):
    raw = str(v.get("buildVersion", ""))
    return (raw.isdigit(), int(raw) if raw.isdigit() else 0, v.get("date", ""))


def on_disk(v):
    # all/ mirrors the server, so an entry whose IPA is gone is a broken
    # download. Anything served from elsewhere is left alone.
    url = v.get("downloadURL", "")
    return not url.startswith(base + "/") or (all_dir / Path(url).name).is_file()


def refresh(app):
    # AltStore 1.x reads these top-level fields instead of `versions`.
    newest = app["versions"][0]
    for key, mirror in (("version", "version"), ("buildVersion", "buildVersion"),
                        ("size", "size"), ("downloadURL", "downloadURL"),
                        ("date", "versionDate"), ("localizedDescription", "versionDescription")):
        if key in newest:
            app[mirror] = newest[key]


mine.update({
    "name": app_name,
    "developerName": os.environ["DEVELOPER"],
    "subtitle": "Your Immich library, offline and permanent",
    "localizedDescription": (
        "A one-way mirror of an Immich server. The phone keeps a durable copy of the part of "
        "the library you choose, and it renders with no network at all — through flat signal, "
        "expired sessions and reboots alike."
    ),
    "iconURL": f"{base}/icon.png",
    "tintColor": "F9971F",
    "category": "photo-video",
    "screenshots": [],
    "versions": sorted(versions, key=newest_first, reverse=True),
})

for app in apps:
    for v in [v for v in app.get("versions", []) if not on_disk(v)]:
        print(f"    dropping {app.get('name', '?')} {v.get('version')}+{v.get('buildVersion')}:"
              f" {Path(v.get('downloadURL', '')).name} not in {all_dir}/")
    app["versions"] = [v for v in app.get("versions", []) if on_disk(v)]

# An app with no downloadable version would list in AltStore and fail on tap.
apps = [a for a in apps if a.get("versions")]
for app in apps:
    refresh(app)

# The source's identifier must not move, or AltStore re-registers the
# subscription and stops matching updates.
source.setdefault("identifier", f"{bundle}.altstore")
source["name"] = all_name
source["sourceURL"] = f"{base}/source.json"
source["apps"] = apps
source.setdefault("news", [])
manifest.write_text(json.dumps(source, indent=2) + "\n")

# latest/ is the same manifest with our app narrowed to this build, so it can be
# uploaded on its own. Only our own app's URLs are rewritten to the latest base:
# every other app is carried through untouched, because nothing else in this
# manifest is served from latest/ and their entries already name where they are.
one = json.loads(json.dumps(source))
one["name"] = latest_name
one["sourceURL"] = f"{latest_base}/source.json"
# Served from its own URL, latest/ is a subscription in its own right, and AltStore keys those on the identifier: left
# equal, the two manifests are one source to it and whichever was fetched last wins — a name alone would not tell them
# apart. Suffixed rather than configured, so it stays stable across builds without another value to keep in step. Sharing
# a URL keeps them one source on purpose: there, latest/ simply replaces the full manifest.
if latest_base != base:
    one["identifier"] = f"{source['identifier']}.latest"
(latest_dir / "source.json").write_text(json.dumps(one, indent=2) + "\n")

print(f"    {filename}, {entry['size']:,} bytes")
for app in apps:
    marker = "->" if app.get("bundleIdentifier") == bundle else "  "
    print(f"    {marker} {app['name']} ({app['bundleIdentifier']}): " +
          ", ".join(f"{v['version']}+{v['buildVersion']}" for v in app["versions"]))
PY

cat <<DONE

Done. Nothing was uploaded.

  $ALL/ -> $BASE_URL
      whole directory; its manifest references the older IPAs too
  $LATEST/ -> $LATEST_BASE_URL
      this build alone$([[ $LATEST_BASE_URL == "$BASE_URL" ]] && echo "; overwrites the manifest above, so no --delete")

Note: AltStore re-signs on install and has to reproduce the shared App Group
container. If the app installs but cannot log in, or dies on launch, that is the
first suspect — the auth cookie store lives in it. See BUILDING.md.
DONE
