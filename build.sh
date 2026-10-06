#!/bin/bash
# Builds build/AirSCP.app and ad-hoc signs it.
#   ./build.sh           universal: arm64 + x86_64
#   ./build.sh --native  host architecture only (fast dev loop)
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
    "") archs=(arm64 x86_64) ;;
    --native) archs=("$(uname -m)") ;;
    *) echo "usage: $0 [--native]" >&2; exit 2 ;;
esac

version=$(tr -d '[:space:]' < VERSION)
app=build/AirSCP.app

# The RDP client's library (FreeRDP and OpenSSL): made by the first build, and again when scripts/build-freerdp.sh
# changes (versions, options). It downloads and builds them, which takes a few minutes and, the first time, the internet.
[ "$(cat vendor/out/stamp 2>/dev/null)" = "$(shasum -a 256 scripts/build-freerdp.sh | cut -d' ' -f1)" ] || scripts/build-freerdp.sh

# `swift build --arch` needs Xcode's build system; per-triple builds + lipo work with CLT alone.
bins=()
for arch in "${archs[@]}"; do
    triple=$arch-apple-macosx13.1
    swift build -c release --triple "$triple"
    bin=$(swift build -c release --triple "$triple" --show-bin-path)
    bins+=("$bin/AirSCP")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${bins[@]}" -output "$app/Contents/MacOS/AirSCP"
cp Resources/AirSCP-Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp -R Resources/Licenses "$app/Contents/Resources/"  # FreeRDP's and OpenSSL's (Apache 2.0)
cp Resources/AgentGuide.md "$app/Contents/Resources/"  # served by AirSCP --mcp (instructions, the guide tool)

codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app $version (${archs[*]})"
