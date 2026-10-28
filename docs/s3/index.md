---
title: S3 storage
nav_order: 8
has_children: true
---

# S3 storage

AirSCP opens Amazon S3 and storage that works like it (MinIO, Cloudflare R2, Backblaze B2, Wasabi, Ceph and others).
Its buckets open in the Files tab like a server's folders: you browse, drag files in and out, rename, delete, edit and
zip, and long copies wait in the Transfers list.

## Pages

- [Connect to S3 or S3-compatible storage](connect.md)
- [Browse and transfer](browse-and-transfer.md)
- [Zip and extract](zip-and-extract.md)

## Good to know

- A bucket is a folder at the top. Folders inside a bucket are parts of the file names (`photos/2024/a.jpg`): an
  empty folder is kept as an empty object named `folder/`.
- S3 storage keeps files only. It has no commands, terminal, tunnels, permissions or symbolic links: those menu
  items are off, and their tooltip says why.
- AirSCP doesn't make or delete buckets. Do that in your provider's console.
