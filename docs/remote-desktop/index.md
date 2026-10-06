---
title: Remote Desktop (Windows)
nav_order: 8
has_children: true
---

# Remote Desktop (Windows)

AirSCP has a built-in Remote Desktop client. It opens a Windows computer's desktop right in AirSCP's window, with the
clipboard and file copying both ways. Nothing else needs to be installed.

{% include shot.html name="rdp-desktop" alt="A Windows desktop in AirSCP's window, with the bar: Ctrl+Alt+Del, Full Screen, Send Files, Shared Folder and Disconnect" %}

## Pages

- [Add a Windows computer](add-a-windows-computer.md)
- [Connect and log in](connect.md)
- [Copy files to and from Windows](copy-files.md)
- [Copy and paste between Mac and Windows](clipboard.md)
- [Keyboard, mouse and screen size](keyboard-and-screen.md)
- [Self-signed certificates and corporate networks](../connecting/self-signed-certificates.md)

## Tips

- Windows must allow Remote Desktop: on the Windows computer, **Settings ▸ System ▸ Remote Desktop**. Windows Home
  editions don't have it.
- A Windows computer behind a server? Set **Connect through** to that SSH host.
