---
title: Use your PuTTY (.ppk) keys
parent: Keys
nav_order: 3
---

# Use your PuTTY (.ppk) keys

Coming from Windows, PuTTY or WinSCP? Your keys are `.ppk` files. AirSCP turns them into keys that ssh on the Mac can
use, and back. Nothing else needs to be installed.

## Import a .ppk key

1. Choose **Window ▸ Keys** and click **Import Key…** (or drop the `.ppk` file on the Keys window).
2. If the `.ppk` file has a passphrase, type it.
3. Check the **Name** of the new key. Keep the same passphrase, or choose a new one (empty for none).
4. Click **Import**. The key appears in the list, ready to use.

{% include shot.html name="import-putty-key" alt="The Import web.ppk sheet: the new key's name, folder and passphrase" %}

A host's **Log in with ▸ Choose a Key File…** accepts a `.ppk` file too: it is imported first.

## Export a key for PuTTY

1. Select a key in the Keys window and click **Export for PuTTY…**.
2. Optional: a passphrase for the `.ppk` file.
3. Click **Export…** and choose where to save it.

{% include shot.html name="export-putty-key" alt="Export as a PuTTY key: an optional passphrase for the .ppk file" %}

The `.ppk` file is in PuTTY's key format version 3, which PuTTY 0.75 (2021) and later read. Update an older PuTTY to
use it.

## Tips

- RSA, ECDSA and Ed25519 keys work, encrypted or not. Import reads PPK version 2 and 3.
- The `.ppk` file and your key stay as they are: AirSCP writes new files and never overwrites one.
- The unencrypted key exists only for a moment, in a private temporary folder that AirSCP wipes.

## If something goes wrong

- **A wrong passphrase** or **a damaged file** is shown in red in the sheet. AirSCP checks the file's integrity (its
  MAC) before using it.
