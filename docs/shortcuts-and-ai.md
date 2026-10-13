---
title: Shortcuts, Siri & Apple Intelligence
nav_order: 15
---

# Shortcuts, Siri and Apple Intelligence

## Shortcuts and Siri

AirSCP's actions are in the **Shortcuts** app, in Spotlight and for Siri:

- **Connect to Host**: opens AirSCP and connects to a saved host. Say “Connect to web-01 with AirSCP”.
- **Open a Shell on Host**: connects and shows the host's [Terminal tab](commands/terminal-tab.md).
- **Open Remote Desktop**: connects to a saved Windows desktop.
- **Upload Files**: uploads files and folders from your Mac to a server folder. Say “Upload to web-01 with AirSCP”.
- **Download Files**: downloads server files and folders to a folder on your Mac (your download folder if you leave
  it empty).
- **Find Files**: finds files on a server by name, like `*.log`, and gives the list to the next action.
- **Run Snippet**: runs one of your [snippets](commands/snippets.md) on a host (one without placeholders such as
  `{file}`: those run on files you select).
- **Start Tunnel** and **Stop Tunnel**: switch one of a host's [tunnels](tunnels.md) on or off.
- **Open Favourite Folder**: connects and shows one of a host's favourite folders.
- **Disconnect All**: disconnects everything AirSCP is connected to.
- **Get Transfer Status**: says how the transfers are going, to use in a shortcut.

Open the Shortcuts app and search for AirSCP to put them in your own shortcuts, or give them a key. They do exactly what
the menus do: AirSCP still asks before it replaces a file, and asks for a password the way it always does.

**Spotlight** (macOS 15 or later) finds your saved hosts and Remote Desktops by name: choose one to open it in AirSCP.

## Ask AirSCP (Apple Intelligence)

On a Mac with Apple Intelligence (Apple silicon, macOS 26 or later, Apple Intelligence turned on):

- **Help ▸ Ask AirSCP…** (<kbd>⌥⌘K</kbd>): ask in your own words, e.g. “Why can't I connect to web-01?” or “How do I
  upload a folder without node_modules?”, and click **Ask**.
- **Do It…** in the same window: say what you want done, e.g. “Upload ~/Sites/site to web-01 in /var/www, leave out
  node_modules” or “Start the 8080 tunnel on db and find big log files in /var/log”. AirSCP shows the steps as
  sentences first. **Nothing runs until you click Run**, and AirSCP still asks before it replaces or deletes anything.
  A step that names a host, snippet or tunnel you don't have says so, and Run stays off.
- A failed connection's banner has **Explain…**: it asks what the error means and what to try.
- **Monitor** has **Explain…**: is anything wrong with the server's CPU, memory, disks or busiest processes?
- The **Command Log** has **Summarize…**: what did AirSCP just do, and did anything fail?
- In **Window ▸ Snippets**, **Explain…** says what a command does, and whether it is risky, before you run it.
- **Suggest…** (the sparkles button) next to a host's **Other ssh options**, **Leave out**, Find Files' pattern and the
  Permissions octal: describe what you want (“keep the connection alive through a firewall”, “everyone can read, only I
  can write”) and AirSCP shows the value. It goes into the field only when you click **Use**.

The answer comes from Apple's model **on this Mac**: your question and a short summary of the host in front (its name,
address, route, state, the last error and the commands AirSCP ran) never leave it. Do It… also tells it the names of
your saved hosts, Remote Desktops, snippets and tunnels. Passwords, keys and file contents are
never part of it. **What AirSCP tells it**, in the Ask window, shows that summary.

AI can be wrong: check what it suggests before you act on it.

## Tips

- **Settings ▸ Apple Intelligence** turns Ask AirSCP, Do It…, Explain, Summarize and Suggest off for AirSCP. The
  buttons only show when Apple Intelligence can answer.
- When Help ▸ Ask AirSCP… is greyed out, point at it to see why (for example, Apple Intelligence is off in System
  Settings ▸ Apple Intelligence & Siri).
