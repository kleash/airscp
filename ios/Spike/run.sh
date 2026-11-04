#!/bin/bash
# Phase 0 spike: builds ssh2spike for the Mac and the iOS Simulator against vendor/ssh2/CSSH2.xcframework and runs
# both against the Docker lab (testenv/up.sh), on an iOS 26 iPhone simulator. Boots one only if none is booted, and
# shuts down what it boots.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -d vendor/ssh2/CSSH2.xcframework ] || scripts/build-libssh2.sh
xcf=vendor/ssh2/CSSH2.xcframework
out=.build/ssh2spike
mkdir -p "$out"

# The macOS slice is libssh2 alone: OpenSSL comes from FreeRDP's library, as in the Mac tests.
swiftc -O ios/Spike/ssh2spike.swift -target arm64-apple-macos13.1 \
    -I $xcf/macos-arm64/Headers -L $xcf/macos-arm64 -lairscp-ssh2 -L vendor/out/universal/lib -lairscp-rdp \
    -o "$out/ssh2spike-mac"
swiftc -O ios/Spike/ssh2spike.swift -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios26.0-simulator \
    -I $xcf/ios-arm64-simulator/Headers -L $xcf/ios-arm64-simulator -lairscp-ssh2 -o "$out/ssh2spike-sim"

# The lab's host keys, read from the servers themselves (nothing from ~/.ssh).
fps=$(ssh-keyscan -p 42201 127.0.0.1 2> /dev/null | ssh-keygen -lf - | awk '{print $2}' | paste -sd, -)
key=$PWD/testenv/.keys/id_lab

echo "== Mac (macos-arm64)"
mac=0; "$out/ssh2spike-mac" "$key" "$fps" || mac=$?

echo "== iOS Simulator (ios-arm64-simulator)"
booted=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=[x["udid"] for k,v in json.load(sys.stdin)["devices"].items() if "iOS-26" in k for x in v]; print(d[0] if d else "")')
started=""
if [ -z "$booted" ]; then
    booted=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=[x["udid"] for k,v in json.load(sys.stdin)["devices"].items() if "iOS-26" in k for x in v if x["name"].startswith("iPhone")]; print(d[-1])')
    xcrun simctl boot "$booted"; started=$booted
fi
sim=0; xcrun simctl spawn "$booted" "$PWD/$out/ssh2spike-sim" "$key" "$fps" || sim=$?
[ -n "$started" ] && xcrun simctl shutdown "$started"
echo "Mac failures: $mac, Simulator failures: $sim"
exit $((mac + sim))
