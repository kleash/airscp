---
title: Install AirSCP
parent: Getting started
nav_order: 1
---

# Install AirSCP

AirSCP runs on macOS 13.1 or later, on Apple silicon and Intel Macs. You need nothing else: AirSCP uses the ssh tools
that come with macOS.

## Steps

1. Install with [Homebrew](https://brew.sh):

   ```sh
   brew install --cask kleash/tap/airscp
   ```

   Or download the newest AirSCP zip file from the
   [Releases page](https://github.com/kleash/airscp/releases), open it, and drag **AirSCP** into your
   **Applications** folder.
2. Open **AirSCP** from your Applications folder or with Spotlight. AirSCP is signed and notarized by Apple, so macOS
   opens it after asking once whether you want to open an app downloaded from the internet: click **Open**.
3. The **Welcome to AirSCP** sheet opens. Choose what you want to do first:
   - **Import from ~/.ssh/config…** if you already use ssh in Terminal.
   - **New Host…** to add one server.
   - **New Remote Desktop…** to add a Windows computer.
   - **Start** to look around first.

{% include shot.html name="welcome" alt="The welcome sheet" %}

## The App Store version

AirSCP also comes from the Mac App Store. It is the same app, but Apple's sandbox keeps it to what you allow, so a
few things work differently. Homebrew or the Releases page give you the version without these differences.

{% include shot.html name="welcome-appstore" alt="The App Store version's welcome sheet, with Give Access to Your SSH Folder…" %}

| In the App Store version | Do this instead |
|---|---|
| AirSCP sees your SSH folder (`~/.ssh`) only after you allow it. | Click **Give Access to Your SSH Folder…** in the welcome sheet, or **Choose…** next to **SSH folder** in **Settings ▸ Keys**. Until then AirSCP keeps its own keys and known hosts. |
| **This Mac**'s pane opens a folder only after you allow it (your Downloads folder is always open). | When AirSCP asks, click **Allow**. Choose your home folder to allow everything in it. |
| **Open Terminal**, **Open Terminal Here** and **Run in Terminal** can't open Terminal or iTerm. | They use the host's [Terminal tab](../commands/terminal-tab.md) in AirSCP: at an empty prompt AirSCP types the `cd` or the command there, else it opens a new tab. |
| **Import from WinSCP…** reads only the files you choose. | Choose `WinSCP.ini` and its `.ppk` keys together. |
| **Import from ~/.aws…** reads your AWS folder only after you allow it. | When AirSCP asks, choose the `.aws` folder in your home folder and click **Allow**. |
| Your hosts from the Homebrew version aren't there. | In that version: **File ▸ Export Hosts…**. In this one: **File ▸ Import Hosts…**. |
| ssh uses only keys and configs in folders you allow, and not another app's ssh agent (a password manager's, for example). | Allow the folder that has them. For another app's agent, use the Homebrew version. |
| `AirSCP --agent … --out file.png` can't save outside AirSCP's own folder. | Use `--out -` and send the picture where you want it, or let your MCP client take it. |

## Tips

- AirSCP has no account and no sign-up. Your hosts stay on your Mac.
- The welcome sheet comes only once. Open it again with **Help ▸ Welcome to AirSCP…**.
- Short tips are always in **Help ▸ AirSCP Tips**.

## If something goes wrong

- **macOS asks whether AirSCP may use your Keychain.** This can happen the first time AirSCP reads a saved password. Choose
  **Always Allow**. AirSCP waits until you answer.
- **macOS asks whether AirSCP may find devices on your local network.** This is for Remote Desktop and servers on your
  network. Choose **Allow**.
- More: [Troubleshooting](../troubleshooting.md).
