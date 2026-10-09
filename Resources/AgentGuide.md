# AirSCP agent guide

AirSCP is a Mac app for SSH servers (saved hosts, a two-pane file browser with Find Files and Synchronize, transfers,
remote file operations, a Linux monitor, tunnels, HTTP proxies and jump hosts) and Windows desktops (a built-in Remote
Desktop client). These tools drive the running AirSCP the way its user does. `guide topic=<name>` gives the details:
tools, hosts, proxies, transfers, files, monitor, tunnels, keys, settings, rdp, troubleshooting.

## overview
How to work with AirSCP:
- Loop: `snapshot` → one action (`menu`, `press`, `set`, `select`, `go`, `drop`, …) → `wait` for its effect →
  `snapshot` again. Never sleep: `wait` polls (until connected, disconnected, sheet, no_sheet, listed, transfers_done,
  rdp_connected, rdp_drawn, text, monitor, found, compared) and stops early, with the question, when a sheet appears.
- Every action returns `{ok, sheet, banner}`: a sheet in the reply is a question AirSCP is asking. Answer it before
  anything else: `set` its fields, then `press` a button (OK, Trust, Upload, Replace, Delete…). Confirmations stay in
  the way on purpose: Delete asks, and you press "Delete".
- Menus: `menu path="Host > Connect"`, `menu path="File > New Folder…"` (… may be left out). A disabled item is
  refused with the reason (e.g. "This account allows file transfers (sftp) only."). `snapshot include=["menus"]`
  lists every item, enabled or not, with its shortcut and reason.
- Files: `go path=/var/log` shows a server folder (`pane=left`: this Mac) and answers with its rows once listed; `open
  name=logs` opens a row as a double-click does (`..` goes up). File commands act on the focused pane's selected rows:
  `select pane=right names=["a.txt"]`, then `menu path="File > Rename…"` or `menu path="context > Rename…"`.
- Controls are found by accessibility id (e.g. `hostEditor.hostname`, `right.filter`, `prompt.answer`), by their
  label or title ("Address", "Password", "Remember in Keychain"), or by placeholder. `snapshot include=["sheets"]`
  shows a sheet's fields and buttons; `include=["elements"]` lists every control of the window, the rows of short lists
  too, with its id, frame and help (its tooltip: what it does, or while it is off, why).
- Other windows (Settings, Keys, Snippets, file editors): add `in="window:<title>"` to `press`, `set`, `select`,
  `menu`, `key`, `type`, `click` and `snapshot` (its elements). Without it, menus and keys act on the main window.
- Hosts and desktops are chosen in the sidebar: `select pane=sidebar names=["web"]`, then `menu path="Host > Connect"`.
  Never click in the file panes or the sidebar (`go`, `open`, `select`, `menu` take them by name). `screenshot` only to
  see how something looks (it is large; the snapshot has the facts).
- A Windows desktop (Remote Desktop) is driven by keys first: `key target=rdp` "win+e" (File Explorer), "alt+d" (its
  address bar: `type target=rdp` a path such as D:\Data, then "return"), "win+r" (Run). Click only where no key does
  it: `click target=rdp` takes pixels of `screenshot target=rdp` as they are. More: `guide topic=rdp`.
- Secrets never come back: password fields read as "•••(n)", and no tool reads the Keychain. From a shell, give a
  password with `value=-` and the password on standard input: a command line can be read by every process.
- Open and Save panels (Upload…, Download To…, Import Hosts…, Export Hosts…, Choose a Key File…, Other Key File…,
  Choose…, Send Files…, Paste Items to Mac…) can't be driven: give the command that opens one `file=<path>` (or
  `files=[…]`), which is chosen instead, e.g. `menu path="File > Export Hosts…" file=/tmp/hosts.json`; the reply's
  `panelFolder` is where the panel would have opened (one that opened anyway: `press title=Cancel`). Quick Look is
  refused. Commands that hand over to another app (Terminal, Finder, the default app, the clipboard) run, unseen.
- Agent control is off unless the user turned it on (AirSCP ▸ Settings ▸ "Allow AI agents to control AirSCP (MCP)");
  the sidebar then shows the user your name, your actions and a way to turn it off. `snapshot` → agent: client, actions.
- A first run with no hosts shows the "Welcome to AirSCP" sheet: press Start first. The Help menu's AirSCP Help items
  and a sheet's "?" button (id `help`) open the browser, outside AirSCP; Tips and Agent Guide open short texts.

## tools
Each tool takes a JSON object. From a shell: `AirSCP --agent <tool> key=value …` (values are text, except for
arguments the tool takes as numbers, true/false or lists: `timeout=60`, `names=["a.txt"]`), `--json` for the raw
reply, `--out shot.png` for an image. The binary is `/Applications/AirSCP.app/Contents/MacOS/AirSCP` (in `~/Applications` when
AirSCP was installed with `./install.sh`).

- `snapshot {include?, rows?, log?, in?}` — AirSCP's state. Default sections: windows, selection, sidebar, workspace
  (host, tab, banner, shell, tunnels), panes (left/right: source, dir, rows, selected, sort, filter, status, busy,
  hiddenColumns, favourites), transfers (summary, speedLimit, jobs with their ids), rdp, sheets, and while their sheet
  is open find (Find Files' results) and sync (Synchronize's plan); always debugLog (on, path: the debug log's file,
  see troubleshooting). Add "log" (command log), "monitor" (connected, the figures, and the processes as the table
  lists them: its search, sort and selection; the ports while Monitor ▸ Ports is shown), "menus", "elements",
  "settings"; `in="window:Keys"` makes "elements" that window's. Example: `snapshot {"include": ["panes", "transfers"], "rows": 50}`.
- `screenshot {target?, scale?}` — a PNG drawn by AirSCP: target "main" (default; sheets and panels composited),
  "sheet", "rdp" (the Windows desktop alone, at its own pixel size, which the reply gives: `click target=rdp` takes
  its pixels as they are), "window:Settings", "element:right.table"; scale 1 or 2. Example: `screenshot {"target":
  "rdp"}`.
