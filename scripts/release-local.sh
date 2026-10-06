#!/bin/bash
# Makes AirSCP's release (PLAN.md AB.1): the universal app signed with the Developer ID and the hardened runtime,
# notarized and stapled, as build/AirSCP-<version>.zip with build/AirSCP-<version>.zip.sha256; then checks it the way
# Gatekeeper will.
#   scripts/release-local.sh           the Keychain's "Developer ID Application" identity, notarytool profile airscp-notary
#   scripts/release-local.sh --adhoc   an ad-hoc signature with the hardened runtime, not notarized: tries the hardened
#                                      runtime without a Developer ID (never for a release)
# One-time setup: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application, then
#   xcrun notarytool store-credentials airscp-notary --apple-id <Apple ID> --team-id <team ID>
# release.yml runs this too, with the identity in a temporary keychain and an App Store Connect API key instead of the
# profile (NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER). AIRSCP_SIGN_IDENTITY picks an identity by name.
set -euo pipefail
cd "$(dirname "$0")/.."

adhoc=false
case "${1:-}" in
    "") ;;
    --adhoc) adhoc=true ;;
    *) echo "usage: $0 [--adhoc]" >&2; exit 2 ;;
esac
version=$(tr -d '[:space:]' < VERSION)
app=build/AirSCP.app
zip=build/AirSCP-$version.zip

if $adhoc; then
    identity=- timestamp=--timestamp=none
else
    identity=${AIRSCP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}
    if [ -z "$identity" ]; then
        echo "No \"Developer ID Application\" identity in the Keychain: see the top of $0 (--adhoc tries the hardened" >&2
        echo "runtime without one)." >&2
        exit 1
    fi
    timestamp=--timestamp
    notary=(--keychain-profile airscp-notary)
    if [ -n "${NOTARY_KEY_ID:-}" ]; then notary=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"); fi
fi

./build.sh
# build.sh signs ad hoc; the release signature adds the hardened runtime and its one entitlement.
codesign --force --options runtime --entitlements Resources/AirSCP.entitlements "$timestamp" --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

if ! $adhoc; then
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    echo "Notarizing (a few minutes)..."
    result=$(xcrun notarytool submit "$zip" "${notary[@]}" --wait --output-format json)
    echo "$result"
    if ! grep -Eq '"status" *: *"Accepted"' <<< "$result"; then
        id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<< "$result")
        [ -n "$id" ] && xcrun notarytool log "$id" "${notary[@]}" >&2
        echo "Notarization wasn't accepted (Apple's log above)." >&2
        exit 1
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"
fi

# The zip people download: the (stapled) app, with its signature intact.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
(cd build && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
codesign --display --entitlements - "$app" 2>/dev/null | grep -q automation.apple-events \
    || { echo "The app's signature lacks its entitlement." >&2; exit 1; }
if $adhoc; then
    echo "Built $zip: ad-hoc signed with the hardened runtime, NOT notarized (for trying it out only)."
else
    echo "Built $zip: Developer ID signed, notarized and stapled. SHA-256: $(cut -d' ' -f1 "$zip.sha256")"
    echo "Release it: gh release create v$version $zip $zip.sha256 --title \"AirSCP $version\" --notes-file <notes>"
fi
