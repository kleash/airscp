#!/bin/bash
# Writes sbom.spdx.json, AirSCP's software bill of materials (SPDX 2.3): the third-party code inside the app, which is
# FreeRDP and OpenSSL as scripts/build-freerdp.sh pins them (version, download, SHA-256), linked statically. AirSCP has
# no package-manager dependencies, and CMake only builds them. The purls (pkg:git with the release tag) are what
# OSV-Scanner looks up in security.yml; the CPEs are for scanners that use NVD. Run it after changing a pin or VERSION:
# a test fails while sbom.spdx.json and those disagree. release.yml attaches the file to every release.
#   scripts/sbom.sh [file]    (default: sbom.spdx.json)
# shellcheck disable=SC2154 # downloads, freerdp_version and openssl_version are build-freerdp.sh's (the eval below)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-sbom.spdx.json}

# The pins exactly as build-freerdp.sh defines them: its lines from cmake_version= to the end of downloads=(…).
eval "$(sed -n '/^cmake_version=/,/^)/p' scripts/build-freerdp.sh)"
for ((i = 0; i < ${#downloads[@]}; i += 3)); do
    case ${downloads[i]} in
        cmake-* | freerdp-* | openssl-*) ;;
        *) echo "sbom.sh: build-freerdp.sh downloads ${downloads[i]}, which this SBOM doesn't list yet: add it" >&2; exit 1 ;;
    esac
done
# pin <file> <1 for its URL, 2 for its SHA-256>
pin() {
    local i
    for ((i = 0; i < ${#downloads[@]}; i += 3)); do
        if [ "${downloads[i]}" = "$1" ]; then echo "${downloads[i + $2]}"; return; fi
    done
    echo "sbom.sh: build-freerdp.sh doesn't download $1" >&2
    exit 1
}
version=$(tr -d '[:space:]' < VERSION)
freerdp_url=$(pin "freerdp-$freerdp_version.tar.gz" 1)
freerdp_sha=$(pin "freerdp-$freerdp_version.tar.gz" 2)
openssl_url=$(pin "openssl-$openssl_version.tar.gz" 1)
openssl_sha=$(pin "openssl-$openssl_version.tar.gz" 2)

cat > "$out" <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "AirSCP $version",
  "documentNamespace": "https://github.com/kleash/airscp/releases/download/v$version/sbom.spdx.json",
  "comment": "The third-party code built into AirSCP: FreeRDP and OpenSSL, pinned and checksummed in scripts/build-freerdp.sh and linked statically. AirSCP has no package-manager dependencies. At run time it also uses the OpenSSH that is part of macOS (/usr/bin/ssh, scp, sftp), which Apple updates with macOS; it isn't shipped with AirSCP. Written by scripts/sbom.sh.",
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
      "comment": "The client library only, with one line changed at build time (utils_set_umask leaves the process umask as it is); see scripts/build-freerdp.sh.",
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
    }
  ],
  "relationships": [
    {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-AirSCP"},
    {"spdxElementId": "SPDXRef-AirSCP", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-FreeRDP"},
    {"spdxElementId": "SPDXRef-AirSCP", "relationshipType": "STATIC_LINK", "relatedSpdxElement": "SPDXRef-OpenSSL"}
  ]
}
EOF
echo "sbom.sh: wrote $out (AirSCP $version: FreeRDP $freerdp_version, OpenSSL $openssl_version)"
