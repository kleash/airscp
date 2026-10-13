---
title: What's New
nav_order: 18
---

# What's new

## AirSCP 1.2.0

- **AI agents ask before they change things**: before an agent deletes, copies or runs something, types into a
  Terminal tab or works on a Windows desktop, a small window asks you: **Deny**, **Allow Once** or **Allow for 15
  Minutes**. Turn it off in **Settings ▸ Ask before agents change things**. See
  [Allow or deny what an agent changes](ai-agents.md#allow-or-deny-what-an-agent-changes).
- **More in Shortcuts, Siri and Spotlight**: **Upload Files**, **Download Files**, **Find Files**, **Run Snippet**,
  **Start Tunnel**, **Stop Tunnel** and **Open Favourite Folder**. Spotlight (macOS 15 and later) finds your saved hosts
  and Remote Desktops by name. See [Shortcuts, Siri & Apple Intelligence](shortcuts-and-ai.md).
- **Ask AirSCP does things**: describe it (“upload ~/Sites/site to web-01, leave out node_modules”), click **Do It…**,
  read the steps, then click **Run**. Nothing runs before that, and AirSCP still asks before it replaces anything.
- **Explain, Summarize and Suggest**: **Explain…** in Monitor and in Snippets, **Summarize…** in the Command Log, and
  **Suggest…** next to Other ssh options, Leave out, Find Files' pattern and permissions. All on this Mac.
- **Select by pattern**: **Edit ▸ Select by Pattern…** (<kbd>⌘+</kbd>), Deselect by Pattern, Select Same Kind and
  Invert Selection. **File ▸ Compare Folders** marks what differs between this Mac's folder and the server's. See
  [Select by pattern, compare folders, move, link](files/select-and-compare.md).
- **Move, copy and link on a server**: **File ▸ Move To…**, **Copy To…** and **New Symbolic Link…**; **Copy Names**;
  **Go ▸ Other Pane's Folder**.
- **Move between this Mac and a server**: **Upload and Delete…**, **Download and Delete…**, or hold <kbd>⌘</kbd> while
  you drag. Originals go only after their copy is done (and its checksum matches, when transfers are verified).
- **Replace If Newer** when a file already exists: only newer files are copied.
- **The Transfers list**: **Move Up** and **Move Down** for waiting transfers, and **When Done**: disconnect, sleep this
  Mac or a notification once everything has finished.
- **Owner, group and checksums**: Permissions… changes the owner and group; Get Info works out a file's SHA-256 (or SHA-1,
  MD5) and compares it with one you paste.
- **Snippets on selected files**: `{file}`, `{files}`, `{name}` and `{folder}` in a snippet, then right-click ▸ **Run
  Snippet**. See [Save commands as snippets](commands/snippets.md).
- **Synchronize options**: compare by size and date, size only, date only or contents (SHA-256); only files on both
  sides; also replace newer files; and **Reverse** one file. See [Synchronize](synchronize.md).
- **Favourites remember this Mac's folder too**, when the other pane shows one.
- **The editor** has a find bar (<kbd>⌘F</kbd>), **Go to Line…** (<kbd>⌘L</kbd>) and **Revert to Server Version**.
- **Find Files' results**: select several, then **Download…**, **Delete…** or **Copy Paths**.
- **The Terminal tab knows your commands** (bash and zsh): each one shows how it ended and how long it took;
  right-click it for **Copy Output**, **Copy Command** and **Run Again**; <kbd>⌘↑</kbd> and <kbd>⌘↓</kbd> jump between
  them. <kbd>⌘F</kbd> finds text, **Follow in Files** keeps the server pane in the shell's folder, **Insert Snippet**
  types a snippet at the prompt, and a setting sends **Open Terminal Here** to the tab. See
  [The Terminal tab](commands/terminal-tab.md).
- **Server Info, Change Password, links**: **Host ▸ Server Info…** shows the server's key fingerprint, software,
  encryption and free space; **Host ▸ Change Password…** runs `passwd` in the Terminal tab; `sftp://` and `ssh://` links
  open in AirSCP, and **Host ▸ Copy Link** makes one. See [Server information](connecting/server-info.md).
- **Browse and copy as root**: **Host ▸ Edit… ▸ Advanced ▸ Browse and transfer as**, with sudo that needs no password.
  See [Browse and copy files as root](connecting/browse-as-root.md).
- **Proxies**: SOCKS5 proxies; HTTP proxies that ask for a Digest login; and Import from WinSCP keeps a site's proxy
  when you already have its bastion.
- **Certificate Manager**: **New…** makes a key with a certificate request (CSR) or a self-signed certificate;
  **JKS…** and **Truststore…** write Java keystores and truststores (PKCS#12 or JKS); **Verify…** checks a
  certificate's chain against a CA bundle or the authorities this Mac trusts, for a host name too. See
  [Create a certificate or request](certificates/create.md).
- **Fixed**: on accounts that allow only sftp, a path longer than sftp takes on one line (about 2,000 bytes) is
  refused with a message: a server with such deep folders could otherwise have had sftp run the rest of the path as a
  command on this Mac.
- **Fixed**: Get Transfer Status said nothing once every transfer had finished.
- **Fixed**: PKCS#12 files made with **Compatible with older systems** had no password check (MAC), which older
  systems expect.

## AirSCP 1.1.0

- **Shortcuts, Siri and Apple Intelligence**: AirSCP's actions (Connect to Host, Open a Shell, Open Remote Desktop,
  Disconnect All, Transfer Status) are in Shortcuts and Spotlight. On a Mac with Apple Intelligence, **Help ▸ Ask
  AirSCP…** answers questions on this Mac, and a failed connection has **Explain…**. See
  [Shortcuts, Siri & Apple Intelligence](shortcuts-and-ai.md).
