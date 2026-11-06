---
title: Search and run on several servers
parent: iPhone and iPad
nav_order: 5
---

# Search and run on several servers

**Search** (the magnifying glass next to the tabs) finds your servers, the commands you ran before, and files on an
open server. From there you run a command again: on one server, or on several at once.

## Find

Tap **Search** and type part of a name or a command.

- **Servers**: tap one to connect to it.
- **History**: the commands you ran in AirSCP's terminal, each with its server.
- **Files**: tap **Find “…” in** and an open server. AirSCP lists the files and folders below your home folder there
  whose names have the text. Tap one to show it in **Files**. Touch and hold one, then tap **Copy Path** to copy
  where it is.

<!-- picture: iphone-search; iPhone, portrait; Search for “log”: a server, two commands from the history with their Run on buttons, and Find “log” in web-01 -->

## Run a command again

Tap the play button (**Run on**) next to a command, and choose an open server. AirSCP types the command in that
server's terminal and runs it. When the shell there is busy, AirSCP opens a new terminal for it.

## Run on several servers

1. Open the servers in **Servers**.
2. In **Search**, find the command. A new command? Run it once in a terminal first: then it is in the history.
3. Tap the play button next to it, then **Several Servers…**.
4. Tap the servers to run it on. A check mark shows the ones you picked.
5. Tap **Run** (the play button at the top). Each server's output shows under it, errors in red, with its **Exit
   status**: 0 means it worked.
6. **Stop** stops it on every server. Leaving the screen stops it too.

<!-- picture: iphone-run-several; iPhone, portrait; Run on Several Servers: uptime on three servers, each with its output and Exit status 0 -->

## Tips

- **Several Servers…** shows when more than one server is open.
- On several servers, the command runs in each account's login shell, without a terminal. For `sudo`, `top` or an
  editor, run it on one server: it runs in that server's terminal.
- On an iPad with a keyboard, <kbd>⌘K</kbd> opens **Search**.
