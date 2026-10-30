#!/bin/bash
# Builds the SSH library the iOS app links (AirSCP 2.0): libssh2 over OpenSSL, static, as one xcframework
#   vendor/ssh2/CSSH2.xcframework   (iOS arm64, iOS Simulator arm64, macOS arm64 for the tests)
# Each slice is one library, libairscp-ssh2.a (libssh2 + libssl + libcrypto), with libssh2's headers and a module
# map, so Swift writes `import CSSH2`. The Mac app keeps macOS's OpenSSH and does not link it; the Mac tests do, next to
# FreeRDP's OpenSSL (the same version, checked below), so the macOS slice is libssh2 alone.
# Same rules as build-freerdp.sh: pinned versions, SHA-256 checked downloads cached in vendor/dl, Command Line Tools
# and Xcode's SDKs only, nothing from Homebrew. Needs Xcode (the iOS SDKs).
set -euo pipefail
cd "$(dirname "$0")/.."

cmake_version=4.4.3
openssl_version=3.5.9
libssh2_version=1.11.1
# name, URL, SHA-256
downloads=(
    "cmake-$cmake_version-macos-universal.tar.gz"
    "https://github.com/Kitware/CMake/releases/download/v$cmake_version/cmake-$cmake_version-macos-universal.tar.gz"
    0c5d65251c14cc884bfa16bdbed3c263ce5bffe2e21c0d0d00962cb0610464fa
    "openssl-$openssl_version.tar.gz"
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
    603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
    "libssh2-$libssh2_version.tar.gz"
    "https://github.com/libssh2/libssh2/releases/download/libssh2-$libssh2_version/libssh2-$libssh2_version.tar.gz"
    d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
)
ios_min=26.0
macos_min=13.1
# slice, OpenSSL target, SDK, minimum-version flag, CMake system name
slices=(
    "ios-arm64           ios64-xcrun               iphoneos         -miphoneos-version-min=$ios_min        iOS"
    "ios-arm64-simulator iossimulator-arm64-xcrun  iphonesimulator  -mios-simulator-version-min=$ios_min   iOS"
    "macos-arm64         darwin64-arm64-cc         macosx           -mmacosx-version-min=$macos_min        Darwin"
)

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH LDFLAGS CFLAGS CPPFLAGS
jobs=$(sysctl -n hw.ncpu)
vendor=$PWD/vendor
work=$vendor/ssh2-work
log=$work/logs
rm -rf "$work"
mkdir -p "$vendor/dl" "$work/src" "$log"
step() { echo "build-libssh2: $*"; }
logged() {
    local name=$1; shift
    if ! "$@" > "$log/$name.log" 2>&1; then
        tail -40 "$log/$name.log" >&2
        echo "build-libssh2: $name failed (log: $log/$name.log)" >&2
        exit 1
    fi
}

grep -qx "openssl_version=$openssl_version" scripts/build-freerdp.sh ||
    { echo "build-libssh2: OpenSSL $openssl_version must be build-freerdp.sh's too (the Mac tests link both)" >&2; exit 1; }
xcrun --sdk iphoneos --show-sdk-path > /dev/null 2>&1 || { echo "build-libssh2: needs Xcode with the iOS SDK" >&2; exit 1; }

for ((i = 0; i < ${#downloads[@]}; i += 3)); do
    name=${downloads[i]} url=${downloads[i + 1]} sha=${downloads[i + 2]}
    file=$vendor/dl/$name
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
        step "downloading $name"
        curl -fL --retry 3 --silent --show-error -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    if [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
        echo "build-libssh2: $name does not have the expected SHA-256 ($sha); not using it." >&2
        rm -f "$file"
        exit 1
    fi
    tar -xzf "$file" -C "$work/src"
done
cmake=$work/src/cmake-$cmake_version-macos-universal/CMake.app/Contents/bin/cmake
openssl_src=$work/src/openssl-$openssl_version
libssh2_src=$work/src/libssh2-$libssh2_version

xcf_args=()
for line in "${slices[@]}"; do
    read -r slice target sdk minflag system <<< "$line"
    prefix=$work/out/$slice
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    export CC="$(xcrun --sdk "$sdk" --find clang)"

    step "OpenSSL $openssl_version ($slice)"
    mkdir -p "$work/build/openssl-$slice"
    (cd "$work/build/openssl-$slice" &&
        logged "openssl-$slice-configure" perl "$openssl_src/Configure" "$target" no-shared no-tests no-apps \
            no-engine no-module --prefix="$prefix" --openssldir="$prefix/ssl" --libdir=lib \
            -isysroot "$sysroot" "$minflag" &&
        logged "openssl-$slice-build" make -j"$jobs" &&
        logged "openssl-$slice-install" make install_sw)

    step "libssh2 $libssh2_version ($slice)"
    deploy=${minflag#*=}
    logged "libssh2-$slice-configure" "$cmake" -S "$libssh2_src" -B "$work/build/libssh2-$slice" -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
        -DCRYPTO_BACKEND=OpenSSL -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DOPENSSL_INCLUDE_DIR="$prefix/include" -DOPENSSL_CRYPTO_LIBRARY="$prefix/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$prefix/lib/libssl.a" -DENABLE_ZLIB_COMPRESSION=OFF
    logged "libssh2-$slice-build" make -C "$work/build/libssh2-$slice" -j"$jobs"
    logged "libssh2-$slice-install" make -C "$work/build/libssh2-$slice" install

    # One library per slice, headers plus a module map for Swift.
    pkg=$work/pkg/$slice
    mkdir -p "$pkg/include"
    openssl=("$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a")
    [ "$system" = Darwin ] && openssl=()
    libtool -static -o "$pkg/libairscp-ssh2.a" "$prefix/lib/libssh2.a" ${openssl[@]+"${openssl[@]}"} 2> "$log/libtool-$slice.log"
    cp "$prefix"/include/libssh2*.h "$pkg/include/"
    printf '#include "libssh2.h"\n#include "libssh2_sftp.h"\n#include "libssh2_publickey.h"\n' > "$pkg/include/CSSH2.h"
    printf 'module CSSH2 {\n    umbrella header "CSSH2.h"\n    export *\n}\n' > "$pkg/include/module.modulemap"
    xcf_args+=(-library "$pkg/libairscp-ssh2.a" -headers "$pkg/include")
done
unset CC

rm -rf "$vendor/ssh2"
mkdir -p "$vendor/ssh2"
logged xcframework xcodebuild -create-xcframework "${xcf_args[@]}" -output "$vendor/ssh2/CSSH2.xcframework"
shasum -a 256 scripts/build-libssh2.sh | cut -d' ' -f1 > "$vendor/ssh2/stamp"
rm -rf "$work"
step "built vendor/ssh2/CSSH2.xcframework (libssh2 $libssh2_version, OpenSSL $openssl_version)"
