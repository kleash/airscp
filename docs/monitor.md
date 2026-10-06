---
title: Monitor
nav_order: 9
---

# Watch a Linux server

The **Monitor** tab shows what a Linux server is doing: CPU, memory, disks, processes and the ports it listens on. You can
also stop a process.

## Steps

1. Connect to the server.
2. Click the **Monitor** tab.
3. Read the figures. They refresh every 3 seconds while the tab is on screen.

The top of the window shows the server's CPU, memory and main disk on every tab, refreshed every 10 seconds. It isn't
there for servers that aren't Linux.

{% include shot.html name="monitor" alt="The Monitor tab: CPU, memory, swap, load, uptime, disks and the list of processes" %}

| Part | What it shows |
|---|---|
| **CPU** | How busy the processors are, since the last refresh. |
| **Memory** and **Swap** | Used and total. |
| **Load** | The load averages for 1, 5 and 15 minutes. |
| **Up** | How long the server has run since it started. |
| **System** | The server's operating system. |
| **Disks** | Free space on each file system, with a bar. |
| **Processes** | Every process with its PID, user, CPU, memory, time, state and command. |

## Stop a process

1. Type its name, user, command or PID in the search field above the list.
2. Select it and click **Kill** (asks the process to quit) or **Force Kill** (stops it at once).
3. AirSCP asks first. Click **Kill** again to confirm.

{% include shot.html name="monitor-kill" alt="The question: Kill python3? The process is asked to quit" %}

## See which ports a server listens on

1. In the **Monitor** tab, click **Ports** above the list of processes.
2. Read the list: each port the server listens on, with the program that listens and how many connections it has.
3. Click a port to see who is connected to it, and how many connections come from each address.

{% include shot.html name="monitor-ports" alt="Ports: the ports web-01 listens on, and the connections to its website on port 8080" %}

| Part | What it shows |
|---|---|
| **Protocol** | TCP or UDP. |
| **Address** | Where the port can be reached. 0.0.0.0 and :: mean every address of the server (open to the network); 127.0.0.1 and ::1 mean only the server itself. |
| **PID** and **Process** | The program that listens (+1: one more process shares the port). A dash means another user's program: connect as root to see it. |
| **User** | The account the port belongs to. |
| **Connections** | How many connections are open to it. UDP has no connections. |

To stop the program that has a port, select the port and click **Kill** or **Force Kill**. **Show Process** shows the
program in the list of processes.

## Tips

- Click a column heading to sort the processes, for example by CPU.
- Kill uses your account's rights. When your account may not stop a process, AirSCP offers **Kill with sudo in
  Terminal**, where sudo can ask for your password (on servers that have sudo).
- The list of processes isn't read while the tab isn't shown. The figures at the top of the window still refresh
  every 10 seconds.
- Reading the ports takes some work on the server, so AirSCP reads them only while **Ports** is shown: at once, then
  every 5 seconds. Click **Pause** to keep the list as it is, and **Refresh** to read it again now.
- Type a port, program or address in the search field above the ports to see only those.
- Right-click a port, or a connection, to copy its address.

## If something goes wrong

- **“The system monitor works only on Linux servers”**: macOS and BSD servers aren't supported. The Files and Tunnels
  tabs work as usual.
- **“This account allows file transfers (sftp) only”**: AirSCP can't read the system there. The Files tab works.
- On BusyBox systems (Alpine), processes show no CPU figure.
