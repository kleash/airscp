# Releasing AirSCP

A release is a tag `vX.Y.Z` whose `VERSION` says `X.Y.Z`. It ships a Developer ID signed, hardened-runtime, notarized
universal app (`AirSCP-X.Y.Z.zip` + `.sha256`), the MCP bundle (`airscp.mcpb` + `.sha256`), the SBOM
(`sbom.spdx.json`), signed build provenance for the files the release workflow built (`AirSCP-X.Y.Z.intoto.jsonl`),
the Homebrew cask in `kleash/homebrew-tap`, and the entry `io.github.kleash/airscp` in the official MCP Registry.
`.github/workflows/release.yml` does everything after the zip; the zip is made either on the Mac
(`scripts/release-local.sh`) or in CI when the signing secrets exist.

## One-time setup

| What | How |
|---|---|
| Developer ID certificate | Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application (Apple Developer Program). `security find-identity -v -p codesigning` lists it. |
| Notary credentials on the Mac | `xcrun notarytool store-credentials airscp-notary --apple-id <Apple ID> --team-id <team ID>` (an app-specific password); check: `xcrun notarytool history --keychain-profile airscp-notary` |
| Tap repository | Create the public repo `kleash/homebrew-tap` with a README (any first commit). release.yml writes `Casks/airscp.rb`. |
| `TAP_TOKEN` secret | A fine-grained token with **Contents: Read and write** on `kleash/homebrew-tap` only; `gh secret set TAP_TOKEN -R kleash/airscp`. Without it, release.yml skips the cask. |
| GitHub Pages | Settings ▸ Pages ▸ Deploy from a branch ▸ `main` / `/docs` (the site is `docs/`, Just the Docs remote theme). |
| Private vulnerability reporting | Settings ▸ Code security ▸ Private vulnerability reporting: on (SECURITY.md and the code of conduct point to it). |
| MCP Registry | Nothing: release.yml logs in with GitHub's OIDC token, which grants `io.github.kleash/*` to workflows of kleash's repos. |
| CI signing (optional) | Secrets `DEVELOPER_ID_P12` (`base64 -i DeveloperID.p12`), `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY` (`base64 -i AuthKey_XXXX.p8`, an App Store Connect API key, role Developer), `NOTARY_KEY_ID`, `NOTARY_ISSUER`. Then a tag alone releases. |

## Before the tag

1. `VERSION`, and the same version in `plugins/airscp/.claude-plugin/plugin.json`, `mcpb/manifest.json` and
   `server.json` (with its package URL `…/releases/download/vX.Y.Z/airscp.mcpb`). CI checks they agree. Then
   `scripts/sbom.sh` (`sbom.spdx.json` names the version too; `SBOMTests` checks it). release.yml zips the MCP bundle
   without checking `mcpb/manifest.json` against its schema: after editing more than the version there, check it with
   `npx @anthropic-ai/mcpb@2.1.2 validate mcpb/manifest.json`.
2. `docs/whats-new.md`: a section for the release, which names every CVE the release fixes (for example when a FreeRDP
   or OpenSSL pin moved for one); `scripts/llms.sh`.
3. CI, CodeQL and the vulnerability scan green on `main`; the lab suites green (`gh workflow run lab.yml -f suite=all`)
   when the release touches what they cover.

## Release (signed on the Mac)

```sh
scripts/release-local.sh      # universal build → Developer ID + hardened runtime → notarize → staple → zip + SHA-256
gh release create vX.Y.Z build/AirSCP-X.Y.Z.zip build/AirSCP-X.Y.Z.zip.sha256 \
    --target main --title "AirSCP X.Y.Z" --notes-file notes.md
```

Publishing the release (it creates the tag) starts release.yml: it checks the zip (version, universal, signature,
Gatekeeper), adds `airscp.mcpb`, `sbom.spdx.json` and their build provenance (`AirSCP-X.Y.Z.intoto.jsonl`, which
leaves out this zip: see "Build provenance" below), updates the cask and publishes `server.json` (with the bundle's
SHA-256) to the MCP Registry. Publish it, don't leave it a draft: the workflow can't read a draft's files. A run that
started from the tag before the zip was there fails with what to do; run it again from Actions ▸ Release ▸ Run workflow
(tag `vX.Y.Z`).

