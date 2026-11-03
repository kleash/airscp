#!/bin/bash
# Makes AirSCP's iPhone and iPad upload: ios/AirSCP.xcodeproj archived for the App Store (Release, any iOS device) with
# the version from VERSION, signed automatically (Xcode makes or fetches the Apple Distribution certificate and the
# App Store profile), exported as build/ios/AirSCP.ipa, checked by Apple (altool --validate-app) and uploaded to App
# Store Connect for TestFlight (altool --upload-package).
#   scripts/release-ios.sh              all of it
#   scripts/release-ios.sh --no-upload  all but the upload
# Needs (docs/dev/release.md, "iPhone and iPad (App Store)"):
#   Xcode with the iOS SDK, and vendor/ssh2 (scripts/build-libssh2.sh)
#   DEVELOPMENT_TEAM          the id of the team that signs it
#   APPSTORE_KEY_ID, APPSTORE_ISSUER   an App Store Connect API key; its AuthKey_<id>.p8 in
#                             ~/.appstoreconnect/private_keys, or APPSTORE_KEY_PATH. Xcode signs with it, altool
#                             validates and uploads with it.
#   AIRSCP_BUILD_NUMBER       CFBundleVersion when the same version goes up again (App Store Connect takes each once)
set -euo pipefail
cd "$(dirname "$0")/.."

upload=true
case "${1:-}" in
    "") ;;
    --no-upload) upload=false ;;
    *) echo "usage: $0 [--no-upload]" >&2; exit 2 ;;
esac
fail() { echo "$*" >&2; exit 1; }
version=$(tr -d '[:space:]' < VERSION)
build=${AIRSCP_BUILD_NUMBER:-$version}
out=build/ios
archive=$out/AirSCP.xcarchive
ipa=$out/AirSCP.ipa
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# First what needs nothing from Apple.
[ -n "${DEVELOPMENT_TEAM:-}" ] || fail "DEVELOPMENT_TEAM: the id of the team that signs the app."
[ -n "${APPSTORE_KEY_ID:-}" ] && [ -n "${APPSTORE_ISSUER:-}" ] || fail "APPSTORE_KEY_ID and APPSTORE_ISSUER: an App Store Connect API key."
key=${APPSTORE_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$APPSTORE_KEY_ID.p8}
[ -f "$key" ] || fail "No $key: the API key's file (or APPSTORE_KEY_PATH)."
[ "$(cat vendor/ssh2/stamp 2>/dev/null)" = "$(shasum -a 256 scripts/build-libssh2.sh | cut -d' ' -f1)" ] \
    || fail "vendor/ssh2 is missing or from another scripts/build-libssh2.sh: run that script."
plutil -lint ios/Info.plist ios/AirSCP/PrivacyInfo.xcprivacy
icon=ios/AirSCP/Assets.xcassets/AppIcon.appiconset/AppIcon.png
[ "$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$icon" | awk 'NR > 1 {printf "%s ", $2}')" = "1024 1024 no " ] \
    || fail "$icon must be 1024 × 1024 pixels without alpha: swift scripts/make-icon.swift $icon"

# The archive, signed for development; the export signs it for the App Store.
xcode_auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$APPSTORE_KEY_ID"
            -authenticationKeyIssuerID "$APPSTORE_ISSUER")
rm -rf "$out"
xcodebuild archive -quiet -project ios/AirSCP.xcodeproj -scheme AirSCP -configuration Release \
    -destination generic/platform=iOS -derivedDataPath .build/ios-release -archivePath "$archive" "${xcode_auth[@]}" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build"

# What App Store Connect and App Review look at.
app=$archive/Products/Applications/AirSCP.app
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist" 2>/dev/null; }
[ "$(read_plist CFBundleIdentifier)" = com.kleash.airscp ] || fail "The bundle id isn't com.kleash.airscp."
[ "$(read_plist CFBundleShortVersionString)" = "$version" ] || fail "CFBundleShortVersionString isn't $version."
[ "$(read_plist CFBundleVersion)" = "$build" ] || fail "CFBundleVersion isn't $build."
[ -z "$(read_plist ITSAppUsesNonExemptEncryption)" ] || fail "ITSAppUsesNonExemptEncryption: App Store Connect asks for each build."
[ "$(read_plist CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName)" = AppIcon ] || fail "The app has no icon (AppIcon)."
for usage in NSFaceIDUsageDescription NSLocalNetworkUsageDescription NSPhotoLibraryAddUsageDescription; do
    [ -n "$(read_plist "$usage")" ] || fail "Info.plist lacks $usage."
done
[ -f "$app/PrivacyInfo.xcprivacy" ] || fail "The app has no PrivacyInfo.xcprivacy."
[ "$(lipo -archs "$app/AirSCP")" = arm64 ] || fail "The app isn't arm64 alone."
scripts/check-private-api.sh "$app/AirSCP"

cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$DEVELOPMENT_TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<!-- The build number is VERSION's (or AIRSCP_BUILD_NUMBER), not one Xcode picks. -->
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" -exportOptionsPlist "$work/ExportOptions.plist" \
    "${xcode_auth[@]}"
[ -f "$ipa" ] || fail "The export made no $ipa."
unzip -q "$ipa" -d "$work/ipa"
codesign --verify --deep --strict "$work/ipa/Payload/AirSCP.app"
codesign -d --entitlements - --xml "$work/ipa/Payload/AirSCP.app" 2>/dev/null > "$work/signed.plist"
entitlement() { /usr/libexec/PlistBuddy -c "Print :$1" "$work/signed.plist" 2>/dev/null; }
[ "$(entitlement application-identifier)" = "$DEVELOPMENT_TEAM.com.kleash.airscp" ] \
    || fail "The export is signed for $(entitlement application-identifier), not $DEVELOPMENT_TEAM.com.kleash.airscp."
[ "$(entitlement get-task-allow)" != true ] || fail "The export is signed for development (get-task-allow)."

auth=(--apiKey "$APPSTORE_KEY_ID" --apiIssuer "$APPSTORE_ISSUER")
if [ -n "${APPSTORE_KEY_PATH:-}" ]; then auth+=(--p8-file-path "$APPSTORE_KEY_PATH"); fi
xcrun altool --validate-app "$ipa" -t ios "${auth[@]}"
if $upload; then
    xcrun altool --upload-package "$ipa" -t ios "${auth[@]}"
    echo "Uploaded $ipa: App Store Connect ▸ AirSCP ▸ TestFlight (iOS) shows the build once Apple has processed it."
else
    echo "Built and validated $ipa (not uploaded)."
fi
