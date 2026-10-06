---
title: New folder, rename, duplicate, delete, Get Info
parent: Files
nav_order: 7
---

# New folder, rename, duplicate, delete, Get Info

Everyday file commands work on servers like in Finder. Right-click a file, or use the **File** menu.

## Steps

- **New folder**: **File ▸ New Folder…** (<kbd>⇧⌘N</kbd>). Type a name, click **Create**.
- **New empty file**: **File ▸ New File…**.
- **Rename**: select one item, **File ▸ Rename…**.
- **Duplicate**: **File ▸ Duplicate** (<kbd>⌘D</kbd>) makes “name 2” next to it.
- **Delete**: **File ▸ Delete…** (<kbd>⌘⌫</kbd>). On a server AirSCP asks first, and names the host. On this Mac, items
  go to the Trash.
- **Get Info**: **File ▸ Get Info** (<kbd>⌘I</kbd>) shows the kind, path, size, dates, owner and group, and lets you
  change the permissions.
- **Copy the path**: **File ▸ Copy Path** (<kbd>⌥⌘C</kbd>).

{% include shot.html name="new-folder" alt="The New folder sheet with the name drafts" %}

{% include shot.html name="delete" alt="The question: Delete notes.txt on web-01? This can't be undone" %}

{% include shot.html name="get-info" alt="Get Info for deploy.sh: kind, path, size, dates, owner and permissions" %}

## Tips

- Delete on a server can't be undone. Turn the question off only if you are sure: **Settings ▸ Ask before deleting on
  a server**.
- Deleting folders works on file-transfer-only (sftp) accounts too.
- A folder that is too big to read whole in Get Info says so.
