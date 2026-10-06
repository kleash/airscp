# Notes for people (and agents) who work on AirSCP

Not part of AirSCP Help: `docs/_config.yml` leaves this folder out of the site. Start with `CLAUDE.md` at the
repository root (rules, architecture table, commands, the CI loop).

| File | What's in it |
|---|---|
| [architecture.md](architecture.md) | How AirSCP works inside and why: processes, SSH, transfers, Remote Desktop, data, tests |
| [feature-map.md](feature-map.md) | Every feature → its code → its tests; measured speeds |
| [agent-control.md](agent-control.md) | The MCP server and agent tools: pieces, how features are reached, screenshots, security |
| [ux-copy.md](ux-copy.md) | How the app explains itself: tooltip, caption, empty-state and error rules |
| [regression-history.md](regression-history.md) | What broke before v1 and what it taught; flaky tests; the Windows VM's quirks |
| [release.md](release.md) | Making a release: signing, notarization, the cask, the MCP Registry, checks; the security scans, SBOM and badges |
| [publishing.md](publishing.md) | Listing AirSCP in AI directories (MCP Registry, Glama, Smithery, plugin directories…) |
| [self-hosted-runner.md](self-hosted-runner.md) | The maintainer's Mac as a runner for the lab, VM and real-screen suites |

The plan of record is `PLAN.md`; the user-facing docs are the rest of `docs/`.
