# Security

AirSCP holds the keys to people's servers, so security reports get priority.

## Report a vulnerability

Please report it privately: **[open a private report](https://github.com/kleash/airscp/security/advisories/new)**
(GitHub ▸ Security ▸ Report a vulnerability). Don't open a public issue for it.

Include what you did, what happened, the AirSCP and macOS versions, and how to reproduce it. You'll get an answer
within a few days. Once a fix is released, the advisory is published with credit to you, unless you'd rather not.

## Supported versions

The latest release. Fixes ship as a new release (Homebrew: `brew upgrade --cask airscp`).

## Check a download

- The zip: `shasum -a 256 -c AirSCP-X.Y.Z.zip.sha256` (the SHA-256 is in the release notes and the Homebrew cask too),
  and once it is installed, `spctl -a -vvv -t exec /Applications/AirSCP.app` says `source=Notarized Developer ID`
  (from 1.0.1; 1.0.0 isn't notarized).
- The files the release workflow built (the MCP bundle and the SBOM, and the zip when GitHub built it) come with signed
  SLSA build provenance, `AirSCP-X.Y.Z.intoto.jsonl` on the release. This checks that a file came out of this
  repository's release workflow, at the release's tag: `gh attestation verify airscp.mcpb --repo kleash/airscp`.

## What AirSCP does to stay safe

- SSH is macOS's own OpenSSH (`/usr/bin/ssh`, `scp`, `sftp`). AirSCP never changes `~/.ssh/config`, and it shows every
  command it runs in the command log.
- Passwords live in the login Keychain, never in AirSCP's settings file, exported files, logs or agent replies.
- ssh's questions reach AirSCP through a private socket that answers only processes AirSCP started, with a secret
  that changes at every launch.
- Agent control (MCP) is off until the user turns it on. Then only processes of the same user account can connect
  (a 0700 socket plus a per-launch token), agents never see saved passwords, and AirSCP's confirmations stay in place.
- New server keys and Remote Desktop certificates are shown for the user to trust, unless the user chooses otherwise
  for a host (with an orange shield wherever checks are off).
- Release builds are signed with a Developer ID, use the hardened runtime and are notarized by Apple (from 1.0.1;
  1.0.0 is ad-hoc signed).

More, in plain words: [Privacy and security](https://kleash.github.io/airscp/privacy-security.html).

## How it is scanned

The results are public, and the badges in the README show the latest ones.

- **CodeQL** checks AirSCP's own Swift and C code for security bugs (the `security-extended` queries): on every change
  to `main` and every pull request.
- **Vulnerability scan**, on every change to `main`, every pull request and before every release: the software bill
  of materials ([sbom.spdx.json](sbom.spdx.json), also attached to every release) lists the code built into AirSCP,
  FreeRDP and OpenSSL at their pinned versions. OSV-Scanner checks it against the OSV database (osv.dev), FreeRDP's own
  security advisories are checked against the pinned FreeRDP, and gitleaks looks for secrets in every commit. A known
  vulnerability fails the scan until the library is upgraded.
- **OpenSSF Scorecard** rates the project's supply-chain practices. Every GitHub Action is pinned to a commit, every
  downloaded tool to its SHA-256 and every Docker image to a digest, each workflow job gets only the permissions it
  needs, and Dependabot keeps the actions and images up to date.
- GitHub's secret scanning (with push protection) and Dependabot alerts watch the repository.

## In scope

Anything that lets someone other than the user read passwords or keys, run commands, reach a server, or drive AirSCP:
the askpass and proxy helpers, the agent-control socket and MCP bridge, the Keychain use, names and paths that come
from servers (path traversal), the Remote Desktop client (FreeRDP) and its shared folder and clipboard, and the release
packages. Bugs in OpenSSH, FreeRDP or OpenSSL themselves belong to those projects, but tell us too if AirSCP is
affected.