- **Certificate Manager**: **Tools ▸ Certificate Manager…** opens certificates, keys, chains, PKCS#12 files and Java
  keystores, shows their details and expiry, and saves them as PEM, DER, chains, keys or PKCS#12, each with the
  `openssl` command that does the same. **Tools ▸ View Server Certificate…** shows what a TLS server sends. See
  [Certificates and keystores](certificates/index.md).
- **A terminal inside AirSCP**: each host has a **Terminal** tab (**Host ▸ Terminal Tab**, <kbd>⌃⌘T</kbd>) with a
  shell on the server, through the same connection. Right-click a file name in its output to show it in Files,
  download it, edit it or copy its path; drop Finder files on it to upload them where you are. See
  [The Terminal tab](commands/terminal-tab.md).
- **Import your sites from WinSCP**: **File ▸ Import from WinSCP…** reads the WinSCP.ini that WinSCP exports and makes
  hosts with their groups, keys (.ppk files), tunnels and HTTP proxies. Saved passwords stay behind. See
  [Import your sites from WinSCP](connecting/import-from-winscp.md).
- **AI agents click the right spot on a Windows desktop**: they click in the pixels of the desktop picture AirSCP
  gives them, see a close-up of each click, and can press the Windows key (<kbd>⊞</kbd> <kbd>E</kbd>,
  <kbd>⊞</kbd> <kbd>R</kbd>). Their guide tells them to use the keyboard first.
- **See which ports a server listens on**: **Monitor ▸ Ports** lists them with the program, its user and how many
  connections each has, and shows who is connected to the one you pick, from which addresses. Kill the program, or
  show it among the processes. AirSCP reads the ports only while you look at them.
- **Tunnels say where they lead**: **Add Tunnel…** reads as a sentence (open port 8080 on this Mac, through your
  server, to the server itself, port 80), and the whole route shows as you type and in the list. The second port is
  the same as the first until you change it.
- **AI agents go through folders without clicking**: they go to a folder by its path and open a file or folder by its
  name, and get the folder's list back at once. You still see each step in the window.
- **Synchronize** leaves out what matches the server's **Leave out** patterns (the same list as for folder
  transfers, shown and changed in the sheet), and you can untick items in the list before you click **Synchronize**.
- **The editor never overwrites someone else's changes unasked**: when a file changed on the server after you opened
  it, **Save** asks first and can show you the server's version.
- **Owner and Group show names** on servers, as **Get Info** does. Point at one to see its number.
- **Pause and resume transfers**: one at a time from the Transfers list (right-click), or all at once with **Pause All**
  and **Resume All**. A single file continues where it stopped. See [Pause and resume transfers](transfers/pause-and-resume.md).
- **Check copies with SHA-256**: **Verify with Checksum** compares a copied file with the original, and **Settings ▸
  Verify transfers with SHA-256** checks every file as it arrives. A damaged copy shows **Mismatch**, and **Retry**
  copies it again. See [Check a copy with its checksum](transfers/verify-checksums.md).
- The toolbar's **+** lists **New Host…** first. Before, it showed only **New Remote Desktop…** and **New Group…**.
- In the New Host and Remote Desktop sheets, the blue ring around the field you type in fits the field.
- After **Disconnect**, the server's pane no longer shows files that may be out of date. It says it is disconnected,
  and **Reconnect** shows the same folder again.
- The horizontal scroll bar no longer covers the last file in a long folder.
- **Debug logging on**, at the bottom of the sidebar, has a **Turn Off** button. **Help ▸ Turn On Debug Logging**
  (**Turn Off Debug Logging** while it is on) switches it too.
- **Remote Desktop full screen shows the way out**: a note says <kbd>⌃⌘F</kbd> leaves it, and the menu bar comes
  down at the top of the screen with **View ▸ Exit Full Screen**.
- **The shared folder explains itself**: the bar says how to open `\\tsclient\AirSCP` in Windows, with a button that
  copies the path. When Windows' policy blocks shared folders (Explorer shows an empty **tsclient**), the bar says so,
  and to copy and paste files instead.

- Smaller things: in dark mode a Blue tag no longer looks like an untagged host; the host's route has a line of its
  own above the tabs; in light mode the server figures above the tabs show their units, totals and free space; a host
  whose Other options connect through ProxyCommand or ProxyJump shows that route in the sidebar; **Copy ssh Command**
  works for hosts behind an HTTP proxy without a login; AI agents see every alias of **Import from ~/.ssh/config**,
  however many there are; AirSCP clears the temporary folders a stopped copy of it left behind.

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
