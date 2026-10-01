#!/bin/bash
# Sends the DMG to Apple's notary service and staples the ticket, so it opens
# on any Mac without a Gatekeeper warning.
#
# One-time setup:
#   - a "Developer ID Application" certificate in the login keychain (only
#     that kind can be notarized for download outside the App Store);
#   - a saved notarytool login:
#       xcrun notarytool store-credentials myhub-notary \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/notarize.sh
. "$(dirname -- "$0")/common.sh"

case "${CODESIGN_IDENTITY:-}" in
    "Developer ID Application"*) ;;
    *)
        echo "CODESIGN_IDENTITY must name a Developer ID Application certificate. This Mac has:" >&2
        security find-identity -v -p codesigning >&2
        exit 64
        ;;
esac

"$PROJECT/Scripts/dmg.sh"
image="$OUT/MyHub-$VERSION.dmg"

step "notarizing (usually a few minutes)"
xcrun notarytool submit "$image" --keychain-profile "${NOTARY_PROFILE:-myhub-notary}" --wait
xcrun stapler staple "$image"
spctl --assess --type open --context context:primary-signature --verbose "$image"
step "notarized: $image"
