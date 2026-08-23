#!/usr/bin/env bash
#
# Build Mirrich for Android.
#
#   --apk     (default) one universal APK. Sideloadable, and what a self-hosted
#             install page can serve without knowing which phone is asking.
#   --split   APKs per ABI instead — about a third of the size each, but the page
#             offering them has to pick the right one.
#   --bundle  an .aab for Play. Only useful if you are publishing there.
#
#   --compact one architecture and compressed libraries, for serving from somewhere
#             with a size limit. Takes the APK from about 180 MB to under 50.
#
# Output goes to dist_android/ (--out to change), laid out like the iOS routes so
# the same hosting story works:
#   all/     every build so far. Mirrors what the server should hold; rsync it
#            whole.
#   latest/  just this build, as Mirrich.apk with no version in the name.
#            Rewritten every run; rsync it WITHOUT --delete.
#
# Signing is upstream's: android/key.jks plus android/key.properties, or the
# ALIAS / ANDROID_KEY_PASSWORD / ANDROID_STORE_PASSWORD variables (BUILDING.md
# §4). With no keystore, Gradle falls back to the debug key — which installs and
# runs, but a build signed with it can never be upgraded in place by one signed
# properly, so the script says so rather than letting you find out later.
#
#   ./tools/build_android.sh [--apk|--split|--bundle] [--build-number N] [--out DIR]
#       [--env FILE] [--skip-checkout] [--skip-analyze]
#
# Every run gets a fresh build number, so a sideloaded update is seen as newer
# than what is installed. pubspec.yaml is never written to, so the fork's diff
# against upstream stays small.
#
# The stamp is `YYjjjHHMM` — two-digit year, day of the year, hour and minute —
# rather than the `YYYYmmddHHMM` the iOS route uses, and that is not a stylistic
# difference. Android's versionCode is capped at 2100000000, which is ten digits;
# `YYYYmmddHHMM` is twelve and has been about a hundred times too large since the
# year 2000, and Gradle rejects it outright rather than truncating. Dropping the
# century is not enough either: `YYmmddHHMM` reads 2608231548 today, still a
# quarter over the cap, and has been over it since 2021.
#
# Day-of-year buys back the digit that month-and-day wastes. It reads 262351548
# today and tops out at 993662359 in the last minute of 2099, comfortably inside
# the cap, and it rises monotonically the whole way there. Unix seconds would
# also fit, at about 1.8 billion, but only until January 2036.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ROUTE="apk"
COMPACT=0
BUILD_NUMBER=""
OUT_DIR=""
ENV_FILE="tools/android.env"
SKIP_CHECKOUT=0
SKIP_ANALYZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apk)            ROUTE="apk";               shift ;;
    --split)          ROUTE="split";             shift ;;
    --bundle)         ROUTE="bundle";            shift ;;
    --compact)        COMPACT=1;                 shift ;;
    --build-number)   BUILD_NUMBER="${2:?}";     shift 2 ;;
    --out)            OUT_DIR="${2:?}";          shift 2 ;;
    --env)            ENV_FILE="${2:?}";         shift 2 ;;
    --skip-checkout)  SKIP_CHECKOUT=1;           shift ;;
    --skip-analyze)   SKIP_ANALYZE=1;            shift ;;
    -h|--help)        sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

[[ -f $ENV_FILE ]] && { set -a; . "$ENV_FILE"; set +a; }

OUT_DIR="${OUT_DIR:-dist_android}"

# ---------------------------------------------------------------------------
# The JDK, which is the one thing about an Android build that goes wrong quietly
# ---------------------------------------------------------------------------
#
# Flutter picks a JDK for Gradle in this order: `flutter config --jdk-dir`, then
# Android Studio's bundled runtime, then JAVA_HOME, then PATH. Android Studio
# ships a *newer* JDK than Gradle accepts, so on a machine that has Studio
# installed the build fails with "Unsupported class file major version" and says
# nothing about where that JDK came from — exporting JAVA_HOME does not help,
# because Studio's is preferred over it.
#
# So the JDK is named explicitly here. mise installs the one this project pins.

# The pinned toolchain, before the JDK lookup below asks mise for it.
#
# Every dart/flutter call here goes through `mise exec`, so that it is the version `mise.toml` names
# that runs and not whatever a shell happens to have on PATH. That only works once the version is
# installed, and upstream bumps Flutter on its own schedule — 3.44.9 to 3.47.1 inside one release —
# so a machine that last built before a bump does not have it. Unguarded, the failure lands minutes
# later inside `flutter build` as "Because immich_mobile requires Flutter SDK version 3.47.1,
# version solving failed", which names the version it wants and not the one command that supplies
# it.
if ! mise which flutter >/dev/null 2>&1; then
  echo "==> Installing the pinned toolchain (mise install)"
  mise install
