---
title: Browse and copy files as root
parent: Connecting
nav_order: 14
---

# Browse and copy files as root (sudo)

Some files only root (or another user) may change: web server configs, other users' folders. AirSCP can browse,
change and copy files as that user, with `sudo`.

## Steps

1. Choose **Host ▸ Edit…**, then **Advanced**.
2. In **Browse and transfer as**, type the user, for example `root`.
3. Click **Save**, then connect.

From then on, listings, new folders, renames, deletes, permissions, uploads and downloads happen as that user. The
commands you type (**Run Command…**, snippets) and the **Terminal** tab stay yours.

## What the server needs

- `sudo` that lets your user become that user **without a password** (a `NOPASSWD` rule in `/etc/sudoers`), for
  example: `deploy ALL=(root) NOPASSWD: ALL`.
- OpenSSH's `sftp-server` program (most Linux servers have it; BusyBox-only systems don't).

When something is missing, connecting stops and says what, instead of browsing as your own user.

## Tips

- Files AirSCP makes this way belong to that user (root, say).
- Copies go with sftp for such a host (scp can't change user); folders still go as one stream where the server has tar.
- Use it only for the hosts that need it: everything you do there is done as root.
