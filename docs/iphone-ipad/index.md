---
title: iPhone and iPad
nav_order: 2
has_children: true
---

# iPhone and iPad

AirSCP is on iPhone and iPad too. Save your servers, copy files between a server and your device, type commands in a
terminal and see how a Linux server is doing, wherever you are. It needs iOS 26 or iPadOS 26, or later. Get it from the
App Store.

<!-- picture: iphone-servers; iPhone, portrait; The Servers tab: two open servers with their CPU, memory and disk, and three saved servers below -->

## The tabs

| Tab | What it is for |
|---|---|
| **Servers** | Add your servers and S3 storage, and connect. Open servers show their CPU, memory and disk. |
| **Files** | Two sides: a server, and **On iPhone** (on an iPad, **On iPad**), AirSCP's own folder on your device. Copy between them. |
| **Terminal** | Type commands on an open server. |
| **Transfers** | The files being copied, and those copied. |
| **Search** (the magnifying glass) | Find a server, a command you ran before, or a file. Run a command on several servers. |

On an iPad, the tabs can be a sidebar, and each open server gets a workspace of its own. See
[iPad and iPhone Duo](ipad.md).

## Pages

- [Get started on iPhone and iPad](get-started.md): add a server, trust it, log in with a password or a key.
- [Files on iPhone and iPad](files.md): copy, share, save, import, edit, and the tray.
- [Terminal on iPhone and iPad](terminal.md)
- [Transfers on iPhone and iPad](transfers.md): and what happens when you leave AirSCP.
- [Search and run on several servers](search.md)
- [Monitor on iPhone and iPad](monitor.md)
- [iPad and iPhone Duo](ipad.md): sidebar, workspaces, windows, keyboard and pointer.

## How it differs from the Mac

- iPhone and iPad have no `~/.ssh` folder. So AirSCP reads no ssh config and uses no ssh agent. Your keys are in the
  Keychain on the device, and the servers you trust are in AirSCP's own list.
- The hosts you saved on your Mac don't come over. Add your servers on the iPhone or iPad too.
- When you copy a file, AirSCP checks the copy against the original (SHA-256). There is nothing to turn on.
- **On iPhone** takes the place of the Mac's **This Mac**.

## Not on iPhone and iPad yet

These are in AirSCP for Mac only:

- Remote Desktop (Windows), tunnels, Synchronize, Disk Usage and the Certificate Manager.
- AI agents (MCP), Shortcuts, Siri and Apple Intelligence.
- Importing hosts (from `~/.ssh/config`, WinSCP or a Mac's **Export Hosts…**) and S3 profiles (`~/.aws`).
- Proxies, browsing as root (sudo), and other ssh options.
- Some commands of the Mac's Files tab: Get Info, permissions, favourites, Compare Folders, extracting archives and
  downloading as one archive.
- Snippets and the Command Log.
- Security keys (FIDO), OpenSSH certificates, and PuTTY keys of version 3 with a passphrase.
