#!/usr/bin/env bash
# Builds "Video Diary.app" into ./build.
#
#   ./scripts/build-app.sh                 # release build for this Mac
#   UNIVERSAL=1 ./scripts/build-app.sh     # Apple silicon + Intel
#   GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... ./scripts/build-app.sh
#       bakes your OAuth client into the app so onboarding skips that step.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Video Diary"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VideoDiary" "$APP/Contents/MacOS/VideoDiary"
cp Resources/Info.plist "$APP/Contents/Info.plist"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${GOOGLE_CLIENT_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :GoogleClientID $GOOGLE_CLIENT_ID" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :GoogleClientSecret ${GOOGLE_CLIENT_SECRET:-}" "$PLIST"
  echo "  baked in Google OAuth client"
fi

echo "▸ Generating icon"
ICON_TMP="$(mktemp -d)"
swift scripts/make-icon.swift "$ICON_TMP/icon_1024.png"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

echo "▸ Signing (ad-hoc)"
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP"

echo "✓ Built $APP"
echo "  Run it with: open \"$APP\""
