#!/bin/sh
# Build WindowShift.app without Xcode (SwiftPM + manual bundle assembly).
#   ./build.sh         build dist/WindowShift.app + dist/WindowShift-<ver>.dmg
#   ./build.sh run     build and launch the app
#   ./build.sh clean   remove build products
set -eu
cd "$(dirname "$0")"

APP_NAME=WindowShift
BUNDLE_ID=dev.nwf.WindowShift
APP=dist/$APP_NAME.app

if [ "${1:-}" = "clean" ]; then
    rm -rf .build dist
    echo "cleaned"
    exit 0
fi

swift build -c release

# A real .app bundle with a signature keeps the Accessibility (TCC) grant
# attached to the app across launches.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Sign with a stable identity so the Accessibility (TCC) grant survives
# rebuilds. Preference: $CODESIGN_IDENTITY, else the first Apple Development
# certificate in the keychain (stable cert-anchored designated requirement),
# else ad-hoc with a pinned identifier-based designated requirement (plain
# ad-hoc DRs are per-build cdhashes, which is why grants used to break).
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ {print $2; exit}')}
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    codesign --force --sign - --identifier "$BUNDLE_ID" \
        --requirements '=designated => identifier "'"$BUNDLE_ID"'"' "$APP"
fi
echo "Built $APP (signed: ${IDENTITY:-ad-hoc+pinned-requirement})"

# Distributable disk image: the app plus an /Applications symlink for
# drag-install, compressed (UDZO). Rebuilt on every build.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 0.0.0)
DMG="dist/$APP_NAME-$VERSION.dmg"
rm -f dist/"$APP_NAME"-*.dmg
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "Built $DMG"

if [ "${1:-}" = "run" ]; then
    open "$APP"
fi