With the CI signing secrets, a tag is enough: `git tag vX.Y.Z && git push origin vX.Y.Z`.

## If there is no Developer ID yet

Ship an ad-hoc signed build only as a deliberate exception: `./build.sh`,
`ditto -c -k --keepParent build/AirSCP.app build/AirSCP-X.Y.Z.zip`, the SHA-256, then the same `gh release create`.
release.yml then warns "not notarized" in the run summary but goes on. Put the "Open Anyway" step back into
`docs/getting-started/install.md` and the README until a notarized release replaces it.
`scripts/release-local.sh --adhoc` makes such a build with the hardened runtime, to try the hardened runtime before a
Developer ID exists.

## Mac App Store

The App Store version is the same code built with `./build.sh --appstore`: Swift's `APPSTORE` condition picks its
differences (users see them in `docs/getting-started/install.md`'s table), and `Resources/AirSCP-AppStore.entitlements`
puts it in the App Sandbox (network client and server, folders the person chooses, their bookmarks, Downloads; no
temporary exceptions). It comes out as `build/appstore/AirSCP.app` with `Resources/PrivacyInfo.xcprivacy`,
no Apple Events and no `ITSAppUsesNonExemptEncryption`. `scripts/check-private-api.sh` (CI runs it) keeps private API out:
the Developer ID version's AXEnhancedUserInterface and key-appearance calls aren't in it.

### One-time setup

| What | How |
|---|---|
| Identities | Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ **Apple Distribution** (signs the app) and **Mac Installer Distribution** (shown in the Keychain as "3rd Party Mac Developer Installer"; signs the package). |
| App ID and record | developer.apple.com ▸ Identifiers ▸ + ▸ App ID `com.kleash.airscp` (no extra capabilities); App Store Connect ▸ Apps ▸ + ▸ New App: macOS, AirSCP, that bundle id. |
| Provisioning profile | developer.apple.com ▸ Profiles ▸ + ▸ Mac App Store Connect, for `com.kleash.airscp` and the Apple Distribution certificate. Download it; `AIRSCP_APPSTORE_PROFILE` names the file. |
| API key | App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API ▸ + (App Manager). `AuthKey_<id>.p8` into `~/.appstoreconnect/private_keys` (or `APPSTORE_KEY_PATH`); `APPSTORE_KEY_ID` and `APPSTORE_ISSUER` are the key's id and the issuer id shown there. Never in the repository. |

### Upload

```sh
scripts/release-appstore.sh --adhoc   # any time: the build and every check that needs nothing from Apple
AIRSCP_APPSTORE_PROFILE=~/Downloads/AirSCP_App_Store.provisionprofile APPSTORE_KEY_ID=… APPSTORE_ISSUER=… \
    scripts/release-appstore.sh       # universal build, Apple Distribution signature, signed .pkg, validate, upload
```

The script signs with the profile embedded and its application and team identifiers added to the entitlements (as
Xcode does), checks the entitlements, the private API scan, the Info.plist, the privacy manifest, the icon (1024 ×
1024) and the package, then runs `xcrun altool --validate-app` and `--upload-package`. `--no-upload` stops after the
validation. App Store Connect takes each build number once, and at most three numbers (CFBundleVersion): a
second upload of 1.3.0 goes up as `AIRSCP_BUILD_NUMBER=1.3.1`, and the next release must then be higher than that. The build then shows in App Store Connect ▸ TestFlight; add it to the version, with
its texts and screenshots, and submit it for review.

**Export compliance.** AirSCP uses non-exempt encryption: ssh, scp and sftp are macOS's own, but it adds standard
encryption the OS doesn't provide (FreeRDP's OpenSSL for Remote Desktop and the Certificate Manager). The Info.plist
leaves `ITSAppUsesNonExemptEncryption` out (YES without a compliance code fails validation, error 90592), so for each
build App Store Connect asks: answer "Standard encryption algorithms instead of, or in addition to, the encryption
within Apple's operating system" and "not available in France"; no documents are then needed. Leave France out under
Pricing and Availability. To sell there, file France's encryption declaration (ANSSI) and upload it in App Store
Connect; its code then goes in `build.sh` as `ITSEncryptionExportComplianceCode`, and the question stops.

