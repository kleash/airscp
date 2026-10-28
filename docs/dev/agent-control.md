# Agent control (MCP): how it works

AI agents and scripts drive the running AirSCP the way its user does: the same menus, controls and questions, with
AirSCP drawing its own screenshots. No Accessibility or Screen Recording permission is involved. User-facing docs:
`docs/ai-agents.md`; the agents' own guide: `Resources/AgentGuide.md` (served by the MCP server as `instructions` and
by the `guide` tool, and shown in Help ▸ Agent Guide).

## Pieces

| Piece | File | Job |
|---|---|---|
| Bridge | `Sources/AirSCPCore/AgentBridge.swift` | `AirSCP --mcp`: newline-delimited JSON-RPC over stdio (initialize with instructions, ping, tools/list, tools/call). `AirSCP --agent <tool> key=value…`: one call from a shell (`--json`, `--out file.png`). Holds the static tool list, so `tools/list`, `initialize` and `guide` work while the app is closed. |
| Server | `Sources/AirSCP/AgentServer.swift` | A unix socket in `<support dir>/agent/sock` (folder 0700), a 64-hex token in `agent/token` rewritten each launch, a uid check of the peer, 1 MB requests, one request per connection. Dispatches the tools on the main actor. |
| Snapshot | `Sources/AirSCP/AgentSnapshot.swift` | The state as JSON, and `AXNode`: the in-process accessibility tree of AppKit views and SwiftUI nodes (what VoiceOver reads), with secure values as `•••(n)`. Always `debugLog` (on, path): an agent reads the debug log's file itself. |
| Indicator | `Sources/AirSCP/HostsSidebar.swift` (`AgentIndicator`) | "Agent control on" in the sidebar footer; the dot pulses while an agent acts; hover: who and since when; click: the last 20 actions in plain words, Turn Off, Settings. |

## How every feature is reached (first tier that fits)

