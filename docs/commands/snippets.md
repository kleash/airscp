---
title: Save commands as snippets
parent: Snippets & Run Command
nav_order: 2
---

# Save commands as snippets

A snippet is a command you run often, saved with a name. You choose the host each time you run it.

## Steps

1. Choose **Window ▸ Snippets**.
2. Click **+** to add a snippet. Type a **Name** and the **Command**.
3. Tick **Run in Terminal** for commands like `sudo` or `top`.
4. To run it: choose a host under **Run on**, then click **Run**. The output appears in a Run Command sheet.

{% include shot.html name="snippets" alt="The Snippets window with four saved commands" %}

## Run a snippet on selected files

A snippet can name the files you select in a server pane:

| Placeholder | Becomes |
|---|---|
| `{file}` | each selected item's path: the command runs once per item |
| `{name}` | each selected item's name |
| `{files}` | all the selected paths, in one command |
| `{folder}` | the folder the pane shows |

1. Write the snippet, for example `gzip -k {file}` or `tar czf {folder}/backup.tgz {files}`.
2. In a server pane, select the files, right-click and choose **Run Snippet ▸** your snippet.
3. The output appears in a Run Command sheet (or Terminal, for **Run in Terminal**). The folder is listed again after.

AirSCP puts each name in quotes, so names with spaces or quotes are safe.

## Tips

- The Run Command sheet has your snippets in its **Snippets** pop-up.
- In the [Terminal tab](terminal-tab.md), **Insert Snippet** types one at the prompt without running it.
- Only snippets with a placeholder appear under **Run Snippet**. One with only `{folder}` runs without a selection.
- A snippet with a placeholder runs only from **Run Snippet**: the Snippets window's **Run**, Shortcuts and Ask AirSCP
  say so instead of running it.
- **−** deletes the selected snippet.