**Trying it on this Mac.** Never launch an ad-hoc `--appstore` build as `com.kleash.airscp`: macOS would make AirSCP's
App Store container owned by that ad-hoc signature, and the real App Store version would meet it. Try a copy with a
bundle id of its own, and a new id for each new build (a container belongs to the signature that made it):

```sh
cp -R build/appstore/AirSCP.app /tmp/t/AirSCP.app
plutil -replace CFBundleIdentifier -string com.kleash.airscp.try1 /tmp/t/AirSCP.app/Contents/Info.plist
codesign --force --sign - --entitlements Resources/AirSCP-AppStore.entitlements /tmp/t/AirSCP.app
open -n -a /tmp/t/AirSCP.app /tmp/t --env AIRSCP_SUPPORT_DIR=/tmp/t/support --env AIRSCP_AGENT=1
```

Opening it with a folder (`/tmp/t` above) lets the sandbox into that folder the way an Open panel does, so a throwaway
instance can keep its settings there. Its data otherwise lives in `~/Library/Containers/<bundle id>`, which Terminal can
read only after macOS asks you, and its agent socket is in that container's `tmp` (a short path).

## After: check it from the outside

```sh
gh release view vX.Y.Z                         # zip, .sha256, airscp.mcpb, .sha256, sbom.spdx.json, .intoto.jsonl
shasum -a 256 -c AirSCP-X.Y.Z.zip.sha256       # in the download folder
spctl -a -vvv -t exec /Applications/AirSCP.app # "accepted, source=Notarized Developer ID"
gh attestation verify airscp.mcpb --repo kleash/airscp --bundle AirSCP-X.Y.Z.intoto.jsonl   # and sbom.spdx.json
brew install --cask kleash/tap/airscp --appdir="$(mktemp -d)"   # then uninstall and untap
brew audit --cask --online kleash/tap/airscp
curl -s "https://registry.modelcontextprotocol.io/v0.1/servers?search=io.github.kleash/airscp"
```

On the notarized app, check what the hardened runtime could break: ssh's questions (askpass), a host behind a proxy
and a jump host (`--proxy-connect`), uploads and downloads, Remote Desktop through an SSH host, agent control over
`--mcp`, Open Terminal (Terminal), and with Settings ▸ Open terminals in ▸ iTerm: macOS asks once "AirSCP wants to
control iTerm" (the Apple Events entitlement), then iTerm opens the session. The iTerm check needs a person at an
unlocked screen to answer macOS's question.

## Build provenance

release.yml's `actions/attest` step makes SLSA v1 build provenance for the files that run built, signs it with
Sigstore through GitHub's artifact attestations (an in-toto statement in a Sigstore bundle, logged in the public Rekor
log for a public repository), keeps it in the repository's attestations and adds it to the release as
`AirSCP-X.Y.Z.intoto.jsonl` (one bundle per line). It covers `airscp.mcpb` and `sbom.spdx.json` always, and the zip only
when release.yml built and notarized it (the CI signing secrets): a zip made on the Mac didn't come out of that run, so
provenance for it would claim a build that didn't happen. That zip is checked by its SHA-256 and Apple's notarization
(`spctl` above). To have the zip covered, release through CI signing.

```sh
gh attestation verify airscp.mcpb --repo kleash/airscp                                     # online
gh attestation verify airscp.mcpb --repo kleash/airscp --bundle AirSCP-X.Y.Z.intoto.jsonl  # with the release's file
```

It prints the repository, workflow and tag that made the file
(`--signer-workflow kleash/airscp/.github/workflows/release.yml` and `--source-ref refs/tags/vX.Y.Z` insist on them).
Notes:
- Attestations need a public repository (or GitHub Enterprise Cloud): on a private one the step fails.
- OpenSSF Scorecard's Signed-Releases check scores 10 when each of the last five releases has a `*.intoto.jsonl`. The
  SLSA generator (`slsa-framework/slsa-github-generator`) would do as well, but it must be referenced by tag, which
  Scorecard's Pinned-Dependencies check counts as unpinned; `actions/attest` is pinned to a commit like every action.

