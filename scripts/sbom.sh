#!/bin/bash
# Writes sbom.spdx.json, AirSCP's software bill of materials (SPDX 2.3): the third-party code inside the apps, which is
# FreeRDP and OpenSSL as scripts/build-freerdp.sh pins them (version, download, SHA-256) in the Mac app, and libssh2 as
# scripts/build-libssh2.sh pins it in the iPhone and iPad app (over the same OpenSSL), all linked statically. AirSCP has
# no package-manager dependencies, and CMake only builds them. The purls (pkg:git with the release tag) are what
# OSV-Scanner looks up in security.yml (libssh2's names a commit, which security.yml looks up in OSV's API itself); the
# CPEs are for scanners that use NVD. Run it after changing a pin or VERSION:
# a test fails while sbom.spdx.json and those disagree. release.yml attaches the file to every release.
#   scripts/sbom.sh [file]    (default: sbom.spdx.json)
# shellcheck disable=SC2154 # downloads and the *_version pins are the build scripts' (the eval below)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-sbom.spdx.json}

# pins <build script>: the pins exactly as it defines them, its lines from cmake_version= to the end of downloads=(…).
pins() {
    eval "$(sed -n '/^cmake_version=/,/^)/p' "scripts/$1")"
    for ((i = 0; i < ${#downloads[@]}; i += 3)); do
        case ${downloads[i]} in
            cmake-* | freerdp-* | openssl-* | libssh2-*) ;;
            *) echo "sbom.sh: $1 downloads ${downloads[i]}, which this SBOM doesn't list yet: add it" >&2; exit 1 ;;
        esac
    done
}
# pin <file> <1 for its URL, 2 for its SHA-256>, from the last pins
pin() {
    local i
    for ((i = 0; i < ${#downloads[@]}; i += 3)); do
        if [ "${downloads[i]}" = "$1" ]; then echo "${downloads[i + $2]}"; return; fi
    done
    echo "sbom.sh: the build script doesn't download $1" >&2
    exit 1
}
version=$(tr -d '[:space:]' < VERSION)
pins build-freerdp.sh
freerdp_url=$(pin "freerdp-$freerdp_version.tar.gz" 1)
freerdp_sha=$(pin "freerdp-$freerdp_version.tar.gz" 2)
openssl_url=$(pin "openssl-$openssl_version.tar.gz" 1)
openssl_sha=$(pin "openssl-$openssl_version.tar.gz" 2)
freerdp_openssl=$openssl_version
pins build-libssh2.sh
# One OpenSSL in the SBOM: build-libssh2.sh insists on build-freerdp.sh's too.
[ "$openssl_version" = "$freerdp_openssl" ] ||
    { echo "sbom.sh: build-libssh2.sh's OpenSSL $openssl_version isn't build-freerdp.sh's $freerdp_openssl" >&2; exit 1; }
libssh2_url=$(pin "libssh2-$libssh2_commit.tar.gz" 1)
libssh2_sha=$(pin "libssh2-$libssh2_commit.tar.gz" 2)

cat > "$out" <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "AirSCP $version",
  "documentNamespace": "https://github.com/kleash/airscp/releases/download/v$version/sbom.spdx.json",
  "comment": "The third-party code built into AirSCP: in the Mac app FreeRDP and OpenSSL, pinned and checksummed in scripts/build-freerdp.sh; in the iPhone and iPad app libssh2 and the same OpenSSL, pinned in scripts/build-libssh2.sh; all linked statically. AirSCP has no package-manager dependencies. At run time the Mac app also uses the OpenSSH that is part of macOS (/usr/bin/ssh, scp, sftp), which Apple updates with macOS; it isn't shipped with AirSCP. Written by scripts/sbom.sh.",
  "creationInfo": {
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "creators": ["Tool: scripts/sbom.sh"]
  },
  "packages": [
    {
      "SPDXID": "SPDXRef-AirSCP",
      "name": "AirSCP",
      "versionInfo": "$version",
      "supplier": "Person: kleash",
      "downloadLocation": "https://github.com/kleash/airscp/releases/download/v$version/AirSCP-$version.zip",
      "homepage": "https://kleash.github.io/airscp/",
      "filesAnalyzed": false,
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright 2026 kleash",
      "primaryPackagePurpose": "APPLICATION",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/kleash/airscp@v$version"}
      ]
    },
    {
      "SPDXID": "SPDXRef-FreeRDP",
      "name": "FreeRDP",
      "versionInfo": "$freerdp_version",
      "supplier": "Organization: FreeRDP",
      "downloadLocation": "$freerdp_url",
      "homepage": "https://www.freerdp.com",
      "filesAnalyzed": false,
      "checksums": [{"algorithm": "SHA256", "checksumValue": "$freerdp_sha"}],
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright the FreeRDP contributors",
      "comment": "The Mac app only: the client library, with one line changed at build time (utils_set_umask leaves the process umask as it is); see scripts/build-freerdp.sh.",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/freerdp/freerdp@$freerdp_version"},
        {"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "cpe:2.3:a:freerdp:freerdp:$freerdp_version:*:*:*:*:*:*:*"}
      ]
    },
    {
      "SPDXID": "SPDXRef-OpenSSL",
      "name": "OpenSSL",
      "versionInfo": "$openssl_version",
      "supplier": "Organization: OpenSSL",
      "downloadLocation": "$openssl_url",
      "homepage": "https://www.openssl.org",
      "filesAnalyzed": false,
      "checksums": [{"algorithm": "SHA256", "checksumValue": "$openssl_sha"}],
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright The OpenSSL Project Authors",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/openssl/openssl@openssl-$openssl_version"},
        {"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "cpe:2.3:a:openssl:openssl:$openssl_version:*:*:*:*:*:*:*"}
      ]
    },
    {
      "SPDXID": "SPDXRef-libssh2",
      "name": "libssh2",
      "versionInfo": "$libssh2_commit",
      "supplier": "Organization: libssh2",
      "downloadLocation": "$libssh2_url",
      "homepage": "https://libssh2.org",
      "filesAnalyzed": false,
      "checksums": [{"algorithm": "SHA256", "checksumValue": "$libssh2_sha"}],
      "licenseConcluded": "BSD-3-Clause",
      "licenseDeclared": "BSD-3-Clause",
      "copyrightText": "Copyright the libssh2 contributors",
      "comment": "The iPhone and iPad app only (its SSH, SCP and SFTP), over OpenSSL; see scripts/build-libssh2.sh. A commit on libssh2's master after 1.11.1: the fixes of 1.11.1's CVEs are in no release yet. The Mac app uses macOS's OpenSSH.",
      "primaryPackagePurpose": "LIBRARY",
      "externalRefs": [
        {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:git/github.com/libssh2/libssh2@$libssh2_commit"}
      ]
    }
  ],
  "relationships": [
    {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-AirSCP"},
    {"spdxElementId": "SPDXRef-AirSCP", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-FreeRDP"},
    {"spdxElementId": "SPDXRef-AirSCP", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-OpenSSL"},
    {"spdxElementId": "SPDXRef-AirSCP", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-libssh2"}
  ]
}
EOF
echo "sbom.sh: wrote $out (AirSCP $version: FreeRDP $freerdp_version, OpenSSL $openssl_version, libssh2 $libssh2_commit)"
