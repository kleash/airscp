# UX copy: how AirSCP explains itself

People don't read manuals, and an app that needs one doesn't spread. AirSCP explains itself where it is used
(PLAN.md section U, binding for every change). These are the rules the v1 copy pass followed (about 390 controls,
14 empty states, a welcome sheet, the Tips page and 27 error messages were written to them).

## Tooltips

- Every button, toolbar item, menu item, checkbox, pop-up, segment, column header and status indicator has one.
  AppKit: `toolTip`, `NSMenuItem.toolTip`, `NSToolbarItem.toolTip`, `setToolTip(_:forSegment:)`,
  `NSTableColumn.headerToolTip`; SwiftUI: `.help("…")`. Menu commands get theirs from the table in `Help.swift`
  (by action, so a command says the same wherever it appears).
- One line, about 90 characters at most, verb first, no full stop: "Upload the selected Mac files into this folder".
- For an option: what it does, the default, and when you'd change it.
- **Disabled says why**: while an item is off, its tooltip is the reason ("Select one server file", "This account
  allows file transfers (sftp) only"). Agents get the same reason when a command is refused.
- `HelpTests.everyControlSaysWhatItDoes` walks every window, sheet and menu in-process and fails on any interactive
  control without help; `everyMenuItemSaysWhatItDoes` does the menus.

## Forms

- A grey caption under each non-obvious field (`Text(…).font(.caption).foregroundColor(.secondary)`).
- "Optional" goes in the placeholder of optional fields, not in the caption.
- Plain words first, the technical term in brackets: "Jump host — connect through another server first (ProxyJump)".
- Sensible defaults, so most fields can stay empty. Rarely used options go under a collapsed **Advanced**
  disclosure, which opens by itself when one of them isn't at its default.

## Empty states and first run

- An empty list says what goes there and offers the next step: no hosts → **Add Host** and **Import from
  ~/.ssh/config**; an empty queue → "Drag files between the panes…"; no Remote Desktop entries → what it is for.
- One skippable welcome sheet on the first run (import, add a host, three tips), again from Help ▸ Welcome to AirSCP.
  No account, no tour carousel. Help ▸ AirSCP Tips is a short in-app page built from the same text.

## Errors

Plain language, the next step, and a button for it where possible ("The server's key has changed … Remove the old
key and connect"). The tool's own output goes under **Details**, never in the headline.

## Words

- "This Mac", never "Local". "Server" for an SSH host in captions, "desktop" for a Remote Desktop entry, "host" in the
  sidebar sense. Shortcuts in tooltips as (⌘K).
- The product is **AirSCP** everywhere users can see (it was Porter before v1).
- The docs (`docs/`) use the same words as the app, in very simple English: short sentences, task-first titles
  ("Upload a folder"), each page: what it's for → steps → picture → tips.

## Checking a change

Run the help tests, look at the new UI in light and dark (an agent screenshot from a throwaway AirSCP, or CI's
`agent-session` artifact), and read each new string aloud: if it needs a second sentence, the control may need a
caption or a better name instead.
