# AirSCP plugin for Claude Code

Lets Claude use [AirSCP](https://github.com/kleash/airscp), a free Mac app for SSH servers, SCP/SFTP file transfers and
Windows Remote Desktop. Claude can connect to the hosts you saved in AirSCP, copy files and folders both ways,
synchronize a Mac folder with a server folder, find files on a server, run commands and use a Windows desktop, while
you watch it happen in AirSCP's window.

## What it contains

- **The `airscp` skill**: when to use AirSCP and how to drive it safely (look, act, wait; answer AirSCP's questions).
- **The `airscp` MCP server**: `scripts/airscp-mcp` starts the MCP server built into the AirSCP app
  (`/Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp`, or the copy in `~/Applications`). It talks only to the
  AirSCP running on this Mac, through a private socket that only your user account can open. The plugin sends nothing
  anywhere and has no account or key.

## Before you use it

1. Install AirSCP: `brew install --cask kleash/tap/airscp`, and open it.
2. Turn on **AirSCP ▸ Settings ▸ Allow AI agents to control AirSCP (MCP)**. It is off until you do, and you can turn it
   off at any time; the sidebar shows when an agent is connected and what it did.

## Install

```
/plugin marketplace add kleash/airscp
/plugin install airscp@airscp
```

Agents never see saved passwords, and AirSCP keeps asking before it deletes or replaces anything.
More: [AI agents (MCP)](https://kleash.github.io/airscp/ai-agents.html) in AirSCP Help.
