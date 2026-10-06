# Driving AirSCP from an AI agent

The guide is `Resources/AgentGuide.md` (in the app: `AirSCP.app/Contents/Resources/AgentGuide.md`); MCP clients get
it from AirSCP itself (`initialize` instructions and the `guide` tool). Setup: the README's "Agents".

For tests (not in the guide, which ships with the app):
- A throwaway AirSCP must never touch the real ~/.ssh: first `mkdir -p $T/ssh && chmod 700 $T/ssh && printf
  'UserKnownHostsFile %s/ssh/known_hosts\nIdentityAgent none\nIdentityFile none\n' "$T" > $T/ssh/config` (without it, trusting a host
  writes the user's ~/.ssh/known_hosts, and an ssh run by hand with it offers the user's keys; AirSCP itself adds
  `-o IdentityFile=none` to every command when AIRSCP_SSH_DIR is set, so a host without a key file of its own never
  offers ~/.ssh/id_*). Then: `open -n build/AirSCP.app --env AIRSCP_SUPPORT_DIR=$T/support --env AIRSCP_SSH_DIR=$T/ssh
  --env AIRSCP_AGENT=1` (AIRSCP_AGENT=1 turns agent control on without the setting; `$T/support/agent/sock` must stay
  under 104 bytes, a unix socket's limit, so keep `$T` short, e.g. under /tmp), and the bridge with the same
  folder: `claude mcp add airscp -e AIRSCP_SUPPORT_DIR=$T/support -- $PWD/build/AirSCP.app/Contents/MacOS/AirSCP --mcp`
  or `AIRSCP_SUPPORT_DIR=$T/support build/AirSCP.app/Contents/MacOS/AirSCP --agent snapshot`. One AirSCP per folder;
  instances with different folders keep their connections apart even with the same hosts (the ssh control sockets
  are named per folder).
- A throwaway instance (AIRSCP_SUPPORT_DIR set) never reads or writes the login Keychain: "Remember in Keychain" and
  saved passwords stay in its memory until it quits, so password hosts and Remote Desktop logins are fine there (no
  macOS question about the "AirSCP" item). Keys ▸ "Add to Agent" still adds the key to the user's ssh agent (without
  its passphrase in the Keychain): don't press it. AirSCP makes `$AIRSCP_SSH_DIR/config` with UserKnownHostsFile,
  IdentityAgent none and IdentityFile none itself when it is missing; the recipe above makes it first anyway.
- A throwaway instance shares AirSCP's defaults (com.kleash.airscp) with the user's AirSCP but leaves them alone: it
  neither reads nor saves window sizes, the sidebar's width or the panes' columns, so its windows open at their own
  sizes (main window 1100 × 700, Settings 600 points of its form, in the middle of the screen) and there is nothing to
  put back afterwards. Only a real Open or Save panel (the `ui` tool's checks) saves its folder and size there.
- An empty throwaway instance greets with the "Welcome to AirSCP" sheet: `press title=Start` first (one with hosts in
  its airscp.json doesn't).
- `--env AIRSCP_DEBUG=1` turns on the debug log from the start (PLAN.md AE): the instance writes it in its own settings
  folder, `$T/support/AirSCP-debug.log` (`snapshot` → debugLog.path), never in ~/Library/Logs.
- AirSCP was called Porter: every AIRSCP_* variable (AIRSCP_SUPPORT_DIR, AIRSCP_SSH_DIR, AIRSCP_AGENT, the tests'
  AIRSCP_DOCKER, AIRSCP_WINDOWS, …) still works under its PORTER_* name in this release; AIRSCP_ wins when both are
  set. A throwaway instance never takes over the user's Porter settings (only the real app's first start does). The
  Docker lab and the Windows VM keep their old names (porter-lab, user porter, "Porter Test Windows").
- Two-factor: host 127.0.0.1 port 42204 user dev with the lab key, then a verification code (`Lab.verificationCode()`,
  or the TOTP of GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ).
- The Docker lab chain (testenv/up.sh): proxy 127.0.0.1:42280 user porter (password porter-proxy), or openproxy
  127.0.0.1:42281 with no password; bastion = host "bastion" port 22 user jump (password porter-jump) with that proxy;
  target = host "target" (or "private", reachable only inside the lab) port 22 user dev, jump host bastion, key
  testenv/.keys/id_lab. Connect asks the bastion's password (and the proxy's, unless saved): one sheet each.
- The end-to-end test: `AIRSCP_DOCKER=1 swift test --filter AgentLabTests` (test.sh's flags); it launches
  build/AirSCP.app when that is newer than the sources. Without the lab: `scripts/agent-session.sh` (CI's scripted
  session against a throwaway sshd: snapshots and light/dark screenshots of each step in build/agent-session).
- Real-screen checks with the `ui` tool (menus, Quick Look, an Open panel, dark mode): `testenv/uidriver/smoke.sh`
  (an unlocked screen nobody is using).
