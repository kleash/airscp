# Regression history: what broke, and what it taught

AirSCP (then Porter) went through adversarial review, two break-it rounds and an every-feature cycle before v1. Each
finding got a fix and, where it was cheap, a regression test that fails without the fix. The classes below are the
ones worth remembering when changing the code.

## Classes of bugs found and fixed

**Data safety**
- Replace destroyed the old copy before the new one was complete. Now everything arrives as `.airscp-<id>.part` in
  the destination folder and is renamed into place; a cancelled, failed or disk-full copy leaves the old item intact
  (tested on a tiny tmpfs). Folders are moved aside, renamed in, then the old one removed.
- Two downloads to one name shared one part file: part names are per job and fixed-length (also fixes names near the
  255-byte limit).
- An item that appeared on the server after the folder was listed could be replaced unasked: destinations are listed
  fresh before planning, and the final move refuses any name it wasn't told to replace.
- A failed Keychain read could lead to a write that wiped every saved password: nothing is cached or written after a
  read that isn't success or not-found.
- ⌘Q dropped unsaved editor text; Extract Here overwrote silently. Both ask now.

**Security**
- Path traversal through server names: listing drops names containing `/` at the parse boundary; every local path
  comes from listing names.
- The askpass socket answered any process of the user: a per-launch token, and saved passwords only to processes
  AirSCP started.
- A jump host's changed key removed the target's known_hosts entry: the key named in ssh's message is the one removed.
- A server's file name on the login shell's command line could run commands when that shell is fish, csh or tcsh
  (they read POSIX quoting differently): every script goes to `sh -s` on standard input, File ▸ Run… too
  (`Session.run(_:sh:)`); the terminal commands (Open Terminal Here, Run in Terminal of a file), whose standard input
  is the keyboard, carry it as printf octal escapes that only sh decodes (`OpenSSH.viaSh`). Checked against fish 4.6,
  tcsh, csh, zsh, bash and BusyBox sh login shells in a container: the old commands ran the injected `touch`, the new
  ones don't (unit test: this Mac's sh, bash, zsh, dash, ksh, csh and tcsh).
- The tar consumer read its target folder as one line (`read`): a destination whose path had a line break was cut
  there and `rm -rf` removed another folder (a sibling, or the parent). Such a destination is refused now.

**Speed**
- Streams crawled at 512 bytes per read when the Mac's pipe pool was exhausted (by other apps): all child I/O uses
  socketpairs (300 MB stream: 33.8 s → 2.9 s).
- One scp per file for big selections: folders, 200+ items and Synchronize batches go as one tar stream.
- Synchronize compared folder by folder (301 folders: 20 s): one listing command per level of the tree (0.39 s).
- Run Command with 60 000 lines froze the main thread for minutes: only the last 1 000 lines are laid out.
- Every finished job re-listed its folder: once per host when its queue is idle.
- Delete sent one sftp `rm` per file, two round trips each (50 files: 33 s over a 300 ms link): on a shell host one
  `rm -f` takes them all; sftp-only accounts keep sftp's batch.

