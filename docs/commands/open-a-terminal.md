---
title: Open a terminal
parent: Snippets & Run Command
nav_order: 3
---

# Open a terminal

Open an ssh session to a host in Terminal or iTerm. It rides on AirSCP's open connection, so you don't log in again.

## Steps

- **Host ▸ Open Terminal** (<kbd>⌘T</kbd>), or the **Open Terminal** button in the toolbar.
- To start in the folder you are looking at: right-click in the server pane and choose **Open Terminal Here**
  (<kbd>⌥⌘T</kbd>).
- To use iTerm instead of Terminal: **AirSCP ▸ Settings… ▸ Open terminals in**.

{% include shot.html name="files" alt="The toolbar's Open Terminal button above the Files tab" %}

## Tips

- macOS asks once whether AirSCP may control iTerm. Click **Allow**.
- **Host ▸ Copy ssh Command** (<kbd>⇧⌘C</kbd>) copies the ssh command line, to paste into any terminal. It is off for
  a host behind an HTTP proxy that needs a password (only AirSCP gives it): use **Host ▸ Open Terminal** for it. A proxy
  without a login is fine: the command reaches it with macOS's `nc`.
