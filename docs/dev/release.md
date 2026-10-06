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
| CI signing (optional, release 2) | Secrets `DEVELOPER_ID_P12` (`base64 -i DeveloperID.p12`), `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY` (`base64 -i AuthKey_XXXX.p8`, an App Store Connect API key, role Developer), `NOTARY_KEY_ID`, `NOTARY_ISSUER`. Then a tag alone releases. |

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

## Release (signing on the Mac: v1)

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

## After: check it from the outside (PLAN.md AC)

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
control iTerm" (the Apple Events entitlement), then iTerm opens the session. An ad-hoc hardened-runtime build passed
all but the iTerm one on 2026-10-05 (that needs a person at an unlocked screen to answer macOS's question).

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
- Attestations need a public repository (or GitHub Enterprise Cloud): on the private repository the step fails, so
  release only once it is public.
- OpenSSF Scorecard's Signed-Releases check scores 10 when each of the last five releases has a `*.intoto.jsonl`. The
  SLSA generator (`slsa-framework/slsa-github-generator`) would do as well, but it must be referenced by tag, which
  Scorecard's Pinned-Dependencies check counts as unpinned; `actions/attest` is pinned to a commit like every action.

## Security scans and badges (PLAN.md AF)

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
- While the repository is private, CodeQL and Scorecard keep their results as run artifacts (`codeql-sarif`,
  `scorecard-sarif`); once it is public, CodeQL uploads to the Security tab and Scorecard publishes its score, with no
  change to the files. Scorecard's own findings stay out of the Security tab: its score and every check are public at
  scorecard.dev.
- Every action is pinned to a commit SHA with its version in a comment; `.github/dependabot.yml` opens one pull request
  a month that moves them. `actionlint` checks the workflows (`.github/actionlint.yaml` names the lab runner's label).
- The other dependencies are pinned too (Scorecard's Pinned-Dependencies): the Docker lab's base images by digest
  (`testenv/*/Dockerfile`, the images the lab was built from; Dependabot's monthly pull request moves them, and the lab
  rebuilds at the next `testenv/up.sh`), `scripts/docs-site.sh` runs GitHub Pages' own build image by digest, and every
  tool a workflow or script downloads is one release checked by its SHA-256 (`scripts/build-freerdp.sh`,
  `testenv/putty/build-puttygen.sh`, `testenv/windows/windows-vm.sh`, OSV-Scanner and gitleaks in security.yml,
  mcp-publisher in release.yml). No workflow installs from npm, PyPI or RubyGems: release.yml zips the MCP bundle
  itself.
- Fuzzing stays at 0 in Scorecard by choice (the maintainer's decision, October 2026): AirSCP has no fuzzing.

### At launch (the repository goes public)

1. Settings ▸ Code security: turn on (or confirm) **Dependabot alerts**, **Secret scanning** with **Push protection**,
   and **Private vulnerability reporting**.
2. Run CodeQL, Vulnerability scan and Scorecard once on `main` (Actions ▸ the workflow ▸ Run workflow) and wait until
   all three are green: CodeQL's results reach the Security tab and the Scorecard badge gets its first score.
3. Security tab: zero open alerts (code scanning, secret scanning, Dependabot). Fix what is open; dismiss only a
   verified false positive, with the reason. CodeQL's first runs (October 2026) found 8 results, all in Swift:
   - six `swift/cleartext-logging`, false positives, gone since: CodeQL takes names such as password, secret and
     certificate for secrets, and any text given to a function of a "…Log" type for logged. The debug log's redaction
     list has a type of its own (`DebugLog.Secrets.add`), and what is logged (a certificate's fingerprint and subject,
     an error message, a host's name, ssh's option `NumberOfPasswordPrompts=1`) no longer comes through such names.
   - two `swift/weak-password-hashing` in `PuTTYKey.deriveKeys`: the SHA-1 key derivation that PuTTY's .ppk version 2
     format prescribes. AirSCP writes version 3 only (Argon2id) and reads version 2 so that old keys still import.
     Dismiss both as "Won't fix": required to read the legacy format (PuTTY .ppk version 2); AirSCP never writes it.
4. README: every badge shows a result and links to a green run (or, for Scorecard, to its page).
5. Protect `main` with the ruleset below and allow squash merges only.
6. An OpenSSF Best Practices entry at https://www.bestpractices.dev: sign in with GitHub (an OAuth grant, so ask the
   maintainer first), add https://github.com/kleash/airscp and answer from the sheet below. Add its badge to the row
   only once it says "passing".
7. After the next scorecard.yml run on `main`, compare https://scorecard.dev/viewer/?uri=github.com/kleash/airscp with
   "Scorecard after launch" below.

#### The `main` ruleset

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

#### OpenSSF Best Practices: the answers for "passing"

Every MUST is met or not applicable; one SHOULD and three SUGGESTED are unmet, with the reason (passing allows that).
Links point to the public repository and site.

| Criterion | Answer | Justification and evidence |
|---|---|---|
| description_good | Met | The README's first lines and https://kleash.github.io/airscp/ say what AirSCP does. |
| interact | Met | README: install (Homebrew, Releases), report a problem and suggest a feature (issue forms), build from source (CONTRIBUTING.md). |
| contribution | Met | https://github.com/kleash/airscp/blob/main/CONTRIBUTING.md: fork, branch, pull request against `main`, CI green. |
| contribution_requirements | Met | CONTRIBUTING.md "What a change needs": smallest change, no third-party packages, tooltips, tests, docs. |
| floss_license | Met | Apache-2.0. |
| floss_license_osi | Met | Apache-2.0 is OSI-approved. |
| license_location | Met | https://github.com/kleash/airscp/blob/main/LICENSE |
| documentation_basics | Met | https://kleash.github.io/airscp/ (every task, step by step). |
| documentation_interface | Met | The help describes every window, sheet and menu command (a test checks that each command is named): https://kleash.github.io/airscp/; the agent interface, MCP tools and `--agent`: https://kleash.github.io/airscp/ai-agents.html, `Resources/AgentGuide.md`, https://kleash.github.io/airscp/llms.txt. |
| sites_https | Met | github.com and kleash.github.io, HTTPS only; downloads from GitHub Releases. |
| discussion | Met | GitHub issues and pull requests: searchable, one URL per topic, open to anyone, no proprietary client needed. |
| english | Met | Docs, code and reports in English. |
| maintained | Met | Actively maintained. |
| repo_public | Met | https://github.com/kleash/airscp |
| repo_track | Met | git: what, who and when for every change. |
| repo_interim | Met | Every change lands on `main` as its own squash-merged pull request between releases (the public history starts at 1.0.0 by choice). |
| repo_distributed | Met | git. |
| version_unique | Met | `VERSION` and one tag `vX.Y.Z` per release. |
| version_semver | Met | Semantic Versioning. |
| version_tags | Met | Each release is a git tag `vX.Y.Z`. |
| release_notes | Met | https://kleash.github.io/airscp/whats-new.html, a section per release, linked from each GitHub release. |
| release_notes_vulns | N/A | No vulnerability fixed yet (1.0.0 is the first release). This procedure ("Before the tag", step 2) has the notes name every CVE a release fixes. |
| report_process | Met | https://github.com/kleash/airscp/issues/new/choose (Help ▸ Report a Problem opens it). |
| report_tracker | Met | GitHub issues. |
| report_responses | Met | No bug reports yet (a new public repository); each one gets an answer. |
| enhancement_responses | Met | No requests yet; each one gets an answer. |
| report_archive | Met | https://github.com/kleash/airscp/issues?q=is%3Aissue (public and searchable). |
| vulnerability_report_process | Met | https://github.com/kleash/airscp/blob/main/SECURITY.md |
| vulnerability_report_private | Met | Private vulnerability reporting: https://github.com/kleash/airscp/security/advisories/new (step 1 turns it on). |
| vulnerability_report_response | N/A | No vulnerability reports in the last 6 months; SECURITY.md promises an answer within a few days. |
| build | Met | `./build.sh` (Swift Package Manager; `scripts/build-freerdp.sh` builds FreeRDP and OpenSSL from pinned, checksummed sources). |
| build_common_tools | Met | Swift Package Manager, CMake. |
| build_floss_tools | Unmet | A native Mac app needs Apple's macOS SDK in the Command Line Tools: free of charge but not FLOSS. The compilers (Swift, Clang), CMake, FreeRDP and OpenSSL are FLOSS. No smaller fix for a macOS app. |
| test | Met | `./test.sh` (Swift Testing, about 380 tests, against throwaway sshd servers); how to run it: CONTRIBUTING.md; CI: https://github.com/kleash/airscp/actions/workflows/ci.yml |
| test_invocation | Met | `swift test` (`./test.sh` wraps it with the environment the tests need). |
| test_most | Unmet | Every feature has tests (`docs/dev/feature-map.md`), but branch coverage isn't measured. Smallest fix: `swift test --enable-code-coverage` in CI with a report. |
| test_continuous_integration | Met | ci.yml on every push and pull request; lab.yml runs the Docker lab, Windows VM and real-screen suites. |
| test_policy | Met | CONTRIBUTING.md: "Tests for what you change, and `./test.sh` green." |
| tests_are_added | Met | The latest major features came with tests: debug logs (DebugLogTests), PuTTY keys (PuTTYKeyTests), trust choices (TrustTests); `docs/dev/feature-map.md`. |
| tests_documented_added | Met | CONTRIBUTING.md and the pull request template. |
| warnings | Met | CI fails on any `swift build` warning. |
| warnings_fixed | Met | Zero warnings is a gate. |
| warnings_strict | Met | Every compiler warning fails CI. |
| know_secure_design | Met | The maintainer's own answer; the design: SECURITY.md "What AirSCP does to stay safe". |
| know_common_errors | Met | The maintainer's own answer: command lines built in one place (`Commands.swift`), names from servers checked for path traversal, secrets redacted from logs, host keys and certificates trusted only by the user, agent control behind a 0700 socket and a token. |
| crypto_published | Met | macOS's OpenSSH, TLS through FreeRDP and OpenSSL, Argon2id with AES and HMAC-SHA-256 for PuTTY keys, the Keychain. |
| crypto_call | Met | Calls OpenSSH, OpenSSL (Argon2, X.509), CommonCrypto (AES) and CryptoKit (HMAC, SHA); implements no primitive itself. |
| crypto_floss | Met | OpenSSH and OpenSSL are FLOSS; what CommonCrypto and CryptoKit do here OpenSSL can do too. |
| crypto_keylength | Met | New keys are Ed25519 by default; RSA from 2048 bits, ECDSA from 256. |
| crypto_working | Met | No broken algorithm by default; SHA-1 only to read PuTTY .ppk version 2 files (that format's key derivation), and old ssh algorithms only when the user adds them. |
| crypto_weaknesses | Met | Defaults avoid SHA-1; AirSCP writes PuTTY keys in format 3 only (Argon2id). |
| crypto_pfs | Met | SSH key exchange (OpenSSH's defaults) and TLS 1.2+ with ECDHE for Remote Desktop. |
| crypto_password_storage | N/A | AirSCP authenticates nobody; it keeps passwords for outgoing connections in the login Keychain (the criterion is for inbound authentication). |
| crypto_random | Met | `arc4random_buf` and Swift's system generator (cryptographically secure on macOS); keys come from `ssh-keygen`. |
| delivery_mitm | Met | HTTPS only (GitHub Releases, the Homebrew cask with the zip's SHA-256), Developer ID signature and notarization. |
| delivery_unsigned | Met | Hashes come with the release over HTTPS and in the cask; nothing is fetched over HTTP. |
| vulnerabilities_fixed_60_days | Met | security.yml on every change to `main`, every pull request and before every release (OSV-Scanner on the SBOM, FreeRDP's advisories): none open. |
| vulnerabilities_critical_fixed | Met | A finding fails the scan, which runs before every release; fixes ship as a new release (SECURITY.md). |
| no_leaked_credentials | Met | gitleaks checks every commit; the passwords and TOTP secret in `testenv/` are sample credentials of a local throwaway lab. |
| static_analysis | Met | CodeQL (`security-extended`) on the Swift and C code on every push to `main` and every pull request: https://github.com/kleash/airscp/actions/workflows/codeql.yml |
| static_analysis_common_vulnerabilities | Met | CodeQL's `security-extended` queries. |
| static_analysis_fixed | Met | CodeQL's findings were fixed, or dismissed with the reason, before 1.0.0 (step 3). |
| static_analysis_often | Met | Every push to `main` and every pull request. |
| dynamic_analysis | Unmet | No fuzzer (Fuzzing skipped by choice) and no measured 80 % branch coverage. Smallest fix: the coverage report above. |
| dynamic_analysis_unsafe | Unmet | The C code (`Sources/CPTY`, `Sources/CRDP`, FreeRDP, OpenSSL) doesn't run under a memory-safety tool. Smallest fix: a CI job with `swift test --sanitize=address` (it leaves the prebuilt FreeRDP and OpenSSL uninstrumented). |
| dynamic_analysis_enable_assertions | Met | The tests run a debug build, where Swift's `assert`/`precondition` and C's `assert` are on. |
| dynamic_analysis_fixed | N/A | No dynamic analysis tool runs, so it found nothing. |

#### Scorecard after launch

What scorecard.dev should show for the new public repository once the steps above are done, check by check:

| Check | Now (private) | After launch | Why |
|---|---|---|---|
| Binary-Artifacts | 10 | 10 | No binaries in the repository. |
| Branch-Protection | 0 | 8 | The ruleset; 9–10 need two approvals, code owners and no admin bypass. |
| CI-Tests | – | – then 10 | Counts merged pull requests: 10 once they merge with green checks. |
| CII-Best-Practices | 0 | 5 | "passing" is 5 (2 while in progress; silver 7, gold 10). |
| Code-Review | 0 | 0 | Needs approvals by someone other than the author: one maintainer has none. |
| Contributors | 0 | 0 | Needs contributors from at least three organisations. |
| Dangerous-Workflow | 10 | 10 | |
| Dependency-Update-Tool | 10 | 10 | Dependabot. |
| Fuzzing | 0 | 0 | No fuzzing, by choice. |
| License | 10 | 10 | |
| Maintained | 0 | 0, 10 after 90 days | 0 while the repository is under 90 days old; then about one commit or issue a week gives 10. |
| Packaging | – | – | Looks for npm, PyPI, Docker and similar publishing; a GitHub release with a Homebrew cask isn't one it knows. |
| Pinned-Dependencies | 5 | 10 | Base images by digest; no unpinned installs. |
| SAST | 10 | 10 | CodeQL on every pull request. |
| Security-Policy | 10 | 10 | |
| Signed-Releases | – | – then 10 | 10 from the first release with `AirSCP-X.Y.Z.intoto.jsonl`. |
| Token-Permissions | 10 | 10 | |
| Vulnerabilities | 10 | 10 | |
| **Aggregate** | **6.1** | **7.2**, 7.4 after the first release, about 7.5 with merged pull requests, about 8.2 after 90 days | Weighted mean of the checks that apply (– doesn't count). |

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
