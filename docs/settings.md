---
title: Settings & appearance
nav_order: 13
---

# Settings and appearance

Choose light or dark mode, your terminal app, your downloads folder and a few defaults. Open **AirSCP ▸ Settings…**
(<kbd>⌘,</kbd>). Every change applies at once.

{% include shot.html name="settings" alt="Settings: Appearance, Files and Security" %}

## Appearance

**System** (the default) follows your Mac's light or dark mode. **Light** or **Dark** keeps AirSCP in one of them.

- **Light** is the Paper look: white panes on a grey background, and black for the selected row, the active tab and the
  main buttons.
- **Dark** is the Night Harbor look: a deep blue-grey, with a colour for each kind of thing (servers blue, Remote
  Desktop purple, proxies orange) and glowing dots for connected servers.

Your Mac's accent colour, **Increase contrast** and **Reduce transparency** (System Settings ▸ Accessibility ▸ Display)
still apply. With Increase contrast on, the dark look drops its blue tint.

{% include shot.html name="files" alt="AirSCP's window; it follows the appearance you choose" %}

## Files

| Setting | What it does |
|---|---|
| **Open terminals in** | Terminal (default) or iTerm, for Open Terminal, Run in Terminal and Kill with sudo. |
| **Downloads folder** | Where **Download To…** starts, and where **Download as .tar.gz** puts the archive when the other pane isn't this Mac. Drags and the Download button go to the folder shown. |
| **Show hidden files in new panes** | Off by default. Each pane can still switch with <kbd>⇧⌘.</kbd>. |
| **Copied files keep their original date** | Off by default: copies are dated now. On: they keep the file's own date (`scp -p`). |
| **Verify transfers with SHA-256** | Off by default. On: each copied file is compared with the original once it arrives. See [Check a copy with its checksum](transfers/verify-checksums.md). |
| **Ask before deleting on a server** | On by default. |
| **Always calculate folder sizes** | Off by default: folders show “—” until you click **Σ**. |

## Security

How new hosts check their server's key, and new desktops their server's certificate. **Ask** unless you change it. See
[Self-signed certificates and corporate networks](connecting/self-signed-certificates.md).

## Keys

**New keys go in**: the folder where New Key Pair and Import Key save keys. `~/.ssh` by default, where ssh finds them by
itself.

## Apple Intelligence

**Use Apple Intelligence for Ask AirSCP and Explain**: on by default, on a Mac that has it. Answers come from Apple's
model on this Mac. See [Shortcuts, Siri & Apple Intelligence](shortcuts-and-ai.md).

## Agents

**Allow AI agents to control AirSCP (MCP)**: off by default. See [AI agents (MCP)](ai-agents.md).

## Advanced

**Debug logging**: off by default. On, AirSCP writes a detailed log of connections and transfers, to help find what
went wrong. Turn it off when done. See [Turn on debug logs](troubleshooting.md#turn-on-debug-logs).

{% include shot.html name="settings-advanced" alt="Settings: Advanced, with Debug logging" %}

## Tips

- The **?** button at the bottom of Settings opens this page.
