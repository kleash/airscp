# AirSCP for AI agents

AirSCP is a Mac app for SSH servers, SCP/SFTP file transfers and Windows Remote Desktop. Agents drive it over MCP.

1. **Install** (macOS 13.1+): `brew install --cask kleash/tap/airscp`, then open AirSCP.
2. **Enable**: the user turns on **AirSCP ▸ Settings ▸ Allow AI agents to control AirSCP (MCP)**.
3. **Connect**: `claude mcp add airscp -- /Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp` (any MCP client: that
   command over stdio), or the Claude Code plugin: `/plugin marketplace add kleash/airscp`, `/plugin install airscp@airscp`.
4. **Drive**: `snapshot` → one action (`menu`, `press`, `set`, `select`, `drop`) → `wait` → `snapshot`; a reply with a
   `sheet` is AirSCP asking something (Trust, a password, Replace, Delete): answer it first.
5. **Learn**: the `guide` tool ([Resources/AgentGuide.md](Resources/AgentGuide.md)); every docs page:
   [docs/llms.txt](docs/llms.txt) (also at https://kleash.github.io/airscp/llms.txt).

Agents never see saved passwords, and AirSCP still asks before deleting or replacing anything.

## Working on this repository

Coding agents: read [CLAUDE.md](CLAUDE.md) first. It has the architecture, the build and test commands, the rules
(smallest change, Command Line Tools only, no third-party packages, every control explains itself), the safety rules
and the CI loop for sessions without a Mac.