- `menu {path, pane?, in?, file?, files?}` — a menu-bar command, or `context > <entry>` from a context menu: a file
  pane's (its selected rows) or with `pane: "transfers"` the Transfers panel's (its selected jobs: Cancel, Retry,
  Remove, Show Details…, Show in Finder). `in`: the window whose command it is, as if it were in front. `file`/`files`:
  what the Open or Save panel it opens chooses. Example: `menu {"path": "View > Show Hidden Files"}`; an editor's
  `menu {"path": "File > Close", "in": "window:notes.txt"}`.
- `press {id | title, in?, file?, files?}` — a button, checkbox, switch, tab or segment, in the frontmost sheet first
  (a window a sheet covers isn't reached: answer the sheet first). `in`: "sheet" or "window:<title>". A disabled
  button is refused with its reason when it has one. A control a long form has scrolled away is scrolled into view
  first (so is `set`'s), as a person scrolls to it. Example: `press {"title": "Trust"}`; tabs: `press {"title":
  "Monitor"}`.
- `set {id | title, value, in?, file?}` — a text or password field, a checkbox or switch (true/false), a pop-up menu
  or segmented control (by the option's title, or words of it: "zip" is "ZIP archive (.zip)"). Text is set as it is
  (no smart quotes). A pane's filter replies with the filtered rows. Synchronize's list: a row's box by the item's path
  as title. Example: `set {"id": "hostEditor.login", "value": "id_lab"}`.
- `key {combo, target?, in?}` — keys as events: "cmd+shift+n", "return", "escape", "down", "f5", "cmd+delete",
  "capslock". "delete" is the Mac's ⌫ (Backspace); "forwarddelete" is the Delete key (⌦, Windows' Del: in Explorer
  "delete" goes up a folder, "forwarddelete" deletes). They go to the frontmost sheet, else the main window (or the
  window `in` names); target "rdp" sends them to the Windows desktop, where "win" is the Windows key ("win+e",
  "win+r"; "win" alone opens Start) and "ctrl", "alt" and "shift" are Windows' own ("cmd" is Ctrl). Example:
  `key {"combo": "win+e", "target": "rdp"}`.
- `type {text, target?, in?}` — text into the focused field, or the Windows desktop with target "rdp" (key by key,
  there at a person's pace, about ten keys a second, which Windows 11's apps keep up with; more than 1 000 characters
  key by key are refused outside a text field: use `set`). Example: `type {"text": "notepad", "target": "rdp"}`.
- `click {x, y, target?, button?, count?, modifiers?, wheel?, in?}` — a click at window points (count 2:
  double-click). Refused in the file panes and the sidebar (`go`, `open`, `select` and `menu` take folders, rows and
  hosts by name); elsewhere the last resort after `press` and `set`. With target "rdp", x, y are pixels of the Windows
  desktop's picture (`screenshot target=rdp`) from its top left, as they are (the window's size, Retina and full
  screen change nothing), and the reply has a picture of the spot, zoomed 2×, with a red cross where it clicked.
  Right-clicks only on the Windows desktop (elsewhere use `menu context > …`). On the Windows desktop the pointer rests
  there a moment first (for controls that react to it), and `wheel` turns the mouse wheel there instead (notches; up
  when positive). Example: `click {"x": 600, "y": 400, "count": 2}`, `click {"target": "rdp", "x": 912, "y": 858}`.
- `focus {pane | target}` — pane "left"/"right" (menu commands then act on it), or target "sidebar", "filter",
  "path" (the Go to Folder field), "desktop". Example: `focus {"target": "filter", "pane": "right"}` then `type`.
- `go {path, pane?}` — shows a folder in a file pane, as Go to Folder (⇧⌘G) does: an absolute path, `~` or `~/…` (the
  pane's home), or relative to the folder shown (`..` goes up). pane "right" (default: the host's server) or "left"
  (this Mac, or the server its source menu shows). It waits until the folder is listed, gives the pane the focus (File
  menu commands then act on it) and answers with the pane: dir, total, rows (name, kind, size, modified, perm, owner,
  group; hidden files only while View > Show Hidden Files is on) — the first 100, `more` counts the others (`snapshot
  rows=…` lists them). A folder it can't show is an error: "No such folder: …", "Permission denied: …", "… isn't
  connected". Example: `go {"path": "/var/log"}`, `go {"pane": "left", "path": "~/Downloads"}`.
- `open {name, pane?}` — opens a file pane's row by its name, as a double-click (or Return) does: a folder, or a link to
  one, is shown in the pane and answered as `go` answers; ".." is the enclosing folder; a file opens in its app on this
  Mac (outside AirSCP: you can't see it; download a file to read it). Example: `open {"name": "reports"}`.
- `select {pane | in, names | ids | all | none}` — rows: pane "left"/"right" (file names, byte for byte: "café" in
  its two Unicode forms are two names), "sidebar" (names: one host or desktop), "processes" (a process name, PID or part
  of its command, among those the Monitor lists with its search), "ports" (one port of Monitor ▸ Ports: its number,
  address:port or process name), "transfers" (a job's name, or `ids` from snapshot); with `in` instead of pane, a list
  in that window or sheet (keys, snippets, the Proxies sheet, Find Files' results; Synchronize's list: the items
  ticked, by path).
  Example: `select {"pane": "right", "names": ["a.txt", "b"]}`, `select {"in": "window:Keys", "names": ["id_lab"]}`.
- `sort {pane, column, ascending?}` — a file pane: name, size, modified, permissions, owner, group, kind; pane
  "processes": pid, user, cpu, mem (% of RAM), memory (its size: RSS), time (running time), state, command. Example:
  `sort {"pane": "right", "column": "size", "ascending": false}`.
- `drop {files, pane | target}` or `{from, to, into?, move?}` — what a drag does. Mac files onto a server pane
  (upload), `target: "desktop"` (the Remote Desktop's shared folder) or `target: "keys"` (a PuTTY .ppk on the open
  Keys window: Import Key opens for it); the selected rows `from` a pane `to` the other
  (`move: true` moves within one server), to `"local:/Users/me/Downloads"` (Download To…: with its questions), or to
  `"finder:/Users/me/Downloads"` (a drag into a Finder window: no questions, a taken name gets a number). Questions
  come as sheets. Example: `drop {"files": ["/tmp/site"], "pane": "right"}`.
- `wait {until, host?, pane?, path?, text?, timeout?}` — until "connected" / "disconnected" (host, default the selected
  one), "sheet" (optional text its title, text, buttons or field names must contain: not what its fields hold),
  "no_sheet", "listed" (pane done listing and filtering; optional path, or text = a row name), "transfers_done",
  "rdp_connected", "rdp_drawn" (the desktop shows a picture, not the blank frame Windows starts with), "text" (anywhere
  in the snapshot, incl. monitor and log, and in AirSCP's other windows), "monitor" (the Monitor has read the server;
  with text, it lists a process with that in its name or command; showing Ports, the ports and the picked port's
  connections are read, and text is in a port's row or a connection; it fails at once with the Monitor's failure, e.g.
  on an sftp-only account), "found" (Find Files' search ended: its results), "compared" (Synchronize's comparison ended:
  its plan). Timeout 30 s by default; a wait ends when the agent that asked has gone. Example: `wait {"until":
  "connected", "host": "chain target"}`.
- `guide {topic?}` — this guide.

## hosts
- New host: `menu path="File > New Host…"` → a sheet. Fields: `hostEditor.name`, `hostEditor.hostname` (Address),
  `hostEditor.port`, `hostEditor.username` (User name), `hostEditor.login` (pop-up: "Keys in ~/.ssh and the ssh agent
  (default)", the keys of ~/.ssh as "id_ed25519 · ED25519 · me@mac", "Password", or a key elsewhere: `set
  id=hostEditor.login value="Choose a Key File…" file=/path/to/key` (a PuTTY .ppk opens Import Key on the editor: see
  keys); "Generate New Key…" opens New Key Pair on the editor, whose result has "Install on This Host" (logs in as
  typed, adds the key, and Log in with then uses it; the result shows next to Test Connection) and "Use for This
  Host"), `hostEditor.password` (only with Password),
  `hostEditor.jump` ("Connect through": another host's name), `hostEditor.remoteFolder` (Start in folder),
  `hostEditor.group`. Under Advanced (`press title=Advanced` shows them; an edited host that uses one shows them
  already): `hostEditor.proxy` (HTTP proxy; its "Add Proxy…" opens the proxy editor on the host editor),
  `hostEditor.keepAlive`, `hostEditor.autoReconnect`, `hostEditor.forwardAgent` ("Let the server use my ssh agent"),
  `hostEditor.hostKey` (Server key: "Ask (default)", "Trust new servers automatically" (accept-new: a changed key is
  still refused), "Don't check (insecure)"; Other options can't set StrictHostKeyChecking),
  `hostEditor.options` (Other ssh options, one per line; `set id=hostEditor.addOption value=Compression` adds a common
  one). Each options line is checked with `ssh -G` as it is typed: a bad one is named, with ssh's reason, in the
  sheet's text (and Add is off). `press title=Add` (Save when editing; disabled while the sheet's text names a
  problem). `press title="Test Connection"` logs in and out with the fields as typed: its questions come as sheets on
  the editor, and the result is in the editor's text (`wait until=sheet text="Logged in"`).
- A host's route: `snapshot` → sidebar hosts' `route` ("via bastion", "via proxy corp-proxy", "via corp-proxy →
  bastion"; a jump host or proxy that no longer exists: "via a missing jump host" with a `warning`). The window's
  subtitle shows it too ("Connected · via bastion"), and the sidebar's search finds hosts by it.
- Every sidebar host has `hostKeyCheck` (ask, acceptNew, off) and every desktop `certificateCheck` (ask, trustNew,
  off, companyCA, with `caFile`); one whose checks are off has `shield` (the orange shield's tooltip), and its banner
  says so while connected.
- Edit, duplicate, delete: select it (`select pane=sidebar names=["web"]`) → `menu path="Host > Edit…"`,
  `"Host > Duplicate"`, `"Host > Delete…"` (asks), colour: `menu path="Host > Colour Tag > Red"`. Groups:
  `menu path="File > New Group…"` (`set id=prompt.name value=<name>`, press Create; a name in use is refused); a
  host's group is `hostEditor.group`; rename or delete one by its name: `menu path='Host > Rename Group > Lab'` (the
  name sheet, press Rename), `menu path='Host > Delete Group > Lab'` (asks; its hosts stay).
- Connect: `menu path="Host > Connect"`. Questions arrive as sheets on the window: a new server key ("Trust …?",
  press Trust), a password ("Password for web": `set id=prompt.answer value=…`, optionally `press title="Remember in
  Keychain"`, `press title=OK`), a key's passphrase, a verification code ("<host> asks": ssh's question is the label of
  `prompt.answer`; set it and press OK). A question asked again begins "That password wasn't accepted" (a code:
  "That answer wasn't accepted"). Then `wait until=connected`.
  Disconnect: `menu path="Host > Disconnect"`. A lost connection reconnects by itself when it can (banner
  "Reconnecting…"); `snapshot` → workspace.banner says what happened, with its buttons ("Reconnect"). Once
  disconnected, the server pane has no rows (its dir stays) and isn't "listed"; `press id=right.reconnect` connects
  and lists that folder again (`wait until=listed pane=right`).
