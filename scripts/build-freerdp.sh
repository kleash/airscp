#!/bin/bash
# Builds the RDP client library that AirSCP links: FreeRDP and OpenSSL as one static, universal library
#   vendor/out/universal/lib/libairscp-rdp.a   (arm64 + x86_64)
#   vendor/out/universal/include/{freerdp3,winpr3,openssl}
# build.sh and test.sh run this when vendor/out is missing or was built by another version of this script (its
# SHA-256 is in vendor/out/stamp). The first run downloads the sources (pinned versions, SHA-256 checked) into
# vendor/dl, which is kept as a cache; everything else it makes is removed once the build succeeds.
# Command Line Tools only: a portable CMake is downloaded too, and nothing from Homebrew (/opt/homebrew, /usr/local)
# is looked at.
set -euo pipefail
cd "$(dirname "$0")/.."

cmake_version=4.4.3
openssl_version=3.5.9
freerdp_version=3.32.1
# name, URL, SHA-256
downloads=(
    "cmake-$cmake_version-macos-universal.tar.gz"
    "https://github.com/Kitware/CMake/releases/download/v$cmake_version/cmake-$cmake_version-macos-universal.tar.gz"
    0c5d65251c14cc884bfa16bdbed3c263ce5bffe2e21c0d0d00962cb0610464fa
    "openssl-$openssl_version.tar.gz"
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
    603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
    "freerdp-$freerdp_version.tar.gz"
    "https://github.com/FreeRDP/FreeRDP/releases/download/$freerdp_version/freerdp-$freerdp_version.tar.gz"
    3021cf8848efbd0064664e187cb61e6101e4e74a4d8ffb495d9f7715e22d67de
)
archs=(arm64 x86_64)
deployment_target=13.0

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH LDFLAGS CFLAGS CPPFLAGS
jobs=$(sysctl -n hw.ncpu)
vendor=$PWD/vendor
work=$vendor/work
log=$work/logs
rm -rf "$work"
mkdir -p "$vendor/dl" "$work/src" "$log"
step() { echo "build-freerdp: $*"; }
# Runs a build step with its output in a log file; prints the end of the log if it fails.
logged() {
    local name=$1; shift
    if ! "$@" > "$log/$name.log" 2>&1; then
        tail -40 "$log/$name.log" >&2
        echo "build-freerdp: $name failed (log: $log/$name.log)" >&2
        exit 1
    fi
}

