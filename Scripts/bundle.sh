#!/bin/bash
# Packs the SwiftPM executable into build/MyHub.app and signs it.
#
#   Scripts/bundle.sh           optimised build
#   Scripts/bundle.sh debug     debug build
#
# Signing identity, first match wins:
#   1. $CODESIGN_IDENTITY
#   2. the first "Apple Development" certificate in the keychain — a stable
#      identity, so macOS remembers Keychain "Always Allow" between builds
#   3. ad-hoc ("-"), which is new on every build
. "$(dirname -- "$0")/common.sh"

configuration="${1:-release}"

identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development:/ { print $2; exit }')"
fi
identity="${identity:--}"

step "compiling ($configuration)"
swift build --package-path "$PROJECT" --configuration "$configuration"
binary="$(swift build --package-path "$PROJECT" --configuration "$configuration" --show-bin-path)/MyHub"

step "laying out $(basename "$APP")"
rm -rf "$APP"
install -d "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$binary" "$APP/Contents/MacOS/MyHub"

plist="$APP/Contents/Info.plist"
cp "$PROJECT/Resources/Info.plist" "$plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
plutil -replace CFBundleVersion -string "$VERSION" "$plist"
plutil -replace NSHumanReadableCopyright -string "© $(date +%Y) orazz" "$plist"
plutil -lint -s "$plist"

shopt -s nullglob
for resource in "$PROJECT"/Resources/AppIcon.icns "$PROJECT"/Resources/*.lproj "$PROJECT"/Resources/*.json; do
    cp -R "$resource" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Files under iCloud Drive pick up extended attributes codesign rejects.
xattr -rc "$APP"

if [[ "$identity" == "-" ]]; then
    step "signing ad-hoc"
    codesign --sign - --force "$APP"
else
    step "signing with \"$identity\" + hardened runtime"
    codesign --sign "$identity" --force --timestamp --options runtime \
        --entitlements "$PROJECT/Resources/MyHub.entitlements" "$APP"
fi
codesign --verify --strict "$APP"

step "ready: $APP"