- Import from ~/.ssh/config: `menu path="File > Import from ~/.ssh/config…"` → a sheet with a checkbox per alias
  (titled "<alias>, <user@host>"): `set title=<alias> value=false` leaves one out → `press title=Import`.
  Hosts to and from a file: `menu path="File > Export Hosts…" file=/tmp/hosts.json`,
  `menu path="File > Import Hosts…" file=/tmp/hosts.json` (the reply's sheet says how many were imported).
- Terminal: `menu path="Host > Open Terminal"` opens Terminal.app, and "Copy ssh Command" fills the clipboard: their
  result is outside AirSCP. Run a command and read its output: `menu path="Host > Run Command…"` →
  `set id=runCommand.command value="uname -a"` (or a snippet: `set id=runCommand.snippet value=<its name>`) →
  `press title=Run` → `wait until=sheet text="Exit status"` (output, error output and "Exit status N" are in the
  sheet's text; a failure to run shows instead) → `press title=Close`. `press title=Stop` ends the command on the
  server too; what it printed so far stays in the sheet (the output shows while it runs).
- Snippets: `menu path="Window > Snippets"` (its controls `in="window:Snippets"`): `press id=snippets.add` makes
  one, or `select in="window:Snippets" names=["uptime"]` picks one; `set id=snippet.name value=…`, `set
  id=snippet.command value=…`, `set id=snippet.runInTerminal value=true`, `set id=snippet.host value=<host>`,
  `press title=Run`: the output comes in a Run Command sheet on the main window (in Terminal when "Run in Terminal" is
  on; refused while the main window shows a sheet). `press id=snippets.remove` deletes the selected one.
- Command log: `menu path="View > Show Command Log"`, and `snapshot include=["log"]`: every command AirSCP ran for
  the host, its exit status and error output.

## proxies
- Proxies: `menu path="Host > Proxies…"` → sheet → `press title="Add Proxy…"` → `proxyEditor.name`, `proxyEditor.host`,
  `proxyEditor.port`, `proxyEditor.username`, then `proxyEditor.password` (it appears once there is a user name) →
  `press title=Add` → `press title=Done` (or `key combo=escape`).
  The sheet's text lists the proxies; to change or remove one: `select in=sheet names=["Office"]` →
  `press title=Edit…` (its editor, press Save) or `press title=Remove…` (asks; a proxy hosts use can't go).
- A host behind a proxy: `press title=Advanced`, then `hostEditor.proxy` = the proxy's name. Through a bastion: make
  the bastion a host (with the proxy, if any), then the target's `hostEditor.jump` = the bastion (the target then uses
  the bastion's proxy).
  Connect asks the bastion's password (and the proxy's, unless saved): one sheet each, the title names whose.
- A proxy that refuses the password: the connect fails with "The proxy rejected the user name or password".

## transfers
- Upload: `drop files=["/path/a.txt", "/path/folder"] pane=right` (into the folder the right pane shows, or `into`).
  A folder (or 200+ items) asks first: "Upload … to “dev”?" with the checkbox "Compress during transfer — faster on
  slow links and for many small files" and the field
  `transfer.leaveOut` (names or patterns separated by commas, e.g. `set id=transfer.leaveOut value="*.log,
  node_modules, .git"`: left out at any depth; remembered for that server; a server without tar copies folders whole)
  → press Upload. A name that exists asks: Replace / Keep Both / Skip (checkbox "Do the same for the other N
  conflicts"); the sheet's text compares them: "New: 1.2 MB, 4 Oct 2026 at 15:21 · Existing: 1.1 MB, …".
- Download: `select pane=right names=["a.txt"]` → `drop from=right to=left` (into the local pane's folder) or
  `to="local:/Users/me/Downloads"`. As one archive: `menu path="File > Download as .tar.gz…"` (sheet: Download; its
  checkbox "Unpack it after the download (the archive is removed)").
  Folders download with the same sheet (Leave out, Compress).
- Speed limit for every host's transfers that start from then on: `set id=transfers.speedLimit value="5 MB/s"`
  (Unlimited, 1, 5, 10 or 50 MB/s); `snapshot` → transfers.speedLimit.
- Between two servers: show the other server in the left pane (its source menu: `set id=left.source value=<host>`),
  then `drop from=left to=right`.
- `wait until=transfers_done` (optionally host), then `snapshot include=["transfers"]`: each job's id, host, name,
  direction, size, percent, speed (or "stalled"), eta, status, problem, note. Cancel or retry: `select pane=transfers
  names=[<name>]` (or `ids=[<id>]`) → `press id=transfers.cancel` / `transfers.retry` / `transfers.remove`, or its
  context menu: `menu path="context > Show in Finder" pane=transfers` (a finished download), `"context > Show
  Details…"` (a problem's output); `press id=transfers.clearFinished`, `press id=transfers.cancelAll` (asks). The
  panel lists the queued, running and paused jobs first, then the newest 100 finished ones (newest first); snapshot has
  every unfinished job and the newest 500 finished ones of each host.
- Pause and resume: select the jobs (as above) → `menu path="context > Pause" pane=transfers` (queued or running ones)
  or `"context > Resume"` (paused ones); every job at once: `press id=transfers.pauseAll` / `transfers.resumeAll`. A
  paused job's status is "Paused" and its note says how it goes on: a single file keeps what it copied (`"resumable":
  true`) and continues where it stopped (then `"resumed": true`); folders, archives and server-to-server copies start
  again. Paused jobs wait through a lost connection and its reconnect (Resume is off while their host reconnects by
  itself); Cancel, Cancel All and Disconnect throw a paused job's part away. `wait until=transfers_done` doesn't wait
  for paused jobs.
- Check a copy against the original (SHA-256, single files): `menu path="context > Verify with Checksum"
  pane=transfers` on a finished job, or every file as it arrives with `set id=settings.verifyTransfers value=true
  in=window:Settings`. `wait until=transfers_done` waits for the checks too; then the status is "Verified" (with
  `sha256`), "Mismatch" (problem, and details with both checksums: `transfers.retry` copies the file again in place of
  the bad copy and checks it again) or "Not verified" (the note says why: an sftp-only account runs no checksum tool).
- A lost connection: a single file cut off keeps what arrived, and its job shows `"resumable": true` (problem "The
  connection to the server was lost."). Retry, or the automatic retry once the host has reconnected, continues it
  where it stopped (while the host reconnects by itself, transfers.retry is off: the job runs again by itself then): the job then shows `"resumed": true` and its percent goes on from there. Remove, Clear Finished,
  Cancel All and Disconnect throw the kept part away (an upload's on the server too). Folders, archives and
  server-to-server copies start again; a server-to-server copy that its source's lost connection stopped runs again
  once that host has reconnected by itself.
- Make two folders the same (one on this Mac, one on the server): Synchronize, in "files".
- Quitting while transfers run asks first ("Quit and cancel the transfers?"): the Quit reply carries that question.

## files
- The Files tab (`press title=Files`) has two panes: left = this Mac (or another connected server), right = the host.
  `snapshot` → panes.left/right: dir, rows, selected, status ("12 items, 2 selected — 30 GB available"). A row's owner
  and group are names, as Get Info shows them; ownerID and groupID are their numbers where the server tells them.
- Through folders without a click: connect (`select pane=sidebar names=["web"]` → `menu path="Host > Connect"` → `wait
  until=connected`) → `go path=/var/www` (the reply lists the folder; `open name=site` opens a row, `open name=..` goes
  up) → `select pane=right names=["index.html"]` → its command: `menu path="File > Download To…" file=/Users/me/Downloads`,
  `menu path="File > Upload…" files=["/Users/me/a.txt"]`, `menu path="File > Rename…"`, `menu path="context > Delete…"`.
- Also `menu path="Go > Back"`, `"Go > Enclosing Folder"`, `"Go > Home"`; this Mac's side: `go pane=left path=~/Downloads`.
- Favourites (a server's folders, kept per host): `focus pane=right` → `menu path="Go > Add to Favourites"` keeps the
  folder shown; `menu path='Go > Favourites > /var/log'` goes back to it, `menu path='Go > Favourites > Remove >
  /var/log'` drops it. `snapshot` → the pane's favourites (and `include=["menus"]` lists them).
- Filter: `set id=right.filter value=log` (the reply has the filtered rows). Hidden files:
  `menu path="View > Show Hidden Files"` (focused pane). Columns: `menu path="View > Columns > Owner"` shows or hides one (snapshot: the pane's
  hiddenColumns). Sizes of folders: `menu path="View > Calculate Folder Sizes"` (the files' sizes, as the status line
  adds them up; BusyBox servers: space on disk). Refresh: `menu path="View > Refresh"`.
- Server commands on the selected rows (File menu or `context > …`): New Folder… and New File… (a name sheet:
  `set id=prompt.name value=<name>`, press Create), Rename… (the same, press Rename), Duplicate, Delete… (or
  `key combo=cmd+delete`; asks: press Delete), Permissions… (`permissions.octal` or the rwx checkboxes, press Apply),
  Make Executable, Run… (`set id=run.arguments value=…`; press Run to see the output, or Run in Terminal), Compress…
  (`set id=compress.format value=zip` or `tar.gz`, press Compress), Extract Here / Extract to New Folder, Get Info
  (sheet with kind, size, dates, owner; press Done), Edit in AirSCP (an editor window titled "<file name> — <host>":
  `set id=editor.text value=… in="window:<file name>"` (a byte order mark the file starts with stays: JSON can't
  carry one), `press title=Save in="window:<file name>"` (when someone saved the file on the server after it was
  opened, Save asks first, a sheet on the editor: press Overwrite, Cancel, or Show Server Version, which opens their
  text read-only in a window titled "<file name> on the server — <host>": read it with
  `snapshot include=["elements"] in="window:<file name> on the server"`, then press Save again to overwrite it); read
  it with `snapshot include=["elements"] in="window:<file name>"`; close it with `menu path="File > Close"
  in="window:<file name>"`, which asks first when it has unsaved changes).
- Handed to other apps, so their result isn't visible here: Open (the default app), Show in Finder, Open Terminal
  Here, Run in Terminal, Copy Path (the clipboard). Quick Look is refused: download the file and read it instead.
- Copy / cut / paste within a server: select → `menu path="Edit > Copy"` (or Cut) → select the target folder's pane
  → `menu path="Edit > Paste"`. Move by dropping: `drop from=right to=right into=/home/dev/dir move=true`. Replace
  keeps the old item until the copy is complete.
- Names and conflicts are checked against the server as it is now (an item made since the folder was listed is asked
  about, not replaced). Names are at most 255 bytes; Windows servers refuse device names (CON, NUL, …) too.
- Find Files (below the folder a server pane shows): `focus pane=right` → `menu path="File > Find Files…"` → `set
  id=find.pattern value="*.log"` (a name part, or a pattern with * ? [ ], any case) → `press title=Find` → `wait
  until=found`: status ("3 found."), count and results (paths below that folder; folders marked), also in `snapshot`
  → find. Go to one: `select in=sheet names=["logs/app.log"]` → `press title=Show` (the sheet closes and the pane
  shows its folder with it selected, its filter cleared if it hid it). Results show as they are found; `press
  title=Stop` stops a search and keeps them ("Stopped: 12 found so far."), `press title=Done` closes the sheet.
- Synchronize (one pane shows a folder on this Mac, the other a folder on the server: go to them as above):
  `focus pane=right` → `menu path="File > Synchronize…"` (the "Synchronize Folders" sheet; when either folder is a home
  folder or /, it waits for `press title=Compare`, as comparing can take minutes: see `started` in the snapshot's sync) →
  `wait until=compared`: sync with direction, delete, leaveOut, steps
  (action upload, download, trash = to the Trash on this Mac, delete = on the server; path below the two folders,
  size, replaces; `"ticked": false` when unticked), count, ticked (how many), summary ("The folders are the same."
  when nothing differs; the ticked ones counted with their sizes) and failure. Change the plan with
  `set id=sync.direction value="Both ways"` (or "This Mac → <host>", "<host> → This Mac") and `set id=sync.delete
  value=true` (one way only: delete what is only on the destination); `snapshot` shows the new steps. Leave out (the
  server's patterns, as in the folder-transfer sheet; remembered once you synchronize): `set id=sync.leaveOut
  value="*.log, node_modules"` → it compares again (`wait until=compared`); what matches isn't compared, copied or
  deleted, at any depth. Untick an item to leave it as it is: `set title="logs/app.log" value=false` (a row's box, by
  its path; true ticks it again); `select in=sheet names=["a.txt", "docs/"]` ticks only those, `select in=sheet
  all=true` / `none=true` every one or none (the sheet's Select All / Select None). `press title=Synchronize` queues
  the ticked copies (times kept; 20 or more files of one folder go as one stream) and runs the ticked deletions →
  `wait until=transfers_done`, then `wait until=listed` for each pane. `press title=Cancel` closes the sheet, also
  while it compares. A folder that can't be listed is named in the failure: add it to Leave out to compare without it.
- A command the server can't run (sftp-only account, no zip) is refused with the reason.

## monitor
- `press title=Monitor` (the host's tab) → `wait until=monitor` (or `wait until=monitor text=<a process name>`) →
  `snapshot include=["monitor"]`: connected, cpu, load, memory, swap, uptime, system, disks, and the processes as the
  table lists them (pid, user, cpu, memory as % of RAM, name, command, state; its search, sort and selection);
  `failure` says why there are no figures (an sftp-only account, a server that isn't Linux), `processNote` why there
  are no processes (no ps). It refreshes every 3 s while it is shown, also behind other windows while you are at work;
  disconnected, it shows nothing.
- Sort: `sort pane=processes column=pid` (user, cpu, mem: % of RAM, memory: RSS, time, state, command;
  `ascending=false`).
- Kill: `set id=monitor.search value=backup` (the list shows only those) → `select pane=processes names=["backup"]` →
  `press title=Kill` (or "Force Kill") → the confirmation → press the same title again. When the account may not, a
  sheet offers "Kill with sudo in Terminal" on a server that has sudo (it runs in Terminal: its result isn't visible
  here); without sudo, it says the process can't be killed from this account.
- Ports (what the server listens on, and who is connected): `press title=Ports` (`monitor.view`: Processes | Ports) →
  `wait until=monitor` (or `text=8080`: a port, process, address or remote address) → `snapshot include=["monitor"]`:
  `view` "Ports" and `ports`: `listening` as the table lists them (protocol, address, port, pids, process, command,
  user, connections: open TCP connections; UDP has none), `othersHidden` (some ports are other users' processes,
  which this account can't see: their pids are empty; root sees them), `note`, `paused`, `search`
  (`monitor.portSearch`). `select pane=ports names=["8080"]` picks a port (by number, address:port or process name)
  → `wait until=monitor` → `selected`, its `connections` (address, port, state; the first 2000) and `from` (how many
  from each address). With a port picked, `press title=Kill` / "Force Kill" (as above) and "Show Process" (Processes,
  with its PID searched for and selected). The ports are read only while Ports is shown: every 5 s, `press
  title=Pause` stops that, `press id=monitor.refresh` reads them now; `press title=Processes` goes back (`ports` is
  then left out of the snapshot).

## tunnels
- `press title=Tunnels` (tab) → `press title="Add Tunnel…"` → a sheet that reads as a sentence: `set
  id=tunnelEditor.type value=Local` (Remote, "SOCKS proxy"), `tunnelEditor.listenPort` (the port to open: on this Mac,
  for Remote on the server), `tunnelEditor.destination` ("The server itself" for Local, "This Mac" for Remote: ssh's
  localhost at that end; or "Another machine", which shows `tunnelEditor.targetHost`: a name that end looks up),
  `tunnelEditor.targetPort` (the port to open until you set it) → `press title=Save`. The sheet's text has the route it
  saves, and why Save is off.
- Each tunnel is named by its route, as its row shows it (web: the host's name): "localhost:8022 on this Mac → web →
  localhost:22 on web (the server itself)", "localhost:9000 on web → this Mac → localhost:3000 on this Mac",
  "localhost:1080 on this Mac (SOCKS proxy) → web → any address web can reach". Its switch is `press title=<route>` (or
  `set title=<route> value=true`), then `press title="Edit <route>"` (only while it is off) and `press title="Remove
  <route>"`. `snapshot` → workspace.tunnels: each one's title (its route) and whether it is on (screenshots may draw a
  switch off). This Mac's end listens on 127.0.0.1; a port another program listens on is refused, with its error
  under the row (elements).

## keys
- `menu path="Window > Keys"` opens the Keys window: use `in="window:Keys"` for its controls (and its sheets). The keys
  (name, type, comment, fingerprint): `snapshot include=["elements"] in="window:Keys"`. Select one first for its
  buttons: `select in="window:Keys" names=["id_lab"]` → `press title="Install on Host…" in="window:Keys"` (a sheet:
  Host pop-up → Install), `press title="Add to Agent" in="window:Keys"` (may ask the passphrase, which goes into the
  login Keychain), Copy Public Key (a menu: `set id=keys.copy value=OpenSSH in="window:Keys"` puts OpenSSH's line on
  the clipboard; "SSH2 (RFC 4716)" and "PEM (PKCS#8)" the other formats). A key outside the folder: `press
  title="Other Key File…" in="window:Keys" file=/path/to/key`.
- New Key Pair: `press title="New Key Pair…" in="window:Keys"` → a sheet: `newKey.type` ("Ed25519 (recommended)",
  "ECDSA 256/384/521", "RSA 2048/3072/4096"; no DSA), `newKey.name` (never an existing file), `newKey.comment`,
  `newKey.passphrase` and `newKey.confirm` (optional; they go to ssh-keygen through askpass, never into a command
  line), `newKey.remember`, `newKey.copy` (on: the public key goes on the clipboard), Change… (`press
  id=newKey.folder file=/folder`); under Advanced (`press id=newKey.advanced`): `newKey.format` (private key:
  "OpenSSH (default)", "PEM (PKCS#1 or SEC1)", "PKCS#8"; Ed25519 is OpenSSH only) and `newKey.publicFormat` →
  `press title=Generate` → `wait until=sheet text="Key pair created"`: the fingerprint and the public key (in the
  format of `keyResult.format`) are the sheet's text; "Copy Public Key", "Install on Host…", "Show in Finder",
  "Export as PuTTY Key (.ppk)…", "Done".
- PuTTY keys: `press title="Import Key…" in="window:Keys" file=/path/key.ppk` (or drop it on the window, as a drag
  there does: `drop files=["/path/key.ppk"] target=keys`) → `importKey.ppkPassphrase` (an encrypted .ppk),
  `importKey.name`, `importKey.same` (keep the same passphrase; false: `importKey.passphrase` and
  `importKey.confirm`, empty for none) → `press title=Import` → `wait until=sheet text="Key imported"` (a wrong
  passphrase or a damaged file is the sheet's red text). Export (a version 3 .ppk: PuTTY 0.75 and later): select a
  key → `press title="Export for PuTTY…" in="window:Keys"` → `exportKey.passphrase`/`exportKey.confirm` (optional) →
  `press title=Export… in="window:Keys" file=/path/key.ppk` → the key's own passphrase may be asked (a sheet) →
  `wait until=sheet text="PuTTY key saved"`.

## settings
- `menu path="AirSCP > Settings…"` opens the Settings window (`in="window:Settings"`): `settings.appearance`
  (System, Light, Dark), `settings.terminal`, `settings.showHidden`, `settings.preserveTimes`,
  `settings.confirmDelete`, `settings.alwaysCalculateFolderSizes`, `settings.hostKey` (new hosts' server key, as
  hostEditor.hostKey), `settings.certificate` (new desktops' certificate, as rdpEditor.certificate; with a company
  certificate authority: `settings.caFile`, or `press id=settings.chooseCA in="window:Settings" file=/path/ca.pem`),
  the folder for new keys (`press id=settings.keyFolder in="window:Settings" file=/folder`; "Use ~/.ssh" goes back),
  `settings.agentControl` (turning it off ends
  agent control at once; `settings.mcpCommand` is the `claude mcp add` command it shows, `settings.copyMCPCommand`
  copies it), `settings.debugLogging` (Advanced: the debug log, see troubleshooting). Downloads folder: `press
  title=Choose… in="window:Settings" file=/Users/me/Downloads`. It is where Download To… opens (its reply's
  `panelFolder`) and where Download as .tar.gz puts the archive when the other pane shows a server too.
- `snapshot include=["settings"]` reads them all. The window opens 600 points tall and its form scrolls; the controls
  work by id wherever they are, and `press`/`set` scroll theirs into view (a screenshot then shows it, e.g. `set
  id=settings.debugLogging value=false in="window:Settings"` for the Advanced section); `menu path="Window > Zoom"
  in="window:Settings"` shows as much of the form as the screen holds.

## rdp
- New desktop: `menu path="File > New Remote Desktop…"` → `rdpEditor.name`, `rdpEditor.hostname`,
  `rdpEditor.username`, `rdpEditor.password` (leave it empty to be asked), `rdpEditor.via` ("Connect through": an SSH
  host to go through), `rdpEditor.clipboard`, `rdpEditor.shareFolder`, `rdpEditor.folder`; under Advanced (`press
  title=Advanced`): `rdpEditor.port` (empty: 3389), `rdpEditor.domain`, `rdpEditor.display` (Fit the window, Fixed
  size, Full screen), `rdpEditor.cmdAsCtrl` (false: ⌘ is the Windows key), `rdpEditor.certificate` (Server
  certificate: "Ask (default)", "Trust automatically" (the first certificate is remembered without a question; a
  changed one is still asked about), "Don't check (insecure)", "Trust my company's certificate authority" with
  `rdpEditor.caFile` or `press id=rdpEditor.chooseCA file=/path/ca.pem`) → `press title=Add`. `press title="Test
  Connection"` logs in and out; with `rdpEditor.via` it connects that SSH host first, its questions as sheets on the
  editor.
- Connect: `select pane=sidebar names=["Windows VM"]` → `menu path="Host > Connect"` → certificate sheet ("Trust the
  certificate of …?": press "Always Trust" or "Trust Once"; none under Trust automatically or Don't check, nor for a
  certificate the chosen company authority signed; "The certificate of … has changed" always asks) → login sheet (`rdpLogin.username`, `rdpLogin.password`,
  `rdpLogin.remember`; press "Log In") → `wait until=rdp_connected` → `wait until=rdp_drawn` (Windows draws a blank
  frame first, for up to a minute at logon). Questions for a desktop that isn't shown come on the window too. `snapshot`
  → rdp: state, size, fullScreen, sharing, sharedFolderReady, sharedFolderRefused, remoteFiles, message.
- Drive Windows with its keyboard first: keys don't miss, clicks can. `key {"combo": …, "target": "rdp"}` with
  "win+e" (File Explorer), "alt+d" or "ctrl+l" (Explorer's address bar: then `type {"text": "D:\\", "target":
  "rdp"}` and "return" opens that folder), "win+r" (Run: a program, a folder or \\tsclient\AirSCP, then "return"),
  "win" (Start: type to search, then "return"), "ctrl+shift+escape" (Task Manager), "alt+tab", "ctrl+w" (closes an
  Explorer window), "alt+f4" (closes the window; on the bare desktop it offers to shut Windows down: "escape"),
  "tab", "shift+tab" and the arrows (move in a dialog or a list; in a folder, type a name's first letters to select
  it), "return" (opens it), "alt+up" (the folder above), "f2" (rename), "ctrl+a", "ctrl+c", "ctrl+v". "cmd" is Ctrl
  too ("cmd+c" copies) unless the desktop's ⌘ is the Windows key; "capslock" lasts until the next desktop action,
  which gives Windows the Mac's own Caps Lock again. Ctrl+Alt+Del: `press title=Ctrl+Alt+Del`.
- See it: `screenshot target=rdp`, the desktop alone at its own pixel size (the reply gives it): read Windows' text
  there, and look again after each step. Windows opens a window a moment after its key: keys sent before it shows go
  elsewhere (typed on the bare desktop, then "return", they open whatever icon the letters chose), so after "win+e"
  or "win+r" take screenshots until it is there, then type.
- Click only what no key reaches: `click {"target": "rdp", "x": …, "y": …}` in pixels of that picture, from its top
  left; `"count": 2` double-clicks, `"button": "right"` right-clicks, `"wheel": -3` scrolls down three notches there.
  The reply's picture shows what was there, zoomed, with a red cross where it clicked: when the cross isn't on what
  you meant, take a new screenshot before clicking again. (Without target, x, y are the main window's points.)
- Full screen: `press title="Full Screen"`, `menu path="View > Enter Full Screen"` or `key combo=ctrl+cmd+f
  target=rdp`; each leaves it again (the menu item and the bar's button are titled Exit Full Screen then). `snapshot` →
  rdp.fullScreen; `screenshot` then draws the full screen, with the note at its top for the first seconds ("Press ⌃⌘F
  to leave full screen").
- Files to Windows: `drop files=[…] target=desktop` copies them into the shared folder, \\tsclient\AirSCP in
  Windows (`wait until=text text="In Windows:"`). Files from Windows: copy them into \\tsclient\AirSCP in Windows; they
  appear in the Mac folder (~/Downloads/AirSCP RDP unless the entry names another). The bar's "Send Files…" copies Mac
  files there too (`press title="Send Files…" files=[…]`). "Paste N Items to Mac…" copies
  what Explorer copied into a Mac folder: `press id=rdp.pasteItems file=/Users/me/Downloads` (its title counts the
  items: see snapshot.rdp.remoteFiles). "Shared Folder" opens Finder. Disconnect asks first while Windows
  copies into the shared folder (the cut-off files are removed). `press id=rdp.copySharedFolder` puts
  \\tsclient\AirSCP on the clipboard (for Explorer's address bar).
- Windows' settings can turn drive redirection off (Group Policy): `sharedFolderRefused` is true, \\tsclient is empty
  there, and drops and Send Files… are refused. Copy and paste files instead (below) when Windows allows the
  clipboard: the bar then says so.
- Clipboard: the desktop has the keyboard focus only while a `key`, `type` or `focus target=desktop` runs, as if
  clicked and then left: the Mac's clipboard goes to Windows then (text, or files), and what Windows copied comes to
  the Mac when it ends. Files Mac → Windows: select them in the left pane (this Mac) → `menu path="Edit > Copy"` →
  show the desktop and `focus target=desktop` (Windows gets the copy) → in Explorer `key combo=cmd+v target=rdp`. Windows → Mac: copy in Explorer
  (`key combo=cmd+c target=rdp`); snapshot.rdp.remoteFiles counts them; AirSCP fetches them (up to 256 MB) onto the
  Mac's clipboard after your next desktop action or `focus target=sidebar` (`wait until=text text="on the Mac's
  clipboard"`), and `menu path="Edit > Paste"` in a server pane uploads them.
- Disconnect: `menu path="Host > Disconnect"`.

## troubleshooting
- "AirSCP isn't running, or agent control is off": start AirSCP and turn on Settings ▸ "Allow AI agents to control
  AirSCP (MCP)". The bridge talks to the AirSCP of its own settings folder (AIRSCP_SUPPORT_DIR, when set). "AirSCP
  didn't answer": it is busy with many calls at once, or quitting; check with snapshot before doing it again.
- A connect or transfer fails and its message doesn't say enough (often through a proxy or a jump host): turn on the
  debug log with `menu path="Help > Turn On Debug Logging"` or `set id=settings.debugLogging value=true
  in="window:Settings"` (or, in the "Can't connect" sheet or a Disconnected banner,
  `press title="Turn On Debug Logging and Try Again"`, which connects again), make it happen again, then read the
  plain-text file at `snapshot` → debugLog.path. Each line has the time and the host.
  "Couldn't connect: it stopped at …" names the hop that failed (the HTTP proxy, the jump host or the server) in plain
  words; the lines before it are ssh's own (-vv: "Authenticated to bastion", "channel 0: open failed"), the proxy's
  answer ("proxy-connect: the proxy 127.0.0.1:3128 answered CONNECT bastion:22 with “HTTP/1.1 407 …”") and the
  questions ssh asked (never the answers: no password is ever in the file). `menu path="Help > Copy Diagnostics"`
  copies the versions and the log's last lines; "Help > Show Debug Log in Finder" shows the file to the user. Turn the
  log off when done: `value=false`, `press id=debugLog.turnOff` (the sidebar's Turn Off) or
  `menu path='Help > Turn Off Debug Logging'`. AIRSCP_DEBUG=1 in AirSCP's environment turns it on from the start (and
  keeps it on).
- "… is disabled now: <reason>": the reason says what is missing (no selection, not connected, sftp only, the Files
  tab not shown…).
  "Nothing to press called …" / "No field …": `snapshot include=["sheets","elements"]` shows what is there (add
  `in="window:<title>"` for another window).
- A `wait` that stops with "a sheet asks something": answer that sheet (it is in the reply), then wait again.
- Sheets queue: a second question appears when the first is answered. `wait until=no_sheet` after the last one.
  `key combo=escape` cancels a question with Cancel; `press title=OK` closes a message with only OK.
- Menus are never in screenshots (they open only for a person): read `snapshot include=["menus"]`.
- File > Find Files… searches a server's folders (focus the server's pane); File > Synchronize… needs this Mac in one
  pane and a connected server in the other. `wait until=found` / `compared` needs its sheet open.
- Synchronize compares times as the server lists them: to the minute (the day for files over six months old, or dated
  after the server's clock: those count as newer), so two versions with the same size saved within one minute count as
  the same. The panes' rows then have `modified` as a day only ("2024-01-01"). A folder it can't list stops it (failure).
- A retry that started from 0 (no `"resumed": true`): sftp couldn't continue the kept part (gone, or not smaller than
  the file), so the file was copied again.
- Typing goes to the focused field: `focus` it, or use `set`, which focuses and replaces the text.
- Every tool works with AirSCP behind other windows: AirSCP isn't brought to the front (keys and clicks go to its
  windows directly). A click on a list row may not select it then (AppKit takes it as the click that activates the
  window): never click rows. Use `select`, `open` (a double-click on a file row), `go` (a folder by its path), and
  `focus target=sidebar` + `key combo=return` (a double-click on a host: it connects and shows its files).
- While the Mac's screen is locked, full screen, window tiling (Move & Resize) and animated toggles (Hide Sidebar)
  wait until it is unlocked, though the reply says ok; the Monitor refreshes only while you are at work (a `wait`).
- Screenshots draw AirSCP's own windows: a table's header can show the rows scrolled under it, the toolbar and the
  sidebar have no glass, and menus are never in them. A host's state is in `snapshot` (sidebar).
- Quit (`menu path="AirSCP > Quit AirSCP"`): refused while a sheet is open; it asks first while transfers run or an
  editor has unsaved changes (the reply is that question), else it answers `quitting` and AirSCP quits.
