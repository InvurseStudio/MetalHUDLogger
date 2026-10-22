#!/bin/bash
# Builds MetalHUD Logger in release mode, wraps it in an .app bundle and signs it.
#
#   ./build.sh               build and sign
#   ./build.sh --zip         also make the release archive
#   ./build.sh --notarize    also notarize with Apple, staple the ticket and make the release archive
#
# Signing uses the first "Developer ID Application" certificate in the keychain (override with
# SIGN_IDENTITY=...), or an ad-hoc signature if there is none. --notarize needs a Developer ID and
# notarytool credentials stored once with:
#   xcrun notarytool store-credentials MetalHUDLogger --apple-id <email> --team-id <team>
# (override the profile name with NOTARY_PROFILE=...).
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
if [[ -n "$MODE" && "$MODE" != "--zip" && "$MODE" != "--notarize" ]]; then
    echo "Unknown option: $MODE (expected --zip or --notarize)" >&2
    exit 1
fi

APP_NAME="MetalHUD Logger"
EXECUTABLE="MetalHUDLogger"
BUNDLE_ID="com.invursestudio.metalhudlogger"
VERSION="1.1"
APP="$APP_NAME.app"
ZIP="MetalHUD-Logger-$VERSION.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-MetalHUDLogger}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ "$MODE" == "--notarize" ]]; then
        echo "Notarization needs a Developer ID Application certificate; none found in the keychain." >&2
        exit 1
    fi
    SIGN_IDENTITY="-"
fi

# Universal binary (Apple Silicon + Intel).
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Hardened runtime and a secure timestamp are required for notarization.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "No Developer ID certificate found; signing ad-hoc (not notarizable)."
    codesign --force --sign - --options runtime --timestamp=none "$APP"
else
    echo "Signing with: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict --verbose "$APP"
# rm -rf + recreate leaves LaunchServices with the old bundle's info (e.g. a missing icon); re-register it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $(pwd)/$APP"

if [[ "$MODE" == "--notarize" ]]; then
    # notarytool takes a zip; the ticket is then stapled to the app itself so it validates offline.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose "$APP"
fi

if [[ "$MODE" == "--zip" || "$MODE" == "--notarize" ]]; then
    # Re-zip after stapling so the archive contains the ticket.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Built $(pwd)/$ZIP"
fi
