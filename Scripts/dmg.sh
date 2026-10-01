#!/bin/bash
# Makes build/MyHub-<version>.dmg: the app next to a link to /Applications.
# Signed too when $CODESIGN_IDENTITY is a Developer ID certificate.
. "$(dirname -- "$0")/common.sh"

image="$OUT/MyHub-$VERSION.dmg"
staging="$OUT/dmg-staging"

"$PROJECT/Scripts/bundle.sh" release

step "staging"
rm -rf "$staging" "$image"
mkdir -p "$staging"
ditto "$APP" "$staging/MyHub.app"
ln -s /Applications "$staging/Applications"

step "writing $(basename "$image")"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "MyHub $VERSION" -srcfolder "$staging" "$image"
rm -rf "$staging"

case "${CODESIGN_IDENTITY:-}" in
    "Developer ID"*) codesign --sign "$CODESIGN_IDENTITY" --timestamp --force "$image" ;;
esac
step "ready: $image"
