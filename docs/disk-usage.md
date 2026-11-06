---
title: Disk Usage
nav_order: 7
---

# Find what fills a disk

Disk Usage shows what takes the room below a folder: on a server, on S3 storage or on this Mac. It shows how full the
disk is, the biggest folders and files, totals by file type, and what grew since the last time you looked.

## Steps

1. In a pane, open the folder to look into (or select one folder in it).
2. Choose **File ▸ Disk Usage…**, or right-click an empty part of the pane.
3. A window opens and AirSCP measures everything below the folder. You can keep working in the panes while it runs.
4. At the top: the folder, its server, and the disk's bar: this folder, the rest that is used, and what is free
   ("This folder: 12 GB of 98 GB used, 31 GB free").
5. The rings: the folder is in the middle, its items around it, and what is in them further out. The wider an arc,
   the more room it takes. Point at an arc to see its name and size. Click a folder's arc to go into it; click the
   middle to go up.
6. The list: the folder's items, largest first, with their share of the folder. Double-click a folder to go into it.
   Use **‹** (back), **↑** (up) or the folder names at the top of the list to go back. Click a column title to sort.
   Type in **Filter** to show only some names.

Opening Disk Usage again for the same folder brings its window to the front. Closing the window stops a scan.

## Choose a view

- **Contents**: the folder's items by size.
- **Largest Files**: the 200 biggest files at any depth below.
- **By Type**: the room each kind of file takes (.log, .mp4…), with how many there are. Double-click a type (or
  select it and click **Show Largest Files**) to see its largest files.
- **Changes**: what grew or shrank since the last scan of this folder, the biggest growth first.
- **Open but Deleted**: files that were deleted while a program still has them open (see below).

## Free space

Select what you don't need, then:

- **Delete…**: AirSCP asks first. On a server it deletes the items (folders with everything in them); on this Mac it
  moves them to the Trash: empty the Trash to free the space.
- **Empty File…**: makes a file 0 bytes. The file stays, but its room is free at once, even while a program writes
  to it. This is the way to shrink a big log. AirSCP asks first and says how much it frees.
- **Download as .tar.gz…** (from S3 storage, **Download as .zip…**): keep a copy on this Mac before you delete. The
  download runs in the Transfers queue.

Other buttons: **Open** goes into a folder. **Show in Pane** goes to the item in the Files tab. **Copy Paths** copies
the full paths, one per line. On this Mac, **Show in Finder** selects the items in a Finder window.

## Deleted files that still take room

When a program has a file open and the file is deleted, its room is freed only when the program closes it. A folder
scan can't see such files, so the disk can look fuller than the folders add up to.

1. Choose **Open but Deleted**. It lists each file with its program, process number (PID), user and size.
2. Restart or stop that program to free the room. On a server, the **Monitor** tab can stop a process.
3. Click **Look Again** to check. On a server, **Look as Root…** also shows other users' programs.

## Compare with the last scan

Each finished scan is saved (on this Mac, one per folder). The next scan of the same folder shows, beside each size,
how much it grew ("+1.2 GB") or shrank ("−300 MB"). The top of the window says how much the whole folder changed.
Choose **Changes** to see what grew the most.

AirSCP keeps the sizes of folders and of files of 1 MB or more. Deleting a server from AirSCP deletes its saved scans.

## Export the list

Click **Export as CSV…** and choose where to save. The file has the view shown: path, size in bytes, number of files
and share of the folder. It opens in Numbers, Excel or any spreadsheet.

## Tips

- **Stop** ends a long scan; the sizes then count what it scanned so far. **Scan Again** measures everything again.
- The scan stays on the folder's own disk: other disks mounted inside it are left out.
- Sizes are the files' own sizes, as the panes show them.
- To see the size of each folder in the pane itself, use **View ▸ Calculate Folder Sizes**.

## If something goes wrong

- **"N folders couldn't be read"**: your account may not open them, so they count as empty. Click the line to see
  which ones. If your account can use sudo, click **Scan as Root…**. AirSCP asks for your password only if sudo needs
  it, and doesn't keep it.
- **Delete… or Empty File… is greyed out**: wait for the scan to end, or click **Stop**. Empty File works on files
  only, not folders. Point at a greyed-out button to see why.
- **Open but Deleted says it can't tell**: some servers don't let AirSCP see this (Windows, accounts without a
  shell, S3 storage).
