---
title: Monitor on iPhone and iPad
parent: iPhone and iPad
nav_order: 6
---

# Monitor on iPhone and iPad

See what a Linux or Mac server is doing: its CPU, memory, disks and busiest processes. You can also stop a process.

## Steps

1. Open the server in **Servers**. Under **Open**, its row shows its **CPU**, **Memory** and **Disk**.
2. Tap the row. Or, in **Files**, tap **More ▸ Monitor**.
3. Read the figures.

<!-- picture: iphone-monitor; iPhone, portrait; Monitor: the CPU, Memory and Disk rings, the CPU chart, and the busiest processes -->

| Part | What it shows |
|---|---|
| **CPU**, **Memory**, **Disk** | How much is in use, as rings. Orange from 80 %, red from 90 %. |
| Under the rings | The server's system, how long it has run, and its load. |
| **CPU** | A chart of the CPU while you look at this screen, up to 15 minutes. |
| **Busiest processes** | The 10 busiest processes, with their CPU and memory. |
| **Disks** | The free space on each disk, when the server has more than one. |

## Stop a process

1. Type its name, user, command or PID in the search field to find it.
2. Swipe left on it and tap **Kill** (asks it to quit). Or touch and hold it and tap **Force Kill** (stops it at once).
3. AirSCP asks first. Tap **Kill** (or **Force Kill**) again.

## Tips

- AirSCP reads the server every 3 seconds, but only while this screen shows and AirSCP is on screen: iOS doesn't let it
  read servers in the background.
- Your account may stop only its own processes. For another user's, AirSCP gives you the `sudo kill` command to type in
  the [terminal](terminal.md).
- The monitor works on Linux and Mac servers. Other servers, accounts that allow file transfers (sftp) only, and S3 storage have
  none.