## Security scans and badges

Three workflows put live results behind the README's badges (each badge is the latest run on `main`):

| Workflow (badge) | What it checks | When |
|---|---|---|
| `codeql.yml` (CodeQL) | AirSCP's Swift and C with the `security-extended` queries. FreeRDP and OpenSSL are built before CodeQL starts watching, so only `swift build` is analysed. | Pushes to `main`, pull requests, by hand |
| `security.yml` (Vulnerability scan) | OSV-Scanner on `sbom.spdx.json` against osv.dev, after showing it flags FreeRDP 3.5.0 and OpenSSL 3.5.0; FreeRDP's own GitHub security advisories against the pinned release (OSV's FreeRDP records list no release after 3.5.1); gitleaks over every commit | Pushes to `main`, pull requests, by hand, and before every release (release.yml calls it) |
| `scorecard.yml` (OpenSSF Scorecard) | Supply-chain practices; publishes the score behind the badge | Pushes to `main`, by hand |

- `sbom.spdx.json` (SPDX 2.3) is written by `scripts/sbom.sh`: FreeRDP and OpenSSL as `scripts/build-freerdp.sh` pins
  them (version, download, SHA-256), with purls (`pkg:git/…@<tag>`, what OSV looks up) and CPEs. Run it after changing
  a pin or `VERSION`; `SBOMTests` fails until you do. release.yml attaches a fresh one to every release.
- A finding fails the run. For a CVE in FreeRDP or OpenSSL: the pin in `scripts/build-freerdp.sh` to the fixed release,
  `scripts/sbom.sh`, the gates, then a release. Only a verified false positive may be allowed, with the reason next to
  it: `.gitleaks.toml`, or `REVIEWED` in security.yml for a FreeRDP advisory that names no fixed release.
- Every run keeps its results as an artifact (`codeql-sarif`, `scorecard-sarif`); on the public repository CodeQL
  also uploads them to the Security tab and Scorecard publishes its score. Scorecard's own findings stay out of the
  Security tab: its score and every check are public at scorecard.dev.
