---
title: Import your sites from WinSCP
parent: Connecting
nav_order: 13
---

# Import your sites from WinSCP

Coming from WinSCP on Windows? AirSCP can make a host for each of your WinSCP sites, with its folder, its key, its
tunnel (as a jump host) and its HTTP proxy.

## Steps

1. In WinSCP on the PC, choose **Tools ▸ Export/Backup Configuration…** and save **WinSCP.ini**.
2. Copy WinSCP.ini to this Mac. Put the PuTTY keys (.ppk files) your sites use in the same folder.
3. In AirSCP, choose **File ▸ Import from WinSCP…** and pick WinSCP.ini.
4. AirSCP says how many hosts it made, and what it left out.

## What comes over

- Each SFTP or SCP site becomes a host: address, port, user name and the folder it opens in.
- A folder of sites becomes a group. A site in a folder in a folder goes in a group such as “Work/Web”.
- **Tunnel** settings become a jump host, shared by the sites that use it. See [Connect through a jump host](jump-hosts.md).
- An HTTP proxy becomes a proxy. See [Connect through an HTTP proxy](proxies.md).
- A .ppk key without a passphrase becomes an OpenSSH key in your key folder (~/.ssh unless Settings names another),
  and the host logs in with it.

## What stays behind

- **Saved passwords**: AirSCP never reads them. It asks for a password when you connect, and can keep it in the
  Keychain.
- **FTP, WebDAV and S3 sites**: AirSCP connects over SSH only.
- **SOCKS proxies** and proxies that WinSCP runs itself: add those hosts by hand.
- A .ppk key **with a passphrase**: import it in **Window ▸ Keys**, then choose it in **Edit Host**.

## Tips

- Importing the same file again adds only the sites that are new.
- WinSCP keeps its settings in the Windows registry until you export them. **Tools ▸ Export/Backup Configuration…**
  always writes a WinSCP.ini that AirSCP can read.

## If something goes wrong

- **“No SSH sites in WinSCP.ini”**: the file has no SFTP or SCP sites. Check that you exported WinSCP's configuration,
  not a single site's URL.
- **“deploy.ppk isn't beside the file”**: copy that key into the folder that holds WinSCP.ini, then import again.
