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
| Snapshot | `Sources/AirSCP/AgentSnapshot.swift` | The state as JSON, and `AXNode`: the in-process accessibility tree of AppKit views and SwiftUI nodes (what VoiceOver reads), with secure values as `•••(n)`. Always `debugLog` (on, path): an agent reads the debug log's file itself (PLAN.md AE). |
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
Click coordinates are the screenshot's points at scale 1 from the window's top left.

## Security

Off until the user turns it on (Settings ▸ Allow AI agents to control AirSCP); `AIRSCP_AGENT=1` turns it on for a
throwaway instance. Same user only (0700 folder + token + uid check). No tool reads the Keychain; password fields read
as `•••(n)`; a password from a shell goes on stdin (`value=-`). AirSCP's confirmations stay in the way (Delete still
asks). Turning the setting off removes the socket and token at once; quitting removes them too.

## Adding a control or feature

1. Give new controls a stable `.accessibilityIdentifier` (`area.name`) and a tooltip (section U).
2. If agents need to read new state, add it to the snapshot section it belongs to (no new state just for agents:
   read the model the view already has).
3. Document it in `Resources/AgentGuide.md` (the right `## topic`). `AgentBridgeTests` fail if the guide names a tool,
   menu path or id that doesn't exist.
4. Test it through the agent server (`AgentTests`, in-process) and, for flows across processes, `AgentLabTests` or
   `scripts/agent-session.sh`.

## Known limits

- A tunnel's switch is drawn off in screenshots even when on (`snapshot.workspace.tunnels` has the truth).
- While the Mac's screen is locked, full screen, window tiling and animated toggles wait until it is unlocked.
- The socket path must be short (unix socket limit ~104 bytes): a throwaway `AIRSCP_SUPPORT_DIR` belongs under `/tmp`.
- MCP protocol versions answered: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25 (else 2025-06-18).