fi

if [[ -z ${MIRRICH_JDK:-} ]]; then
  MIRRICH_JDK="$(mise where java 2>/dev/null || true)"
fi
if [[ -n ${MIRRICH_JDK:-} && -x "$MIRRICH_JDK/bin/java" ]]; then
  echo "==> JDK: $MIRRICH_JDK"
  export JAVA_HOME="$MIRRICH_JDK"
  mise exec -- flutter config --jdk-dir "$MIRRICH_JDK" >/dev/null
else
  echo "warning: no pinned JDK found; leaving Flutter to choose one." >&2
  echo "         If the build fails with 'Unsupported class file major version'," >&2
  echo "         that is Android Studio's bundled JDK. Set MIRRICH_JDK to a 21." >&2
fi

# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
#
# There is no forcing function for this on Android the way a Team ID is on iOS, so
# a build that never set it goes out claiming to be Immich — and cannot be
# installed beside upstream's build, or over it.
APP_ID=$(sed -n 's/^[[:space:]]*applicationId[[:space:]]*=[[:space:]]*//p' \
  android/Identity.local.properties android/Identity.properties 2>/dev/null | head -1)
if [[ ${APP_ID:-app.alextran.immich} == app.alextran.immich ]]; then
  echo "warning: this build calls itself 'app.alextran.immich', which is upstream's." >&2
  echo "         It cannot sit beside Immich on a phone, and installing over one" >&2
  echo "         signed differently fails outright. Set applicationId in" >&2
  echo "         android/Identity.local.properties (BUILDING.md §7.1)." >&2
else
  echo "==> Identity: $APP_ID"
fi

SIGNED=0
if [[ -s android/key.jks ]]; then
  SIGNED=1
elif [[ -n ${ANDROID_KEYSTORE:-} ]]; then
  [[ -s $ANDROID_KEYSTORE ]] || { echo "error: ANDROID_KEYSTORE is set but '$ANDROID_KEYSTORE' is empty or missing" >&2; exit 1; }
  cp "$ANDROID_KEYSTORE" android/key.jks
  trap 'rm -f android/key.jks' EXIT
  SIGNED=1
fi

# The passwords, asked for rather than stored.
#
# Gradle reads them from the environment (`android/app/build.gradle`), so they never have to be
# written down: `key.properties` is one way to supply them and this is the other. Prompted here
# rather than passed as `-P`, which would put them in the process list for anything on the machine
# to read, and read with `-s` so they are not echoed and never reach shell history.
#
# The daemon is the reason for `--no-daemon` below. A build script's `System.getenv()` runs inside
# the daemon JVM, which keeps the environment it was *started* with — so a password exported here
# reaches a daemon started before it only by luck. A fresh JVM costs a few seconds and removes the
# question.
if [[ $SIGNED -eq 1 ]]; then
  [[ -n ${ALIAS:-} ]] || { read -r -p "Key alias: " ALIAS; export ALIAS; }
  if [[ -z ${ANDROID_STORE_PASSWORD:-} ]]; then
    read -r -s -p "Keystore password: " ANDROID_STORE_PASSWORD; echo
    export ANDROID_STORE_PASSWORD
  fi
  if [[ -z ${ANDROID_KEY_PASSWORD:-} ]]; then
    read -r -s -p "Key password (blank if same): " ANDROID_KEY_PASSWORD; echo
    export ANDROID_KEY_PASSWORD="${ANDROID_KEY_PASSWORD:-$ANDROID_STORE_PASSWORD}"
  fi
  export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false"
fi

if [[ $SIGNED -eq 0 ]]; then
  echo "warning: no keystore, so Gradle will sign with the debug key." >&2
  echo "         Fine for trying it out. A build signed this way cannot be" >&2
  echo "         upgraded in place by a properly signed one — the install has to" >&2
  echo "         be removed first, taking its offline copies with it." >&2
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if [[ $SKIP_CHECKOUT -eq 0 ]]; then
  echo "==> Generating code (mise run //mobile:checkout)"
  mise run //mobile:checkout
fi