for ((i = 0; i < ${#downloads[@]}; i += 3)); do
    name=${downloads[i]} url=${downloads[i + 1]} sha=${downloads[i + 2]}
    file=$vendor/dl/$name
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
        step "downloading $name"
        curl -fL --retry 3 --silent --show-error -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    if [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sha" ]; then
        echo "build-freerdp: $name does not have the expected SHA-256 ($sha); not using it." >&2
        rm -f "$file"
        exit 1
    fi
    tar -xzf "$file" -C "$work/src"
done
cmake=$work/src/cmake-$cmake_version-macos-universal/CMake.app/Contents/bin/cmake
openssl_src=$work/src/openssl-$openssl_version
freerdp_src=$work/src/freerdp-$freerdp_version

# FreeRDP sets the umask of the whole process to 077 whenever it makes a session (utils_set_umask). AirSCP writes the
# user's files (downloads, transfers) from the same process, so the umask stays as it is.
utils=$freerdp_src/libfreerdp/core/utils.c
sed -i '' 's|(void)umask(S_IRWXG \| S_IRWXO);|/* AirSCP: the process umask is left as it is. */|' "$utils"
if ! grep -q "AirSCP: the process umask is left as it is" "$utils"; then
    echo "build-freerdp: couldn't patch utils_set_umask in $utils" >&2
    exit 1
fi

for arch in "${archs[@]}"; do
    prefix=$work/out/$arch

    step "OpenSSL $openssl_version ($arch)"
    mkdir -p "$work/build/openssl-$arch"
    (cd "$work/build/openssl-$arch" &&
        logged "openssl-$arch-configure" perl "$openssl_src/Configure" "darwin64-$arch-cc" no-shared no-tests no-apps \
            no-docs no-legacy no-module no-dso no-engine no-ssl3 no-comp no-zlib --prefix="$prefix" --libdir=lib \
            -mmacosx-version-min=$deployment_target &&
        logged "openssl-$arch-build" make -j"$jobs" &&
        logged "openssl-$arch-install" make install_sw)

    step "FreeRDP $freerdp_version ($arch)"
    # Client library only: the core, GDI, and the channels AirSCP uses (clipboard, display resizing, graphics
    # pipeline, drive redirection; rdpdr and rdpsnd with its fake backend because FreeRDP loads them by itself).
    # MD4 and RC4 (NTLM) are compiled in: OpenSSL is built without its legacy provider.
    logged "freerdp-$arch-configure" "$cmake" -S "$freerdp_src" -B "$work/build/freerdp-$arch" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DOPENSSL_ROOT_DIR="$prefix" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DCMAKE_IGNORE_PATH="/opt/homebrew/bin;/opt/homebrew/lib;/opt/homebrew/include;/usr/local/bin;/usr/local/lib;/usr/local/include" \
        -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DWITH_LIBRARY_VERSIONING=OFF \
        -DWITH_VERBOSE_WINPR_ASSERT=OFF \
        -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON \
        -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF \
        -DWITH_SAMPLE=OFF -DWITH_SERVER=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
        -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_CAIRO=OFF \
        -DWITH_OPENH264=OFF -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_FAAC=OFF -DWITH_FAAD2=OFF -DWITH_GSM=OFF \
        -DWITH_LAME=OFF -DWITH_SOXR=OFF -DWITH_MACAUDIO=OFF \
        -DWITH_CUPS=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF \
        -DWITH_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_PKCS11=OFF -DWITH_KRB5=OFF \
        -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF -DWITH_URIPARSER=OFF -DWITH_FUSE=OFF \
        -DWITH_MANPAGES=OFF -DWITH_CLANG_FORMAT=OFF -DWITH_CCACHE=OFF -DWITH_WINPR_TOOLS=OFF \
        -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON \
        -DCHANNEL_DRDYNVC=ON -DCHANNEL_CLIPRDR=ON -DCHANNEL_DISP=ON -DCHANNEL_RDPGFX=ON \
        -DCHANNEL_RDPDR=ON -DCHANNEL_RDPSND=ON -DCHANNEL_DRIVE=ON \
        -DCHANNEL_AINPUT=OFF -DCHANNEL_AUDIN=OFF -DCHANNEL_ECHO=OFF -DCHANNEL_ENCOMSP=OFF \
        -DCHANNEL_GEOMETRY=OFF -DCHANNEL_LOCATION=OFF -DCHANNEL_PARALLEL=OFF -DCHANNEL_PRINTER=OFF -DCHANNEL_RAIL=OFF \
        -DCHANNEL_RDPECAM=OFF -DCHANNEL_RDPEI=OFF -DCHANNEL_RDPEMSC=OFF \
        -DCHANNEL_REMDESK=OFF -DCHANNEL_SERIAL=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_TELEMETRY=OFF -DCHANNEL_VIDEO=OFF \
        -DCHANNEL_URBDRC=OFF -DCHANNEL_TSMF=OFF -DCHANNEL_SSHAGENT=OFF -DCHANNEL_RDP2TCP=OFF -DCHANNEL_RDPEAR=OFF \
        -DCHANNEL_RDPEWA=OFF -DCHANNEL_GFXREDIR=OFF
    logged "freerdp-$arch-build" make -C "$work/build/freerdp-$arch" -j"$jobs"
    logged "freerdp-$arch-install" make -C "$work/build/freerdp-$arch" install

    # One library per architecture, so Package.swift links a single -lairscp-rdp.
    libtool -static -no_warning_for_no_symbols -o "$prefix/libairscp-rdp.a" \
        "$prefix"/lib/libfreerdp-client.a "$prefix"/lib/libfreerdp.a "$prefix"/lib/libwinpr.a \
        "$prefix"/lib/libssl.a "$prefix"/lib/libcrypto.a 2> "$log/libtool-$arch.log"
done

# Nothing from Homebrew may end up in the compiler or linker flags.
if grep -rl --include=flags.make --include=link.txt -e /opt/homebrew -e /usr/local "$work/build"; then
    echo "build-freerdp: the build picked up Homebrew files (see the files above); not using it." >&2
    exit 1
fi

universal=$work/out/universal
mkdir -p "$universal/lib" "$universal/include"
lipo -create $(for arch in "${archs[@]}"; do echo "$work/out/$arch/libairscp-rdp.a"; done) \
    -output "$universal/lib/libairscp-rdp.a"
# The headers are the same for both architectures (only install paths differ). OpenSSL's are for AirSCP's own C
# helpers in Sources/CRDP (Argon2 for PuTTY keys, a Remote Desktop's company certificate authority).
cp -R "$work/out/${archs[0]}/include/freerdp3" "$work/out/${archs[0]}/include/winpr3" \
    "$work/out/${archs[0]}/include/openssl" "$universal/include/"

rm -rf "$vendor/out"
mv "$universal" "$vendor/out.tmp"
mkdir -p "$vendor/out"
mv "$vendor/out.tmp" "$vendor/out/universal"
shasum -a 256 scripts/build-freerdp.sh | cut -d' ' -f1 > "$vendor/out/stamp"
rm -rf "$work"
step "built vendor/out/universal (FreeRDP $freerdp_version, OpenSSL $openssl_version; $(lipo -archs "$vendor/out/universal/lib/libairscp-rdp.a"))"
