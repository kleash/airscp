#!/bin/bash
# Makes AirSCP's Mac App Store upload: the universal App Store version (./build.sh --appstore) signed with the "Apple
# Distribution" identity and the Mac App Store provisioning profile, packed as build/appstore/AirSCP-<version>.pkg
# signed with the installer identity, checked by Apple (altool --validate-app) and uploaded (altool --upload-package).
#   scripts/release-appstore.sh              all of it
#   scripts/release-appstore.sh --no-upload  all but the upload
#   scripts/release-appstore.sh --adhoc      what needs nothing from Apple: the build, its entitlements, the private API
#                                            scan, Info.plist, privacy manifest and icon, an unsigned package's layout
# Needs, except with --adhoc (docs/dev/release.md, "Mac App Store"):
#   AIRSCP_APPSTORE_PROFILE   the Mac App Store provisioning profile of com.kleash.airscp (.provisionprofile)
#   APPSTORE_KEY_ID, APPSTORE_ISSUER   an App Store Connect API key; its AuthKey_<id>.p8 in
#                             ~/.appstoreconnect/private_keys, or APPSTORE_KEY_PATH
#   the "Apple Distribution" and "3rd Party Mac Developer Installer" (or "Mac Installer Distribution") identities in the
#   Keychain; AIRSCP_APPSTORE_IDENTITY and AIRSCP_INSTALLER_IDENTITY pick others by name.
#   AIRSCP_BUILD_NUMBER       CFBundleVersion when the same version goes up again (App Store Connect takes each once)
set -euo pipefail
cd "$(dirname "$0")/.."

adhoc=false upload=true
case "${1:-}" in
    "") ;;
    --adhoc) adhoc=true upload=false ;;
    --no-upload) upload=false ;;
    *) echo "usage: $0 [--adhoc | --no-upload]" >&2; exit 2 ;;
