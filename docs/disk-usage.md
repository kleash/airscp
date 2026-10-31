---
title: Disk Usage
nav_order: 7
---

# See what takes the room on a disk

Find the big folders and files below a folder, on a server or on this Mac, and delete what you don't need.

## Steps

1. In a pane, open the folder to look into (or select one folder in it).
2. Choose **File ▸ Disk Usage…**, or right-click an empty part of the pane.
3. AirSCP scans everything below the folder. While it runs, the bar shows how far it is, the files it finds show
   with their sizes, and the rings and the list grow as the sizes add up.
4. The rings: the folder is in the middle, its items around it, and what is in them further out. The wider an arc,
   the more room it takes. Point at an arc to see its name and size. Click a folder's arc to go into it; click the
   middle to go up.
5. The list: the folder's items, largest first, with their share of the folder. Double-click a folder to go into it,
   or click **↑** to go up. Choose **Largest Files** to see the 200 biggest files at any depth below.
6. Select what you don't need and click **Delete…**. AirSCP asks first. On a server it deletes the items (folders with
   everything in them); on this Mac it moves them to the Trash: empty the Trash to free the space.
7. Or select an item and click **Show** (or right-click ▸ **Show in Pane**): the pane goes to its folder and selects
   it. **Copy Paths** copies the full paths, one per line. On this Mac, **Show in Finder** selects them in a Finder
   window.

## Tips

- **Stop** ends a long scan; the sizes then count what it scanned so far. **Scan Again** measures everything again.
- The scan stays on the folder's own disk: other disks mounted inside it are left out.
- Sizes are the files' own sizes, as the panes show them.
- On a server, AirSCP runs one `du` command. It needs a server with a shell (not file-transfer-only accounts).
- To see the size of each folder in the pane itself, use **View ▸ Calculate Folder Sizes**.

## If something goes wrong

- **Delete… is greyed out**: wait for the scan to end, or click **Stop**.
- **A folder you can't read** counts as empty: open it as root (see [Browse as root](connecting/browse-as-root.md))
  and scan again.
- Disk Usage doesn't work on S3 storage.
