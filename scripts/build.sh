#!/bin/bash
# Builds "Qwen Reader.app" into ./build.
#
#   ./scripts/build.sh            build the app
#   ./scripts/build.sh --install  also copy it to ~/Applications and launch it
#   ./scripts/build.sh --zip      also make build/Qwen-Reader-<version>.zip for sharing
#
# xcodebuild is required (not `swift build`) because MLX's Metal shaders are only compiled by Xcode.
#
# Signing uses your "Apple Development" certificate when you have one, so macOS keeps the
# Accessibility permission across rebuilds, and falls back to ad-hoc signing. Set CODESIGN_IDENTITY
# to choose another, such as a "Developer ID Application" certificate for a release.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Qwen Reader"
EXECUTABLE="QwenReader"
CONFIGURATION="Release"
DERIVED_DATA=".build/xcode"
PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP="build/$APP_NAME.app"

INSTALL=false
ZIP=false
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=true ;;
        --zip) ZIP=true ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done

echo "==> Building $EXECUTABLE ($CONFIGURATION)"
xcodebuild build \
    -scheme "$EXECUTABLE" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/$EXECUTABLE" "$APP/Contents/MacOS/"
cp App/Info.plist "$APP/Contents/"
cp App/AppIcon.icns "$APP/Contents/Resources/"
# SwiftPM resource bundles, including mlx-swift_Cmlx.bundle which holds MLX's compiled Metal library.
for bundle in "$PRODUCTS"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
# Notarization needs a secure timestamp, which only a Developer ID signature can have.
TIMESTAMP="--timestamp=none"
if [[ "$IDENTITY" == "Developer ID"* ]]; then
    TIMESTAMP="--timestamp"
fi
echo "==> Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" --options runtime --entitlements App/QwenReader.entitlements "$TIMESTAMP" "$APP"

if $ZIP; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
    ARCHIVE="build/Qwen-Reader-$VERSION.zip"
    echo "==> Zipping to $ARCHIVE"
    rm -f "$ARCHIVE"
    ditto -c -k --keepParent "$APP" "$ARCHIVE"
fi

if $INSTALL; then
    DEST="$HOME/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    pkill -x "$EXECUTABLE" 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    # Register with Launch Services and refresh the Services menu so "Read Aloud with Qwen Reader" appears.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    /System/Library/CoreServices/pbs -update || true
    open "$DEST"
fi

echo "==> Done: $APP"
