---
title: Terminal on iPhone and iPad
parent: iPhone and iPad
nav_order: 3
---

# Terminal on iPhone and iPad

The **Terminal** tab is a shell on an open server. It uses the server's connection, so there is no second login. Each
open server has one.

## Steps

1. Open the server in **Servers**.
2. Tap **Terminal**.
3. Type a command in the **Command** field at the bottom, then tap the return arrow next to it. While you type, the
   commands you ran on that server before show above the field: tap one to fill it in.

To type in the shell itself, for example in `vim`, `top` or `less`, tap the terminal. The keyboard comes up.

<!-- picture: iphone-terminal; iPhone, portrait; The terminal with the keyboard up: the output of ls, and the key bar with esc, ctrl, tab, the arrows and | ~ / - -->

## The keys a phone keyboard lacks

While the terminal has the keyboard, a bar above it has **esc**, **ctrl**, **tab**, the four arrows, `|`, `~`, `/` and
`-`, and a button that hides the keyboard. For Control-C, tap **ctrl**, then **c**.

## With the keyboard down

Big buttons at the bottom:

- **Stop**: stops the command that runs (Control-C).
- **Return**: presses Return in the shell.
- **Type**: brings the keyboard up.

<!-- picture: iphone-terminal-deck; iPhone, portrait; The terminal with the keyboard down: the output of grep -n, a notes.txt:3 button above the command line, and Stop, Return and Type -->

## Scroll, select and copy

- Drag up or down to go back through what the shell printed. While you look back, a button says how many new lines
  came: tap it to see the newest. In full-screen programs such as `less` and `vim`, a drag moves with the arrow keys.
- Touch and hold a word to select it, and drag to select more. Then tap **Copy**. **Paste** types the copied text at
  the prompt. **Select All** selects everything.
- Pinch to make the text bigger or smaller.

## Open the file a command names

When a command prints a file's name with a line number (an error from a compiler, `grep -n`), a button such as
**main.c:12** shows above the command line. Tap it to open the file in the editor at that line.

## More shells

- Tap **+** (New Terminal) and choose an open server: another shell there.
- With more than one terminal, the menu at the top left shows another one. **Close Terminal** (**×**) ends the shell
  you see; a server's last terminal stays.
- When the shell ends, for example after `exit`, tap **Return** for a new one.

## Tips

- AirSCP keeps the commands you run on each server. [Search](search.md) finds them and runs them again, on one server
  or on several.
- On an iPad, a keyboard works as on a computer: arrows, Esc, Tab, Control keys and function keys go to the shell, and
  <kbd>⌘C</kbd> and <kbd>⌘V</kbd> copy and paste. **Full Window** gives the terminal the whole screen. See
  [iPad and iPhone Duo](ipad.md).
- There is no terminal for S3 storage, nor for an account that allows file transfers (sftp) only.
