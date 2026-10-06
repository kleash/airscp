---
title: Connect and log in
parent: Remote Desktop (Windows)
nav_order: 2
---

# Connect and log in

## Steps

1. Double-click the computer in the sidebar (or select it and press <kbd>⌘K</kbd>, or click **Connect**).

   {% include shot.html name="rdp-idle" alt="Office PC selected, not connected yet: Connect to show the Windows desktop here" %}

2. The first time, AirSCP shows the computer's certificate: who it was issued to, by whom, and its fingerprint.
   Click **Always Trust** to remember it, or **Trust Once** for this time only.
3. If no password is saved, AirSCP asks: type the **User name** and **Password** (and the **Domain** for a company
   account). Tick **Remember the password in Keychain** to save it.
4. Click **Log In**. The Windows desktop appears in AirSCP's window.

{% include shot.html name="rdp-login" alt="The Log in to Office PC sheet with user name, domain and password" %}

To end the session, click **Disconnect** in the bar, or choose **Host ▸ Disconnect** (<kbd>⌘E</kbd>).

## Tips

- Connected desktops stay connected while you look at a server. Switch with <kbd>⌘1</kbd> to <kbd>⌘9</kbd>.
- A password typed with Remember is saved only after Windows has checked it.
- Through an SSH host, AirSCP connects that host first and opens a tunnel through it.

## If something goes wrong

- **“The user name or password is incorrect”**: try again. A company account needs its domain (the Domain field, or
  `DOMAIN\user`).
- **“AirSCP couldn't reach the server”**: check the address, that Remote Desktop is on in Windows, and your VPN.
  macOS may ask once whether AirSCP may find devices on your local network: choose **Allow**.
- **“The certificate of … has changed”**: someone may be in the middle of the connection, or the computer got a new
  certificate. Trust it only if you know why it changed.
- **“The session was disconnected in Windows”**: another login took it over. Reconnect to take it back.
