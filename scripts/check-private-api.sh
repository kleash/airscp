#!/bin/bash
# Checks that a build of AirSCP uses public API only, as App Review's scan does (scripts/release-appstore.sh, ci.yml):
#   scripts/check-private-api.sh build/appstore/AirSCP.app
# - no framework from /System/Library/PrivateFrameworks is linked;
# - no Objective-C class whose name starts with "_" (Apple's private classes; Swift's own are _Tt…) is used;
# - no CoreGraphics or SkyLight window-server call (CGS…, SLS…) is used;
# - none of the private names below is anywhere in the binary: those the Developer ID version uses (agent control's
#   AXEnhancedUserInterface, its screenshots' key and main appearance), left out of the App Store version.
set -euo pipefail

target=${1:?usage: $0 <AirSCP.app or its binary>}
bin=$target
[ -d "$target" ] && bin=$target/Contents/MacOS/AirSCP
# The scans below find nothing in a file that isn't there.
[ -f "$bin" ] || { echo "No binary at $bin." >&2; exit 2; }
private_names='AXEnhancedUserInterface|acquireKeyAppearance|acquireMainAppearance|resignKeyAppearance|resignMainAppearance'

found=$(
    otool -L "$bin" | awk 'NR > 1 {print "linked: " $1}' | grep /PrivateFrameworks/ || true
    nm -um "$bin" | grep -oE '_OBJC_CLASS_\$__[A-Za-z0-9_]+' | grep -v '_OBJC_CLASS_\$__Tt' | sed 's/^/private class: /' || true
    nm -um "$bin" | grep -oE ' _(CGS|SLS)[A-Za-z0-9_]+' | sed 's/^ /window server call: /' || true
    strings -a "$bin" | grep -oE "$private_names" | sort -u | sed 's/^/private name: /' || true
)
if [ -n "$found" ]; then
    echo "$found" >&2
    echo "$bin uses private API (above): App Review rejects it." >&2
    exit 1
fi
echo "No private API found in $bin."