- Every action is pinned to a commit SHA with its version in a comment; `.github/dependabot.yml` opens one pull request
  a month that moves them. `actionlint` checks the workflows (`.github/actionlint.yaml` names the lab runner's label).
- The other dependencies are pinned too (Scorecard's Pinned-Dependencies): the Docker lab's base images by digest
  (`testenv/*/Dockerfile`, the images the lab was built from; Dependabot's monthly pull request moves them, and the lab
  rebuilds at the next `testenv/up.sh`), `scripts/docs-site.sh` runs GitHub Pages' own build image by digest, and every
  tool a workflow or script downloads is one release checked by its SHA-256 (`scripts/build-freerdp.sh`,
  `testenv/putty/build-puttygen.sh`, `testenv/windows/windows-vm.sh`, OSV-Scanner and gitleaks in security.yml,
  mcp-publisher in release.yml). No workflow installs from npm, PyPI or RubyGems: release.yml zips the MCP bundle
  itself.
- Some Scorecard checks stay below 10 by design: Code-Review and Contributors need more than one maintainer,
  Branch-Protection reaches 8 (the ruleset below), and Fuzzing needs a fuzzer, which AirSCP doesn't have.

### Repository settings

- Settings ▸ Code security: turn on **Dependabot alerts**, **Secret scanning** with **Push protection**, and
  **Private vulnerability reporting**.
- `main` is protected by the ruleset below, and pull requests merge by squashing only.
- The README's badges each show the latest run on `main` (or, for Scorecard, its page).

### CodeQL alerts that are dismissed, and why

Keep the Security tab at zero open alerts (code scanning, secret scanning, Dependabot): fix what opens, and dismiss
only a verified false positive, with the reason. CodeQL's results so far, all in Swift:
- six `swift/cleartext-logging`, false positives, gone since: CodeQL takes names such as password, secret and
  certificate for secrets, and any text given to a function of a "…Log" type for logged. The debug log's redaction
  list has a type of its own (`DebugLog.Secrets.add`), and what is logged (a certificate's fingerprint and subject,
  an error message, a host's name, ssh's option `NumberOfPasswordPrompts=1`) no longer comes through such names.
- two `swift/weak-password-hashing` in `PuTTYKey.deriveKeys`: the SHA-1 key derivation that PuTTY's .ppk version 2
  format prescribes. AirSCP writes version 3 only (Argon2id) and reads version 2 so that old keys still import.
  Dismiss both as "Won't fix": required to read the legacy format (PuTTY .ppk version 2); AirSCP never writes it.
- 1.1.0's Certificate Manager added three `swift/weak-sensitive-data-hashing` in `JKS.read` and `JKS.open`: the
  SHA-1 integrity check and key protection that Java's JKS format prescribes. Dismissed as "Won't fix": required to
  read Java keystores. A `cpp/overflowing-snprintf` in `add_san` was fixed (one call formats an IPv6 address).
- 1.2.0 also writes JKS (JKS… and Truststore…, only when the person picks that format; PKCS#12 is the default), so
  the same SHA-1 is in `JKS.digest` (the integrity check, now shared by reading and writing) and `JKS.seal` (the key
  protection). Expect `swift/weak-sensitive-data-hashing` there; dismiss as "Won't fix": required to read and write
  Java keystores, whose format prescribes it.
- 1.2.0's HTTP Digest proxy login added two `swift/weak-password-hashing` in `ProxyConnect.digest` (the MD5 and
  SHA-256 of the user name, realm and password). HTTP Digest authentication (RFC 7616) defines the response as
  these hashes; the proxy computes the same and compares. The password is hashed, never sent in the clear, and is
  never logged. Dismiss both as "Won't fix": required by the Digest protocol a proxy asks for, and MD5 is the
  algorithm the proxy chooses, not AirSCP.

### The `main` ruleset

No force pushes or deletion, a pull request with one approval (stale approvals dismissed, the last push approved by
someone else), squash merges only, linear history, and green CI, CodeQL and Vulnerability scan jobs on an up-to-date
branch (`integration_id` 15368 is GitHub Actions). Repository admins may bypass, and only through a pull request: the
solo maintainer merges their own pull requests with `gh pr merge <number> --squash --admin`, and nobody pushes to `main`
directly. Scorecard reads rulesets with the workflow's own token (classic branch protection would need an admin token).

```sh
gh api -X PATCH repos/kleash/airscp -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false
gh api -X POST repos/kleash/airscp/rulesets --input - <<'EOF'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_linear_history"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_last_push_approval": true,
      "require_code_owner_review": false,
      "required_review_thread_resolution": false,
      "allowed_merge_methods": ["squash"]
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [
        {"context": "build-and-test", "integration_id": 15368},
        {"context": "analyze", "integration_id": 15368},
        {"context": "Known vulnerabilities in FreeRDP and OpenSSL", "integration_id": 15368},
        {"context": "Secrets in the git history", "integration_id": 15368}
      ]
    }}
  ]
}
EOF
gh api repos/kleash/airscp/rulesets   # check: one ruleset "main", enforcement active
```

The contexts are the jobs' names (ci.yml `build-and-test`, codeql.yml `analyze`, security.yml's two jobs): renaming a
job means updating the ruleset. Scorecard gives this 8 of 10: two required approvals and code owners' review (9) and no
admin bypass (10) don't fit a project with one maintainer.

## What the cask looks like

release.yml writes it; for reference:

```ruby
cask "airscp" do
  version "X.Y.Z"
  sha256 "<the zip's SHA-256>"

  url "https://github.com/kleash/airscp/releases/download/v#{version}/AirSCP-#{version}.zip"
  name "AirSCP"
  desc "SCP and SFTP client with a two-pane browser and Remote Desktop"
  homepage "https://kleash.github.io/airscp/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "AirSCP.app"

  zap trash: [
    "~/Library/Application Support/AirSCP",
    "~/Library/Preferences/com.kleash.airscp.plist",
    "~/Library/Saved Application State/com.kleash.airscp.savedState",
  ]
end
```

No `binary` stanza: run through a symlink, the app's binary can't find its bundle (no guide, version "dev"); agents use
the full path `/Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp`.
