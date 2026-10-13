#!/bin/bash
# Runs the Swift Testing suite. Command Line Tools have no XCTest and keep Testing.framework
# outside the default search paths, so point the compiler, linker and rpath at it.
# Extra arguments go to `swift test` (e.g. ./test.sh --filter sftpOnlyAccount).
# AIRSCP_DOCKER=1 ./test.sh also runs the tests against the Docker lab, starting it first (testenv/up.sh;
# testenv/down.sh removes it).
set -euo pipefail
cd "$(dirname "$0")"

version=$(swift --version 2>&1) || true
if [[ ! $version =~ Swift\ version\ ([0-9]+)[0-9.]* ]] || (( BASH_REMATCH[1] < 6 )); then
    echo "The tests use Swift Testing, which needs Swift 6 or later (this Mac has ${BASH_REMATCH[0]:-no Swift})." >&2
    echo "The app itself builds with Swift 5.9 or later: ./build.sh" >&2
    exit 1
fi
# The RDP client's library (FreeRDP and OpenSSL), as build.sh makes it: when missing or its build script changed.
[ "$(cat vendor/out/stamp 2>/dev/null)" = "$(shasum -a 256 scripts/build-freerdp.sh | cut -d' ' -f1)" ] || scripts/build-freerdp.sh
if [[ ${AIRSCP_DOCKER:-${PORTER_DOCKER:-}} == 1 ]]; then
    testenv/up.sh
fi
clt=$(xcode-select -p)
fw=$clt/Library/Developer/Frameworks
il=$clt/Library/Developer/usr/lib
# The run must reach Swift Testing's last line ("✔/✘ Test run with N tests …"): an AppKit call that stops the main
# run loop once ended the test process early with status 0, so tests after it never ran.
log=$(mktemp -t airscp-test)
trap 'rm -f "$log"' EXIT
status=0
swift test \
    -Xswiftc -F -Xswiftc "$fw" \
    -Xlinker -F -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$fw" \
    -Xlinker -rpath -Xlinker "$il" \
    "$@" 2>&1 | tee "$log" || status=$?
if [[ $status == 0 && " $* " != *" list "* && " $* " != *" --list-tests "* ]] && ! grep -qE '^. Test run with [0-9]+ tests? ' "$log"; then
    echo "The test process ended before Swift Testing's summary: a test stopped it (see the last test that started above)." >&2
    status=1
fi
exit $status
