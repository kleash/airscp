---
title: What's New
nav_order: 18
---

# What's new

## AirSCP 1.1.0

- **Tunnels say where they lead**: **Add Tunnel…** reads as a sentence (open port 8080 on this Mac, through your
  server, to the server itself, port 80), and the whole route shows as you type and in the list. The second port is
  the same as the first until you change it.
- **AI agents go through folders without clicking**: they go to a folder by its path and open a file or folder by its
  name, and get the folder's list back at once. You still see each step in the window.
- **Synchronize** leaves out what matches the server's **Leave out** patterns (the same list as for folder
  transfers, shown and changed in the sheet), and you can untick items in the list before you click **Synchronize**.

## AirSCP 1.0

The first release.

{% include shot.html name="main-window" alt="AirSCP 1.0: hosts, two file panes and transfers in one window" %}

- **One window for all your servers**: saved hosts in groups, connected ones at the top, <kbd>⌘1</kbd> to
  <kbd>⌘9</kbd> to switch.
- **Two-pane file browser**: drag to copy between your Mac and a server, or between two servers.
- **Background transfer queue** with resume after a lost connection and a speed limit.
- **Folders as one stream**, with **Compress during transfer** and **Leave out** patterns.
- **Synchronize** two folders, with a preview before anything is copied.
- **Find Files** on a server, by name or pattern.
- **Server file commands**: edit, permissions, compress, extract, run, Get Info.
- **Jump hosts and HTTP proxies**, with the route shown in the sidebar.
- **Remote Desktop for Windows**, built in, with the clipboard and files both ways.
- **Linux monitor**: CPU, memory, disks and processes, with Kill.
- **Tunnels**: local, remote and SOCKS.
- **Keys**: make key pairs of every common type, install them on servers, import PuTTY keys and export them for
  PuTTY 0.75 and later.
- **Trust choices** for self-signed certificates and company certificate authorities.
- **AI agents** can drive AirSCP over MCP when you allow it.
- **Two looks**: Paper in light mode and Night Harbor in dark mode, with a CPU, memory and disk strip for a connected
  Linux server.
- **Help everywhere**: tooltips on every control, a welcome sheet, AirSCP Tips, and this help with a **?** button on
  every sheet with choices.
- **Debug logs** that show each step of a failed connection, to attach to a problem report.
