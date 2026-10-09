---
title: The Terminal tab
parent: Snippets & Run Command
nav_order: 5
---

# The Terminal tab

A shell on the server, inside AirSCP. It uses the host's connection, so there is no second login, and it knows
files: right-click a file name in the output to show, download or edit it, and drop Finder files on it to upload them
to the folder you are in.

## Steps

1. Connect to the host.
2. Click **Terminal** above the files, or choose **Host ▸ Terminal Tab** (<kbd>⌃⌘T</kbd>).
3. Type as in any terminal. Programs such as `less`, `vim`, `top` and `nano` work full screen.

## Work with files from the output

Right-click a file or folder name that a command printed (`ls`, `find`, `grep -l`, a compiler's `file.c:12`):

- **Show in Files**: the Files tab shows it in the server's pane.
- **Download**: copies it to the Mac folder of the Files tab, through the transfer queue.
- **Edit in AirSCP**: opens it in AirSCP's editor. **Save** puts it back on the server.
- **Get Info**: its size, owner, permissions and dates.
- **Copy Path**: its full path on the server.

A name without a path is taken from the folder the shell is in.

## Upload by dropping files

Drag files from Finder onto the terminal. AirSCP uploads them to the shell's folder through the transfer queue, and
types their names at the prompt.

## Tips

- Select text by dragging; <kbd>⌘C</kbd> copies it and <kbd>⌘V</kbd> pastes. A double-click selects a word.
- Scroll up to see earlier output. **Clear Scrollback** (right-click) forgets it.
- <kbd>⌃C</kbd>, <kbd>⌃D</kbd> and the other Ctrl keys go to the shell. <kbd>⌘</kbd> shortcuts stay AirSCP's.
- When the shell ends (you typed `exit`, or the connection dropped), press <kbd>Return</kbd> for a new one.
- **Host ▸ Open Terminal** (<kbd>⌘T</kbd>) still opens Terminal or iTerm instead. See [Open a terminal](open-a-terminal.md).

## If something goes wrong

- **“Connect to the host to open a shell here”**: the host isn't connected. Choose **Host ▸ Connect**.
- **“AirSCP can't tell which folder the shell is in”**: the server doesn't show it (no `/proc` and no `lsof`). Use
  full paths, or drop files on the Files tab's server pane instead.
