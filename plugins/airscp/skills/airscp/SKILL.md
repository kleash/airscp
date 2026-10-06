---
name: airscp
description: Work with SSH servers and Windows desktops through AirSCP, the user's Mac app for SCP/SFTP, over its MCP tools - copy files and folders to or from a server, browse, synchronize a Mac folder with a server folder, find files on a server, run a command, watch a Linux server, open tunnels, or use a Windows computer over Remote Desktop. Use when the user asks for any of these on a host saved in AirSCP, or asks to use AirSCP.
---

# Using AirSCP

AirSCP is a Mac app the user already uses for their servers. Its MCP server (`airscp`) drives the running app the way
the user would: the same menus, buttons and questions. Everything happens in the user's AirSCP window, so they can
watch it, and agents never see saved passwords.

## Before the first call

- The `airscp` MCP tools must be available. If a call says "AirSCP isn't running, or agent control is off", ask the
  user to open AirSCP and turn on **AirSCP ▸ Settings ▸ Allow AI agents to control AirSCP (MCP)**. Not installed:
  `brew install --cask kleash/tap/airscp`.
- Call `guide` once (no topic) for the overview, and `guide topic=<name>` before a feature you haven't used:
  hosts, proxies, transfers, files, monitor, tunnels, keys, settings, rdp, troubleshooting.

## The loop

1. `snapshot` to see the state: hosts in the sidebar, both file panes, transfers, open questions.
2. One action: `menu` (a menu-bar path such as `Host > Connect`), `press`, `set`, `select`, `go`, `open`, `drop`,
   `key`. Never click in the file panes or the sidebar: folders, rows and hosts are taken by name.
3. `wait` for its effect (`connected`, `listed`, `transfers_done`, `found`, `compared`, `sheet`, `no_sheet`). Never
   sleep: `wait` polls and stops early when AirSCP asks something.
4. A reply with a `sheet` is AirSCP asking a question (trust a new server, a password, Replace or Keep Both, Delete).
   Answer it with `set` and `press` before anything else.

## Common tasks

- Connect: `select pane=sidebar names=["web-01"]`, `menu path="Host > Connect"`, answer the sheets (a new server's
  key: show the user the fingerprint question if you are unsure), `wait until=connected`.
- Upload: `drop files=["/Users/me/site"] pane=right`; a folder asks first (press Upload); `wait until=transfers_done`.
- Download: `select pane=right names=["app.log"]`, then `drop from=right to="local:/Users/me/Downloads"`.
- Go to a server folder: `go path=/var/www` (it answers once listed, with the folder's rows); a row by name:
  `open name=site` (a folder: its rows; `open name=..` goes up). This Mac's side: `go pane=left path=~/Downloads`.
- Synchronize: show the Mac folder in the left pane and the server folder in the right pane, `focus pane=right`,
  `menu path="File > Synchronize…"`, `wait until=compared`, read the plan in the reply, then press Synchronize only if
  the plan is what the user wants.
- Find files: `focus pane=right`, `menu path="File > Find Files…"`, `set id=find.pattern value="*.log"`,
  `press title=Find`, `wait until=found`.
- Run a command: `menu path="Host > Run Command…"`, `set id=runCommand.command value="df -h"`, `press title=Run`,
  `wait until=sheet text="Exit status"`, then `press title=Close`.

## Care

- Destructive steps (Delete, Replace, Synchronize with delete, Kill) ask in AirSCP on purpose. Press the destructive
  button only when the user asked for exactly that.
- Don't type passwords for the user unless they gave you one for this task; prefer letting them answer the sheet.
- Use `screenshot` only to check how something looks; `snapshot` has the facts and is much smaller.
- Open and Save panels can't be driven: give the command that opens one `file=<path>` instead (see `guide`).
