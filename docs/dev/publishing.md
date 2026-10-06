# Publishing to AI directories (launch checklist)

Where AirSCP is listed so that people and agents find it, and exactly how each listing is made. Checked on
2026-10-05; directories change, so open each one first and note anything different here. Record every submission
(URL, date, status) in the launch ledger. Do them after the repository is public, the v1.0.0 release exists (with
`airscp.mcpb`) and the docs site is live.

Shared facts for the forms:
- **Name** AirSCP · **Registry name** `io.github.kleash/airscp` · **Repository** https://github.com/kleash/airscp
- **Short description** (≤ 100 characters): "Drive AirSCP, the Mac app for SCP/SFTP file transfers, SSH servers and Windows
  Remote Desktop"
- **Longer**: a free, open-source Mac app for SSH servers and Windows desktops (two-pane SCP/SFTP browser, transfer
  queue, Synchronize, Find Files, Linux monitor, tunnels, jump hosts and proxies, built-in Remote Desktop) whose own
  MCP server lets agents drive it the way its user does; agents never see saved passwords.
- **Install**: `brew install --cask kleash/tap/airscp`; turn on AirSCP ▸ Settings ▸ Allow AI agents to control AirSCP
  (MCP); `claude mcp add airscp -- /Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp`.
- **Category**: developer tools / file systems / OS automation; **platform**: macOS only; **local** (stdio), no API key.
- **Logo**: `docs/assets/icon.png` (512×512; make a 400×400 copy with `sips -z 400 400` where asked).
- **Docs for agents**: https://kleash.github.io/airscp/llms.txt, `AGENTS.md`, `Resources/AgentGuide.md`.

## 1. Official MCP Registry (registry.modelcontextprotocol.io): automatic

release.yml's `mcp-registry` job publishes `server.json` with the release's `airscp.mcpb` URL and SHA-256 (package type
`mcpb`: the registry accepts GitHub release assets whose URL contains "mcp"), logging in with GitHub's OIDC token.
- Check: `curl -s "https://registry.modelcontextprotocol.io/v0.1/servers?search=io.github.kleash/airscp"`.
- By hand, if the job failed: put the SHA-256 from `airscp.mcpb.sha256` into `server.json` as `packages[0].fileSha256`,
  then `mcp-publisher login github` (device code in the browser, as kleash) and `mcp-publisher publish`
  (mcp-publisher: https://github.com/modelcontextprotocol/registry/releases).
- Validate without publishing: `curl -X POST -H 'Content-Type: application/json' --data @server.json
  https://registry.modelcontextprotocol.io/v0.1/validate` (it answered `{"valid":true}` for this file).

**PulseMCP** ingests the registry weekly (its own submission form is paused: "publish it to the Official MCP Registry").
**GitHub's MCP Registry** (github.com/mcp, which feeds VS Code's @mcp gallery) is curated: ask for onboarding in
https://github.com/github/github-mcp-server/discussions/1257 (a public comment: the user's yes first); after that, new
versions sync from the official registry.

## 2. Glama (glama.ai/mcp/servers)

1. Open https://glama.ai/mcp/servers ▸ **Add MCP Server** (log in with GitHub as kleash); give the repository URL, the
   name and the short description.
2. `glama.json` at the repository root lists kleash as maintainer; on the server's page choose **Claim** (log in with
   GitHub) to manage the listing. Glama doesn't need a Dockerfile for a listing; its automatic checks can't start a
   Mac app, which only lowers its score.
3. The listing's score badge is what awesome-mcp-servers entries show (next step).

## 3. awesome-mcp-servers (github.com/punkpeye/awesome-mcp-servers): pull request

Fork, branch, add one line in alphabetical order under **🖥️ Command Line** (where the SSH servers are), open a PR
titled "Add AirSCP". The list's format (language emoji left out: the legend has none for Swift):

```markdown
- [kleash/airscp](https://github.com/kleash/airscp) [![kleash/airscp MCP server](https://glama.ai/mcp/servers/kleash/airscp/badges/score.svg)](https://glama.ai/mcp/servers/kleash/airscp) 🏠 🍎 - Drive the AirSCP Mac app: SSH hosts, two-pane SCP/SFTP transfers, Synchronize, Find Files and Windows Remote Desktop, with the user's own confirmations.
```

