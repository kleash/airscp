---
title: Check a copy with its checksum
parent: Transfers & queue
nav_order: 5
---

# Check a copy with its checksum

AirSCP can make sure that a copied file is exactly the same as the original. It compares their SHA-256 checksums: a
fingerprint of every byte in the file.

## Steps

- **One transfer**: right-click a finished transfer in the Transfers list and choose **Verify with Checksum**.
- **Every transfer**: turn on **AirSCP ▸ Settings ▸ Verify transfers with SHA-256**. Each file is checked as soon as it
  arrives.

The status then says:

- **Verified**: the copy and the original are the same.
- **Mismatch** (red): they differ. The copy was damaged, or one of them changed after the copy was made. Click
  **Retry** to copy the file again. AirSCP replaces the bad copy and checks the new one.
- **Not verified**: AirSCP couldn't check it. Point at the status to see why.

{% include shot.html name="transfers" alt="The Transfers list with a verified upload" %}

## Tips

- Only single files are checked, not folders or archives.
- The server works out its checksum with `sha256sum` or `shasum`. Accounts that allow file transfers (sftp) only can't
  run them, so their copies show **Not verified**.
- Checking reads the whole file on both sides, so big files take longer.
- To see the checksum, point at **Verified** in the list.
