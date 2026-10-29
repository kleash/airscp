#!/bin/bash
# Builds build/AirSCP.app and ad-hoc signs it.
#   ./build.sh            universal: arm64 + x86_64
#   ./build.sh --native   host architecture only (fast dev loop)
#   ./build.sh --appstore the Mac App Store version (App Sandbox; Swift's APPSTORE condition picks its differences) as
#                         build/appstore/AirSCP.app, signed ad hoc with Resources/AirSCP-AppStore.entitlements; with
#                         --native too for a quick one. scripts/release-appstore.sh signs it for Apple.
set -euo pipefail
cd "$(dirname "$0")"

archs=(arm64 x86_64) appstore=false
for arg in "$@"; do
    case $arg in
        --native) archs=("$(uname -m)") ;;
        --appstore) appstore=true ;;
        *) echo "usage: $0 [--native] [--appstore]" >&2; exit 2 ;;
    esac
done

version=$(tr -d '[:space:]' < VERSION)
app=build/AirSCP.app
flags=() sign=()
if $appstore; then
    # Its own build folder, so that switching between the two versions doesn't rebuild everything each time.
    app=build/appstore/AirSCP.app
    flags=(-Xswiftc -DAPPSTORE --scratch-path .build/appstore)
    sign=(--entitlements Resources/AirSCP-AppStore.entitlements)
fi

# The RDP client's library (FreeRDP and OpenSSL): made by the first build, and again when scripts/build-freerdp.sh
# changes (versions, options). It downloads and builds them, which takes a few minutes and, the first time, the internet.
[ "$(cat vendor/out/stamp 2>/dev/null)" = "$(shasum -a 256 scripts/build-freerdp.sh | cut -d' ' -f1)" ] || scripts/build-freerdp.sh

# App Intents (Shortcuts, Siri, Spotlight): their metadata comes from Xcode's processor and the compiler's
# constant values. With the Command Line Tools alone the app builds without it, and Shortcuts doesn't list AirSCP.
intents=$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)
mkdir -p build
if [ -n "$intents" ]; then
    printf '%s' '["AppIntent","EntityQuery","EntityStringQuery","EntityPropertyQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","IndexedEntity","OpenIntent","SetValueIntent","ControlConfigurationIntent"]' \
        > build/intent-protocols.json
    flags+=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc
            "$PWD/build/intent-protocols.json")
fi

# `swift build --arch` needs Xcode's build system; per-triple builds + lipo work with CLT alone.
bins=()
for arch in "${archs[@]}"; do
    triple=$arch-apple-macosx13.1
    swift build -c release --triple "$triple" ${flags[@]+"${flags[@]}"}
    bin=$(swift build -c release --triple "$triple" ${flags[@]+"${flags[@]}"} --show-bin-path)
    bins+=("$bin/AirSCP")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${bins[@]}" -output "$app/Contents/MacOS/AirSCP"
cp Resources/AirSCP-Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp -R Resources/Licenses "$app/Contents/Resources/"  # FreeRDP's and OpenSSL's (Apache 2.0), and FreeRDP's notices
cp Resources/AgentGuide.md "$app/Contents/Resources/"  # served by AirSCP --mcp (instructions, the guide tool)
if $appstore; then
    # Its privacy manifest and no Apple Events (its sandbox has no Terminal or iTerm hand-off). No
    # ITSAppUsesNonExemptEncryption: App Store Connect asks about encryption for each build (docs/dev/release.md).
    cp Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
    plutil -remove NSAppleEventsUsageDescription "$app/Contents/Info.plist"
    # What an Xcode build records of the SDK and Xcode it used, which App Store Connect checks (Xcode's swift builds it).
    if xcodebuild -version >/dev/null 2>&1; then
        sdk=$(xcrun --show-sdk-version) sdk_build=$(xcrun --show-sdk-build-version)
        xcode=$(xcodebuild -version | awk '/^Xcode/ {split($2, v, "."); printf "%d%d%d", v[1], v[2], v[3]}')
        xcode_build=$(xcodebuild -version | awk '/Build version/ {print $3}')
        for pair in DTPlatformName=macosx DTPlatformVersion="$sdk" DTPlatformBuild="$sdk_build" DTSDKName="macosx$sdk" \
                    DTSDKBuild="$sdk_build" DTXcode="$xcode" DTXcodeBuild="$xcode_build" \
                    DTCompiler=com.apple.compilers.llvm.clang.1_0 BuildMachineOSBuild="$(sw_vers -buildVersion)"; do
            plutil -insert "${pair%%=*}" -string "${pair#*=}" "$app/Contents/Info.plist"
        done
        plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$app/Contents/Info.plist"
    fi
fi

if [ -n "$intents" ]; then
    work=build/intents
    rm -rf "$work"
    mkdir -p "$work"
    ls "$PWD"/Sources/AirSCP/*.swift > "$work/sources"
    echo "$(dirname "${bins[0]}")/AirSCP.build/AirSCP.swiftconstvalues" > "$work/constants"
    : > "$work/none"
    "$intents" --output "$app/Contents/Resources" --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name AirSCP --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
        --platform-family macOS --deployment-target 13.1 --target-triple "${archs[0]}-apple-macosx13.1" \
        --source-file-list "$work/sources" --swift-const-vals-list "$work/constants" --metadata-file-list "$work/none" \
        --static-metadata-file-list "$work/none" --binary-file "$app/Contents/MacOS/AirSCP" --dependency-file "$work/dependencies.d" \
        --stringsdata-file "$work/shortcuts.stringsdata" --deployment-aware-processing --no-app-shortcuts-localization --force \
        > "$work/log" 2>&1 || { cat "$work/log" >&2; exit 1; }
else
    echo "No Xcode: the app has no App Intents metadata, so Shortcuts won't list AirSCP's actions." >&2
fi

codesign --force --sign - ${sign[@]+"${sign[@]}"} "$app"
codesign --verify --deep --strict "$app"
# codesign signs without entitlements it can't parse (an XML comment holding "--" does that), and says so only in passing.
if $appstore && ! codesign -d --entitlements - "$app" 2>/dev/null | grep -q com.apple.security.app-sandbox; then
    echo "The App Store version's signature has no App Sandbox: check Resources/AirSCP-AppStore.entitlements." >&2
    exit 1
fi
echo "Built $app $version (${archs[*]})"
