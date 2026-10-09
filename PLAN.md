# Porter — a native macOS GUI for ssh / scp / sftp (plan, rev 2 after Fable 5.1 review)

## Context
User wants a Crate-style native Mac app (SwiftUI+AppKit, CLT-only build, no admin/brew, installable on another Mac)
that is a **GUI over the built-in OpenSSH commands** (`ssh`, `scp`, `sftp`, `ssh-keygen`, `ssh-add`, `ssh-copy-id`) —
Termius-like: saved hosts + config, one-click SSH, dual-pane local/remote file browser, upload/download, remote file
operations (delete, zip/unzip, …). Goal: the user **never has to type a command**; the app constructs, shows and runs them.

Verified on this Mac (macOS 26.5, Swift 6.3.1 CLT, OpenSSH_10.2p1) by me and by the Fable review (experiments on a
throwaway 127.0.0.1 sshd, never `~/.ssh`):
- Non-root `sshd -f <tmp config>` (temp host key, temp AuthorizedKeysFile, `UsePAM no`, `StrictModes no`) → real
  integration tests. `ForceCommand internal-sftp` gives an sftp-only account ("This service allows sftp connections only.").
- `SSH_ASKPASS=<prog> SSH_ASKPASS_REQUIRE=force` routes every prompt (passphrase, password, host-key yes/no, 2FA,
  ssh-keygen new-passphrase prompts) to the program (prompt = argv[1], answer on stdout, non-zero exit = cancel).
- Mux reuse ~11 ms. **ControlPersist daemonises the master** (pid changes) → not used. A dead master makes muxed commands
  silently fall back to a fresh connection → every muxed command gets `BatchMode=yes`.
- `%C` ControlPath collides for hosts differing only by jump/options → socket keyed on the saved host id.
- ssh uses `-p` for port, scp/sftp use `-P` (`-p` = preserve) → host settings are expressed only as `-o Key=Value`.
- Quoting: sftp batch = `"` + path with `\`→`\\`, `"`→`\"` + `"` (literal, no globbing; never escape `*?[]`).
  scp remote path (SFTP mode) = no shell quoting, backslash-escape `\ * ? [ ]` only; `--` before operands.
  ssh remote command = POSIX single-quote escaping.
- `sftp ls -lan "<dir>"`: includes `.`/`..`, nlink `?`, owner/group may be names, symlinks `l…` without target,
  dates `Mon DD HH:MM` / `Mon DD  YYYY` local time; trailing `/` lists a symlinked dir's contents.
- `scp` under a pty prints `\r` frames `name  48%  14MB  5.8MB/s  00:02 ETA`; `scp -r` one frame set per file, follows
  symlinks, broken link → exit 1 after copying the rest. sftp batch: `-` prefix hides failures, `rename` overwrites.
- Tunnels: `ssh -S <sock> -O forward -L/-R/-D …` and `-O cancel …` work over the master with no extra process.
- `ssh -G <alias>` resolves `~/.ssh/config` (Include/Match/wildcards).

## Scope
### 1. Hosts & config
- Sidebar: hosts in groups, search, colour tag, status dot.
- Host editor: label, hostname, port, username, auth = {agent/default keys | key file (picker) | password}, jump host
  (another saved host → `ProxyCommand=ssh <jump's -o list> -W %h:%p <jump>`, one hop), default remote dir,
  **Forward agent** checkbox, extra `-o Key=Value` lines (covers Compression etc.).
- Duplicate / delete host; "Copy ssh command".
- **Import from ~/.ssh/config**: Host alias names via a small regex (skip `* ? !`), each resolved with `ssh -G`.
  Porter runs ssh with the user's normal config, so aliases keep working. Porter never writes `~/.ssh/config`.
- Export/import Porter hosts JSON (no secrets) for the other Mac.
- Storage: `~/Library/Application Support/Porter/porter.json` (hosts, groups, snippets, tunnels, settings), atomic write.
  Secrets: **one** login-Keychain generic-password item (service `com.sa.porter`) holding a JSON dict keyed by host id —
  one ACL prompt per rebuild instead of one per host (README notes this).

### 2. Connecting & authentication (GUI only)
- One shared option list per host (`-o Port= User= IdentityFile= IdentitiesOnly=yes ProxyCommand= ForwardAgent=` + extras),
  reused verbatim by ssh/scp/sftp/ssh-copy-id/ssh -O; tool flags added separately. Unit test: no bare `-p` for scp/sftp.
- Master = tracked foreground child `ssh -M -N -o ControlPath=/tmp/porter-<uid>/<12 chars of host UUID>
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 …`, connected when `-O check` succeeds;
  its exit = **Disconnected** banner with Reconnect (no automatic reconnect). Disconnect/Quit = `-O exit`.
  On launch, `-O check` existing sockets and adopt orphaned masters from a crashed run.
- Every muxed command: `-o ControlMaster=no -o ControlPath=<sock> -o BatchMode=yes`; stderr `Control socket connect` /
  `session request failed` ⇒ Disconnected, no new ops until Reconnect. Per host: 1 transfer + 1 control command at a time
  (works with MaxSessions 2).
- **Askpass**: `SSH_ASKPASS` = Porter binary in askpass mode (env `PORTER_ASKPASS_SOCK=<unix socket>`, `PORTER_HOST=<id>`).
  The helper has no UI: it sends the prompt to the running Porter over the socket and prints the reply (exit 1 on cancel
  or no answer). Porter shows the dialog as a sheet on the host's window (avoids macOS 14+ background-activation problems):
  - host-key `(yes/no/[fingerprint])` → host + fingerprint, Trust / Cancel;
  - password → if saved and first attempt for this connect, answer from Keychain silently; else secure field with
    **"Remember in Keychain"**; the secret is saved (or a wrong saved one replaced) only after the master comes up;
  - passphrase / verification code / anything else → secure field showing the prompt text (jump-host prompts name the jump host).
- **Host key changed** → explain risk, "Remove old key and reconnect" (`ssh-keygen -R '[host]:port'` / `host` for 22,
  hostname resolved via `ssh -G` for config aliases).
- Friendly error mapping for **ssh, sftp and scp** stderr: refused, DNS, timeout, no route, permission denied (+methods),
  too many auth failures (→ choose a key file), sftp-only, Permission denied, No such file, `Failure` (folder not empty /
  refused), `dest open … Permission denied`, disk full. Raw text under "Details". A failed listing keeps the previous dir.
- Capability probe after connect, sentinel-wrapped to survive MOTD/.bashrc noise:
  `printf '\n__PORTER__\n'; <probe>; printf '\n__PORTER_RC__=%s\n' $?` → shell yes/no, home, `zip unzip tar gzip python3`.
  sftp-only (exact message or failed probe) → shell-only actions disabled with reason; everything else via sftp.

### 3. Terminal
- "Open Terminal" (double-click host / toolbar): per-host `.command` in Application Support (`#!/bin/sh` +
  `exec ssh -o ControlPath=<sock> -o ControlMaster=no <opts> host`), `open`ed in Terminal.app or iTerm (Settings).
  No askpass env: rides the master; if it is down, ssh prompts natively in the terminal.
- "Open Terminal Here" adds `-t 'cd <quoted dir> && exec "$SHELL" -l'`.
- **Run in Terminal** option for snippets/Run command (`-t '<cmd>'`), for sudo/top/anything needing a tty.

### 4. File browser (one window per connected host)
- Dual pane **Local | Remote**: path bar + editable "Go to", back/forward/up/home, refresh, show hidden, filter, sortable
  table (name, size, modified, permissions, owner), UTType icons, multi-select, Return/⌫/Space, context menus.
  Local pane remembers its last directory per host. Names compared with Unicode-canonical equality (NFC/NFD).
- Remote listing: one `sftp -b -` `ls -lan "<dir>"` per refresh; unparseable lines (e.g. newline in name) skipped.
  Symlink double-click lists `"<path>/"`; on error it is treated as a file.
- Remote ops — **one sftp invocation per operation, no `-` prefix**, status = exit code + mapped stderr:
  new folder, rename/move (destination-exists check → Replace / Keep both), delete file, chmod (rwx checkboxes + octal),
  new empty file (put empty temp file), disk free (`df -h`).
- **Recursive delete**: shell host → `rm -rf -- '<p>'`; sftp-only → walk with sftp (list, rm files, recurse, rmdir).
  Recursive chmod same split (`chmod -R` / walk). Confirm dialog listing the names.
- Shell ops (`ssh host '<cmd>'`, sentinel-wrapped where output is parsed): duplicate (`cp -R`), get info size (`du -sk`),
  **compress** (sheet: zip | tar.gz; zip disabled with reason if absent), **extract** (zip via `unzip`, else
  `python3 -m zipfile -e`; tar/tar.gz/tgz/tar.bz2/tar.xz via `tar -xf`; .gz via `gunzip -k`; into same folder or new
  folder named after the archive).
- **Edit**: built-in plain-text editor sheet (NSTextView) for text files ≤ a few MB → Save uploads back (remote mode
  preserved). "Open with default app" downloads to temp, polls its mtime while the window is open and offers
  "Upload changes". Quick Look preview via temp download.
- Local pane ops: new folder, rename, move to Trash, open, reveal in Finder, Quick Look.
- Copy path (remote/local).

### 5. Transfers
- Upload/Download buttons, pane↔pane drag & drop, Finder→remote pane drop. (No drag remote→Finder: "Download to…" covers it.)
- Conflict check first (destination listing): Replace / Skip / Keep both ("name 2") / Apply to all.
- `scp` under a pty (openpty) with `-r` for folders, `-p` per Settings, `--` before operands, absolute local paths.
  Downloads land in `<dest>.porter-part` and are renamed on success; cancel/failure deletes the part file; cancelled
  uploads `sftp rm` the partial remote file.
- Queue panel (serial per host): name, direction, progress parsed from the right of each frame (file %, bytes, speed, ETA);
  folders show current file + files done; Cancel, Retry, Clear finished. Exit 1 with files copied = "completed with
  errors" + stderr. Transfer sheet notes symlinks are copied as their targets. Target pane refreshes on completion.
- Confirm on Quit / Disconnect while transfers run (cancel → clean up → tear down).

### 6. Command log, Run command, snippets, tunnels
- **Command log** per window: exact argv as a copyable shell line, exit status, stderr.
- **Run command** sheet + global **Snippets** (host picked at run time): output/stderr/exit code view, or Run in Terminal.
- **Port forwarding** saved per host — Local / Remote / Dynamic(SOCKS); toggle = `ssh -O forward` / `-O cancel` over the
  master; Porter keeps the on/off state; busy port → error shown; all off on disconnect.

### 7. Keys
- Keys window: `~/.ssh` key pairs listed (type, comment, fingerprint via `ssh-keygen -lf`); read-only otherwise.
- Generate (ed25519 default, rsa 4096; name, comment) via `ssh-keygen` under the askpass env (passphrase prompts answered
  in the GUI, nothing secret in argv); refuses to overwrite an existing file.