1. **Menus**, generically: `NSApp.mainMenu` walked after validation, items fired through `NSApp.sendAction` to the
   target found on the window's responder chain (works while AirSCP isn't the active app). A disabled item is refused
   with its reason (the item's tooltip while disabled). `context > …` reaches a pane's or the Transfers panel's context
   menu for the selected rows.
2. **Controls** through the in-process accessibility tree: found by `.accessibilityIdentifier` (e.g.
   `hostEditor.hostname`), label, title or placeholder; pressed with `accessibilityPerformPress()`, set with
   `setAccessibilityValue`. Pop-ups and segmented controls are chosen directly. Lists of up to 200 cells are walked
   into `elements`; file panes, processes and transfers are selected from their models.
3. **Events** for keys, typing and clicks (`NSApp.sendEvent` to the window), and for the Windows desktop (`target: rdp`,
   typed at 15 ms per character, the desktop given the focus only for that request).
4. **Purpose-built verbs** where no control fits: `drop` (what a drag does, including file promises to a Finder
   folder), `select`, `sort`, `focus`, `go` and `open` (a folder by its path, a row by its name: `FilePane.open` and
   `openItems`, so the pane moves where the user sees it, and the reply carries the listing or a plain error instead
   of an error sheet), and `wait` (polling conditions: connected, sheet, listed, transfers_done, rdp_drawn, found,
   compared…), which stops early when a sheet appears. Agents never need coordinates outside the Windows desktop.

Open and Save panels are drawn by another process and can't be driven: a request that opens one carries `file=` /
`files=`, which `Panels.run` uses instead of showing it (the reply's `panelFolder` says where it would have opened).
Quick Look is refused (its panel can't be hidden from another app's actions).

## Screenshots

`composite(window:)` draws the window's frame and content, its sheets and the panels or popovers over it into a bitmap
at scale 1 or 2, in the window's appearance, as the key window: behind other apps or with the screen locked, AppKit's
key and main appearance is lent to the windows for the drawing only (else grey window buttons, dim sidebar text, grey
selections and tabs). Things the window server draws, not the views, need care:
- backdrops (blur, scroll-edge pockets, Liquid Glass platters) are hidden while drawing (they'd come out white); the
  window background shows instead, and a popover gets a plain background;
- vibrant layers (the sidebar's text and symbols) are drawn through their own colour matrix (they'd come out black).
  The sidebar's coloured parts (chips, status dots, the selected row's pill) are drawing groups of their own, not
  vibrant, so they come out as the screen shows them;
- the Remote Desktop is drawn from its frame buffer (an IOSurface layer that views can't render);
- Open/Save panels are a labelled placeholder; menus never appear.
Click coordinates are the screenshot's points at scale 1 from the window's top left. The Windows desktop has a
space of its own: `screenshot target=rdp` is its frame buffer at Windows' own pixel size, and `click target=rdp` (its
`wheel` too) sends those pixels to Windows as they are, without the view (Retina, a desktop scaled to fit with bars,
full screen in a window of its own). Window points that land on the desktop go through `desktopPoint(atWindowPoint:)`.
Every desktop click replies with a picture: 200 × 120 pixels around the point, zoomed 2×, a red cross on it, taken
after the pointer has rested there and before the button goes down (`clickPicture`). In 1.0.0 the rdp picture's
pixels were taken for window points: off by the sidebar, the bar and the Retina scale, most clicks missed the desktop
(measured on the test VM for 1.0.1).
Keys for the desktop go as AppKit key events to `RDPDesktopView`, except the Windows key ("win", "windows", "⊞",
"super" in a combo), which has no Mac key: its scancode (0x15B) is held around the rest of the combo.

## Security

Off until the user turns it on (Settings ▸ Allow AI agents to control AirSCP); `AIRSCP_AGENT=1` turns it on for a
throwaway instance. Same user only (0700 folder + token + uid check). No tool reads the Keychain; password fields read
as `•••(n)`; a password from a shell goes on stdin (`value=-`). AirSCP's confirmations stay in the way (Delete still
asks). Turning the setting off removes the socket and token at once; quitting removes them too.

**Changes wait for the person at the Mac** (Settings ▸ Ask before agents change things, on by default). Each tool
works out, where it acts, what it would change outside AirSCP's own windows (`AgentServer.ask`, worked out only while
the setting is on): a button that a question marks as destructive (`hasDestructiveAction`; Run passwd too, which
types into a Terminal tab that may be busy, and Close Tab, which ends a running command), a control in
`changingControls` (by id), a command in `changingCommands` (by selector, for menus, context menus, shortcuts and
buttons with that action; Delete, Disconnect and Quit only when they don't ask their own question, whose destructive
button asks then), one in `s3Commands` in a pane that shows S3 storage (Compress and Extract, which copy through this
Mac there, and Copy Presigned Link), keys and text for a Terminal tab (a snippet chosen in its Insert Snippet too, and the Insert of
History… and Insert Path…, `terminal.pickInsert`), keys, text and clicks for a Windows desktop, drops, opening a file
in its app, and a Save panel that would replace a file. Open Terminal Here's `cd` at an empty prompt goes to a folder
and doesn't ask; a busy shell gets a new tab instead, which doesn't either. The Certificate Manager's saves ask only that way, through the Save panel when they would
replace a file (New… never replaces one: it saves nothing then). `approve` shows `AgentQuestionPanel` (floating, on
every Space, not modal, Deny the default) for up to 45 s; Allow for 15 Minutes lets every change through until then.
What was allowed is worked out again before it happens: a selection that changed meanwhile fails the request. The
panel isn't one of the agents' windows (`appWindows`) and their screenshots leave it out; the setting itself is
refused to them. The replies (`AgentBridge.declined`, `noAnswer`) are in the guide's troubleshooting topic and the
tool descriptions. Tests, scripts and throwaway instances that nobody answers turn it off in airscp.json
(`testModel`, `agentWindow`, `LaunchedAirSCP`, `scripts/agent-session.sh`, `scripts/docs-screenshots.sh`,
`testenv/*smoke.sh`).

## Adding a control or feature

1. Give new controls a stable `.accessibilityIdentifier` (`area.name`) and a tooltip ([ux-copy.md](ux-copy.md)).
2. If agents need to read new state, add it to the snapshot section it belongs to (no new state just for agents:
   read the model the view already has).
3. Document it in `Resources/AgentGuide.md` (the right `## topic`). `AgentBridgeTests` fail if the guide names a tool,
   menu path or id that doesn't exist.
4. Test it through the agent server (`AgentTests`, in-process) and, for flows across processes, `AgentLabTests` or
   `scripts/agent-session.sh`.
5. A control or command that changes something outside AirSCP without a question of its own (deletes, runs, copies,
   disconnects…): its id in `AgentServer.changingControls`, or its selector in `changingCommands`, so that it waits
   for the person at the Mac. A button a question marks as destructive asks by itself.

## The App Store version

It has no private API: SwiftUI builds its accessibility nodes after AirSCP asks for its own windows through the
public accessibility API (`AXUIElementCopyAttributeValue` on its own pid, off the main thread), which works sandboxed and
without Accessibility permission; and screenshots draw a window behind other apps as inactive (no lent key
appearance). Its agent socket is in the container's `tmp`; `--mcp` and `--agent` run in the same container, so they
find it, and `--agent … --out` can write only there (`--out -` sends the image to standard output).

## Known limits

- A tunnel's switch is drawn off in screenshots even when on (`snapshot.workspace.tunnels` has the truth).
- While the Mac's screen is locked, full screen, window tiling and animated toggles wait until it is unlocked.
- The socket path must be short (unix socket limit ~104 bytes): a throwaway `AIRSCP_SUPPORT_DIR` belongs under `/tmp`.
- MCP protocol versions answered: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25 (else 2025-06-18).