**Correctness traps**
- This Mac's bsdtar stops the whole archive at the first file it can't open (and says only that it couldn't read it):
  such folders go with `scp -r`.
- macOS's scp/sftp cut remote paths at 1 023 bytes: AirSCP says so and offers the folder or Download as .tar.gz.
- BusyBox `ls` prints every non-ASCII byte as `?`: BusyBox hosts list with `ls` only when no name needs it, else sftp.
- The Monitor knew its own probe by the marker on its command line; once every script went to `sh -s` on standard
  input, the table listed the probe (`sh -s` and its `ps`). The script prints its shell's pid (`$$`) first, and the
  table leaves out that pid and its children.
- Foundation's `Process` turns arguments into NFD, and FileManager stores names decomposed: posix_spawn and rename(2)
  keep names byte for byte; NFC and NFD forms of a name are two names on a server.
- A normally exiting master removes its socket, after which ssh silently logs in afresh: every muxed command checks the
  socket file first.
- Errors on this Mac were blamed on the server: scp's local-side messages are recognised first.
- Silent reconnects through a jump host tried three passwords (`NumberOfPasswordPrompts=1` now) and hung on a dead
  target (`ConnectTimeout=30` for hops).
- AirSCP and its Settings opened full height after the rename: Porter had saved its window taller than the screen, the
  takeover copied that frame, and AppKit clamps such a frame to the whole screen; Settings opened as tall as its form.
  A saved frame is used only when it fits on a screen, the takeover leaves frames out, and Settings opens 600 points
  tall (its form scrolls).

## Test-suite lessons

- The suite's main queue stalls 10–30 s at its start (dozens of windows laid out at once): tests that wait for
  main-queue deliveries get 60 s.
- Window animations crashed the test process when a window was freed mid-animation while the screen was locked:
  `Support.swift` turns them off. A window released twice on close caused intermittent zombie crashes.
- The suite once read the real, locked login Keychain and hung: `Keychain.readItem`/`writeItem` are stand-ins in tests.
- A pane's saved sort order leaked from a run cut short into later tests: the test process clears its defaults domain.
- Throwaway instances (AIRSCP_SUPPORT_DIR) saved their window frames into the user's own defaults, so testers never
  saw the user's bad frame and the scripts had to put the user's back: they neither read nor save layout now.
- App tests that drive agent control run one at a time (`.serialized`): they share NSApp.
- A busy machine (CI's 3-core runner under the whole suite stalls the main queue for a minute and more): tests wait
  on conditions, not timings. `eventually` waits up to 120 s by default (only a failing test waits that long); the
  reconnect and retry tests take a test proxy away (`TestProxy.away`, which keeps its port) instead of catching the
  2 s before the first attempt; a test that needs the main queue's deliveries drains it (`await MainActor.run {}`);
  time bounds catch hangs and quadratic work only; a tunnel started on a just-freed port tries another if that one was
  taken. The suite passes so with 16 busy loops beside it on a 10-core Mac. ci.yml still runs a failed test once more
  alone, with a warning: treat that warning as a bug. RDP's silent-server test checks what ended it, not the clock.
- Test helpers close each descriptor once: TestProxy closed an upstream socket twice when it stopped mid-request, which
  could close whatever socket or pipe had taken that number meanwhile (a likely cause of a test run killed by SIGPIPE).
- The test process was still killed by SIGPIPE in about every other full run, always just after the RDP silent-server
  test: FreeRDP writing on the connection that the test's listener reset as it closed. FreeRDP's own clients ignore
  SIGPIPE, and `RDPSession` now does too (in the app as well: a server resetting the connection would have ended
  AirSCP); children keep the default (Runner.spawn and cpty reset every signal).

## The Windows VM

- Windows 11 ARM64 in UTM (`testenv/windows/`). Disabling or enabling its network adapter inside the guest crashes
  Windows (bugcheck 0x7E) until a power cycle: simulate network loss from the Mac side only.
- It gets slow after hours up ("all connections in use", late frames, programs starting minutes late); restart it
  gracefully (`utmctl stop --request`). Suite runs can fail the long desktop tests right after the login tests; they
  pass alone. One RDP session per account: never run two VM suites at once. Every VM test is in `RDPWindowsTests`
  (`.serialized`; the agent's VM tests too, as an extension): run beside the suite, a second login took the session over.
- A launched (ad-hoc signed) AirSCP connecting straight to the VM may hit macOS's Local Network prompt; the tests and
  scripts go through the lab's bastion (an SSH tunnel) or in-process.

## Real-screen findings (things only a person or the `ui` tool sees)

Other Key File… wedged the app while its panel was open (panels are sheets now); the dark-mode sidebar drew unreadably
in agent screenshots (vibrant layers are now drawn through their colour matrix); stray tab items in the Window and
View menus; Escape didn't close Get Info; a too-small minimum window size. Quick Look, real drags, Open/Save panels
and full screen still need a real-screen pass (`testenv/uidriver/smoke.sh`, lab.yml's screen job).
