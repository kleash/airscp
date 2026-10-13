---
title: Server information, password and links
parent: Connecting
nav_order: 13
---

# Server information, change your password, links

## Server information

1. Connect to the host.
2. Choose **Host ▸ Server Info…**.
3. You see:
   - **Server key**: the server's key type and SHA-256 fingerprint, as your Mac trusts it. Compare it with what your
     server's admin gives you.
   - **Software**, **Key exchange** and **Cipher**: what the server runs and how the connection is encrypted. These need
     **Help ▸ Turn On Debug Logging** before you connect.
   - **Can**: what AirSCP found the server can do (run commands, tar, zip, checksums…).
   - **Free space** in the folder the pane shows.
4. Click **Copy** to put it all on the clipboard, for a support request.

## Change your password on the server

1. Connect to the host.
2. Choose **Host ▸ Change Password…**. The Terminal tab opens and runs `passwd`.
3. Type your current password, then the new one twice, as `passwd` asks.
4. If AirSCP saved your old password, it offers to save the new one: type it once more and click **Save** (or
   **Forget It**, and the next connect asks).

AirSCP never reads the password back from your Keychain to do this.

## Links

- **Host ▸ Copy Link** copies a link like `sftp://deploy@web.example.com/var/www`: the host and the folder shown. It
  never holds a password.
- Opening an `sftp://` or `ssh://` link (in Safari, Mail or Terminal) opens it in AirSCP: the saved host with that
  address at that folder, or its Terminal tab for `ssh://`. For a server you haven't saved, **New Host…** opens filled
  in from the link.
