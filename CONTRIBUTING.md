# Contributing to AirSCP

Thank you for helping. Bug reports, fixes, docs and features are all welcome. For a bigger change, open an issue first
so we can agree on the approach before you write it.

## Build and test

You need a Mac with macOS 13.1 or later and the Command Line Tools (`xcode-select --install`); Xcode isn't needed.

```sh
./build.sh --native     # build/AirSCP.app for this Mac (./build.sh: universal); the first build compiles FreeRDP
./test.sh               # unit tests and tests against throwaway sshd servers (needs Swift 6)
scripts/agent-session.sh   # the scripted agent-control session CI runs, against your build
./install.sh            # copies build/AirSCP.app to ~/Applications (./uninstall.sh removes it)
```

The app builds with Swift 5.9 or later; the tests use Swift Testing (Swift 6).

Optional suites: `AIRSCP_DOCKER=1 ./test.sh` (the Docker lab, `testenv/`), `AIRSCP_WINDOWS=1 ./test.sh` (a Windows VM,
`testenv/windows/`). The tests never touch your `~/.ssh`, your ssh agent or your Keychain. To try the app without your
own data: `testenv/AGENT.md`.

## What a change needs

- **The smallest change that solves the problem.** No new layers, settings or abstractions unless the problem needs
  them.
- **No third-party Swift packages, and nothing from Homebrew** in the build or the app. FreeRDP and OpenSSL are built
  from pinned, checksummed sources by `scripts/build-freerdp.sh`; after changing a pin, run `scripts/sbom.sh`.
- **The app explains itself.** Every button, menu item, field and toggle gets a short tooltip (`.help` / `toolTip`)
  saying what it does; a disabled one says why; non-obvious fields get a caption, optional ones say "Optional". A test
  fails on any control without one. Plain words first, jargon in brackets.
- **Tests** for what you change, and `./test.sh` green. CI runs it on every pull request.
- **Docs**: the page in `docs/` for what users see (simple English, task-first), `Resources/AgentGuide.md` when agent
  control changes, then `scripts/llms.sh` to refresh `docs/llms.txt` and `docs/llms-full.txt`.
- No passwords, keys, real server names or personal paths in code, tests, docs or screenshots
  (`scripts/docs-screenshots.sh` makes the pictures with neutral demo data).

## Pull requests

Fork, branch, and open a pull request against `main`. Describe what changed and how you checked it. CI must be green.
Changes that need the Docker lab, the Windows VM or the real screen are run by a maintainer on their Mac
(`.github/workflows/lab.yml`). Commit messages are short and imperative ("Fix the upload sheet's default button").

Working with an AI coding agent? `CLAUDE.md` and `AGENTS.md` describe the codebase, the rules and the CI loop for it.

## Licence

AirSCP is Apache 2.0. By contributing you agree that your contribution is licensed the same way.
