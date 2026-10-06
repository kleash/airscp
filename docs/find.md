---
title: Find
nav_order: 7
---

# Find files on a server

Search for files by name in a server folder and in every folder below it.

## Steps

1. In the server pane, open the folder to search in.
2. Choose **File ▸ Find Files…** (<kbd>⇧⌘F</kbd>), or right-click the folder.
3. Type a name, or part of one. Or a pattern, for example `*.log`. `*`, `?` and `[ ]` work; case doesn't matter.
4. Click **Find**.
5. Select a result and click **Show** (or double-click it): the pane goes to its folder and selects it.

{% include shot.html name="find" alt="Find Files in dev with *.log: three results" %}

## Tips

- Text without `*` or `?` finds names that contain it: `report` finds `report.pdf` and `old-report.txt`.
- Up to 10,000 results. They show as they are found. **Stop** ends a long search and keeps what it found; **Done**
  closes the sheet.
- On servers with a shell, AirSCP runs one `find` command. On file-transfer-only (sftp) accounts it lists folder after
  folder, which is slower.
- To narrow the files the pane shows instead, use **Filter by name** at the top of the pane (<kbd>⌘F</kbd>).

## If something goes wrong

- **“Nothing found below …”**: try part of the name, or a pattern like `*.log`.
- Find Files searches servers. For files on your Mac, use Spotlight or Finder.
