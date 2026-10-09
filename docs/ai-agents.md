---
title: AI agents (MCP)
nav_order: 14
---

# Let AI agents use AirSCP (MCP)

AI agents such as Claude Code, Codex CLI or Gemini CLI can drive AirSCP the way you do: the same menus, buttons and
questions, and AirSCP's own screenshots. AirSCP is an MCP server for them. It is off until you turn it on.

## Steps

1. Open **AirSCP ▸ Settings…** and turn on **Allow AI agents to control AirSCP (MCP)**.
2. Settings shows the command that adds AirSCP to Claude Code. Click **Copy** and paste it into Terminal. It looks like
   this:

   ```sh
   claude mcp add airscp -- /Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp
   ```

   Other MCP clients take the same program with `--mcp`. Codex: `codex mcp add airscp -- /Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp`.

   For Claude Code there is also a plugin, with a skill that teaches Claude how to use AirSCP. In Claude Code, type
   `/plugin marketplace add kleash/airscp`, then `/plugin install airscp@airscp`.
3. Ask your agent to do something in AirSCP, for example “upload the build folder to web-01”.

{% include shot.html name="settings-agents" alt="Settings: Allow AI agents to control AirSCP (MCP), turned on" %}

## See what an agent does

- The sidebar's footer shows **Agent control on**. While an agent acts, its dot pulses and the footer names the agent and
  its last action.
- Hover over it to see who is connected and since when. Click it for the last 20 actions in plain words, with **Turn
  Off Agent Control** and **Settings…**.

{% include shot.html name="agent-activity" alt="The agent's recent actions: it dropped three files on the server pane, set a speed limit and selected a file" %}

## Windows desktops

An agent can work in a Remote Desktop too. It works the way a careful person at the keyboard does:

- **Keys first.** It opens File Explorer with <kbd>⊞</kbd> <kbd>E</kbd>, goes to a folder through the address bar
  (<kbd>Alt</kbd> <kbd>D</kbd>, the path, <kbd>Return</kbd>) and runs programs with <kbd>⊞</kbd> <kbd>R</kbd>.
  Keys don't miss.
- **Clicks where no key reaches.** The agent clicks in the pixels of the desktop picture AirSCP gives it, so the
  window's size, a Retina screen or full screen don't move its clicks. After each click AirSCP shows it a close-up of
  the spot with a red cross, so it can see what it hit.

## Safe by design

- Only programs of your own user account on this Mac can connect, through a private socket with a secret that changes
  at every launch.
- Agents never see saved passwords: password fields read as •••, and no tool reads the Keychain.
- AirSCP's questions stay in the way: Delete still asks, and the agent has to answer.
- Turning the setting off closes the connection at once.

## For agents and scripts

- The agent gets AirSCP's guide when it connects, and a `guide` tool for the details. **Help ▸ Agent Guide** shows the
  same text.
- Agents go to a folder by its path and open a file or folder by its name (the `go` and `open` tools). You see the
  panes move as they work, and they never need to click in the file list.
- From a shell: `AirSCP --agent snapshot`, `AirSCP --agent menu path='Host > Connect'`,
  `AirSCP --agent screenshot --out shot.png`.
- All of this help as plain text for agents: [llms.txt](https://kleash.github.io/airscp/llms.txt) and
  [llms-full.txt](https://kleash.github.io/airscp/llms-full.txt).
