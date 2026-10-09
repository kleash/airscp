# Architecture

How AirSCP works inside, and why it is built the way it is. The file table is in `CLAUDE.md`; the feature-by-feature
map with tests is [feature-map.md](feature-map.md).

## Shape

- **Two Swift modules and two C targets.** `AirSCPCore` has no UI: models, every command line, sessions, listings,
  transfers, the monitor parser, the RDP session, keys, agent bridge. `AirSCP` is the AppKit/SwiftUI app. `CPTY` runs a
  program on a pseudo-terminal (scp prints its progress meter only there; Swift can't fork and `posix_spawn` can't give
  a child a controlling terminal, so this is ~30 lines of C). `CRDP` is a C shim over FreeRDP (its public header
  includes no FreeRDP or OpenSSL header) plus `airscp_crypto.c` (Argon2 for PuTTY keys, company certificate authority
  checks), both against the static `libairscp-rdp.a` that `scripts/build-freerdp.sh` makes.
- **One binary, several modes** (`Sources/AirSCP/main.swift`): the app; `--proxy-connect` (ssh's ProxyCommand for a
  host behind an HTTP proxy); askpass (ssh's `SSH_ASKPASS`, when `AIRSCP_ASKPASS_SOCK` is set); `--mcp` and
  `--agent` (agent control). Helper modes run before any UI code.
- **One window.** `MainWindowController` holds the sidebar and one workspace per shown host or desktop; a connected
  host keeps its workspace (and its connection) while another is shown. Settings, Keys, Snippets, editors and Help
  windows are separate.

## SSH

- **macOS's own OpenSSH** (`/usr/bin/ssh`, `scp`, `sftp`, `ssh-keygen`, `ssh-add`, `ssh-copy-id`). Every command line
  is built in `Commands.swift` (`OpenSSH.*`), so options are consistent and the command log can show each one as a
  line the user can paste into Terminal.
- **One master connection per host** (`ControlMaster`, socket in `/tmp/airscp-<uid>/<12 hex digits of a hash of the settings folder and the host id>`); every other
  command rides on it with `BatchMode`, so a password is asked once per connection. A master left by an AirSCP that
  crashed is taken over at the next launch and watched like our own.
- **Disconnects** are detected three ways: our child master exits; a muxed command finds the socket file gone (a
  master that exits normally removes it, after which ssh would silently log in afresh); or stderr says "Control socket
  connect". "session request failed" (MaxSessions) is *not* a disconnect: retried.
- **Automatic reconnect** (per host, on by default): 2, 5, 15, 30 s, then every minute for 10 minutes, and at once on
  wake or network change. Silent: an attempt that would need a typed answer stops at Disconnected.
- **Processes**: no Foundation `Process` for ssh tools: it converts arguments to NFD, which breaks NFC file names.
  `Runner` uses `posix_spawn` (own process group, default signals) with **socketpair** pipes (the Mac's pipe pool runs
  dry under load and pipes then crawl at 512 bytes per read; sockets don't), and the pump for tar streams (pacing for
  the speed limit, cancellable).
- **Prompts**: ssh runs AirSCP's own binary as `SSH_ASKPASS`; the helper hands the prompt to the app over a private
  socket with a per-launch token, and the app shows a sheet naming the host. Saved passwords go only to processes
  AirSCP started (checked by pid ancestry). The proxy helper gets the proxy's address and password the same way,
  never from the command line or the environment.
- **Quoting** (`Quote.swift`): three contexts (shell, sftp batch, scp remote path). Listing is `cd "<dir>"` then
  `ls -la` in one script (`ls "<dir>"` would brace-expand). Only scp *download sources* are glob-escaped. AirSCP's own
  shell operations run through `sh` whatever the login shell is (csh/fish don't know `$?`), and the login shell only
  ever sees `exec sh -s`: the script is piped to `sh` on standard input (`OpenSSH.longScript`), so a server-supplied
  name in it is never re-parsed by a non-POSIX login shell (fish, csh, tcsh mis-read even correct POSIX quoting on the
  command line). A tar consumer, whose stdin is the archive, uses a fixed `sh -c` script with no server bytes and reads
  its one variable — the target folder — from the head of its stdin with `read` (`TransferQueue.consumer`; a folder
  whose path has a line break is refused, as `read` would cut it). File ▸ Run… goes to `sh -s` too
  (`Session.run(_:sh:)`); commands with a terminal (Open Terminal Here, Run in Terminal of a file), whose stdin is the
  keyboard, carry the command as printf octal escapes that only sh decodes (`OpenSSH.viaSh`).

## Files and transfers

- **Listing** (`RemoteFS.swift`): a byte-level `ls -la` parser (50 000 entries in about a second), sftp's `ls` as
  the fallback (sftp-only accounts; BusyBox when names aren't ASCII: BusyBox prints every such byte as `?`). Owners
  and groups come by name, as Get Info shows them; with a shell, the same command lists the folder again with `-n`,
  cut by awk to a line per owner and group pair, for their numbers (the cells' tooltips). Names with `/` are dropped
  at the parse boundary (path traversal from a hostile server). A folder that can't be read is an error, never an
  empty folder.
- **Editor** (`RemoteEditor.swift`): Save reads the file again first and compares it byte for byte with what the
  editor last read or wrote (sftp gives sizes and times to the minute only); when someone saved it meanwhile it asks:
  Overwrite, Show Server Version (read-only, in a window beside it), Cancel.
- **Transfers** (`Transfer.swift`): one queue per host (one job at a time per host, hosts in parallel). Single files
  go with scp on the pty (its meter drives progress); folders, 200+ items and Synchronize batches go as **one tar
  stream** (bsdtar here, GNU/BSD/BusyBox tar there), optionally gzip-compressed, with Leave out patterns as
  `--exclude`. Everything arrives as `.airscp-<id>.part` and is renamed into place when complete, so a cancelled or
  failed copy never damages what it was replacing (a replaced file keeps its mode). Server-to-server copies stream
  through this Mac (relay). A single file cut off by a lost connection keeps its part, and its retry continues with
  sftp `reget`/`reput`.
- **UI performance**: listing, sorting and progress parsing happen off the main thread; progress updates are throttled
  (≤ 10/s per job, ≤ 4/s for the panel); the Transfers panel lists unfinished jobs and the newest 100 finished.

## Remote Desktop

- FreeRDP 3 and OpenSSL 3, built static and universal by `scripts/build-freerdp.sh` (pinned versions, SHA-256
  checked, Command Line Tools only, Homebrew prefixes ignored and checked for). Channels: drdynvc, cliprdr, disp,
  rdpgfx, rdpdr + drive, rdpsnd (fake backend). FreeRDP's process-wide umask change is patched out.
- One `rdp_session` per connection with FreeRDP's event loop on its own thread; events reach Swift through one C
  callback. The desktop is shown as two IOSurfaces swapped as a layer's contents (only changed pixels copied).
- Through an SSH host: a local forward on that host's master, and FreeRDP's TCP connect is pointed at it while the
  settings keep the real host name (for the certificate check).
- File transfer: a Mac folder shared as `\\tsclient\AirSCP` (drive redirection), and clipboard file lists both ways
  (FileGroupDescriptorW / FileContents). Windows → Mac clipboard reads block range by range (30 s timeout).

## Data

- `~/Library/Application Support/AirSCP/airscp.json`: hosts, groups, proxies, desktops, snippets, settings. Models are
  Codable with `decodeIfPresent` for every field, so old files load; new fields go last with a default.
- Passwords: one login-Keychain item (service `com.kleash.airscp`) holding a JSON dictionary. A failed read never
  leads to a write (so it can't wipe the item). A throwaway instance (`AIRSCP_SUPPORT_DIR`) keeps passwords in memory.
- First start of AirSCP copies Porter's settings folder and defaults (not its window frames); Porter's Keychain item is
  read once and copied.
- Window sizes, the sidebar's width and the panes' columns: AppKit's autosave in AirSCP's defaults. A saved frame that
  no longer fits on a screen is dropped, and the window opens at its own size (`NSWindow.open`, at most 85 % × 80 % of
  the screen). A throwaway instance neither reads nor saves them (they are the user's).

## Agent control

Off by default. `AirSCP --mcp` (stdio MCP) and `--agent` (one call from a shell) send each tool call to the running
app's socket; the app performs it through its own menus, controls (in-process accessibility tree) and events, and
draws its own screenshots. Details: [agent-control.md](agent-control.md).

## Debug log

Off by default (Settings ▸ Advanced ▸ Debug logging, or AIRSCP_DEBUG=1). `DebugLog` (AirSCPCore) is one file and a
serial queue: ~/Library/Logs/AirSCP/AirSCP-debug.log (a throwaway instance's is in its AIRSCP_SUPPORT_DIR), rotated at
10 MB with one older file kept. While it is on, `Runner` starts a host's ssh, scp and sftp with -vv (the jump host's ssh
in a ProxyCommand too), writes each line of their error output with the time, host and process, and hands back only
what isn't debug output: the command log, error messages and Details stay as they are without it. The proxy helper gets
AIRSCP_DEBUG=1 and prints "debug1: proxy-connect: …" lines (the proxy, the CONNECT target, its status line, the time)
that ssh passes through. `Session` writes the route, the questions asked (never the answers), the states, and a failed
connect's hop in words (`failedHop`); `TransferQueue` each transfer's start and end; `RDPSession` its steps, and
FreeRDP's WLog comes in through `rdp_log_to` (INFO; DEBUG for connection, TLS, NLA, gateway, clipboard and drive).
Passwords, passphrases and the askpass/agent tokens are registered with `DebugLog.Secrets.add` (as bytes: every line
is searched for them), and a line that holds one on its own is left out whole (a marker in its place would show where
the secret was in text a reader can guess, such as a password that is also the user name); any HTTP authorization
header is blanked out; stdout (file contents) is never logged. ssh's per-packet window lines ("rcvd adjust") stay out
of the file.

## Help and docs

- Tooltips for menu commands live in `Help.swift` (by action); controls use `.help` / `toolTip` where they are made.
- `HelpPage` (Help.swift) is the one table of docs URLs the app opens (Help menu, the sheets' **?** buttons);
  `DocsTests` checks each page exists in `docs/`, every link and picture in the docs leads somewhere, and every menu
  command is named in the docs.
- The docs site is GitHub Pages from `docs/` with the Just the Docs remote theme (no Gemfile, no workflow);
  `docs/dev/` is excluded from the site.

## Tests

- Swift Testing (`./test.sh` points the compiler at the Command Line Tools' Testing.framework).
- `Support.swift`: test-wide isolation (`-F` test ssh_config, scratch HOME, no agent, own socket folder, no Keychain)
  and `TestServer`, a throwaway user-mode sshd on 127.0.0.1 with its own host key, keys and home.
- App tests drive real windows off-screen; agent tests go through the agent server in-process; `AgentLabTests`
  launches `build/AirSCP.app` (when newer than the sources) and drives it over `--agent` and `--mcp`.
- `Lab*` suites need the Docker lab (`AIRSCP_DOCKER=1`), RDP VM suites the Windows VM (`AIRSCP_WINDOWS=1`),
  `AIRSCP_BIG=1` the 1 GB transfer, `AIRSCP_PUTTY=1` the interop with PuTTY's own puttygen.
