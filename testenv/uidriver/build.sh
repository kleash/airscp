#!/bin/bash
# Builds the GUI test tools into testenv/.uidriver (gitignored): the `ui` command and "Porter Screenshot.app".
# Rebuilding the app changes its signature, so macOS asks for Screen Recording again; build once and keep it.
set -euo pipefail
cd "$(dirname "$0")"
out=../.uidriver
mkdir -p "$out"
swiftc -O -o "$out/ui" ui.swift
app="$out/Porter Screenshot.app"
if [[ ! -x $app/Contents/MacOS/screenshot || ${1:-} == --force ]]; then
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    swiftc -O -o "$app/Contents/MacOS/screenshot" screenshot.swift
    cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sa.porter.screenshot</string>
<key>CFBundleName</key><string>Porter Screenshot</string>
<key>CFBundleExecutable</key><string>screenshot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.1</string>
</dict></plist>
PLIST
    codesign --force --sign - --identifier com.sa.porter.screenshot "$app"
fi
echo "Built $out/ui and $app"