(Use the badge URL Glama shows on the listing's page if it differs.) Agent-made PRs are accepted when the title ends
with 🤖🤖🤖 (their CONTRIBUTING.md). List on Glama first (step 2): the list's bot labels a PR without the Glama badge
`missing-glama`, and such PRs are rarely merged.

## 4. mcp.so

https://mcp.so/submit (log in), or the **Submit** issue on its GitHub. Public GitHub servers only: the repository URL,
then complete the draft (name, description, features, connection details: the install lines above); saving publishes it.

## 5. Smithery (smithery.ai)

A local server is published as its MCPB bundle with Smithery's CLI (a Smithery account; npm package `smithery`):

```sh
npx -y smithery@latest auth login                                   # OAuth in the browser
npx -y smithery@latest mcp publish ./airscp.mcpb -n kleash/airscp   # the airscp.mcpb from the release
```

Known issue ([arcadeai-labs/smithery-cli#806](https://github.com/arcadeai-labs/smithery-cli/issues/806), open on
2026-10-06): its publish wants an `inputSchema` per tool, which the MCPB manifest format forbids;
if it refuses the bundle, note it here and retry when fixed (the listing's quality score also stays low without
schemas).

## 6. Other MCP directories (web forms)

| Directory | How | Notes |
|---|---|---|
| mcpservers.org | https://mcpservers.org/submit: name, category (Development or File System), short description, repository URL, registry name `io.github.kleash/airscp`, contact email | Free plan: review within 2 weeks; skip the paid option |
| MCP Market (mcpmarket.com) | the site's **Submit** form | Thin details; repository URL and description |
| Cline MCP Marketplace | Don't submit: dropped by the owner (2026-10-06, PLAN.md) | |
| LobeHub MCP (lobehub.com/mcp) | Nothing to submit: it listed AirSCP by itself, https://lobehub.com/mcp/kleash-airscp (Unvalidated) | Claim it there (GitHub login) to manage it. It keeps its own copy of the README: after a README change, a person clicks **Refresh Metadata** there (a Cloudflare human check) |

## 7. Claude Code plugins and skills

- **The repo is its own marketplace** (already live once public): `/plugin marketplace add kleash/airscp`, then
  `/plugin install airscp@airscp`, or `/plugin install airscp --marketplace kleash/airscp` (Claude Code 2.1.275+).
  Check with `claude plugin validate --strict ./plugins/airscp` and `claude plugin validate .`.
- **Anthropic's directory** (claude.ai and Cowork, and Claude Code through account sync): the developer portal
  https://claude.ai/directory/manage ▸ **Submit new** ▸ **Plugin bundle**; repository `kleash/airscp`, plugin path
  `plugins/airscp`, branch `main`; **Validate**, fix anything blocking, answer the data-handling questions (it reads
  and stores nothing, sends nothing anywhere; it runs the AirSCP app installed on the Mac), contact email, submit. Needs a
  paid claude.ai plan and the GitHub account connected on claude.ai. Expect a reviewer hold ("MCP server command"
  runs the installed app, outside the plugin folder): that is fine. Approved plugins also appear in
  `anthropics/claude-plugins-community` (a mirror; no separate submission).
- **awesome-claude-code** (github.com/hesreallyhim/awesome-claude-code): its "Recommend a resource" issue form; the
  list wants these made by a person, so leave it to the maintainer.
- **Skill lists** (the `airscp` skill in `plugins/airscp/skills/airscp/`): a PR to VoltAgent/awesome-agent-skills and
  to travisvn/awesome-claude-skills, a few days after launch (VoltAgent asks for no brand-new skills). Skill sites
  such as skillsmp.com index public GitHub `SKILL.md` files by themselves.

## After submitting

Re-check each listing after a day and after three days (PLAN.md AC): live, correct description and links, install
lines work. A fresh agent with no context, told only "install and use AirSCP to list files on <host>", should get
there from the public pages alone; fix the docs or packaging for every stumble.
