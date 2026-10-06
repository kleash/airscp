#!/bin/bash
# Test-only (PLAN.md K.2): builds PuTTY's own puttygen from the official PuTTY source, for the interop tests of
# AirSCP's .ppk import and export (AIRSCP_PUTTY=1 ./test.sh --filter PuTTY). It is never shipped or linked.
#   vendor/puttygen/puttygen   (this Mac's architecture)
# The source (pinned version, SHA-256 checked) and the portable CMake that scripts/build-freerdp.sh downloaded are
# cached in vendor/dl; the build runs in a temporary folder that is removed afterwards. Command Line Tools only:
# nothing from Homebrew. PuTTY is MIT licensed.
set -euo pipefail
cd "$(dirname "$0")/../.."

putty_version=0.85
putty_sha=13fd4db2936d03b73812a7bcc2a658e4dd29cc776a56c3670a7fc6f1a0ee8af8
cmake_version=4.4.3
out=vendor/puttygen
[ -x "$out/puttygen" ] && [ "$(cat "$out/version" 2>/dev/null)" = "$putty_version" ] && exit 0

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH LDFLAGS CFLAGS CPPFLAGS
mkdir -p vendor/dl
source=vendor/dl/putty-$putty_version.tar.gz
if [ ! -f "$source" ] || [ "$(shasum -a 256 "$source" | cut -d' ' -f1)" != "$putty_sha" ]; then
    curl -fL --retry 3 --silent --show-error -o "$source.part" \
        "https://the.earth.li/~sgtatham/putty/$putty_version/putty-$putty_version.tar.gz"
    mv "$source.part" "$source"
fi
if [ "$(shasum -a 256 "$source" | cut -d' ' -f1)" != "$putty_sha" ]; then
    echo "build-puttygen: $source does not have the expected SHA-256; not using it." >&2
    rm -f "$source"
    exit 1
fi
cmake_archive=vendor/dl/cmake-$cmake_version-macos-universal.tar.gz
[ -f "$cmake_archive" ] || scripts/build-freerdp.sh  # it downloads the portable CMake

work=$(mktemp -d "${TMPDIR:-/tmp}/airscp-puttygen.XXXXXX")
trap 'rm -rf "$work"' EXIT
tar -xzf "$source" -C "$work"
tar -xzf "$cmake_archive" -C "$work"
cmake=$work/cmake-$cmake_version-macos-universal/CMake.app/Contents/bin/cmake
"$cmake" -S "$work/putty-$putty_version" -B "$work/build" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
    -DPUTTY_GTK_VERSION=NONE -DPUTTY_GSSAPI=OFF -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" > "$work/configure.log" 2>&1 \
    || { tail -30 "$work/configure.log" >&2; exit 1; }
make -C "$work/build" -j"$(sysctl -n hw.ncpu)" puttygen > "$work/build.log" 2>&1 || { tail -30 "$work/build.log" >&2; exit 1; }
mkdir -p "$out"
cp "$work/build/puttygen" "$out/puttygen"
echo "$putty_version" > "$out/version"
echo "build-puttygen: built $out/puttygen ($("$out/puttygen" --version | head -1))"
