---
title: Change permissions
parent: Files
nav_order: 8
---

# Change permissions

Permissions say who may read, change and run a file on a server (`chmod`).

## Steps

1. Select the items and choose **File ▸ Permissions…**.
2. Tick the boxes: **Read**, **Write** and **Execute**, for the **Owner**, the **Group** and **Others**.
   Or type the number in **Octal (chmod)**, for example `755` or `644`.
3. To change who owns them, type a user in **Owner** or a group in **Group** (a name, or a number). Leave them as they
   are to keep them. On a file-transfer-only account, type numbers (user and group IDs).
4. For folders: tick **Change everything in the folders too** to change what is inside as well.
5. Click **Apply**.

{% include shot.html name="permissions" alt="The Permissions sheet with Read, Write and Execute boxes and the octal number 755" %}

## Tips

- **Read** lets someone see the file, **Write** change it, **Execute** run it (or enter a folder).
- **File ▸ Make Executable** is a shortcut for `chmod +x`: a script can then run.
- When you change a whole folder, folders keep their Execute box where they can be read, so a mode like `640` doesn't
  lock you out of them.
- A symbolic link has its target's permissions: change those on the target.
- Only root can give a file to another user; you can change the group to one you belong to.
