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
- **Disconnect All**: disconnects everything AirSCP is connected to.
- **Get Transfer Status**: says how the transfers are going, to use in a shortcut.

Open the Shortcuts app and search for AirSCP to put them in your own shortcuts, or give them a key. They do exactly what
the menus do.

## Ask AirSCP (Apple Intelligence)

On a Mac with Apple Intelligence (Apple silicon, macOS 26 or later, Apple Intelligence turned on):

- **Help ▸ Ask AirSCP…** (<kbd>⌥⌘K</kbd>): ask in your own words, e.g. “Why can't I connect to web-01?” or “How do I
  upload a folder without node_modules?”.
- A failed connection's banner has **Explain…**: it asks what the error means and what to try.

The answer comes from Apple's model **on this Mac**: your question and a short summary of the host in front (its name,
address, route, state, the last error and the commands AirSCP ran) never leave it. Passwords, keys and file contents are
never part of it. **What AirSCP tells it**, in the Ask window, shows that summary.

AI can be wrong: check what it suggests before you act on it.

## Tips

- **Settings ▸ Apple Intelligence** turns Ask AirSCP and Explain off for AirSCP.
- When Help ▸ Ask AirSCP… is greyed out, point at it to see why (for example, Apple Intelligence is off in System
  Settings ▸ Apple Intelligence & Siri).
