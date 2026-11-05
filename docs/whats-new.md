---
title: What's New
nav_order: 18
---

# What's new

## AirSCP 2.0.6

- **Disk Usage opens in its own window**: keep browsing while it scans, and open several. It works on every server:
  Windows, servers that only allow file transfers (sftp), and S3 storage too.
- See how full the disk is, totals **By Type** (.log, .gz, …), and in **Changes** what grew since your last scan.
- **Open but Deleted** finds deleted files that a program still holds open: their room comes back only when the
  program closes them.
- **Empty File…** frees a big log's room at once, even while a program writes to it. **Download as .tar.gz…** keeps a
  copy before you delete, and **Export as CSV…** saves any list.
- Disk Usage says which folders it couldn't read and, where your account can use sudo, offers **Scan as Root…**.

## AirSCP 2.0.5

- **Compare, side by side**: the two files in two columns, lines kept in line, with line numbers and the changed
  letters marked. Scrolling moves both sides together (untick **Sync Scrolling** to move one). Go from one difference
  to the next with <kbd>⌥⌘↓</kbd> and <kbd>⌥⌘↑</kbd>, or click the bar at the right.
- In Compare, **Prettify** lays out JSON and XML before comparing (**Original** or <kbd>⌘Z</kbd> puts them back), and
  **Ignore** leaves out whitespace, case or blank lines. Copy a difference to the other side, then save either file, on
  this Mac or on the server. **Swap**, **Reload** and find (<kbd>⌘F</kbd>) are there too.
- **Compare a file on this Mac with one on a server**: select one file in each pane, right-click ▸ **Compare with**.
  Files that aren't text are compared by their SHA-256 checksums.
- **Two servers side by side**: the menu above the left pane lists every saved server. Choose one and AirSCP connects
  it and shows it there, so you can copy between the two servers.
- **Open Terminal** and the **Terminal** tab start in the folder the Files tab shows, on every server.
- **Windows servers**: the **Monitor** tab shows CPU, memory, drives, processes and ports, and **Kill** stops a
  process. The Terminal tab and **Open Terminal Here** open cmd.exe or PowerShell in the folder you are looking at.

## AirSCP 2.0.4

- **Compare two files**: select two text files, right-click ▸ **Compare**. Lines only in one of them are marked red or
  green.
- **Open With**: right-click a file ▸ **Open With** to open it in an app you choose.
- **The path bar**: click the folder shown to type a path. Right-click any folder in it for **Get Info**, **Download
  To…**, **Rename…**, **Copy Path** and more.
- **Paste** is in a file's right-click menu too, and a full folder keeps empty space below its last item to right-click
  for the folder's menu (**New Folder…**, **Show in Finder**…).
- The **Kind** column now comes after **Date Modified**.
- **Follow in Files**: ticking it sends the shell to the folder the Files tab shows, and the Files tab stays there.
- **Fixed**: <kbd>Return</kbd> didn't answer the Delete question. In the Terminal tab, a selection highlighted the whole
  line instead of only the text selected.

## AirSCP 2.0.3

- **The monitor works on Mac servers**: CPU, memory, swap, load, disks and processes, with Kill, in the Monitor tab
  and on iPhone and iPad (ports stay Linux only).
- **iPhone and iPad**: the Terminal tab has **Disconnect** for a server's last terminal. A folder you copy shows how
  many files are done and how many are to go, and how far the whole folder is.
- **Fixed** on iPhone and iPad: tapping the Terminal tab sent the tab bar back to the tab before for a moment.

## AirSCP 2.0.2

