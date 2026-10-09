<p align="center">
  <img src="https://raw.githubusercontent.com/kleash/airscp/main/docs/assets/shots/main-window-light.png" width="49%" alt="AirSCP's window: saved servers on the left, files on this Mac and on a server side by side, uploads running in the Transfers queue below">
  <img src="https://raw.githubusercontent.com/kleash/airscp/main/docs/assets/shots/main-window-dark.png" width="49%" alt="The same window in dark mode">
</p>

<h1 align="center"><img src="https://raw.githubusercontent.com/kleash/airscp/main/docs/assets/icon.png" width="40" alt=""> AirSCP</h1>

<p align="center"><b>SCP/SFTP file transfer, SSH and Windows Remote Desktop in one native Mac app. Free and open source.</b></p>

<p align="center">
  <a href="https://github.com/kleash/airscp/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://github.com/kleash/airscp/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/kleash/airscp/actions/workflows/codeql.yml?query=branch%3Amain"><img src="https://github.com/kleash/airscp/actions/workflows/codeql.yml/badge.svg?branch=main" alt="CodeQL"></a>
  <a href="https://github.com/kleash/airscp/actions/workflows/security.yml?query=branch%3Amain"><img src="https://github.com/kleash/airscp/actions/workflows/security.yml/badge.svg?branch=main" alt="Vulnerability scan"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/kleash/airscp"><img src="https://api.scorecard.dev/projects/github.com/kleash/airscp/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://github.com/kleash/airscp/blob/main/LICENSE"><img src="https://img.shields.io/github/license/kleash/airscp" alt="Licence"></a>
  <a href="https://github.com/kleash/airscp/releases/latest"><img src="https://img.shields.io/github/v/release/kleash/airscp" alt="Latest release"></a>
</p>

- **Two panes**: your Mac on the left, a server on the right. Drag to copy, also server to server.
- **A transfer queue** that runs in the background: pause and resume, go on after a dropped connection, check copies
  with SHA-256, limit the speed.
- **Folders as one fast stream**, with compression and "leave out" patterns (`node_modules, *.log`).
- **Synchronize** two folders with a preview first; **Find Files** on a server by name or pattern.
- **Every way in**: keys, passwords, 2FA codes, jump hosts, HTTP proxies. Your `~/.ssh/config` just works.
- **Remote Desktop for Windows** built in, with the clipboard and files both ways.
- **Monitor** a Linux server (CPU, memory, disks, processes), open **tunnels**, run commands and snippets.
- **Keys**: make any key type, put it on a server, import and export PuTTY `.ppk`.
- **AI agents can drive it** over MCP when you allow it, and they never see your passwords.
- Uses the `ssh`, `scp` and `sftp` built into macOS, shows every command it runs. No account. macOS 13.1+.

<table>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airscp/main/docs/assets/shots/rdp-desktop-light.png" alt="A Windows desktop inside AirSCP, with the bar for the shared folder and the clipboard"><br><b>Remote Desktop</b>: Windows in the window, files and clipboard both ways</td>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airscp/main/docs/assets/shots/synchronize-light.png" alt="The Synchronize sheet listing what it would copy"><br><b>Synchronize</b>: see what will be copied before anything changes</td>
  </tr>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airscp/main/docs/assets/shots/monitor-light.png" alt="The Monitor tab: CPU, memory, disks and processes of a Linux server"><br><b>Monitor</b>: CPU, memory, disks and processes, with Kill</td>
    <td width="50%"><img src="https://raw.githubusercontent.com/kleash/airscp/main/docs/assets/shots/agent-activity-light.png" alt="The agent control popover listing what an AI agent just did in AirSCP"><br><b>AI agents</b>: they drive AirSCP, and you see every action</td>
  </tr>
</table>

## Install

```sh
brew install --cask kleash/tap/airscp
```

Or download the zip from [Releases](https://github.com/kleash/airscp/releases).
The first time you open AirSCP, macOS says it can't check the app for malware (1.0.0 isn't notarized yet): click **Done**,
then **System Settings ▸ Privacy & Security ▸ Open Anyway**. On macOS 14 or earlier, right-click AirSCP ▸ **Open** works too.
Every file has its SHA-256, and the ones GitHub built have signed build provenance: [check a download](SECURITY.md#check-a-download).

## Use it from AI agents

1. Turn on **Settings ▸ Allow AI agents to control AirSCP**, then `claude mcp add airscp -- /Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp`
2. Or install the Claude Code plugin: `/plugin marketplace add kleash/airscp`, then `/plugin install airscp@airscp`
3. Docs for agents: [llms.txt](docs/llms.txt) · [AGENTS.md](AGENTS.md)

## More

[AirSCP Help](https://kleash.github.io/airscp/) (every task, step by step) · [What's new](https://kleash.github.io/airscp/whats-new.html) ·
[Report a problem](https://github.com/kleash/airscp/issues/new?template=bug_report.yml) · [Build from source](CONTRIBUTING.md) ·
[Security](SECURITY.md) · Apache 2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE))
