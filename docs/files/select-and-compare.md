---
title: Select by pattern, compare files and folders, move, link
parent: Files
nav_order: 10
---

# Select by pattern, compare files and folders, move, link

Commands for many files at once, and for arranging files on a server.

## Select

- **Edit ▸ Select by Pattern…** (<kbd>⌘+</kbd>): type names or patterns, separated by commas, for example `*.log` or
  `report-??.pdf`. Case doesn't matter. The matching items are added to the selection.
- **Edit ▸ Deselect by Pattern…** (<kbd>⌘-</kbd>): takes the matching items out of the selection.
- **Edit ▸ Select Same Kind**: selects every item with the selected item's extension (all `.jpg` files, say).
- **Edit ▸ Invert Selection** (<kbd>⇧⌘I</kbd>): selects what wasn't selected.
- **File ▸ Copy Names**: copies the names of the selection, one per line (**Copy Path**, <kbd>⌥⌘C</kbd>, copies full
  paths). To copy the path of a folder, right-click it in the path above the list and choose **Copy Path**.

## Compare two files

1. Select two files in one pane (click one, then <kbd>⌘</kbd>-click the other). Or select one file in each pane: a
   file on this Mac and one on a server, say.
2. Right-click one of them and choose **Compare** (with one file in each pane: **Compare with “name”**).
3. A window shows the two files side by side, line by line:
   - Red lines are only in the left file, green lines only in the right file. A grey gap stands opposite them.
   - A line that changed is tinted on both sides, and the letters that changed are darker.
   - The bar at the far right marks where the differences are. Click a mark to go there.

What you can do in the window:

- **Previous** and **Next** (<kbd>⌥⌘↑</kbd> and <kbd>⌥⌘↓</kbd>) go from one difference to the next. "3 of 12" says
  where you are.
- **Sync Scrolling** keeps both sides scrolling together. Turn it off to scroll one side alone.
- **Ignore** leaves out **Whitespace**, **Case** or **Blank Lines**. The window's title bar then says, for example,
  "The files are the same apart from whitespace".
- **Prettify** lays out JSON or XML files neatly on both sides, then compares again. **Original** (or <kbd>⌘Z</kbd>)
  puts the text back.
- **Copy →** and **← Copy** copy the difference shown to the other side. **Save Left** or **Save Right** then writes
  that side back to its file (on this Mac or on the server). <kbd>⌘Z</kbd> undoes a copy.
- **Swap** puts the files the other way round. **Reload** reads both files again. **Find** (<kbd>⌘F</kbd>) looks for
  text in the side you clicked last.

Compare shows plain text files (UTF-8) up to 4 MB side by side. Other files (pictures, programs, archives, or larger
files) are compared by their SHA-256 checksum instead: the window shows each file's size and checksum, and says **The
files are the same** or **The files are different**. Click **Stop** to stop a long check.

## Compare two folders

1. Show a folder on this Mac in one pane and a server's folder in the other.
2. Choose **File ▸ Compare Folders**.
3. The names that differ turn blue in both panes. Point at one to see why: **Only here**, **Newer here**, **Older
   here** or **Another size**.

Compare Folders looks at the two folders only, not inside their subfolders. The marks go when the pane lists again.
To make the folders the same, use [Synchronize](../synchronize.md).

## Move or copy within a server

- **File ▸ Move To…**: type a folder on the same server (its full path, `~/…` in your home folder, or one relative to
  the folder shown). The other pane's folder is filled in when it shows the same server.
- **File ▸ Copy To…**: the same, as a copy. It needs an account that runs commands (not file transfer only).
- When a name is taken there, AirSCP asks [Replace, Keep Both or Skip](replace-or-keep-both.md).

## Make a symbolic link

1. Select the file or folder to link to (or nothing).
2. Choose **File ▸ New Symbolic Link…**, type the link's name, click **Next**.
3. Type what it points to, click **Create**. A relative path (like `../shared/config.yml`) keeps working when the
   folder moves.

## Go to the other pane's folder

**Go ▸ Other Pane's Folder** (<kbd>⌥⌘O</kbd>) shows the folder the other pane shows, when both panes show this Mac or
the same server.

## Tips

- Windows servers can't make symbolic links over SSH: the command is greyed out there.
