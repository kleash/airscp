---
title: Zip and extract
parent: S3 storage
nav_order: 3
---

# Zip and extract

S3 storage can't make or open archives itself. AirSCP does it on your Mac, as a job in the Transfers list: it
downloads, zips or unpacks, and uploads.

## Steps

**Download as a .zip**

1. Select the items and choose **File ▸ Download as .zip…**.
2. Click **Download**. The `.zip` lands in the folder the left pane shows (or in your Downloads folder).

**Compress in the bucket**

1. Select the items and choose **File ▸ Compress…**.
2. Click **Compress**. A `.zip` appears next to the items (`Archive.zip` for several items).

**Extract**

- Select a `.zip`, `.tar`, `.tar.gz`, `.tgz` or `.gz` file.
- **File ▸ Extract Here** puts its items in the same folder. When an item of the same name is there already, AirSCP
  puts them in a new folder named after the archive instead: nothing is replaced.
- **File ▸ Extract to New Folder** always puts them in a new folder.

## Tips

- Zips are made with macOS's `ditto`, without Mac-only extras, so they open on Windows and Linux too.
- The job needs room on your Mac for the items while it works. It cleans up when it ends.
- Like any transfer, the job can be paused (it starts again on Resume), cancelled or retried.
