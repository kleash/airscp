---
title: iPad and iPhone Duo
parent: iPhone and iPad
nav_order: 7
---

# iPad and iPhone Duo

On an iPad, AirSCP uses the room it has: a sidebar with your open servers, a workspace for each, several windows, the
keyboard and the pointer. AirSCP follows the width of its window, not the device. A narrow window (next to another app,
or an iPhone Duo folded) looks as on an iPhone.

## The sidebar and a server's workspace

1. Tap the sidebar button next to the tabs at the top. The sidebar lists **Servers**, **Files**, **Terminal**,
   **Transfers** and **Search**, and under **Open**, each open server.
2. Tap an open server. Its workspace shows:
   - the server's files and **On iPad** next to each other: drag between them to copy;
   - the server's terminal under the files: tap the bar with its name, or drag the bar up. Drag the bar to change the
     terminal's height;
   - in that bar, **+** (New Terminal), **Full Window**, and **Transfers**, which shows the transfers on the right.
3. Touch and hold an open server in the sidebar for **Open in New Window** or **Disconnect**.

<!-- picture: ipad-workspace; iPad, landscape; A server's workspace: the sidebar with the open server, its files and On iPad next to each other, the terminal pulled up under them, and Transfers on the right -->

In a wide window, such as an iPad on its side:

- **Transfers** show on the right by themselves when a copy starts.
- A file you edit opens next to the files, not over them.

## Full Window

**Full Window** (<kbd>⇧⌘F</kbd>) gives the terminal, or the editor next to the files, the whole window: for work with a
keyboard. Where there is room, the editor then shows the lines you changed next to the text. **Exit Full Window** gives
the window back. For the editor, <kbd>Esc</kbd> does too. In the terminal, <kbd>Esc</kbd> goes to the shell (for
`vim`): press <kbd>⇧⌘F</kbd> again.

## Several windows

Touch and hold AirSCP's icon in the Dock or on the Home Screen, then tap **New Window**. Or touch and hold an open
server in the sidebar and tap **Open in New Window**.

All windows share the servers, connections, transfers, tray and terminals: a new window doesn't log in again. Each
window shows what you choose there: its own tab, folders and terminal. When you close a window, the others keep
everything it opened.

## Keyboard shortcuts

With a keyboard, hold <kbd>⌘</kbd> to see them.

| Keys | What they do |
|---|---|
| <kbd>⌘1</kbd>, <kbd>⌘2</kbd>, <kbd>⌘3</kbd>, <kbd>⌘4</kbd> | Show **Servers**, **Files**, **Terminal**, **Transfers** |
| <kbd>⌘K</kbd> | **Search** |
| <kbd>⌘T</kbd> | **New Terminal** on the server in front |
| <kbd>⇧⌘F</kbd> | **Full Window** for the terminal or the editor |

In **Files**, on the side you used last:

| Keys | What they do |
|---|---|
| <kbd>⌘R</kbd> | Read the folder again |
| <kbd>⌘N</kbd> | **New Folder** |
| <kbd>Return</kbd> or <kbd>⌘↓</kbd> | Open the selected folder or file |
| <kbd>⌘↑</kbd> | Go up one folder |
| <kbd>⌘A</kbd> | Select everything in the folder (while you select) |
| <kbd>⌘C</kbd>, then <kbd>⌘V</kbd> | Copy the selected items into the folder shown, on either side |
| <kbd>⌘⌫</kbd> | Delete the selected items (AirSCP asks first) |

In the terminal, the keys go to the shell: arrows, <kbd>Esc</kbd>, <kbd>Tab</kbd>, Control keys, function keys, Home,
End, Page Up and Page Down. <kbd>⌘C</kbd>, <kbd>⌘V</kbd> and <kbd>⌘A</kbd> copy, paste and select all.

## Pointer

With a trackpad or a mouse:

- Over the terminal, the pointer is a text cursor. Scroll to go back through the output. Right-click for **Copy**,
  **Paste** and **Select All**.
- Right-click a file, a server or a transfer for the menu that touch and hold shows.
- Drag files between the two sides, and to and from other apps.

## iPhone Duo

Folded, an iPhone Duo shows AirSCP as an iPhone does: one side of **Files** at a time. Open, it shows AirSCP as an iPad
does: both sides next to each other, the sidebar and the workspaces.

Folding, opening or turning it keeps what you were doing: the folder, the selection, the scroll position, the terminal
and the copies that run. A server's workspace goes on in **Files** while the iPhone is folded, and comes back when you
open it.