if [[ $SKIP_ANALYZE -eq 0 ]]; then
  echo "==> Analyzing"
  mise exec -- dart analyze --fatal-infos
fi

# Upstream tags pre-releases — `version: 3.2.0-rc.1+3020001` — and the two halves of that go to
# two different places. `CFBundleShortVersionString` must be one to three dot-separated integers or
# the App Store rejects the upload outright, so the numeric core is what a build is *stamped* with,
# on both platforms rather than only the one that insists on it, so that the two report the same
# version. Nothing else would carry the suffix, though, and `all/` exists precisely to tell one
# build from another — an rc and the release it became would otherwise share a file name — so the
# file names take the whole thing.
VERSION_FULL=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\)+.*$/\1/p' pubspec.yaml)
[[ -n $VERSION_FULL ]] || { echo "error: could not parse 'version: X.Y.Z[-PRERELEASE]+BUILD' from pubspec.yaml" >&2; exit 1; }
BUILD_NAME=${VERSION_FULL%%-*}
[[ $BUILD_NAME =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "error: '$BUILD_NAME' from pubspec.yaml is not an X.Y.Z version" >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%j%H%M)}"

echo "==> Building $VERSION_FULL ($BUILD_NUMBER) — $ROUTE"

STAMP=(--build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER")

# Two changes, one decision: this build is for a host that charges by the megabyte.
#
# Almost all of it is the second one. AGP stores native libraries uncompressed so they can be mapped
# straight out of the APK — smaller once installed, a shade faster to start — and for this app that
# is eighty of the ninety-odd megabytes, `.so` files that compress by more than half. Dropping the
# other two architectures halves what is left.
#
# `--obfuscate` is deliberately *not* here. It saves 1.3 MB, because the APK's own compression has
# already crushed the symbol names it strips, and it costs every crash report its stack trace unless
# the exact `build/symbols` of that build is kept forever. For a fork whose source is public it buys
# nothing worth that.
if [[ $COMPACT -eq 1 ]]; then
  STAMP+=(--target-platform android-arm64 -PmirrichCompactLibs=true)
  echo "==> Compact: arm64-v8a only, native libraries compressed"
fi

mkdir -p "$OUT_DIR/all" "$OUT_DIR/latest"
rm -f "$OUT_DIR/latest"/*

# One Gradle invocation per run, and that is not incidental. Building the splits and then the
# universal APK into the same output directory leaves R8 looking for per-ABI linked resources the
# second invocation has just invalidated, and it fails with a bare `NoSuchFileException` naming an
# intermediate. Pick a shape and build it once.
case "$ROUTE" in
  bundle)
    mise exec -- flutter build appbundle --release "${STAMP[@]}"
    SOURCE="build/app/outputs/bundle/release/app-release.aab"
    [[ -f $SOURCE ]] || { echo "error: expected $SOURCE" >&2; exit 1; }
    cp "$SOURCE" "$OUT_DIR/all/Mirrich-$VERSION_FULL-$BUILD_NUMBER.aab"
    cp "$SOURCE" "$OUT_DIR/latest/Mirrich.aab"
    ;;

  split)
    mise exec -- flutter build apk --release --split-per-abi "${STAMP[@]}"
    shopt -s nullglob
    for apk in build/app/outputs/flutter-apk/app-*-release.apk; do
      base=$(basename "$apk")
      abi=${base#app-}
      abi=${abi%-release.apk}
      cp "$apk" "$OUT_DIR/all/Mirrich-$VERSION_FULL-$BUILD_NUMBER-$abi.apk"
      cp "$apk" "$OUT_DIR/latest/Mirrich-$abi.apk"
    done
    shopt -u nullglob
    ;;

  *)
    mise exec -- flutter build apk --release "${STAMP[@]}"
    SOURCE="build/app/outputs/flutter-apk/app-release.apk"
    [[ -f $SOURCE ]] || { echo "error: expected $SOURCE" >&2; exit 1; }
    cp "$SOURCE" "$OUT_DIR/all/Mirrich-$VERSION_FULL-$BUILD_NUMBER.apk"
    cp "$SOURCE" "$OUT_DIR/latest/Mirrich.apk"
    ;;
esac

cat <<EOF

Done. $VERSION_FULL ($BUILD_NUMBER):
  $OUT_DIR/all/      every build so far — rsync whole
  $OUT_DIR/latest/   this build under a stable name — rsync WITHOUT --delete
EOF
if [[ $SIGNED -eq 0 ]]; then
  echo "  (signed with the debug key)"
fi