- **Fixed: Windows SSH servers** (Windows' own OpenSSH). A folder showed empty, because AirSCP didn't read how newer
  versions list permissions. Now folders list, and the top of the path (the server's name) shows the drives (C:, D:…)
  to go to. The Terminal tab opens the server's own shell (cmd.exe or PowerShell) instead of ending at once.

## AirSCP 2.0.1

- **Copy Path from the path bar**: right-click the path above a Files pane's list ▸ **Copy Path** copies the full path
  of the folder shown.
- **Follow in Files goes both ways**: with it ticked in the Terminal tab, a folder you open in the server pane has `cd`
  typed at the shell's empty prompt, so the shell goes there too. AirSCP never types into a running command.
- **Fixed** in the Terminal tab: a double-click just before a word (on the space in front of a PID in `ps -ef`, say)
  selected the space with the word.

## AirSCP 2.0.0

- **AirSCP for iPhone and iPad** (iOS 26 or later): save your servers and S3 storage, or find them on your network with
  **Nearby**. Copy files between a server and your device, or between two servers: a file you copy is checked against
  the original. Share files, save them in the Files app, or carry them from place to place in the tray. Edit text files,
  type in a terminal with the keys a phone keyboard lacks, run a command on several servers at once, and watch a Linux
  server's CPU, memory and processes. Keys stay in the Keychain on your device, and Face ID unlocks them. See
  [iPhone and iPad](iphone-ipad/index.md).
- **On iPad**: a sidebar with a workspace for each open server (its files, its terminal pulled up under them, and the
  transfers), several windows, drag and drop with other apps, keyboard shortcuts and the pointer. On an iPhone Duo,
  AirSCP follows the fold and keeps what you were doing. See [iPad and iPhone Duo](iphone-ipad/ipad.md).
- **Fixed** on the Mac (macOS 27): an AI agent that chose from two pop-up menus at once, or while AirSCP was busy,
  could leave a menu open.

## AirSCP 1.4.0

- **Disk Usage**: **File ▸ Disk Usage…** shows what takes the room below a folder, on a server or on this Mac. While
  it scans, a bar shows how far it is, the files it finds show with their sizes, and the rings and the list grow as
  the sizes add up. Point at a ring to see what it is; click a folder's ring, or double-click it in the list, to go
  into it. **Largest Files** lists the 200 biggest files below. Select what you don't need and **Delete…** it (on this
  Mac it goes to the Trash), or **Show** it in the pane or in Finder. See [Disk Usage](disk-usage.md).

## AirSCP 1.3.0

- **Amazon S3 and S3-compatible storage**: **File ▸ New S3 Connection…** saves an Amazon S3, MinIO, Cloudflare R2,
  Backblaze B2, Wasabi or Ceph account. Its buckets open in the Files tab like a server's folders: browse, drag files
  in and out, rename, move, copy, delete, edit, Get Info, Find Files and Synchronize. Big files go in parts that
  survive a pause. The secret key stays in your Keychain. See [S3 storage](s3/index.md).
- **Import from ~/.aws**: **File ▸ Import from ~/.aws…** makes S3 connections from the AWS command line tool's
  profiles.
- **Links to files on S3**: right-click ▸ **Copy S3 Link** or **Copy Presigned Link…** (an `https` link anyone can open
  until it expires).
- **Zips on S3**: **Download as .zip…**, **Compress…** in the bucket and **Extract Here**, made on your Mac. See
  [Zip and extract](s3/zip-and-extract.md).
- **Terminal tabs**: open several shells on one host in the Terminal tab, each in a tab of its own, all on the same
  connection (no second login). Click **+** or choose **Host ▸ New Terminal Tab** (<kbd>⇧⌘T</kbd>); <kbd>⇧⌘[</kbd> and
  <kbd>⇧⌘]</kbd> go through them, and closing a tab asks first while a command still runs in it. See
  [The Terminal tab](commands/terminal-tab.md).
- **Command history**: **History…** lists the commands you ran on a host (bash and zsh), newest first. Type to filter,
  and AirSCP types the one you choose at the prompt without running it. It stays on this Mac; **Clear History** forgets it.
- **Insert Path…** (<kbd>⌥⇥</kbd>): pick a file or folder name from the server's folder you are typing, and AirSCP types
  it at the prompt, quoted where it needs it. Handy for long names and shells that can't complete names.
- **Drag to Finder**: select a file name in the Terminal tab's output and drag it to Finder to download it.
- **Open Terminal Here and Run in Terminal** can both go to the Terminal tab (Settings): at an empty prompt AirSCP types
  the `cd` or the command there; while the shell is busy, it opens a new tab instead of typing into it.
- **In the Mac App Store**: the same AirSCP, in Apple's sandbox. You choose the folders it may open, starting with your
  SSH folder, and terminals open in the Terminal tab. See [The App Store version](getting-started/install.md#the-app-store-version).
- **Apple Intelligence** gives shorter answers that stick closer to AirSCP's real menus and buttons. The Command
  Log's **Summarize…** now sees which commands failed, and **Do It…** keeps closer to the steps you ask for.
- **AI agents** work with S3 storage and terminal tabs too. They ask you first before they zip or unpack files on S3
  or make a presigned link, as they do before they copy or delete. **`AirSCP --agent … --out -`** writes a screenshot to
  standard output.
- **Security**: Remote Desktop now uses FreeRDP 3.32.2, which fixes 40 problems found in 3.32.1 (10 of them rated
  high). None has a CVE number yet; they are listed in
  [FreeRDP's security advisories](https://github.com/FreeRDP/FreeRDP/security/advisories).

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
