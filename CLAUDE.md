# AirSCP: notes for Claude (and other coding agents)

AirSCP is a native macOS app (Swift, AppKit + SwiftUI, macOS 13.1+) for SSH servers and Windows desktops: saved
hosts, a two-pane SCP/SFTP browser with a background transfer queue, Synchronize, Find Files, a Linux monitor,
tunnels, jump hosts and HTTP proxies, and a built-in Remote Desktop client (FreeRDP). For SSH it is a GUI over macOS's
own OpenSSH tools. AI agents drive it over MCP (agent control). The app was called Porter before v1: internal names
(the Docker lab `porter-lab`, the VM "Porter Test Windows", `PORTER_*` env aliases) keep that name; nothing users see
may say Porter.

Knowledge beyond this file: `docs/dev/` (architecture, feature map, regression history, agent control, UX copy,
release, self-hosted runner) and `CONTRIBUTING.md`. User docs: `docs/` (published at https://kleash.github.io/airscp/).

## Rules for every change

- **Simplicity first**: the smallest change that solves the problem; no speculative abstractions, no new layers or
  settings unless the problem needs them. Read the surrounding code and follow its patterns; comments say why, not
  what.
- **Toolchain**: Command Line Tools only (no Xcode project), Swift 5 language mode, code that compiles with Swift 5.9,
  deployment target macOS 13.1. No third-party Swift packages. Nothing from Homebrew in the build or the app.
  FreeRDP + OpenSSL come from `scripts/build-freerdp.sh` (pinned, checksummed, static, universal).
- **The app explains itself**: every interactive control and menu item has a one-line tooltip (`.help` / `toolTip`,
  verb first, no full stop); disabled items say why; non-obvious fields get a grey caption and "Optional" where
  optional; plain words before jargon ("Jump host — connect through another server first (ProxyJump)"); rare options
  under Advanced; empty states say what to do next. `HelpTests.everyControlSaysWhatItDoes` and
  `everyMenuItemSaysWhatItDoes` fail on a control without help. Wording conventions: docs/dev/ux-copy.md.
- **Docs follow the code**: the user page in `docs/` (very simple English, task-first; `DocsTests` checks links,
  pictures and that every menu command is named), `Resources/AgentGuide.md` for anything agents reach (the MCP server
  serves it; `AgentBridgeTests` check it names only real tools, menu paths and ids), then `scripts/llms.sh` (CI fails
  while `docs/llms*.txt` are stale). Pictures come from `scripts/docs-screenshots.sh` (neutral demo data).
- **Versions**: `VERSION` is the source of truth; `plugins/airscp/.claude-plugin/plugin.json`, `mcpb/manifest.json` and
  `server.json` must match it (CI checks). After changing `VERSION` or a pin in `scripts/build-freerdp.sh`, run
  `scripts/sbom.sh` (`SBOMTests` checks `sbom.spdx.json`; security.yml scans it for known vulnerabilities).
- **Commits**: short imperative messages that say what the code now does, no attribution trailers. Never commit
  build outputs, `vendor/`, `testenv/.keys`, `testenv/.windows`, `testenv/.uidriver`.
- **The repository is public**: no passwords, keys, real server names, personal paths or e-mail addresses in code,
  tests, docs, screenshots or commit messages (the Docker lab's documented throwaway credentials excepted).

## Safety (you are working on someone's own Mac and accounts)

- Never read or write `~/.ssh`. A throwaway AirSCP follows `testenv/AGENT.md`: its own `AIRSCP_SUPPORT_DIR` and an
  `AIRSCP_SSH_DIR` whose `config` sets `UserKnownHostsFile`, `IdentityAgent none` and `IdentityFile none`. A throwaway
  AirSCP never touches the login Keychain; don't write it any other way either.
- Test against the local throwaway sshd (the tests make their own), the shared Docker lab (never recreate or stop it;
  destructive tests in your own `porter-*` containers) and the Windows VM (never toggle its network adapter — that
  crashes Windows — and never stop or destroy it; one RDP session at a time).
- Never run the x86_64 slice. Don't install into `~/Applications` (`./install.sh` is for the person at the Mac). Kill
  what you start.
- **Never wait blind** when driving the app: if nothing changes for ~20–30 s, take a snapshot and a screenshot you look
  at, and answer the sheet that is open (Trust, password, conflict…). A wait that times out reports what was on screen.

## Architecture (where things are)

| Path | What |
|---|---|
| `Package.swift` | Targets: `CPTY` (C: run on a pseudo-terminal), `CRDP` (C shim over FreeRDP + `airscp_crypto.c`), `AirSCPCore` (no UI), `AirSCP` (the app), `AirSCPTests` |
| `Sources/AirSCPCore/Commands.swift` | Every ssh/scp/sftp command line, built in one place (`OpenSSH.*`) |
| `…/Session.swift` | One master `ssh` per host (ControlMaster), capability probe, reconnect, tunnels |
| `…/Runner.swift` | Process and pty runner, socketpair pipes, the pump for tar streams, cancellation |
| `…/RemoteFS.swift`, `RemoteOps.swift` | Listing (`ls -lan` parser, sftp fallback), remote file operations, Find |
| `…/Transfer.swift` | The transfer queue: scp, tar streams, `.airscp-<id>.part` files, resume, pause, SHA-256 checks, relays |
| `…/Askpass.swift`, `ProxyConnect.swift` | The app binary as `SSH_ASKPASS` and as `ProxyCommand` (private socket + token) |
| `…/Certificates.swift` (+ `CRDP/airscp_pki.c`) | The Certificate Manager's model: PEM/DER/PKCS#7/PKCS#12/JKS reading, details, exports (OpenSSL in process) |
| `…/Keychain.swift`, `Keys.swift`, `PuTTYKey.swift`, `WinSCP.swift` | Saved passwords (one Keychain item), key pairs, PuTTY .ppk, Import from WinSCP (WinSCP.ini) |
| `…/Monitor.swift`, `RDP.swift`, `Models.swift`, `ErrorMapping.swift` | Linux monitor parser, the RDP session, `airscp.json` models (append-only fields), plain-language errors |
| `…/AgentBridge.swift` | `AirSCP --mcp` (MCP over stdio) and `--agent` (one tool from a shell); the tool list and the guide |
| `Sources/AirSCP/main.swift` | Helper modes first (`--proxy-connect`, `--mcp`, `--agent`, askpass when `AIRSCP_ASKPASS_SOCK` is set), then the app |
| `…/AppDelegate.swift`, `MainWindow.swift`, `HostsSidebar.swift`, `HostWorkspace.swift` | Menu bar, the one main window, sidebar, per-host workspace |
| `…/BrowserContent.swift`, `FilePane.swift`, `FileActions.swift`, `FileSheets.swift`, `Synchronize.swift`, `DiskUsageSheet.swift` | The Files tab (Disk Usage's scan and tree: Core's `DiskUsage.swift`) |
| `…/TransfersPanel.swift`, `MonitorTab.swift`, `Tunnels.swift`, `TerminalTab.swift`, `RDPWorkspace.swift`, `RDPDesktopView.swift` | Panels and tabs (TerminalTab: the shell inside AirSCP over Core's `TerminalScreen` + `TerminalSession`) |
| `…/AgentServer.swift`, `AgentSnapshot.swift` | Agent control inside the app: socket, tools, in-process accessibility tree, screenshots |
| `…/Help.swift` | Tooltips of menu commands, Help menu, the docs URL table (`HelpPage`) |
| `…/Themes.swift` | The Night Harbor (dark) and Paper (light) looks from system colours: ground, content, bar, pill; chips, dots, pills, bars, cards (`card()`), and `primaryTint()` for a sheet's default button |
| `Resources/` | Info.plist, entitlements (release signing), icon, licences, `AgentGuide.md` |
| `Tests/AirSCPTests/` | Swift Testing; `Support.swift` = throwaway sshd harness; `Lab*` need `AIRSCP_DOCKER=1`, RDP VM tests `AIRSCP_WINDOWS=1` |
| `testenv/` | Docker lab, Windows VM, `uidriver` (real-screen `ui` tool), `AGENT.md` |
| `scripts/` | FreeRDP build, docs site + screenshots, `agent-session.sh` (CI), `release-local.sh`, `llms.sh`, `sbom.sh` |
| `plugins/airscp/`, `.claude-plugin/`, `mcpb/`, `server.json`, `glama.json` | Claude Code plugin, MCP bundle, MCP Registry entry |

## Build and test (on a Mac)

```sh
./build.sh --native        # build/AirSCP.app for this Mac; ./build.sh = universal; first run builds FreeRDP (minutes);
                           # with Xcode installed it also makes the App Intents metadata (Shortcuts), else it says so
swift build                # debug build: must have 0 warnings
./test.sh                  # Swift Testing suite (needs Swift 6), throwaway sshd servers; extra args go to swift test
AIRSCP_DOCKER=1 ./test.sh  # + Docker lab suites (starts the lab: testenv/up.sh)
AIRSCP_WINDOWS=1 ./test.sh --filter RDPWindowsTests   # + Windows VM (one suite: its tests run one at a time)
scripts/agent-session.sh   # the scripted agent-control session CI runs (needs build/AirSCP.app)
scripts/docs-site.sh       # build the docs site as GitHub Pages does and check every link (Docker)
scripts/release-local.sh   # signed + notarized release zip (docs/dev/release.md); --adhoc to try the hardened runtime
```

Gates for a change that touches the app: `swift build` 0 warnings; `./test.sh` green twice; the lab and VM suites
when the change can affect them; `./build.sh` + `codesign --verify --deep --strict build/AirSCP.app`; a smoke launch
of a throwaway AirSCP in light and dark; `AgentLabTests` (agent control end to end, against `build/AirSCP.app` when it
is newer than the sources; run it as `testenv/AGENT.md` says, with the shared lab left as it is). Tests wait on conditions,
not timings, so the suite passes on a busy runner (docs/dev/regression-history.md); don't add fixed sleeps or tight bounds.

## Without a Mac (a cloud session on Linux)

Such a session can't build or run the app. It edits, pushes, and lets GitHub's Macs do the rest:

1. Branch, edit, commit, `git push -u origin <branch>`.
2. CI (`.github/workflows/ci.yml`, macos-26, Command Line Tools) runs: versions + `docs/llms*.txt` up to date,
   FreeRDP (cached by `scripts/build-freerdp.sh`'s hash), `swift build` (fails on any warning), `./test.sh`,
   `./build.sh --native`, `scripts/agent-session.sh`, and uploads the session's screenshots + snapshot JSON as the
   `agent-session` artifact.
   A second job, `xcode`, builds the same commit with Xcode: the App Intents metadata (checked by
   `scripts/check-intents.sh`) and the signature; artifact `AirSCP-xcode`.
3. `gh run watch` (or `gh run list --branch <branch>`), then `gh run view <id> --log-failed`; download the pictures:
   `gh run download <id> -n agent-session -D /tmp/agent-session` and look at them (`failed.png` / `failed.json` say
   what AirSCP showed when a step failed).
4. Fix and push again; when green, `gh pr create`. The skill `.claude/skills/airscp-dev/SKILL.md` has the details.

The Docker lab suite (GitHub's Macs have no Docker), the Windows VM's Remote Desktop suite and real-screen checks
(menus, Quick Look, Open panels, appearance with the `ui` tool) run only on the maintainer's Mac, through a
self-hosted runner (`.github/workflows/lab.yml`, `docs/dev/self-hosted-runner.md`): a maintainer starts them, after
reading the change, when it needs them.