esac
fail() { echo "$*" >&2; exit 1; }
version=$(tr -d '[:space:]' < VERSION)
app=build/appstore/AirSCP.app
pkg=build/appstore/AirSCP-$version.pkg
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! $adhoc; then
    identity=${AIRSCP_APPSTORE_IDENTITY:-$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Distribution: [^"]*\)".*/\1/p' | head -n 1)}
    installer=${AIRSCP_INSTALLER_IDENTITY:-$(security find-identity -v \
        | sed -n 's/.*"\(3rd Party Mac Developer Installer: [^"]*\)".*/\1/p; s/.*"\(Mac Installer Distribution: [^"]*\)".*/\1/p' | head -n 1)}
    [ -n "$identity" ] || fail "No \"Apple Distribution\" identity in the Keychain: see docs/dev/release.md."
    [ -n "$installer" ] || fail "No \"3rd Party Mac Developer Installer\" (or \"Mac Installer Distribution\") identity in the Keychain."
    [ -f "${AIRSCP_APPSTORE_PROFILE:-}" ] || fail "AIRSCP_APPSTORE_PROFILE must name the Mac App Store provisioning profile."
    [ -n "${APPSTORE_KEY_ID:-}" ] && [ -n "${APPSTORE_ISSUER:-}" ] || fail "APPSTORE_KEY_ID and APPSTORE_ISSUER: an App Store Connect API key."
    auth=(--apiKey "$APPSTORE_KEY_ID" --apiIssuer "$APPSTORE_ISSUER")
    if [ -n "${APPSTORE_KEY_PATH:-}" ]; then auth+=(--p8-file-path "$APPSTORE_KEY_PATH"); fi
fi

./build.sh --appstore
plutil -replace CFBundleVersion -string "${AIRSCP_BUILD_NUMBER:-$version}" "$app/Contents/Info.plist"

# The signature: ad hoc, or Apple Distribution with the profile, whose application and team identifiers go into the
# entitlements as Xcode would put them.
entitlements=Resources/AirSCP-AppStore.entitlements
if $adhoc; then
    identity=-
else
    security cms -D -i "$AIRSCP_APPSTORE_PROFILE" > "$work/profile.plist"
    appid=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$work/profile.plist")
    team=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$work/profile.plist")
    [ "$appid" = "$team.com.kleash.airscp" ] || fail "The profile is for $appid, not $team.com.kleash.airscp."
    cp "$entitlements" "$work/entitlements.plist"
    entitlements=$work/entitlements.plist
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $appid" \
        -c "Add :com.apple.developer.team-identifier string $team" "$entitlements"
    cp "$AIRSCP_APPSTORE_PROFILE" "$app/Contents/embedded.provisionprofile"
fi
codesign --force --options runtime --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# What App Store Connect and App Review look at.
codesign -d --entitlements - --xml "$app" 2>/dev/null > "$work/signed.plist"
for key in app-sandbox network.client network.server files.user-selected.read-write files.bookmarks.app-scope \
           files.downloads.read-write; do
    [ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.$key" "$work/signed.plist" 2>/dev/null)" = true ] \
        || fail "The signature lacks com.apple.security.$key."
done
! grep -q temporary-exception "$work/signed.plist" || fail "The signature has a temporary exception: App Review rejects those."
scripts/check-private-api.sh "$app"
plist=$app/Contents/Info.plist
plutil -lint "$plist" "$app/Contents/Resources/PrivacyInfo.xcprivacy"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }
[ "$(read_plist CFBundleIdentifier)" = com.kleash.airscp ] || fail "The bundle id isn't com.kleash.airscp."
[ "$(read_plist CFBundleShortVersionString)" = "$version" ] || fail "CFBundleShortVersionString isn't $version."
[ "$(read_plist LSApplicationCategoryType)" = public.app-category.developer-tools ] || fail "No LSApplicationCategoryType."
[ -n "$(read_plist LSMinimumSystemVersion)" ] || fail "No LSMinimumSystemVersion."
[ -n "$(read_plist ITSAppUsesNonExemptEncryption)" ] || fail "No ITSAppUsesNonExemptEncryption (export compliance)."
[ -z "$(read_plist NSAppleEventsUsageDescription)" ] || fail "NSAppleEventsUsageDescription: the App Store version sends no Apple Events."
[ "$(lipo -archs "$app/Contents/MacOS/AirSCP")" = "x86_64 arm64" ] || fail "The app isn't universal."
iconutil -c iconset -o "$work/icon.iconset" "$app/Contents/Resources/AppIcon.icns"
[ "$(sips -g pixelWidth "$work/icon.iconset/icon_512x512@2x.png" | awk '/pixelWidth/ {print $2}')" = 1024 ] \
    || fail "The icon has no 1024-pixel image (512 × 512 @2x)."

# The package: the app installed in /Applications.
rm -f "$pkg"
if $adhoc; then productbuild --component "$app" /Applications "$pkg"; else
    productbuild --component "$app" /Applications --sign "$installer" "$pkg"
    pkgutil --check-signature "$pkg"
fi
pkgutil --expand "$pkg" "$work/pkg"
component=$(find "$work/pkg" -maxdepth 1 -name '*.pkg' | head -n 1)
grep -q 'install-location="/Applications"' "$component/PackageInfo" || fail "The package doesn't install into /Applications."
(cd "$work" && gzip -dc "$component/Payload" | cpio -it 2>/dev/null) | grep -qx './AirSCP.app/Contents/MacOS/AirSCP' \
    || fail "The package holds no AirSCP.app."

if $adhoc; then
    echo "Checked $app and $pkg: ad-hoc signed and unsigned, never for an upload."
    exit 0
fi
xcrun altool --validate-app "$pkg" -t macos "${auth[@]}"
if $upload; then
    xcrun altool --upload-package "$pkg" -t macos "${auth[@]}"
    echo "Uploaded $pkg: App Store Connect ▸ AirSCP ▸ TestFlight shows the build once Apple has processed it."
else
    echo "Built and validated $pkg (not uploaded)."
fi
