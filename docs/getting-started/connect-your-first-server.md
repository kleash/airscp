---
title: Connect to your first server
parent: Getting started
nav_order: 2
---

# Connect to your first server

Save a server once, then connect with one click. You need the server's address and your user name on it. Your server
admin or hosting company gives you these.

## Steps

1. Choose **File ▸ New Host…** (or click **+** in the toolbar).
2. Type the server's **Address**, for example `web-01.example.com` or `192.168.1.20`.
3. Type your **User name** on the server.
4. Under **Log in with**, choose your key, or **Password**. Not sure? Leave the default: it tries the keys in `~/.ssh`.
5. Click **Add**. The server appears in the sidebar.

   {% include shot.html name="host-editor" alt="The New Host sheet with a name, an address, a user name and a key" %}

6. Double-click the server in the sidebar (or select it and press <kbd>⌘K</kbd>).
7. The first time, AirSCP shows the server's key fingerprint and asks **Trust “…”?**. Click **Trust** if it is the
   server you expect. Read more in [Trust a server the first time](../connecting/trust-a-server.md).

   {% include shot.html name="trust-server" alt="The Trust sheet with the server's key fingerprint" %}

8. If the server asks for a password, type it. Tick **Remember in Keychain** if you don't want to type it again.

Now you see your Mac's files on the left and the server's files on the right.

{% include shot.html name="files" alt="Connected: this Mac on the left, the server's folder on the right" %}

## Tips

- Only the address is required. Everything else has a sensible default.
- **Test Connection** in the sheet logs in once, without saving, so you can check your settings.
- Behind a bastion? See [Connect through a jump host](../connecting/jump-hosts.md).

## If something goes wrong

- **“Can't connect”**: check the address and the port. The message says what went wrong, and **Details** shows ssh's
  own words.
- **The password is not accepted**: check the user name in the host's settings (**Host ▸ Edit…**).
- More: [Troubleshooting](../troubleshooting.md).
