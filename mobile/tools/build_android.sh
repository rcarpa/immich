#!/usr/bin/env bash
#
# Build Mirrich for Android.
#
#   --apk     (default) one universal APK.
#   --split   APKs per ABI, about a third of the size each.
#   --bundle  an .aab for Play.
#   --compact one architecture and compressed libraries: about 180 MB down to under 50.
#
# Output goes to dist_android/ (--out to change), laid out like the iOS routes:
#   all/     every build so far. Rsync it whole.
#   latest/  this build as Mirrich.apk. Rsync it WITHOUT --delete.
#
# Signing is upstream's: android/key.jks plus android/key.properties, or the ALIAS / ANDROID_KEY_PASSWORD /
# ANDROID_STORE_PASSWORD variables (BUILDING.md §7.2). Without a keystore the debug key is used, and the script warns.
#
#   ./tools/build_android.sh [--apk|--split|--bundle] [--build-number N] [--out DIR]
#       [--env FILE] [--skip-checkout] [--skip-analyze]
#
# Every run gets a fresh build number, `YYjjjHHMM` (year, day of year, hour, minute): Android's versionCode is capped at
# 2100000000, which `YYYYmmddHHMM` and `YYmmddHHMM` exceed, and this stays under it until 2100.

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
    -h|--help)        awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

[[ -f $ENV_FILE ]] && { set -a; . "$ENV_FILE"; set +a; }

OUT_DIR="${OUT_DIR:-dist_android}"

# --------------------------------------------------------------------------- The JDK, named explicitly: Flutter prefers
# Android Studio's bundled one, which is newer than Gradle accepts.
# ---------------------------------------------------------------------------

# The pinned toolchain, installed if missing, since every dart/flutter call goes through `mise exec`.
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

# --------------------------------------------------------------------------- Identity. Without one set, the build
# claims upstream's application id. ---------------------------------------------------------------------------
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

# Keystore passwords are prompted for (not echoed, not on the command line) and passed through the environment.
# `--no-daemon` below, because a running daemon keeps the environment it started with.
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

# The build is stamped with the numeric core of the pubspec version, as on iOS; file names keep the full string.
VERSION_FULL=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\)+.*$/\1/p' pubspec.yaml)
[[ -n $VERSION_FULL ]] || { echo "error: could not parse 'version: X.Y.Z[-PRERELEASE]+BUILD' from pubspec.yaml" >&2; exit 1; }
BUILD_NAME=${VERSION_FULL%%-*}
[[ $BUILD_NAME =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "error: '$BUILD_NAME' from pubspec.yaml is not an X.Y.Z version" >&2; exit 1; }
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%j%H%M)}"

echo "==> Building $VERSION_FULL ($BUILD_NUMBER) — $ROUTE"

STAMP=(--build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER")

# --compact: one ABI, and native libraries compressed in the APK, which is most of the saving. No `--obfuscate`: it
# saves about 1 MB and costs crash reports their stack traces.
if [[ $COMPACT -eq 1 ]]; then
  STAMP+=(--target-platform android-arm64 -PmirrichCompactLibs=true)
  echo "==> Compact: arm64-v8a only, native libraries compressed"
fi

mkdir -p "$OUT_DIR/all" "$OUT_DIR/latest"
rm -f "$OUT_DIR/latest"/*

# One Gradle invocation per run: building splits and then a universal APK into one directory breaks R8.
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
