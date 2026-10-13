---
title: Select by pattern, compare folders, move, link
parent: Files
nav_order: 10
---

# Select by pattern, compare folders, move, link

Commands for many files at once, and for arranging files on a server.

## Select

- **Edit ▸ Select by Pattern…** (<kbd>⌘+</kbd>): type names or patterns, separated by commas, for example `*.log` or
  `report-??.pdf`. Case doesn't matter. The matching items are added to the selection.
- **Edit ▸ Deselect by Pattern…** (<kbd>⌘-</kbd>): takes the matching items out of the selection.
- **Edit ▸ Select Same Kind**: selects every item with the selected item's extension (all `.jpg` files, say).
- **Edit ▸ Invert Selection** (<kbd>⇧⌘I</kbd>): selects what wasn't selected.
- **File ▸ Copy Names**: copies the names of the selection, one per line (**Copy Path** copies full paths).

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