- Copy public key; **Install on host**: `ssh-copy-id -i <key.pub> [-f when the host already uses a key] <shared -o list>`
  (sftp-only host: get/append/put `authorized_keys` + chmod via Porter's sftp runner); add to agent + Keychain
  (`ssh-add --apple-use-keychain`, askpass).

### 8. Settings
Terminal app (Terminal/iTerm), default download folder, show hidden default, preserve times, confirm before delete.

### Out of scope
Built-in terminal emulator, cloud sync/teams, mosh/telnet/serial, remote↔remote copy, sudo file editing, multi-hop jump
chains, transfer resume, drag remote→Finder, ControlPersist, automatic reconnect, editing `~/.ssh/config`,
Windows-server shell ops (sftp browse/transfers still work).

## Architecture (mirrors Crate; smallest thing that works)
```
~/work/working/porter/
  Package.swift            tools 5.9, Swift 5 mode, macOS 13 (LSMinimumSystemVersion 13.1), no dependencies
  Sources/PorterCore/      pure Swift, no UI, testable:
    Models.swift           Host, Group, Snippet, Tunnel, Settings; Codable JSON store (atomic)
    Quote.swift            shell / sftp-batch / scp-remote quoting
    Commands.swift         shared -o list + argv for every operation (single source of truth)
    Runner.swift           Process runner (pipes) + PTY runner (openpty), cancellation, env
    Session.swift          master lifecycle, check/adopt, BatchMode muxing, capability probe, error mapping
    RemoteFS.swift         ls parser, sftp ops, sftp walk (recursive delete/chmod), shell ops
    Transfer.swift         scp jobs, progress parser, part files, conflict resolution, serial queue
    SSHConfig.swift        alias list + `ssh -G` resolution
    Askpass.swift          helper side (socket client) + prompt classification
    Keychain.swift         single JSON item get/set
  Sources/Porter/          SwiftUI + AppKit: App/AppDelegate (askpass-mode switch first thing in main), HostsSidebar,
                           HostEditor, BrowserWindow (NSTableView-backed panes for drag & drop), TransfersPanel,
                           CommandLog, RunCommand/Snippets, Tunnels, Keys, Settings, AskpassServer+sheets, TextEditor,
                           Terminal launcher
  Resources/               Info.plist, AppIcon.icns (scripts/make-icon.swift like Crate)
  Tests/PorterCoreTests/   unit (quoting, argv incl. no-bare--p, ls/progress parsers, error mapping, prompt
                           classification, sentinel parsing) + integration vs throwaway user-mode sshd(s): key auth,
                           passphrase key via askpass socket, list, mkdir/rename-conflict/delete/recursive delete
                           (shell + sftp walk)/chmod, zip/unzip/tar, upload/download file+folder with progress, cancel
                           cleans part files, names with spaces/quotes/`*`/`[`/`\`/unicode/leading dash/newline,
                           sftp-only host, MaxSessions 2 (refresh during transfer queues, no fallback), master killed →
                           Disconnected and BatchMode fails fast, host-key-changed detection ([host]:port), MOTD noise,
                           broken symlink in folder transfer, tunnel forward/cancel/busy port, ssh-copy-id -f case
  build.sh / test.sh / install.sh / uninstall.sh / README.md / VERSION   (Crate's CLT-only recipes)
```
Integration tests isolate everything (`-F /dev/null`, temp known_hosts, temp keys, temp sockets); never `~/.ssh`.

## Execution (operating model)
Fable orchestrates; Workflow agents `{ model: 'claude-opus-5-5', effort: 'max' }`, simplicity constraint in every brief.
1. **Lane A — PorterCore + tests + build/test/install scripts** (sshd harness).
2. **Lane B — App UI** on A.
3. **Lane C — adversarial review** (correctness, quoting/injection, auth flows, scenario list) → **Lane D fixes**.
4. Fable verifies: `./test.sh` green, `./build.sh` universal + codesign verify, `install.sh --dry-run`, launch smoke test,
   scenario checklist against a local test sshd; rejects over-engineering.

## Scenario checklist (GUI only)
New host (trust key) · saved password · wrong saved password → prompt → Remember replaces it · encrypted key · 2FA ·
agent keys · jump host · non-22 port · ~/.ssh/config alias · host key changed · refused/DNS/timeout · sftp-only account ·
MOTD noise · network drop (one banner, no stacked dialogs, queued transfers failed with Retry) · MaxSessions 2 ·
upload/download file & folder · conflict · cancel (part files cleaned) · special names · delete non-empty folder (shell and
sftp-only) · rename onto existing · zip/unzip/tar incl. missing tools · edit config file in-app and save · open default
app + upload changes · terminal at dir · sudo via Run in Terminal · generate key, install on password host and on
key host · tunnel start/stop/busy port · quit with running transfer · quit cleans up masters.

## Rev 2 confirmation notes (Fable 5.1 agreed, no blockers) — binding for implementation
- `session request failed` (MaxSessions exhausted) ≠ Disconnected: queue/retry. Only `Control socket connect` or master
  exit ⇒ Disconnected. Adopted orphan masters (not our child): detect loss via that stderr rule / occasional `-O check`.
- `.gz` extract: `gzip -dc f.gz > f` (no `gunzip -k`, missing on gzip < 1.6).
- Askpass mode needs code before the app starts: explicit `main.swift` (no `@main`) checks askpass mode, else runs the app.
- sftp-only key install: create `~/.ssh` (chmod 700) and treat a failed `get authorized_keys` as empty.
- Jump-host prompts: don't answer from the target host's Keychain entry — match the prompt's user@host to the jump's saved
  host, else just prompt.
- Cancelled **folder** upload leaves a partial remote dir → clean via the recursive-delete path.
- iTerm: verify `open -a iTerm x.command`; fall back to an osascript one-liner for iTerm only.
- ssh-copy-id probes with ControlPath=none → count each ssh-copy-id run as a fresh "first attempt" for the saved password.

---
# Rev 3 — user-requested additions (2026-10-02), after Lane A (core) and B1 (app shell) were committed

State: `b7c64d1` PorterCore+tests+scripts, `f0dbd2b` app shell (hosts window, host editor, prompts, terminal, log,
snippets, tunnels, keys, settings, a per-host BrowserWindow placeholder). Browser lane (B2) not started.

## A. Multiple hosts in one window, switched from a side panel (replaces "one window per host")
- One main window (Termius-style): sidebar = saved hosts (groups, search) with a "Connected" section on top (status dot,
  transfer badge); selecting a host shows its workspace in the detail area (browser | monitor | tunnels tabs); sessions
  stay connected while you look at another host. ⌘1…⌘9 switch connected hosts. "Open in New Window" stays available
  for side-by-side work (same workspace view in its own window).

## B. Remote-side file operations (within the host)
- Copy / Cut / Paste and drag-onto-folder **inside the remote pane** (copy = `cp -R --`, move = sftp rename; across
  folders; conflict Replace / Keep both / Skip). Delete, chmod (exists).
- **Execute**: on an executable/script file → "Run" (output sheet with stdout/stderr/exit, optional arguments field,
  runs `cd <dir> && ./<file> <args>`) or "Run in Terminal" (for interactive/sudo). "Make executable" shortcut (chmod +x).

## C. Background transfer queue like WinSCP
- Transfers always run in the background; browsing and other ops continue (control lane is separate).
- A **global Transfers queue** (bottom panel of the main window, all hosts): host, name, direction, size, %, speed,
  ETA, status; Cancel, Retry, Remove, Clear finished, "Cancel all"; Dock badge with active count; notification when a
  long queue finishes. Serial per host, parallel across hosts.

## D. Download as compressed / E. Upload compressed + auto-uncompress
- **Download as archive** (shell host): stream `ssh host 'cd <dir> && tar czf - -- <names>' > <local>.tar.gz`
  (no remote temp space; zip variant `zip -qr - -- <names>` when zip exists); progress = bytes received + speed against
  a `du -sk` estimate; option "Extract after download" (local `/usr/bin/tar -xzf` / `ditto -x -k`).
- **Upload compressed** (shell host with tar): local `/usr/bin/tar -czf <tmp>.tar.gz --no-mac-metadata` (COPYFILE_DISABLE=1,
  no `._*` files) → scp with normal progress → remote `tar xzf <tmp> -C <dest> && rm <tmp>` (tmp in the destination
  dir, named `.porter-upload-<uuid>.tar.gz`, removed on failure/cancel). Conflict check as for normal uploads.
  Worth it for many small files; the transfer sheet offers it ("Compress during transfer") with that hint.

## F. Proxies and bastion chains (WinSCP-style)
- **Proxies** list (Settings ▸ Proxies or sidebar section): name, type HTTP (CONNECT) / SOCKS5, host, port, optional
  username + password (Keychain). A host (or its jump host) can use a proxy for its first hop.
- Chain: Mac → proxy → bastion (saved host, own user/key/password) → target. Built as nested ProxyCommands:
  target `ProxyCommand=ssh <bastion opts incl. bastion's ProxyCommand> -W %h:%p bastion`.
- HTTP proxy with auth: macOS `nc -X connect` has no auth, so Porter ships a **proxy-connect mode** in its own binary
  (like askpass mode): `Porter --proxy-connect <proxy id> %h %p` connects to the proxy, sends `CONNECT h:p` with
  `Proxy-Authorization: Basic`, then relays stdin/stdout. Credentials are fetched from the running app over the askpass
  socket (never in argv/env); 407 → friendly "proxy rejected the credentials". SOCKS5 without auth uses `nc -X 5 -x`;
  SOCKS5 with user/password uses the same helper (RFC 1929).
- Test-connection button per proxy and per host.

## G. RDP for Windows servers
- macOS has no built-in RDP client and building one is out of scope; Porter manages **RDP entries** (hostname, port,
  username, domain, optional "through SSH host" + optional proxy chain, display: fullscreen / window size, multi-monitor
  off/on) and one-click opens them in Microsoft **Windows App** (free, App Store; formerly "Microsoft Remote Desktop")
  by writing a `.rdp` file and `open`ing it. "Through SSH host" = Porter adds a local forward
  `-O forward -L 127.0.0.1:<free port>:<winhost>:3389` on that host's master and points the .rdp at it.
  If no RDP app is installed: explain + button opening its App Store page. Password is typed in Windows App (it can
  remember it in its own Keychain item); Porter does not store RDP passwords.

## H. Details / sizes / hidden files
- Listing columns: name, size (files; folders show "—" until calculated), modified, permissions, owner, group, kind;
  status bar: item count, selection count + total size, free space. "Calculate folder sizes" (toolbar/menu) runs one
  `du -sk -- <dir>/*/ <dir>/.*/` per folder view and fills the folder sizes; optional "always calculate" setting off by default.
- **Get Info** panel for remote items: full path, kind (`file -b`), size (du for folders, + item count via `find | wc -l`),
  permissions (symbolic + octal), owner/group, modified/accessed/changed (GNU `stat -c` with BSD `stat -f` fallback;
  sftp attributes only on sftp-only hosts), symlink target (`readlink`), editable permissions/owner fields.
- Hidden files: toolbar toggle per pane (also ⌘⇧.), default in Settings.

## I. Remote system monitor (per host tab)
- Overview: CPU usage % (two `/proc/stat` samples), load average, memory/swap used/total (`/proc/meminfo`), uptime,
  OS (`/etc/os-release`/`uname`), disk usage per filesystem (`df -kP`) with bars. Auto-refresh every 3 s while visible.
- Processes: `ps -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args` (BusyBox fallback `ps` columns), sortable,
  search by name/user/command/pid, **Kill** (TERM) / **Force kill** (KILL) with confirm; if not permitted, offer
  "Kill with sudo in Terminal". Linux first; macOS/BSD via `top -l 1` / `vm_stat` / `ps -axo`; others show "not supported".
- Disk: `du` of a chosen folder (top-level children sorted by size) to find what fills the disk.

## J. Test lab in Docker (testenv/)
- `testenv/docker-compose.yml` + `up.sh`/`down.sh`, all bound to 127.0.0.1 high ports, throwaway keys generated into
  testenv/.keys (gitignored):
  - `target` (debian:stable-slim + openssh-server, zip/unzip, python3, procps, file): user `dev` with password and key,
    sudo; user `sftponly` (ForceCommand internal-sftp, chroot); MOTD + noisy .bashrc; a busy background process to kill.
  - `minimal` (alpine + openssh, BusyBox ps, no zip/unzip/python3).
  - `bastion` (alpine + openssh, AllowTcpForwarding yes; key + password users); `target` reachable only via the
    internal network in the bastion scenario (a second internal-only target instance or network alias).
  - `proxy` (tinyproxy with BasicAuth user/password, ConnectPort 22) on the internal + host network.
  - `rdp` (optional profile: debian + xrdp + xfce, for a manual Windows App check).
- Integration tests gated by `PORTER_DOCKER=1` run the scenario list against the lab (password auth incl. Remember,
  keyboard-interactive, proxy→bastion→target chain, compressed up/download, process kill, monitor parsers on Debian and
  BusyBox, sftp-only chroot). The fast local user-mode sshd tests stay as they are.

## Lanes (rev 3)
- **T — test lab** (testenv + gated tests harness), parallel with **C2 — core additions** (proxy helper mode + chains,
  remote copy/move/execute, compressed transfers, info/sizes, monitor collectors/parsers, RDP file + forward, global queue).
- **B1' — shell rework**: single main window with sidebar workspaces, Connected section, ⌘1…9, Proxies + RDP entries UI.
- **B2 — workspace**: browser (A–E, H), monitor tab (I), transfers queue panel (C).
- Review ×3 (core/security, GUI scenarios against the Docker lab, simplicity) → fixes → Fable verification incl. Docker lab.

## K. SSH key dropdown (user request, 2026-10-02)
- Wherever a key is chosen (host editor, bastion/jump host, Install public key, Add to agent), the key field is a
  **dropdown** listing: "Default keys / ssh-agent", every private key found in `~/.ssh` (files with a matching `.pub`,
  or whose first line is an OpenSSH/PEM private-key header; shown as name · type · comment, e.g.
  `id_ed25519 · ED25519 · sa@mac`), keys created in Porter's Keys window (they live in `~/.ssh` too, so they appear
  automatically), and "Other…" (file picker, for keys outside `~/.ssh`). The list refreshes when the editor opens.
- A key that no longer exists shows "(missing)" in red in the dropdown and the host shows a warning instead of failing silently.
- The Keys window lists the same `~/.ssh` keys (already built) — single source: `Keys.list()`.

## L. Restored items (user request, 2026-10-02) — supersede the earlier cuts
- **Remote ↔ remote copy** between two connected hosts (pane can switch its side to any connected host, or drag from one
  host's remote pane onto another's): stream `ssh A 'cd <dir> && tar cf - -- <names>' | ssh B 'tar xf - -C <dest>'` when
  both have a shell + tar (no temp space, through the Mac; progress = bytes + speed vs `du` estimate); otherwise relay
  via a Mac temp folder (scp down, scp up, temp deleted). Shown as one job in the global queue; conflict check on B first.
- **Drag remote → Finder** (and Desktop/other apps): `NSFilePromiseProvider`; the promise downloads into the drop
  folder through the normal transfer queue (files and folders); Finder → remote drop stays.
- **Auto-reconnect**: on master loss, retry silently with backoff (2 s, 5 s, 15 s, 30 s, then every 60 s up to 10 min)
  **only when it can succeed without asking** — `BatchMode=yes` attempt (key/agent, or saved Keychain password via the
  askpass first-attempt path); if it would need a prompt, show the Disconnected banner + Reconnect instead (no surprise
  dialogs). Also after wake from sleep / network change (NWPathMonitor). Queued transfers resume after reconnect
  (Retry automatically, downloads restart from the part file's beginning). Per-host "Auto-reconnect" checkbox, on by default.
- **Keep-alive**: already in (ServerAliveInterval 15 / CountMax 3 on every master); make the interval editable per host
  (default 15 s) for flaky NAT/firewalls.

## M. Built-in RDP client (user decision 2026-10-02: embed FreeRDP) — supersedes section G's "open in Windows App"
- **Vendored build, no brew, no admin**: `scripts/build-freerdp.sh` downloads pinned, SHA-256-checked releases into
  `vendor/` (gitignored cache): portable CMake (binary tarball), OpenSSL 3.x source, FreeRDP 3.x source; builds
  **static** libs for arm64 and x86_64 (lipo'd universal) with a minimal feature set (client core + gdi + cliprdr +
  disp + rdpsnd off unless trivial; no ffmpeg/cups/pulse/server/sample clients/X11/Wayland/SDL). `build.sh` runs it only
  when `vendor/out` is missing (first build needs internet; later builds and the exported prebuilt app don't).
  Licences (FreeRDP Apache-2.0, OpenSSL Apache-2.0) copied into the app's Resources and listed in README.
- **Small C shim** `Sources/CRDP/` (module map + `rdp_shim.c/.h`) wraps FreeRDP's callback-heavy API into a flat one:
  create(settings, callbacks) / connect / disconnect, a framebuffer (BGRA32) + dirty-rect callback, send key (macOS
  keycode → RDP scancode via WinPR's Apple keycode map) / unicode / mouse / wheel, clipboard text in/out (cliprdr),
  resize (disp channel), certificate-verify and credential callbacks, error code → message. Runs FreeRDP's event loop on
  its own thread; Swift sees only the shim.
- **RDP entries** in the sidebar (own section, like hosts): label, hostname, port 3389, username, domain, password
  (Keychain item, Remember checkbox), "through SSH host" (local `-O forward` on that host's master, incl. its
  proxy/bastion chain), display: fit window (dynamic resize) / fixed size / fullscreen, scale for Retina, clipboard on/off.
- **Session view**: the desktop draws in the workspace (or its own window / fullscreen ⌘⌃F); keyboard incl. ⌘→Ctrl
  mapping option and a "Send Ctrl+Alt+Del" button; mouse + scroll; text clipboard both ways; reconnect button; status
  line (resolution, latency-free). Certificate prompt on first connect (show issuer/fingerprint, Trust once / Always,
  stored per entry), changed-certificate warning. NLA (CredSSP/NTLM), TLS and RDP security negotiated by FreeRDP.
- **Testing**: Docker lab `rdp` service becomes mandatory (debian + xrdp + xfce) for connect/draw/keyboard/mouse/
  clipboard/resize/cert prompt; the shim also gets a headless connect test against it. xrdp has no NLA, so NLA/real
  Windows is verified manually by the user against a real Windows server (documented checklist).
- Section G's Windows App launcher is dropped (no fallback path).

## N. Windows test server for RDP (user request, 2026-10-02)
- Docker on this M1 Pro has no KVM, so Windows cannot run in a container; x86_64 Windows Server under UTM would be
  fully emulated (hours to install, unusable). → **Windows 11 Pro ARM64 in UTM** (HVF-accelerated, near native; UTM 4.6.3
  is installed). Same RDP stack as Windows Server (TLS, NLA/CredSSP, NTLM), so it covers what xrdp can't.
- New VM "Porter Test Windows" (the existing empty "Windows" VM is left untouched): 4 cores, 6 GB RAM, 64 GB disk,
  TPM + Secure Boot (UTM Windows preset), Shared network (RDP at the VM's 192.168.64.x address; plus a UTM port forward
  127.0.0.1:13389 → 3389 if needed for the bastion scenario).
- ISO: the user downloads the official Windows 11 ARM64 ISO once in a browser (Microsoft blocks scripted downloads).
- Unattended install via an `autounattend.xml` on a small ISO made with `hdiutil makehybrid`: bypass TPM/online-account
  checks, local admin `porter` with a generated password (stored in testenv/.windows, gitignored), enable Remote
  Desktop + firewall rule, NLA on, install UTM guest tools (virtio drivers) at first logon.
- Unactivated Windows (generic Pro install key) is fine for a short-lived test VM; the user activates/licenses it if kept.
- Driven by `testenv/windows-vm.sh` (UTM AppleScript + utmctl); macOS will ask once to allow controlling UTM.

## O. Light and dark mode (user request, 2026-10-02)
- Settings ▸ Appearance: **System** (default, follows macOS) / **Light** / **Dark**, applied app-wide at once via
  `NSApp.appearance` (nil / .aqua / .darkAqua) and remembered.
- Every view uses semantic system colours (labelColor, controlBackgroundColor, separatorColor, accent colour) — no
  hard-coded light-only colours; host colour tags, status dots, monitor bars and log/stderr text get light+dark
  variants; the text editor and command log follow the appearance. The RDP desktop view is unaffected.
- Review gate: grep for hard-coded `NSColor(red:`/`Color(red:`/`.white`/`.black` in UI code; smoke-launch in each mode.

## P. Parallel build (user request, 2026-10-02) — supersedes the serial lane list
Each lane works in its own git worktree/branch off `main` (`git worktree add ../porter-wt-<lane> -b lane/<lane>`),
owns a disjoint set of files, commits there; an integration lane merges. All agents Opus 5.5 max.
0. **Contracts** (1 agent, short, on `main`): data models + API signatures every lane codes against — Models
   (Proxy, RDPEntry, host fields proxyID/keepAlive/autoReconnect/keyFile dropdown, AppSettings.appearance), stub
   methods (throwing `.notImplemented`) for new PorterCore APIs, Package.swift targets (CRDP placeholder), file-ownership
   table. Builds + tests green.
1. Parallel lanes (after 0):
   - **Core-net**: proxy-connect helper + nested chains, auto-reconnect/keep-alive, Session changes, keys list for dropdown.
   - **Core-files**: remote copy/move/execute, info/sizes, compressed up/download, remote↔remote, global queue.
   - **Core-monitor**: monitor collectors/parsers (Linux, BusyBox, macOS), kill.
   - **RDP**: vendored FreeRDP build script, CRDP shim, RDP view/session, cert/credential prompts, headless connect test.
   - **Test lab**: testenv/ Docker compose (target, minimal, bastion, proxy, xrdp) + `PORTER_DOCKER=1` test harness.
   - **UI-shell**: single main window + sidebar workspaces, Connected section, ⌘1…9, appearance, key dropdown,
     Proxy + RDP entry editors, host editor fields.
   - **UI-workspace**: browser panes (incl. remote ops, drag to Finder, remote↔remote pane), monitor tab, global
     transfers queue panel — against the contract stubs.
   (The Windows 11 VM lane is already running.)
2. **Integrate** (1 agent): merge lanes in order core → RDP → lab → UI, resolve conflicts, full test (local sshd +
   Docker lab), universal build.
3. **Review ×3** (core/security, GUI scenarios vs Docker lab + Windows VM, simplicity/appearance) → **Fix** →
   Fable final verification.

## Q. Rev 3 review outcome (Fable 5.1, approve-with-changes; all adopted) — binding
Verified by Fable in a Docker lab (tinyproxy BasicAuth → alpine bastion → Debian target, PAM password): nested
ProxyCommand with the CONNECT helper (%%h/%%p doubling) brings up a master through proxy→bastion→target; PAM prompt
arrives via askpass as "(dev@target) Password: "; streamed `tar czf -` over a muxed BatchMode ssh works with exit codes;
`-O forward/cancel` work through the chain.
Fixes:
- Folder sizes: `cd <dir> && du -sk -- 'n1' 'n2' …` with names from the listing — never `*/ .*/` globs (match `..`).
- main.swift: check `argv[1] == "--proxy-connect"` BEFORE the askpass env test; proxy credentials are a distinct
  socket message ({proxy: id}) answered from the Keychain (or a "Proxy X needs a password" prompt with Remember), never
  routed through Session.handlePrompt. Terminal `.command` scripts export PORTER_ASKPASS_SOCK so the helper still works;
  helper prints one recognisable line on non-200 (`Porter proxy: HTTP/1.1 407 …`) → mapped "proxy rejected the user name or password".
- Compressed upload: `/usr/bin/tar --no-mac-metadata --no-xattrs -czf …` (+ COPYFILE_DISABLE=1); Docker test asserts no `._*`.
  Conflicts: Replace / Skip only (skip = leave conflicting names out of the archive).
- Monitor: GNU `ps -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args`; BusyBox `ps -o pid,ppid,user,rss,etime,stat,comm,args`
  (%MEM from rss/MemTotal, no %CPU); "ps: not found" → "The server has no ps command"; decided once per session.
  CPU % = diff of one /proc/stat sample against the previous refresh (no sleep). Linux only; others get a message.
- Streamed download: indeterminate progress (bytes + speed + elapsed); Runner variant writing stdout to the part file.
- Move within host: `mv --` on shell hosts (cross-device), sftp rename on sftp-only ("Failure" → can't move across file systems).
- Keys list: fingerprint with SSH_ASKPASS_REQUIRE=never; filter by private-key header; unknown → "type unknown".
Cuts: SOCKS5 (HTTP CONNECT only, helper handles auth and no-auth; nc not used), zip streaming (tar.gz only),
"Open in New Window" (single main window only; B1's per-host window machinery goes), per-proxy test button, macOS/BSD
monitor, Disk tab, editable owner/group, completion notifications (Dock badge only), xrdp lab profile (the Windows 11
VM covers RDP), duplicate lab target (one target, one bastion, one proxy, one minimal; Debian target installs
procps file zip unzip python3; tinyproxy `Allow` includes Docker Desktop's host gateway).
B1 rework list (from Fable): HostsWindowController becomes the main window (NSSplitViewController: sidebar = hosts
list, detail = one HostWorkspace per host kept alive); drop AppDelegate.browsers/closing/cascadePoint/open/show/closed/
closeWindow, BrowserWindowController's window/delegate/toolbar parts and Window ▸ Hosts; keep HostConnection,
connect(then:), show(error), prompts, CommandLog, Tunnels, RunCommand, Keys, Settings, Terminal.

## R. L–O review outcome (Fable 5.1, approve-with-changes; adopted) — binding
**FreeRDP spike succeeded** (/tmp/porter-freerdp-spike: build-freerdp.sh, NOTES.txt, swiftpm-test/): FreeRDP 3.32.1 +
OpenSSL 3.5.9 static, arm64 + x86_64, portable CMake 4.4.3, CLT only, zero Homebrew (verified by log grep), ~2.5 min incl.
downloads; SwiftPM C target + Swift executable link with only /System frameworks + /usr/lib (otool), both triples.
- Channels: DRDYNVC, CLIPRDR, DISP, RDPGFX, **RDPDR, RDPSND (fake backend)** ON (load_addins hard-wires rdpdr+rdpsnd);
  everything else OFF exactly as the spike script; add `-DWITH_VERBOSE_WINPR_ASSERT=OFF` (asserts must not abort Porter).
  WITH_KRB5=OFF → NLA is NTLM only (README note). Libs merged with `libtool -static` into `libporter-rdp.a`.
- CRDP target: cSettings `-I vendor/out/universal/include/{freerdp3,winpr3}`, `-Wno-deprecated-declarations`;
  link `-L vendor/out/universal/lib -lporter-rdp` + CoreFoundation, Foundation, IOKit, Carbon, CoreServices. The shim's
  public header includes no FreeRDP headers. Vendor cache keeps only dl/ + out/ after a successful build.
- Shim: event loop thread like MRDPView.m (get_event_handles / WaitForMultipleObjects / check_event_handles);
  gdi_init(BGRX32); BeginPaint/EndPaint (post invalid rects to main) / **DesktopResize → gdi_resize under a mutex the view
  also takes** when wrapping primary_buffer in a CGImage. Retina: request pixels with DesktopScaleFactor 200/DeviceScaleFactor
  180 at 2×; resize via disp SendMonitorLayout debounced 500 ms after caps. Keys: GetVirtualKeyCodeFromKeycode(APPLE) →
  scancode; flagsChanged modifiers; ⌘→Ctrl option in Swift; unicode fallback; Ctrl+Alt+Del. Clipboard text only
  (CF_UNICODETEXT ↔ NSPasteboard, poll changeCount 0.5 s while focused). `rdp_auth_only()` (FreeRDP_AuthenticationOnly →
  last error 0 = success) = headless test + "Test connection" button.
- Certificates: FreeRDP_ConfigPath = <Application Support>/Porter/freerdp; FreeRDP's known_hosts2 is the only store
  (Always → 1, Once → 2, Cancel → 0; changed-cert callback → warning). Callbacks block the FreeRDP thread on a semaphore;
  disconnect/close releases with 0. Through-SSH (127.0.0.1) pins by fingerprint.
- Auto-reconnect: **not BatchMode** (it disables askpass). Session `silent` mode: saved password answered once, any
  other prompt cancelled; master gets `NumberOfPasswordPrompts=1`; failure → banner + Reconnect. Single-flight reconnect
  task per Session, cancelled by Disconnect/Quit/host edit; triggers master exit, NWPathMonitor .satisfied,
  didWake (2 s debounce, backoff reset); banner "Reconnecting… next try in N s" + Cancel; auto-retry only jobs failed with
  .disconnected. `host.serverAliveInterval` (default 15) replaces the literal for the master.
- Remote↔remote: Porter relays — posix_spawn both muxed commands, copy A.stdout → B.stdin in 64 KB chunks, bytes for
  progress, SIGTERM both on cancel, both statuses + stderr; temp-folder fallback (scp down/up) when either side is
  sftp-only or lacks tar. **Deviation from Fable (orchestrator):** keep a source selector on the LEFT pane (Local ▾ or any
  connected host) — with "Open in New Window" cut, that is the only way to see two hosts at once and drag between them.
- Drag remote → Finder: one NSFilePromiseProvider per row (UTType of file / public.folder; background operationQueue);
  writePromiseTo enqueues a normal download to exactly that URL and calls completionHandler when the job ends (README: Finder
  shows the item when the download completes).
- Windows VM: utmctl by bundle path; Pro via generic key; NIC must have a driver (guest tools at first logon or an in-box NIC).
- Light/dark: apply the saved appearance before the first window; RDP CGImage drawing appearance-independent.

## S. WinSCP replacement + RDP file transfer + regression cycle (user request, 2026-10-02) — binding
Goal: Porter replaces WinSCP on the Mac, plus built-in Windows RDP with copy/paste and upload/download.
- **RDP file transfer** (RDP lane): (1) **Shared folder** via drive redirection — build FreeRDP with `CHANNEL_DRIVE=ON`
  (the spike had it OFF); per RDP entry "Share a Mac folder" (on by default, folder defaults to
  `~/Downloads/Porter RDP`), visible in Windows as `\\tsclient\Porter`. RDP toolbar: **Upload…** (copies chosen Mac files
  into the shared folder, status "In Windows: \\tsclient\Porter\<name>"), **Show shared folder** (Finder); dropping
  Finder files onto the RDP view = Upload. Download = the user copies into `\\tsclient\Porter` in Windows. (2) **Clipboard
  files** (cliprdr file lists, FileGroupDescriptorW/FileContents): Finder ⌘C → Ctrl+V in Explorer; Explorer Ctrl+C →
  toolbar "Paste N files to Mac…" (choose folder, progress, cancel), and, when the total is ≤ 256 MB, Porter fetches them
  to a temp folder when the RDP view loses focus so ⌘V in Finder works. Text clipboard stays as in R.
- **Performance targets** (all lanes; verified in the regression cycle): listing a 50 000-entry folder shows within ~2 s
  and scrolls smoothly (parse off the main thread, no per-row work on main); progress parsing off main, UI updates
  throttled (≤ 10/s per job, ≤ 4/s for the queue panel); multi-GB files transfer at plain-scp speed with no UI stall; many
  small files (10 000) go as one tar stream where both ends allow it instead of per-file scp; `du`/find/listing work is
  cancellable; idle app ≈ 0 % CPU; command log and transfer history bounded in memory.
- **WinSCP parity candidates** (decided by the Fable gap review, implemented only if worth it, smallest form): Synchronize
  directories (compare, preview, mirror either way, delete option), Compare directories highlight, resumable large transfers (sftp `reget`/`reput` instead of restart), bookmarks/favourite
  folders per host, transfer include/exclude masks, speed limit (`-l`), preserve timestamps, remote find by name, Windows
  OpenSSH servers (non-POSIX shell → sftp-only mode, path quirks; testable on the Windows VM).
- **Regression cycle** after build + reviews: parallel break-it testers (transfers/perf incl. large and many files;
  names/permissions/remote ops corner cases; connection/auth/proxy/reconnect/network loss; RDP incl. clipboard + files
  against the Windows VM; UI flows/perf) → fix every verified finding → **Fable 5.1 (high) verification** of all features,
  corner cases and perf targets + gap review → implement worthwhile gaps → repeat until Fable passes (max 3 rounds).

### S.1 additions (gap review, round 1: the three WinSCP features worth having) — binding
Each in its smallest form, on the existing listing, transfer and sheet code; no new layers or settings.
- **Resume after a lost connection** (WinSCP's reget/reput): a plain single-file upload or download cut off by a lost
  connection keeps its partial copy (a download's local `.porter-<id>.part`; an upload's remote file or part), and its
  retry (Retry, or the automatic one after reconnecting) continues it with one sftp `reget` / `reput` (`-p` when times
  are kept) on a pseudo-terminal, with `progress` on so that sftp's meter (scp's format) drives the progress. When sftp
  can't continue (the partial copy is gone, or not smaller than the source), the job starts afresh as before. A kept
  local partial copy goes with Cancel, Remove, Clear Finished and Cancel All. Folders, streams and archives restart as
  before. (A file changed on the source between the tries isn't detected: sftp resumes by size, as WinSCP does.)
- **Find Files** (WinSCP's Find Files): File ▸ Find Files… (⇧⌘F) on a server pane: a name or pattern (`*` `?` `[ ]`,
  any case; text without them matches names containing it), searched below the folder shown. Shell hosts: one
  `cd <dir> && find . -iname <pattern>` with each match's kind printed by `-exec sh -c` (NUL-separated, so any name
  works; output capped at 2 MB, which also stops a search for everything early); sftp-only hosts: a walk with the
  existing listing, matched with fnmatch (case-folding). At most 10 000 results, sorted by path; folders that can't be
  read are passed over. The sheet lists them; Show (or a double-click) opens the item's folder in the pane and selects
  it. Stop / closing the sheet cancels the search.
- **Synchronize** (WinSCP's Synchronize): File ▸ Synchronize… when one pane shows this Mac and the other a connected
  server. Compares the two folders recursively, listing with `FileList.local` and `Session.list` and descending only
  into folders that are on both sides; names are matched as in conflict checks (`Names.key`, ignoring case when this
  Mac's disk or the server does). Files are the same when their sizes are and their modification times are at the
  listing's precision (the minute; the day for files over six months old, which ls and sftp show without a time).
  Sheet: direction **This Mac → server** / **server → This Mac** / **Both ways**, "Delete items that are only on <the
  destination>" (one way only), the planned uploads, downloads and deletions with their sizes, and what is left as it
  is (files newer on the destination, a file against a folder, the same time with another size both ways, symbolic
  links, names Windows can't store). One way copies what is missing or newer on the source (or the same minute with
  another size); both ways copies the newer file and what is missing on each side. Synchronize queues ordinary transfer
  jobs (folders as one stream as usual) with times kept (scp -p, tar -p), so the next compare finds the copies the
  same; deletions run as Delete on the server and Move to Trash on this Mac. `.DS_Store` and Porter's own `.porter-*`
  items are left out. Comparing can be cancelled; a folder that can't be listed stops it (rather than delete too much).

### S.2 additions (feature cycle, round 1 gap review: four more WinSCP habits) — binding
Each in its smallest form, on the existing panel, menu, sheet and transfer code; no new layers or windows.
- **Speed limit** (WinSCP's queue "Speed"): one pop-up in the Transfers panel's header, Unlimited / 1 / 5 / 10 / 50 MB/s
  (`AppSettings.transferSpeedLimit`, MB/s, 0 = none), for every host's jobs that start from then on: scp and sftp
  (reget/reput) get `-l` (Kbit/s), and Porter's own tar streams are paced to it where they pass through this Mac (the
  pump). No per-job or per-host limit.
- **Favourites** (WinSCP's bookmarks): Go ▸ Add to Favourites keeps the folder the focused server pane shows in that
  host's `SSHHost.favourites` (porter.json); Go ▸ Favourites lists the focused pane's host's favourites (choosing one
  goes there), and its Remove ▸ <folder> drops one. A pane showing this Mac: disabled, with the reason. No sheet.
- **Conflict details** (WinSCP's overwrite dialog): the Replace / Keep Both / Skip sheet gets one more line, "New: 1.2
  MB, 4 Oct 2026 at 15:21 · Existing: 1.1 MB, 3 Oct 2026 at 09:02", from the listings the conflict check already
  reads (a folder says "folder" instead of a size). No new buttons.
- **Leave out** (WinSCP's file masks): one field in the folder-transfer sheet (folders, or 200+ items): names or
  patterns (`*` `?` `[ ]`) separated by commas, e.g. `*.log, node_modules, .git`, remembered per host
  (`SSHHost.leaveOut`). What matches is left out at any depth: each tar stream gets `--exclude` (GNU, BSD and BusyBox
  tar agree), and matching items that were picked themselves aren't copied. A folder that goes with scp -r (a server
  without a shell or tar) is copied whole; the sheet says so.
- Also: a working network again (NWPathMonitor) restarts the reconnect backoff as a wake does (R's triggers alike).

## T. Agent control (user request, 2026-10-03)

**Decision (user, binding):** Porter gets a built-in **MCP server**; it renders its own windows to PNG in-process and returns them as MCP image content. No macOS Accessibility or Screen Recording permission is ever needed. One implementation serves MCP and a free CLI wrapper.

### Shape (3 pieces, one implementation)
1. **`AgentServer`** (in the app; new `Sources/Porter/AgentServer.swift` + `AgentSnapshot.swift`): a unix-socket listener in the askpass style (accept thread → one JSON request per connection → handled on the main actor → one JSON reply). Socket `Store.directory/agent/sock` (dir 0700, so `PORTER_SUPPORT_DIR` gives every test instance its own), `token` file 0600 rewritten per launch (32 random bytes hex, as `AskpassServer`). Request `{tool, arguments, token}`; reply `{content:[{type:text,text}|{type:image,data,mimeType}], isError}` — already MCP's result shape, so the bridge forwards it untouched.
2. **`Porter --mcp`** (new `Sources/PorterCore/AgentBridge.swift`, ~150 lines, `JSONSerialization` only): stdio JSON-RPC 2.0, newline-delimited. Answers `initialize` (capabilities `{tools:{}}`), `notifications/initialized`, `ping` itself; forwards `tools/list` and `tools/call` over the socket using `Askpass.exchange`. App not running or control off → `isError` "Porter isn't running, or agent control is off (Settings)". `main.swift` checks `--mcp`/`--agent` before the askpass env test, like `--proxy-connect`.
3. **`Porter --agent <tool> [json] [--out shot.png]`**: same exchange, prints the text content, writes images to `--out`. ~25 lines; this is the whole "CLI".

Agents connect with `claude mcp add porter -- ~/Applications/Porter.app/Contents/MacOS/Porter --mcp` (`-e PORTER_SUPPORT_DIR=…` for a throwaway instance); Codex `codex mcp add porter -- … --mcp`; Gemini `mcpServers` in settings.json; scripts use `--agent`. `install.sh` adds `~/bin/porter-mcp` → `exec …/Porter --mcp` (optional nicety).

**Why the others lose.** (b) CLI-only: every target CLI speaks MCP natively (typed tools, inline images); a CLI makes the agent learn syntax and read PNGs from disk — kept only as the free wrapper. (c) AppleScript/sdef: Apple Events need an Automation consent per calling app (terminal), can't carry images, and would be a hand-written parallel surface over SwiftUI views. (d) AX identifiers + external driver (the committed `testenv/uidriver/ui`): needs Accessibility + Screen Recording, owns the real mouse/keyboard/screen, one test at a time — exactly what the user wants to drop; `ui` stays only for a human pass on real drag gestures. (e) URL scheme: one-way, no results, no images.

### How "every feature" is reached with the least new code (four tiers, first that fits)
1. **Menus, generically.** Walk `NSApp.mainMenu` after `menu.update()`: path ("File > New Folder…"), key equivalent, enabled, state, `toolTip` (FilePane's validation puts the *reason* there, e.g. "file transfers (sftp) only"). Fire with `performActionForItem` — the same path ⌘-shortcuts take. This alone covers ~70 commands: File/View/Go (Files tab, routed by the responder chain to the focused pane), Host, Window ⌘1–9, Settings, Quit. Pane context menus: `pane.contextMenu(for: targets)` lists them; fired with `NSApp.sendAction(sel, to: pane)` after `validateMenuItem` — identical `check()` + action methods; targets = the selection (agent selects rows first; documented difference). Sidebar's SwiftUI context menu duplicates the Host menu, so it isn't driven.
2. **In-process accessibility tree.** `accessibilityChildren()` from `window.contentView` down: role, title/label, value, identifier, enabled, frame. AppKit controls (FilePane bars, every `NSAlert` sheet: buttons by title, accessory `NSTextField`/`NSSecureTextField`/`NSPopUpButton`/checkbox, suppression button) come for free; `NSHostingView` returns SwiftUI's own AX nodes — the objects the system AX server queries, so no TCC. Act with `accessibilityPerformPress()`, `setAccessibilityValue(_:)`. Stable ids: `.accessibilityIdentifier("hostEditor.hostname")` on the SwiftUI forms (HostEditor, RDPEditor, ProxyEditor, TunnelEditor, RunCommand, Permissions, Info, Settings, Keys, Import, Snippets; ~40 one-liners) and `identifier` on FilePane controls (~10). **Day-0 spike (2 h):** confirm SwiftUI nodes are enumerable and pressable in-process in the existing off-screen test window; if a control isn't, tier 3 covers it.
3. **In-process events.** `click x y [right|double|modifiers]`, `key combo`, `type text` build `NSEvent`s with the window number and go through `NSApp.sendEvent` — real hit-testing, same handlers, permission-free. Coordinates = window points, top-left origin = the screenshot's pixels at scale 1 = element frames in the snapshot. Also the only path into the RDP desktop (its `keyDown`/`mouseDown` → FreeRDP, with ⌘→Ctrl etc.).
4. **Hand-written, five of them**, where the GUI entry point takes data no press can carry: `drop` = the exact calls `acceptDrop`/`onDrop`/the panels' completion handlers make (`browser.transfer`, `browser.upload`, RDP `upload(urls)`; `to:"local:<dir>"` is Download To…, since `NSOpenPanel` is an out-of-process remote view that can't be driven or rendered); `select`/`sort` (`table.selectRowIndexes`, `sortDescriptors` — what clicking does); `wait`; `snapshot`; `screenshot`. Dragging is not synthesised (`NSDraggingSession` blocks the main thread).

### API surface (MCP tools; arguments JSON, results text-JSON unless noted)
| tool | arguments | result |
|---|---|---|
| `snapshot` | `include?: [sidebar,workspace,panes,transfers,log,monitor,rdp,sheets,menus,elements,settings]`, `rows?: 200`, `log?: 20` | `{windows:[{title,subtitle,frame,key,sheets:[…]}], sidebar:{connected:[{name,kind,state,transfers,shortcut}], sections:[{group,hosts:[{name,address,state,color,warning}]}], rdp:[…], proxies:[names]}, selection:{kind,name}, workspace:{tab,banner:{state,text,buttons},commandLogShown}, panes:{left:{source,dir,rows:[{name,kind,size,modified,perm,owner,group,hidden}],selected:[names],sort,filter,showHidden,status,activity,canGoBack/Forward}, right:{…}}, transfers:{summary,jobs:[{id,host,name,direction,size,percent,speed,eta,status,problem}]}, log:[{date,command,status,stderr}], monitor:{cpu,load,memory,swap,uptime,system,disks,processes(top N / search)}, rdp:{state,size,fullscreen,sharing,sharedFolderReady,remoteFiles,message}, sheets:[{title,text,buttons:[{title,enabled,default,destructive}],fields:[{id,role,label,value,enabled}]}], menus:[{path,shortcut,enabled,state,reason}], elements:[{id,role,title,value,enabled,frame}], appearance, settings(no secrets), agent:{on,lastRequest}}` |
| `screenshot` | `target?: main \| window:<title> \| sheet \| rdp \| element:<id>`, `scale?: 1 (points) \| 2` | image/png + `{width,height,scale}` |
| `menu` | `path` ("Host > Connect", "context > Rename…") | `{ok, sheet?, banner?}` |
| `press` | `id \| title`, `in?: sheet \| window:<title>` | same |
| `set` | `id \| title \| placeholder`, `value`, `in?` (text, secure, checkbox, popup/picker by option title) | same |
| `key` / `type` | `combo` ("cmd+shift+n", "return") / `text` | same |
| `click` | `x, y, button?, count?, modifiers?` | same |
| `focus` | `pane: left\|right \| target: sidebar\|filter\|desktop\|path` | same |
| `select` / `sort` | `pane, names \| all \| none` / `pane, column, ascending` | pane slice |
| `drop` | `files:[paths], pane\|target:desktop, into?` or `from: left\|right, to: left\|right\|local:<dir>, into?, move?` | `{ok, jobs}` |
| `wait` | `until: connected\|disconnected\|sheet\|no_sheet\|listed\|transfers_done\|rdp_connected\|text`, `host?, pane?, path?, text?, timeout?: 30` | the matching slice; on timeout `isError` + current state |

Every acting tool returns the open sheet (if any) and banner so a round trip is saved; prompts (password, host key, passphrase, conflicts, certificate, credentials) are answered by `set` + `press` on the very `NSAlert` the user would see, so `PromptAnswer`/`Trust` reach `Session`/`RDPSession` unchanged.

### Screenshots (in-process)
`window.contentView!.superview!` (the frame view: title bar + toolbar + content) → `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)`; works for occluded, off-screen (the tests' −20000 window) and other-Space windows (the integration lane already rendered the whole window this way). **Sheets** are their own `NSWindow`s (`attachedSheet`, recursively — the editor's Test-Connection prompt sits on the editor): each is rendered and composited at its screen offset, so the picture is what the user sees; **popovers/panels** (`NSApp.windows` visible, child of or over the main window; the Quick Look panel too) likewise. **Menus** are not captured: they draw only inside a tracking loop the agent never starts (items are fired directly); their content is in `snapshot.menus`. **Open/Save panels** are system remote views: shown as a frame, not rendered or drivable (use `drop`). **RDP desktop:** the view's layer is an IOSurface, which `cacheDisplay` can't read, so its rect is filled from `RDPSession.withFrame` (BGRX → `CGImage`, aspect-fit as the layer does); `target: rdp` returns the raw framebuffer at pixel size for reading Windows text. Default scale 1 (≈1100×700 PNG, 200–400 KB base64); `scale: 2` for Retina detail.

### Security
Off by default: `AppSettings.agentControl` (append-only field) with Settings toggle "Allow AI agents to control Porter (MCP)"; `PORTER_AGENT=1` forces it on for tests. Turning it off closes the socket at once. Same-user boundary: 0700 dir + `getpeereid == getuid` check + per-launch token in a 0600 file every request must carry (as the askpass token; a same-user process that can read the file is inside the boundary the user opted into). 1 MB request cap, JSON only, one request per connection. **Never returns secrets:** secure-field values are reported as `"•••(n)"`, Keychain is never read for a snapshot, settings/hosts are `porter.json` content (secret-free by design). Destructive tools (Delete, Cancel All, Quit) work because the user opted in; nothing is hidden. **Indicator:** sidebar footer "Agent control on" with a dot that lights for 5 s after each request (`AppModel.agentActivity`), plus a log line per request.

### Testing
*Regression agents* (throwaway instance: `open -n build/Porter.app --env PORTER_SUPPORT_DIR=$T/support --env PORTER_SSH_DIR=$T/ssh --env PORTER_AGENT=1`; `claude mcp add porter -e PORTER_SUPPORT_DIR=$T/support -- build/Porter.app/Contents/MacOS/Porter --mcp`). Session: `key cmd+n` → `set hostEditor.name "chain target"`, `…hostname target`, `…username dev`, `set hostEditor.key "id_lab · ED25519 · porter-lab"`, `set hostEditor.jump bastion` → `press Add` → `menu "Host > Connect"` → `wait sheet` (bastion password) → `set Password porter-jump`, `press "Remember in Keychain"`, `press OK` → `wait connected host="chain target"` → `screenshot` (log shows `--proxy-connect`, `-W`) → `drop files=["$T/big"] pane=right` → `wait sheet`, `press Upload` (Compress on) → `wait transfers_done` → `snapshot include=[transfers,panes]` (one job Done, `big` listed) → `press Monitor` (tab) → `wait text "porter-busy"` → `set processSearch porter-busy`, `select`, `press Kill`, `press Kill` (confirm) → `menu "File > New Remote Desktop…"` … `press Add` → `menu "Host > Connect"` → `wait sheet` → `press "Always Trust"` → `set Password …`, `press "Log In"` → `wait rdp_connected` → `screenshot target=rdp` → `drop files=["$T/a.txt"] target=desktop` → `wait text "In Windows: \\\\tsclient\\Porter\\a.txt"`.
*Suite* (`Tests/PorterCoreTests/AgentTests.swift`): bridge framing (initialize/tools/list/tools/call, malformed input, app absent) by running the real `Porter --mcp` subprocess against a test-owned socket; token/uid refusal; snapshot of the off-screen test window (sidebar, selection, banner, menus with a disabled reason); screenshot is a PNG of the window size with non-blank pixels, and differs once a `confirm` sheet is composited; SwiftUI reach: `set` + `press` in the host editor saves a host (the spike's assertion, kept as a test); against the throwaway sshd: Connect → `press Trust` → `wait connected` → `select` + `menu "File > Rename…"` → `set`/`press` → row renamed; `drop` → conflict sheet → `press "Keep Both"` → `wait transfers_done`. Lab (`PORTER_DOCKER=1`): the session above minus RDP; VM (`PORTER_WINDOWS=1`): `target: rdp` not black, desktop drop lands in the shared folder.

### Files
New: `Sources/Porter/AgentServer.swift` (socket, token, dispatch, actions, screenshot, wait), `Sources/Porter/AgentSnapshot.swift` (builders), `Sources/PorterCore/AgentBridge.swift` (`--mcp`, `--agent`), `Tests/PorterCoreTests/AgentTests.swift`. Changed: `main.swift` (2 lines); `AppDelegate` (start/stop server with the setting); `Models.swift` (append `agentControl`); `SettingsWindow` (toggle); `HostsSidebar` (indicator); `FilePane`/`HostWorkspace`/`RDPWorkspaceController`/`BrowserContentController` (a few `private` → internal: `sortOrder`, `tabs`, `bar`, `desktop`, `session`; control identifiers); the SwiftUI forms listed in tier 2 (`.accessibilityIdentifier`); `install.sh` (symlink), README (`## Agents`).

### Brief (2 Opus agents, ~1.5 days each, in worktrees)
**A — app side:** day-0 spike (in-process AX of `NSHostingView`), then `AgentServer`/`AgentSnapshot`, setting + indicator, identifiers, screenshot composite incl. RDP frame, `wait`. **B — bridge + tests:** `AgentBridge` (`--mcp`, `--agent`), `main.swift`, `AgentTests` against a mock socket first (wire format above is fixed), then against A's server; README, `install.sh`. Rules: no new abstractions beyond the tool table (`[String: (Args) async throws -> Result]`), no config beyond the one setting, no secrets in any reply, `./test.sh` green with no warnings.

### T.1 Discovery guide (user request, 2026-10-03)
An agent that connects knows nothing about Porter, so the MCP server teaches it. One source: `Resources/AgentGuide.md`
(copied into the app's Resources by build.sh). (1) `initialize` returns `instructions` (≤ 40 lines: what Porter is,
the loop snapshot → act → wait (never sleep), selectors (menu paths, ids, titles), confirm sheets must be answered,
disabled menu items return their reason, secrets show as •••, call `guide` for details). (2) A `guide` tool
(`topic?`: overview | tools | hosts | proxies | transfers | files | monitor | tunnels | keys | settings | rdp |
troubleshooting) returns the matching section: every tool with arguments and a worked example, a recipe per
feature, and the gotchas (Open/Save panels aren't drivable: use `drop`; menus aren't in screenshots: read
`snapshot.menus`; RDP keys go to the desktop with `target`). The helper answers `guide` and `instructions` itself
from the bundle, so they work when Porter isn't running or agent control is off (the guide says how to turn it on).
A test checks that every tool in `describe` appears in the guide and every menu path the guide names exists.

## U. Self-explanatory UI (user request, 2026-10-03) — binding
People don't read docs; an app that needs them doesn't spread. Porter must explain itself while it's used.
- **Every control says what it does** in one short line: tooltips (`toolTip` / SwiftUI `.help`) on every button,
  toolbar item, menu item, checkbox, pop-up, column header and status indicator; for options also the default and
  when you'd change it. Disabled items say why (FilePane's reason pattern, everywhere).
- **Forms teach**: a one-line caption under each non-obvious field (grey, small), "Optional" on optional fields,
  plain words before jargon ("Jump host — connect through another server first (ProxyJump)"), sensible defaults so
  most fields can stay empty; rarely used options under an "Advanced" disclosure.
- **Empty states guide the next step**: no hosts → "Add Host" + "Import from ~/.ssh/config"; empty pane/queue →
  "Drag files here to upload…"; no RDP entries → what RDP is for + "Add Remote Desktop"; monitor unsupported → why.
- **First run**: one skippable welcome sheet (import ~/.ssh/config, add a host, three tips: drag to transfer,
  right-click for actions, ⌘1–9 to switch), re-openable from Help ▸ Welcome to Porter. No account, no tour carousel.
- **Errors** in plain language with the next step and a button for it (most exist; audit for gaps).
- **Help menu** search finds every menu item (macOS does this for free when titles are clear); Help ▸ Porter Tips
  is a short in-app page (no website needed), built from the same text.
- **Verification**: an automated test walks every window, sheet and menu in-process (agent control's tree) and fails
  on any interactive control or menu item without a tooltip/help text; a Fable fresh-user review gets 8 first-time
  tasks (add a host via a bastion, upload a folder, sync two folders, find a file, kill a process, connect to Windows
  and paste a file, set dark mode, enable agent control) and must finish each from the UI alone, with screenshots.

## V. Cloud-ready development (user request, 2026-10-03) — for the next release
Next-release work runs in Claude cloud sessions (Linux VMs: no macOS, Docker available, only repo-level config applies —
not ~/.claude). Ready means:
1. GitHub repo (account kleash) under the new name; public at launch (free macOS Actions minutes).
2. Repo `CLAUDE.md`: architecture, conventions, operating model (Fable plans/orchestrates; Opus 5.5 max via Workflow
   agents with the model set explicitly; simplicity first), safety rules, section U rule, and the cloud loop below.
3. `.claude/settings.json` + `.claude/skills/porter-dev/SKILL.md`: push branch → `gh run watch` → read logs and the
   uploaded agent-control screenshots/snapshots → fix → PR.
4. GitHub Actions: `ci.yml` on macOS arm64 (FreeRDP vendor cache keyed by scripts/build-freerdp.sh hash, swift build,
   ./test.sh, launch the app with PORTER_AGENT=1 and run a scripted agent-control session, upload screenshots +
   snapshot JSON as artifacts); `release.yml` (tag → universal build, zip + SHA-256, GitHub Release, tap cask bump).
5. `docs/dev/`: the handoff knowledge now in /tmp/porter-handoffs (feature matrix, regression history, integration
   map, agent guide notes, UX copy) and the memory facts a cloud session needs.
6. Self-hosted runner on the user's Mac (user decision 2026-10-03: yes), label porter-mac-lab, for whatever cloud and
   GitHub-hosted runners can't do: the Docker-lab suite, the Windows-VM suite and the real-screen (`ui`) checks. It
   runs as the user (Docker, UTM, TCC grants). Public repo, so: workflow_dispatch only (never pull_request or forks),
   jobs restricted to the owner's branches, "require approval for outside contributors" on, only the lab/VM/screen
   workflows use the label; idle (no CPU) unless a cloud session triggers it with `gh workflow run`.
7. A trial cloud task end to end before real development moves there.

## W. Smart terminal (user request, 2026-10-03) — FUTURE RELEASE, plan only (replaces "built-in terminal tab")
A terminal inside Porter that understands files, so it works like a terminal with the browser's powers. This is a big
item and a key differentiator (Termius/Warp/Transmit don't combine a terminal with file-aware actions and a transfer
queue). Design it in its own planning round (Fable) before any code.
- **Terminal**: a tab per host in the workspace, using the host's existing control master (no second login), full
  xterm-compatible emulation (decide then: own emulator on top of Sources/CPTY vs vendoring SwiftTerm (MIT) — weigh
  against the no-third-party-deps rule), themes following light/dark, scrollback search, copy as plain text.
- **Knows where you are**: shell integration through the ssh session (OSC 7 for the current directory, OSC 133 for
  prompt/command/output marks), injected without editing the server's dotfiles; falls back gracefully on shells that
  don't support it (BusyBox sh, Windows OpenSSH).
- **File-aware output**: paths and names in output (ls, find, grep -l, git status, errors with file:line) become
  hoverable; right-click → Get Info, Download, Open in Porter's editor, Show in Files pane, Copy Path, Delete (with the
  usual confirm), Run; ⌘-click opens.
- **Drag and drop**: drop Finder files on the terminal → upload into the current directory through the transfer queue,
  then insert their names at the prompt; drag a path out of the output to Finder → download (file promise).
- **Command blocks**: each command with its output as a block: copy output, re-run, collapse, jump between prompts,
  exit status and duration shown.
- **Linked with the Files pane**: optional "follow" so cd in the terminal and the remote pane stay in the same folder;
  "Open Terminal Here" lands in the tab, not Terminal.app.
- **Helpers**: completion of remote paths from the listing cache, the snippets palette, per-host history.
- **Agents**: terminal buffer and input exposed through agent control, gated by the next version's approval prompts.
- **Section U applies**: every gesture discoverable (hover hints, right-click everywhere, a first-use tip).

## X. Name (user decision, 2026-10-03)
The app ships as **AirSCP** (CLI/binary `airscp`, bundle id `com.kleash.airscp`, repo kleash/airscp). The rename happens in
launch prep, after the feature cycle passes: app/bundle/binary/module names, Keychain service names (with a one-time
migration of existing "Porter" items and Application Support data), PORTER_* env vars (keep old ones as aliases for
one release), docs, guide, MCP server name, tests. Domains airscp.app/.dev were free on 2026-10-03 (registration is
the user's call).

## Y. Documentation site + Help menu (user request, 2026-10-03) — part of launch prep
- **Help menu**: "AirSCP Help" (⌘?) opens the docs site home; "Getting Started", "What's New", "Report a Problem"
  (GitHub issue form) and "Welcome to AirSCP…" / "AirSCP Tips" (section U, in-app, offline). Sheets with several
  options get a small "?" button that opens the matching docs page (one URL per topic, kept in one table in code; a
  test checks every linked page exists in docs/).
- **Site**: GitHub Pages from `docs/` in the repo (kleash.github.io/airscp, or a custom domain later), built by the
  simplest thing that gives good navigation + search (just-the-docs on GitHub Pages, or MkDocs Material via Actions —
  decide in launch prep; no app-side dependency). Not the GitHub wiki (no review, weak navigation/search).
- **Writing**: very simple English (short sentences, no jargon without a one-line explanation, task-first titles like
  "Upload a folder"), every page: what it's for → steps → screenshot → tips/troubleshooting. Categories: Getting
  started · Connecting (hosts, keys, passwords, jump hosts, proxies) · Files · Transfers & queue · Synchronize · Find ·
  Remote Desktop (Windows) · Monitor · Tunnels · Snippets & Run Command · Keys · Settings & appearance · AI agents
  (MCP) · Troubleshooting · FAQ · Privacy & security.
- **Screenshots never go stale**: generated by a script that drives the app through agent control (`screenshot`, light
  and dark) against the local test sshd / lab with neutral demo data (no real host names); CI regenerates them on
  release; the docs reference them by stable names.
- **Verification**: link check, every menu item/sheet has a docs page or anchor, a Fable read-through as a first-time
  user (can each task be done from the page alone?).

## Z. Easy for AI agents to find, install and use (user request, 2026-10-03) — part of launch
- **In the repo**: `AGENTS.md` (install, enable agent control, connect over MCP, in 5 lines), `docs/llms.txt` +
  `llms-full.txt` on the docs site, a Claude Code plugin (`.claude-plugin/marketplace.json`: the airscp skill + the MCP
  server config; `/plugin marketplace add kleash/airscp`), an MCP Registry `server.json` (+ whatever package format the
  registry accepts for a macOS app, e.g. an MCPB bundle built by release.yml), one-command install
  (`brew install --cask kleash/tap/airscp` then `claude mcp add airscp -- …/AirSCP --mcp`).
- **Published at launch** (orchestrator, no further sign-off): the official MCP Registry, Smithery, Glama, mcp.so,
  PulseMCP, awesome-mcp-servers (PR), Claude Code plugin/skill directories, and any other live AI tool directory found
  by the publishing research (docs/dev/publishing.md), plus the human launch posts (Show HN, relevant subreddits within
  their rules, X).
- **README** (user rules): hero screenshot of the two-pane window at the very top so it reads as an SCP app at a
  glance, bullets and screenshots instead of paragraphs, 2-line install, 3-line "Use it from AI agents".

### U.1 Show each host's route in the sidebar (user request, 2026-10-04)
A host that connects through a jump host and/or a proxy says so in the sidebar, so nobody has to open the editor:
- second line under the host name (small, secondary colour): `via bastion` · `via proxy corp-proxy` ·
  `via corp-proxy → bastion` (proxy first, in connection order); nothing extra for direct hosts;
- a small route icon (SF Symbol, e.g. `arrow.triangle.branch`) before that line; the row's tooltip spells out the full
  chain with user@host:port for each hop, and says when a referenced jump host or proxy no longer exists (red, like a
  missing key);
- the same route in the host's workspace header and in agent control (`snapshot.sidebar…hosts[].route`) and in the
  docs screenshots; search in the sidebar also matches the jump host / proxy names.

### U.2 Agent control indicator explains itself (user request, 2026-10-04)
The sidebar footer's "Agent control on" indicator tells the user what is happening:
- **Hover**: a tooltip with the state (idle / an agent is connected / acting now), who is connected (the MCP client's
  name from `initialize` clientInfo, e.g. "claude-code", or "airscp --agent" for the CLI), connected since, the last
  action in plain words ("Pressed “Trust” in the sheet “Trust minehop?” · 4 s ago"), and the number of actions this
  session.
- **Click**: a small popover with the last 20 agent actions (time, plain-words description, target window/host;
  secrets shown as •••), "Turn Off Agent Control" and "Settings…" buttons.
- While an agent is acting, the dot pulses and the footer reads "Agent: <client> — <last action>" (truncated).
- Plain-words descriptions come from the request (tool + target), never from field values of secure fields.

### U.3 Host editor "Other options" teaches by example (user request, 2026-10-04)
- **Caption + placeholder**: "Extra ssh settings, one per line as Name=value. Leave empty unless you need one."
  The placeholder shows two real examples (`Compression=yes`, `ConnectTimeout=10`).
- **"Add Common Option…" pop-up** next to the field: each entry inserts a line and shows a one-line explanation of
  when you'd use it. Starter set (keep short; options Porter already has as fields are left out):
  - `Compression=yes`: faster on slow links for text and logs; slower on fast networks.
  - `ConnectTimeout=10`: give up after 10 s instead of waiting long for a dead server.
  - `IdentitiesOnly=yes`: try only the chosen key ("Too many authentication failures" fix).
  - `PubkeyAcceptedAlgorithms=+ssh-rsa` and `HostKeyAlgorithms=+ssh-rsa`: old servers that only know RSA keys.
  - `KexAlgorithms=+diffie-hellman-group14-sha1`: very old servers ("no matching key exchange").
  - `AddressFamily=inet`: use IPv4 only (when IPv6 hangs).
  - `StrictHostKeyChecking=accept-new`: trust a new server's key automatically, still warn when it changes.
  - `SetEnv LANG=en_US.UTF-8`: fix garbled characters in names.
  - `IPQoS=throughput`: steadier big transfers on some Wi-Fi/routers.
  - `LogLevel=ERROR`: hide the server's banner noise in the log.
- **Checks as you type**: each line is validated with `ssh -G` (offline, nothing connects); a bad line is shown in red
  with ssh's reason. Options Porter forbids for safety (e.g. ControlPersist, ProxyCommand overrides) say why.
- The docs page "Connecting ▸ Extra ssh settings" lists the same set with examples (section Y).

### U.4 Certificate / server-key trust options for corporate setups (user request, 2026-10-04)
Corporate servers often use self-signed certificates, so users must be able to skip the prompt. Defaults stay safe,
and a relaxed setting is always visible.
- **Remote Desktop entries**, pop-up "Server certificate":
  - **Ask (default):** today's prompt.
  - **Trust automatically:** accept on first connect and remember (FreeRDP TOFU), but still warn if it CHANGES later.
  - **Don't check (insecure):** FreeRDP IgnoreCertificate; never asks.
  - **Trust my company's certificate authority:** pick a CA file (PEM/CER) used to verify this server. This is the
    proper corporate fix, so research FreeRDP's CA-path settings and prefer it in the caption.
- **SSH hosts**, pop-up "Server key":
  - **Ask (default).**
  - **Trust new servers automatically:** StrictHostKeyChecking=accept-new; a CHANGED key still blocks with the
    usual warning.
  - **Don't check (insecure):** StrictHostKeyChecking=no plus a throwaway known_hosts for that host only; the red
    caption explains the risk.
  - Proxies: the HTTP CONNECT proxy has no certificates, so nothing to add there.
- **Settings ▸ Security:** the default for new hosts and desktops (Ask unless the user changes it), with a one-line
  explanation of each choice.
- **Always visible:** a host or desktop set to "Don't check" shows an orange shield in the sidebar and workspace
  header, with a tooltip ("Certificate checks are off for this server; anyone on the network could impersonate
  it."). "Trust automatically" shows nothing extra. Agent-control snapshot fields carry the mode. Docs page:
  "Connecting ▸ Self-signed certificates and corporate networks".
- **Tests:** RDP against the Windows VM with each mode (and a changed certificate under "Trust automatically" must
  still warn); SSH accept-new against the lab (new key accepted, changed key refused). The security audit reviews
  this feature specifically.

### K.1 Generate key pairs with every common algorithm and format (user request, 2026-10-04)
"New Key Pair…" (Keys window, and a "Generate New Key…" item in the host editor's key dropdown) lets you make a key
for a new host without the command line. All of it goes through ssh-keygen, with passphrases via askpass as today:
- **Type and size**, one pop-up with a one-line explanation each:
  - **Ed25519 (recommended):** modern, short, fast.
  - **ECDSA:** 256 / 384 / 521 bits.
  - **RSA:** 2048 / 3072 / 4096 bits; for old servers and appliances; 3072+ recommended.
  - **Ed25519-SK / ECDSA-SK:** hardware security key such as a YubiKey; shown only if ssh-keygen supports it and
    explained.
  - Not offered: DSA, which is obsolete and refused by modern OpenSSH. The tooltip says why.
- **Private-key format:**
  - **OpenSSH (default).**
  - **PEM:** PKCS#1 for RSA / SEC1 for ECDSA, for older tools.
  - **PKCS#8.**

  Each says when you'd need it.
- **Public-key format** (for copying and export):
  - **OpenSSH (`ssh-ed25519 AAAA… comment`).**
  - **SSH2 / RFC 4716:** for commercial SSH servers and some network appliances.
  - **PEM / PKCS#8 public key.**

  Conversion uses `ssh-keygen -e -m …`, and the same choice is in Copy Public Key for existing keys.
- **Where:** defaults to ~/.ssh (0700) with a suggested name (`id_ed25519`, `id_ed25519_<host>` when started from a
  host) that never overwrites anything. "Change…" picks another folder; Settings ▸ Keys sets the default folder.
- **Comment** prefilled `user@mac`; **passphrase** optional, with a caption on why you'd want one, and "Remember in
  Keychain" (ssh-add --apple-use-keychain).
- **After generating:** a result sheet shows the fingerprint and the public key with **Copy Public Key** (one click;
  auto-copied when "Copy to clipboard after generating" is ticked, on by default) in the chosen format,
  **Install on Host…** (existing ssh-copy-id flow), **Use for This Host** (when opened from the host editor) and
  **Show in Finder**.
- **Tests:** each type, size and format round-trips (`ssh-keygen -l`, `-y`); a conversion test for every public
  format; no overwrite; the passphrase never appears in argv; a temp folder in tests, never ~/.ssh.

### K.2 PuTTY keys (.ppk): import and export (user request, 2026-10-04)
Windows and WinSCP users carry PuTTY keys, and ssh-keygen can't read or write .ppk (puttygen from Homebrew is not
allowed), so AirSCP handles the format itself. No new dependency:
- **Import** ("Import Key…" in the Keys window; a .ppk dropped on it; "Other…" in a host's key dropdown accepts .ppk):
  - reads PPK v2 and v3 for RSA, ECDSA (256/384/521) and Ed25519, encrypted or not. v3 uses Argon2id, taken from
    the already vendored OpenSSL 3.5 KDF through a tiny CRDP-side C helper; v2 uses CommonCrypto.
  - The passphrase is asked in a sheet. It writes an OpenSSH private key + .pub into ~/.ssh (or the chosen folder):
    the unencrypted key goes in a 0700 temp dir that is wiped right away, then `ssh-keygen -p` adds the passphrase
    the user picks (default: the same one) through askpass. It never overwrites a file, and verifies the MAC.
- **Export** ("Export as PuTTY Key (.ppk)…" on a selected key, and a format choice in New Key Pair's result sheet):
  - writes PPK v3 only (PuTTY 0.75 and later). Writing v2 was dropped on 2026-10-05: its key derivation is SHA-1 over
    the passphrase (CodeQL's swift/weak-password-hashing); v2 files are still read.
  - The passphrase is optional; v3 uses Argon2id with PuTTY's default parameters.
  - The source key is decrypted through ssh-keygen into a wiped temp copy; the private key never sits unencrypted
    outside that temp dir.
- **Tests:**
  - parser/writer round trips for every type (v3; v2 is read from PuTTY's test vectors and puttygen's files);
  - interop against PuTTY's own puttygen, built from the official PuTTY source in a temp dir by the test helper
    (CLT, MIT licence, test-only, never shipped) or against PuTTY's published test vectors;
  - a wrong passphrase gives a clear error; a bad MAC is refused;
  - secrets never appear in argv or logs; temp files are gone afterwards.
- **Docs:** "Keys ▸ Use your PuTTY (.ppk) keys" in simple English (section Y).

## AA. Tools menu + Certificate Manager (user request, 2026-10-04) — NEXT RELEASE (plan only)
A **Tools** menu gathers utilities:
- Certificate Manager…
- New Key Pair… (K.1)
- Import/Export PuTTY Key… (K.2)
- View Server Certificate… (below)

**Certificate Manager** is a GUI over the day-to-day OpenSSL / keytool work, so admins never have to remember the
commands.
- **Open anything**, by drop or File ▸ Open: PEM/CRT/CER (single or bundle), DER, PKCS#7 (.p7b/.p7c), PKCS#12
  (.pfx/.p12), Java keystores (JKS, JCEKS, PKCS#12 keystores), CSRs, and private keys (RSA/EC/Ed25519, PKCS#1/SEC1/
  PKCS#8, encrypted or not). It asks for passwords in a sheet and shows the contents as a tree: certificates, chains,
  keys and aliases.
- **Details:** subject, issuer, serial, validity with an expiry colour (expired / < 30 days), SANs, key usage/EKU,
  basic constraints, signature algorithm, public key type and size, SHA-1/SHA-256 fingerprints, and chain order with
  issuer links.
- **Convert:** PEM ↔ DER; PKCS#7 → PEM chain; PKCS#12 ↔ PEM (key + cert + chain); JKS/JCEKS ↔ PKCS#12; key format
  changes (PKCS#1 ↔ PKCS#8, add/remove/change the passphrase); public key → PEM or OpenSSH format. A "Compatible with
  older systems" switch for PKCS#12 (3DES/SHA-1, for old Java and Windows) next to the modern AES-256 default, with a
  one-line note on when to use it.
- **Extract:** a certificate, the full chain, the private key (with or without a passphrase, with a warning), or the
  public key.
- **Build:**
  - a PKCS#12/PFX from key + cert + chain (friendly name, password);
  - a truststore (JKS or PKCS#12) from CA certificates, adding and removing entries;
  - a CSR or a self-signed certificate (subject form + SANs, key type/size).
- **Check:** does this key match this certificate; verify a chain against a chosen CA bundle or the system roots;
  View Server Certificate (host:port, TLS handshake, through a connected host's tunnel if needed), showing the chain
  the server sends.
- **Transparent:** every action shows the equivalent `openssl` / `keytool` command (Copy Command) and writes it to
  the command log.
- **Implementation:** in-process libcrypto from the already vendored OpenSSL 3.5 (C shim; no CLI shipped, no Java
  needed). JKS/JCEKS read/write implemented in Swift (documented formats, integrity checked). Never overwrites;
  secrets stay out of argv and logs; temp files go in a 0700 dir and are wiped.
- **Section U applies** (every option explained), plus a docs category "Certificates and keystores" (section Y).
  Interop is tested against openssl and keytool, test-only, in a temp dir.

## AB. Mac App Store + Homebrew distribution (user request, 2026-10-04) — RELEASE 2 (plan only)
Release 2 ships in two channels from one codebase.
- **Prerequisite (user):** an Apple Developer Program membership ($99/year). It provides the Developer ID
  certificate (signing + notarization for the Homebrew/direct build) and the App Store distribution certificate,
  App ID com.kleash.airscp, App Store Connect record "AirSCP" and provisioning profile.
- **Homebrew / direct build (full features, unsandboxed):**
  - Developer ID signed, hardened runtime, notarized and stapled by release.yml (`xcrun notarytool`), so there is no
    "Open Anyway" step.
  - Cask in kleash/homebrew-tap; submit to the official homebrew/cask once it meets Homebrew's notability bar.
- **Mac App Store build (sandboxed: same app, a build flag picks the differences):**
  - **Entitlements:** app-sandbox, network.client (+ server only if tunnels/agent socket need it),
    files.user-selected.read-write, files.bookmarks.app-scope. No temporary exceptions, which App Review usually
    rejects.
  - **~/.ssh:** a first-run step "Give AirSCP access to your SSH folder" (NSOpenPanel on ~/.ssh, stored as a
    security-scoped bookmark). ssh/scp/sftp children inherit the sandbox, so OpenSSH is given explicit paths (-F
    config, -i keys, UserKnownHostsFile) inside the granted folder or the app container; control sockets live in the
    container. Without the grant, the app still works with keys added in-app (container) and an in-container
    known_hosts.
  - **Terminal hand-off:** opening Terminal with a command needs Apple Events, which the App Store build replaces with
    the built-in smart terminal (section W) or "Copy ssh command".
  - **Agent control:** keep the MCP/socket design (socket in the container; `--mcp` launched from the bundle runs
    under the same container). Replace the private AXEnhancedUserInterface call with a public-API path, or leave
    that feature out of the App Store build, to avoid a private-API rejection.
  - **Remote Desktop:** fine in the sandbox (network.client); the shared folder becomes a user-chosen folder via a
    bookmark.
  - **Self-check in CI:** `codesign -d --entitlements`, a sandbox smoke run (connect to the test sshd with a granted
    folder), a scan for private symbols, plus the App Store packaging (productbuild .pkg signed with the installer
    certificate, uploaded via App Store Connect API / Transporter from release.yml on tags).
  - **App Store assets:** screenshots generated by the docs screenshot script, description, keywords, privacy
    "Data Not Collected" label, support URL = docs site.
- **Feature parity:** a table in the docs of what differs in the App Store build (e.g. Terminal.app hand-off), each
  with the in-app alternative; anything missing points users to the Homebrew build. Section U applies (the sandbox
  folder grant is explained in plain words).
- **Order in release 2:** Developer ID signing + notarization first (better brew experience at once), then the
  sandbox build, App Review submission, then the official homebrew/cask PR.

## AC. Launch + post-launch verification loop (user request, 2026-10-04) — part of v1 launch
Publishing isn't done until it is verified from the outside, as a stranger (human or AI agent) meets it. After each
launch step, and again once everything is public, run this loop: verify → fix (patch release v1.0.x if the app or
release assets change) → re-verify, until every check is green.
- **GitHub repo:**
  - public, description, topics (sftp, scp, ssh, winscp, rdp, macos, mcp, ai-agents), website = docs site, social
    preview image set;
  - the README renders: hero image loads at the top, every image and link works (checked against the live page, not
    the local file);
  - licence detected as Apache-2.0; SECURITY/CONTRIBUTING picked up; issue forms work;
  - CI green on main; fork-PR approval required; Actions can't reach the self-hosted runner from PRs.
- **Release:**
  - v1.0.0 exists with the universal zip + SHA-256 and the MCPB/registry asset if any; release.yml green; notes
    correct; checksums match the downloaded files.
- **Homebrew:**
  - on this Mac, `brew tap kleash/tap && brew install --cask airscp --appdir=<temp dir>` installs, the app launches
    (the "Open Anyway" path matches the README), `airscp --mcp` answers initialize, then uninstall + untap;
  - `brew audit --cask --online kleash/tap/airscp` has no errors.
- **Docs site:**
  - live at its URL; a crawl of every page → 200; every image loads; search works; navigation categories as Y;
  - every Help-menu and "?" URL baked into the released app resolves to a live page (an app test lists them; the
    loop fetches each one);
  - llms.txt / llms-full.txt reachable; the README ↔ docs links both ways work.
- **AI discoverability (Z):**
  - each directory entry is live, or its submission is recorded with status and link (pending review is fine; record
    it and re-check later);
  - MCP Registry entry returned by its API; awesome-mcp-servers PR open;
  - a FRESH agent test: a Claude Code session with a clean config and no project context is told only "install and use
    AirSCP to list files on <lab host>". Using public info (README/AGENTS.md/registry/plugin) it must install
    (brew + `claude mcp add` or the plugin), connect through agent control, and succeed. Every stumble is fixed in the
    docs or packaging.
- **Launch posts:**
  - Show HN, the chosen subreddits (within each one's rules) and X are live: URLs recorded; links in the posts work
    and point to the repo/docs; posts not removed by moderation (re-check after ~1 h).
  - Afterwards, a check after 24 h and 72 h: new issues, questions and directory approvals get answered or fixed,
    with notes in porter-ops.
- **Ledger:** all launch URLs and statuses are kept in porter-ops/launch-ledger.md, so a resumed session knows exactly
  what is live.

## AD. Apple Intelligence (Foundation Models) + App Intents (user request, 2026-10-04) — RELEASE 2 (plan only)
Both frameworks are in the macOS 26 SDK installed here. App Intents' metadata processor (appintentsmetadataprocessor)
ships only with Xcode, not the Command Line Tools, so release 2 builds intents on CI's Xcode (GitHub macOS runners,
which release 2 needs anyway for the App Store, section AB). Local CLT builds still work, just without registered
intents; build.sh says so.
- **App Intents (macOS 13+; Spotlight entities 15+): AirSCP actions in Shortcuts, Siri, Spotlight and the Action
  button.**
  - Entities: Host, Remote Desktop entry, Snippet, Favourite folder, saved Synchronize pair.
  - Intents:
    - Connect to Host; Open Remote Desktop;
    - Upload Files (files + host + folder); Download Files (host + paths → Mac folder);
    - Run Synchronize (a saved pair, preview or run); Run Snippet; Find Files (returns paths);
    - Start/Stop Tunnel; Get Transfer Status; Disconnect All.
  - App Shortcuts with natural phrases ("Upload to <host> with AirSCP"); hosts indexed in Spotlight; a Control Center
    control (macOS 26) to toggle a tunnel.
  - Every intent reuses the same action code as the GUI and agent control (no parallel implementation), shows the
    usual confirm for destructive actions, and is covered by section U wording.
- **Foundation Models (macOS 26+, Apple Intelligence Macs; on-device, private, offline): optional and hidden when
  unavailable** (`SystemLanguageModel.default.availability`; `if #available(macOS 26, *)` and
  `#if canImport(FoundationModels)`, so the app still runs on macOS 13).
  - **Ask AirSCP:** a command bar (⌘K-style) that turns plain requests into actions, e.g. "upload the site folder to
    prod, skip node_modules" or "find big log files on target". It uses tool calling over the SAME action registry
    agent control exposes; it shows the planned steps and runs them only after the user confirms (destructive steps
    always confirm).
  - **Explain:** turn ssh/scp/RDP errors and Monitor readings into plain-language causes and next steps ("why can't I
    connect?"), summarise the command log, explain a snippet before it runs.
  - **Help me fill in:** suggest Other options lines (U.3), exclude patterns, find patterns and permission modes from a
    sentence; the user always sees and confirms the exact value.
  - **Privacy:** everything stays on the Mac (Apple's on-device model). Settings ▸ Apple Intelligence on/off; a clear
    note in the docs and the App Store privacy label.
  - **Implementation:** prefer DynamicGenerationSchema/plain prompts if the @Generable macro plugin isn't available to
    the CLT toolchain; bound context (send summaries, never whole files or secrets); a test double for the model so
    tests run on any Mac/CI.
- **Docs and agents:** a docs category "Shortcuts, Siri and Apple Intelligence"; the AgentGuide notes that the same
  actions are reachable three ways (GUI, MCP, App Intents).

### V.1 Work split for release 2 (user decision, 2026-10-04)
Cloud first: Claude cloud sessions write code, run Linux/Docker work and drive GitHub. GitHub macOS runners (with
Xcode) build, run the test suite and agent-control tests, generate App Intents metadata and package releases.
**Whatever neither can build or test runs on the user's Mac** through the self-hosted runner (label porter-mac-lab,
workflow_dispatch only; see V item 6), triggered by the cloud session:
- the Docker-lab suite, the Windows-VM (UTM) RDP suite, and real-screen `ui` checks (menus, drag and drop, Finder,
  Open/Save panels, Quick Look, appearance);
- Foundation Models tests on the real on-device model. GitHub's runners are VMs without Apple Intelligence; on this
  M1 Pro it currently reports `appleIntelligenceNotEnabled`, so the user switches it on in System Settings ▸ Apple
  Intelligence & Siri before release-2 testing (one-time model download);
- runtime checks of App Intents (Shortcuts/Siri/Spotlight actually invoking the CI-built app, downloaded as an
  artifact) and the sandboxed App Store build's real-folder-grant flow;
- anything needing the user's local signing identities in the login Keychain (if signing isn't moved to CI secrets).
The lab workflow (lab.yml) grows one job per item, each with a label and a clear summary posted back to the run.

### AB.1 Developer ID signing + notarization moves into v1 (user enrolled, 2026-10-04)
The user installed Xcode 26.6 (now the active developer dir) and enrolled in the Apple Developer Program, so v1.0.0
ships signed (Developer ID Application, hardened runtime, the entitlements the app needs: network client/server for
tunnels and agent socket, Apple Events for the Terminal hand-off) and notarized + stapled, with no "Open Anyway" step.
- `scripts/release-local.sh`: builds the universal app, signs with the Keychain's Developer ID identity, notarizes
  with `xcrun notarytool submit --keychain-profile airscp-notary --wait`, staples, zips, and prints the SHA-256;
  verified with `spctl -a -vvv -t exec` and `codesign --verify --deep --strict`.
- release.yml: same steps when CI secrets exist (DEVELOPER_ID_P12, DEVELOPER_ID_P12_PASSWORD, notary App Store
  Connect API key); otherwise it falls back to attaching the locally built notarized zip. CI secrets come in release 2.
- The hardened runtime must not break: askpass/proxy helper modes, spawning /usr/bin/ssh etc., FreeRDP (static,
  fine), the agent socket, Apple Events to Terminal (needs NSAppleEventsUsageDescription + the
  com.apple.security.automation.apple-events entitlement). Test all of it on the notarized build.
- The README and docs drop the "Open Anyway" instructions once notarized (keep a short note for older downloads).
- The build still works with CLT only (unsigned/ad-hoc) for contributors.
- The App Store build (sandbox) stays in release 2 (AB).

### O.1 Themes "Night Harbor" (dark) and "Paper" (light) — v1 (user approved 2026-10-04)
Spec: the mockup page https://claude.ai/artifact/4E2VH58NbB1bjsz1u7rtmF (source porter-ops/design/airscp-themes.html),
built only from native AppKit/SwiftUI colour tokens (semantic + systemX palette + materials):
- **Night Harbor:** a systemIndigo 7 % wash over windowBackgroundColor/controlBackgroundColor (off under Increase
  Contrast); section hues via `.tint`: hosts blue, Remote Desktop purple, proxies orange, lab/monitor teal, agent
  pink, success green, error red; blue→purple gradient progress capsules; status dots glow in their own colour;
  pulse strip with rings.
- **Paper:** windowBackgroundColor ground with controlBackgroundColor panes as 10 pt cards; the black pill
  (labelColor fill + controlBackgroundColor text) for the selected sidebar row, active tab and primary buttons;
  hairline table grid; heavy numbers + a monochrome sparkline in the pulse strip; colour only for status.
- Both: the same layout. The compact "server pulse" strip (CPU/memory/disk) reuses the Monitor sampler and hides
  when unsupported. No asset-catalog colours; the PLAN § O hard-coded-colour gate stays green. Settings ▸ Appearance
  stays System/Light/Dark. Accent colour, Increase Contrast and Reduce Transparency keep working.
- Applied after the v1 build and before the verification loop; the docs, README and App Store screenshots are
  regenerated in the new look.

## AE. Debug logs (user request, 2026-10-05) — v1
"Add debug logs which, if enabled, capture what happened in case of failures like being unable to scp via a proxy and
bastion host." Off by default; one switch; a single plain-text file a user can attach to an issue.
- **Switch:** Settings ▸ Advanced (or General) "Debug logging" with a caption ("Writes a detailed log of connections
  and transfers to help find what went wrong. Turn it off when done."), also `AIRSCP_DEBUG=1` for tests and agents.
  Takes effect for new connections; the sidebar/status bar shows a small "Debug logging on" hint while on.
- **What it captures, per host (timestamped, host name in each line):**
  - ssh with `-v` (`-vv` is enough; no `-vvv` packet noise) on the master connection and every command's stderr, so a
    jump-host chain shows each hop (`ProxyJump`, "Authenticated to", "channel open failed", host-key decisions);
  - the `--proxy-connect` helper: proxy address, CONNECT target, the proxy's status line (200/407/502), timing, which
    hop it served — never the Proxy-Authorization value;
  - askpass: which prompt was asked and that it was answered/cancelled — never the answer;
  - connection state changes, auto-reconnect attempts and backoff, transfer start/finish/failure with the mapped error
    and the raw ssh/sftp error text, the exact command lines (as the command log shows them);
  - Remote Desktop: FreeRDP's WLog at INFO (DEBUG only for the connection/TLS/NLA/gateway/cliprdr/drive channels),
    routed into the same file.
- **Redaction:** passwords, passphrases, proxy credentials, tokens (agent socket token) and clipboard/file contents
  never reach the log; a unit test feeds known secrets through every path and greps the file.
- **File:** `~/Library/Logs/AirSCP/AirSCP-debug.log` (a throwaway instance writes under its AIRSCP_SUPPORT_DIR),
  rotated at 10 MB with one previous file kept; nothing is sent anywhere.
- **Getting it out:** Help ▸ "Show Debug Log in Finder" and "Copy Diagnostics" (app/macOS version, ssh -V, the last
  ~500 lines); a failure banner offers "Show Debug Log" when logging is on and "Turn on debug logging and try again"
  when it is off; Report a Problem's issue form asks for the file. Agent control exposes the log path (snapshot field)
  so an agent can read it, and the agent guide says when to use it.
- **Docs:** one Troubleshooting page section ("Turn on debug logs") with a screenshot.
- **Tests:** lab tests break each chain on purpose (wrong proxy password → 407, bastion down, private host via
  openproxy→bastion with a wrong key, refused target) with AIRSCP_DEBUG=1 and assert the log names the failing hop;
  the redaction test; a size/rotation test; off by default writes nothing.
- Simplicity: one small logger type (file handle + serial queue), no logging framework, no levels beyond on/off.

## AF. Security and vulnerability scanning + README badges (user request, 2026-10-05) — v1 launch
"Add security and vulnerability scans and badges on GitHub to show the open-source community it has no CVEs and no
vulnerabilities." Badges must be live results from real scans, never static images; the claim is "no known
vulnerabilities, scanned on every change", which stays true only while the scans are green. **When scans run
(owner, 2026-10-05; supersedes the daily/weekly schedules first planned here): no schedules — pushes to main, pull
requests and by hand; security.yml also before every release; Dependabot monthly.**
- **Code scanning:** CodeQL (`.github/workflows/codeql.yml`) for Swift and C (the CRDP shim, porter_crypto.c) on a
  macOS runner, on push to main, PRs and by hand; `security-extended` queries; vendored FreeRDP/OpenSSL source excluded.
  Results upload once the repo is public (free code scanning); until then the job runs and keeps the SARIF artifact.
- **Dependency CVEs:** the app has no package-manager deps; its third-party code is the vendored FreeRDP and OpenSSL
  pinned in scripts/build-freerdp.sh. Generate an SPDX or CycloneDX SBOM (`sbom.json`, with purls/CPEs for
  freerdp@<ver> and openssl@<ver>, plus the macOS system OpenSSH as a runtime note) from those pins, and scan it with
  OSV-Scanner (and/or Grype) on push to main, PRs and before every release; fail on any known vulnerability; the
  release attaches the SBOM.
  A test keeps the SBOM in step with build-freerdp.sh. If a scan finds a CVE: upgrade the pin before launch.
- **Secrets:** gitleaks over the full history in CI; at launch turn on GitHub secret scanning + push protection.
- **Supply chain:** OpenSSF Scorecard workflow (`scorecard.yml`, publish_results) + badge; every action pinned to a
  commit SHA with the version in a comment; least-privilege `permissions:` per workflow; Dependabot for
  github-actions (monthly) — the only ecosystem with a manifest.
- **At launch (repo public):** enable Dependabot alerts, secret scanning + push protection, private vulnerability
  reporting; confirm CodeQL/Scorecard/OSV green and zero open alerts in the Security tab; optional OpenSSF Best
  Practices (bestpractices.dev) passing badge, filled in honestly.
- **README:** one compact badge row under the hero image: CI, CodeQL, Vulnerability scan (OSV), OpenSSF Scorecard,
  Licence, latest release; SECURITY.md lists the scans and how to report. Post-launch verify (AC) checks every badge
  renders and links to a green run.
- Simplicity: three small workflows (codeql.yml, security.yml for SBOM+OSV+gitleaks, scorecard.yml) and one SBOM
  script; no paid tools, no extra services beyond GitHub + OSV.

## Release 2 backlog
Worth doing, not cheap enough for v1: one line each (feature — why — smallest form). From the round-1 fix step
(2026-10-05, verify-r1 findings); later fix steps add to it.
- Dark-mode Blue tag — in Night Harbor a Blue tag looks the same as an untagged host — draw untagged chips neutral in
  dark (as Paper does), or give tagged chips a stronger fill.
- Workspace header route line — middle-truncated while the pulse strip takes the room — put the route on its own line,
  or truncate the address first.
- Cut labels — "Export as PuTTY Key…" in the key result sheet and the empty sidebar's "Import from ~/.ssh/config…" are
  truncated — shorten to "Export .ppk…" or widen the sheet; let the empty state wrap.
- Config import with over ~100 aliases — agents can't see the rows, so they can't leave aliases out — answer the rows
  from `ConfigImport`'s model in snapshot/select/set, as is done for keys and Find results.
- Pulse strip in Paper (light) — figures have no unit, total or "free", and VoiceOver reads each tile's help three
  times — show the units as dark mode does, and put `.help` once on the combined element.
- Route line for a custom ProxyCommand (U.1) — a host that runs a command to connect looks direct in the sidebar — show
  "via a proxy command" when its options have ProxyCommand.
- Copy ssh Command for a password-less proxy — currently off; such hosts could have a working command — generate
  `nc -X connect -x host:port %h %p` for proxies without a user name.
- Test infrastructure — in in-process tests, ticking an NSAlert checkbox through the agent and then pressing OK ends the
  test process's run loop: `swift test` exits 0 mid-test, so a failure goes unseen (the real app is fine) — find out
  why; meanwhile tests tick such checkboxes directly. Also seen (1.1.0): an agent's press whose action opens an alert
  sheet, with another agent test running; the process exits from `swift_task_asyncMainDrainQueue` (its `CFRunLoopRun`
  returned: something stopped the main run loop).

Dropped (owner, 2026-10-06): Keep remote directory up to date (watch a Mac folder and upload changes), synchronized
browsing, Remote Desktop Gateway, showing names with a line break in server listings, and the Cline MCP Marketplace listing.
