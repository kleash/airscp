---
name: airscp-dev
description: The AirSCP development loop. On a Mac - build, test and run the gates. In a cloud session (Linux, no macOS) - push a branch, follow GitHub Actions CI with gh, read the failed logs and look at the agent-control screenshots and snapshots it uploads, fix, then open a PR; and trigger the maintainer's self-hosted lab runner for the Docker lab, Windows VM and real-screen suites. Use when changing AirSCP's code, checking or debugging CI, reading CI artifacts, or running the lab suites.
---

# AirSCP development loop

Rules first: `CLAUDE.md` (smallest change, Command Line Tools only, every control explains itself, safety). Where
things are: `CLAUDE.md`'s architecture table and `docs/dev/`.

`uname` says where you are: **Darwin** → the local loop; **Linux** → the cloud loop (you can't build or run AirSCP:
GitHub's Macs do it for you).

## Local loop (a Mac)

```sh
swift build                 # 0 warnings
./test.sh                   # green twice before you call it done
./build.sh --native && scripts/agent-session.sh   # the app, and the scripted agent-control session
```

When the change can affect them, also `AIRSCP_DOCKER=1 ./test.sh` (the Docker lab; `--filter AgentLabTests` is the
agent-control end-to-end test) and the Windows VM suite (see `CLAUDE.md`). Drive a throwaway AirSCP to see a change:
`testenv/AGENT.md`. Never wait blind: after ~20–30 s without change, snapshot + screenshot and answer the open sheet.

## Cloud loop (push → CI → read → fix → PR)

1. Work on a branch: `git switch -c fix/<topic>`, edit, commit, `git push -u origin HEAD`.
2. Find the run and follow it (a cold run builds FreeRDP first, so allow ~30–40 min; later runs reuse the cache):
   ```sh
   gh run list --branch "$(git branch --show-current)" --workflow CI --limit 1
   gh run watch <run-id> --exit-status
   ```
   If it seems stuck, `gh run view <run-id>` shows the step it is on; don't just wait.
3. When it fails, the step's name says what broke:
   - **Versions agree** / **Agent-readable docs**: a version file differs from `VERSION`, or run `scripts/llms.sh`
     and commit `docs/llms*.txt`.
   - **swift build (no warnings)**: any `warning:` fails it. **Tests**: `./test.sh` (Swift Testing).
   - **App** / **Agent-control session**: `./build.sh --native` or `scripts/agent-session.sh`.
   ```sh
   gh run view <run-id> --log-failed | tail -n 200
   gh run view <run-id> --log-failed | grep -E '✘|Expectation failed|error:|Failed:' | head -n 50
   ```
4. Look at what the app did: the **agent-session** artifact (also uploaded when the run fails).
   ```sh
   gh run download <run-id> -n agent-session -D /tmp/agent-session
   ```
   - `NN-step.json`: the snapshot after each step (hosts, panes, transfers, sheets; `05-synchronize.json` the plan).
   - `NN-step-light.png`, `NN-step-dark.png`: AirSCP's own screenshots, light and dark. Open them with the Read tool
     and look: a UI change must look right in both.
   - `agent.log`: every agent call (`+ …`) and its reply; `app.log`, `sshd.log`; `06-mcp.jsonl`: the MCP replies.
   - `failed.png` + `failed.json`: what AirSCP showed when a step failed (usually an unanswered sheet or a wait that
     ran out).
5. Fix, push, repeat. A test that failed under the suite and passed when ci.yml ran it again alone (its warning
   names it) is a timing bug in the test: make it wait on a condition (docs/dev/regression-history.md).
6. Green: `gh pr create` with what changed, why, and how it was checked (CI run, screenshots looked at); then
   `gh pr checks --watch`.

## The maintainer's Mac: lab, VM, real screen

CI can't run the Docker lab (no Docker on GitHub's Macs), the Windows VM (Remote Desktop) or real-screen checks
(menus, Quick Look, Open panels, real appearance). The self-hosted runner on the maintainer's Mac does, only when
the repository owner starts it:

```sh
gh workflow run lab.yml -r <branch> -f suite=all        # or docker, windows, screen
gh run list --workflow lab.yml --limit 1
gh run watch <run-id> --exit-status
gh run view <run-id>                                    # each job's summary (test totals, failures)
gh run download <run-id> -n screen-smoke -D /tmp/screen-smoke   # real screenshots (failed.png on failure)
```

It needs the Mac on with the runner running, the Docker lab and the Windows VM up, and for `screen` an unlocked screen
nobody is using (`docs/dev/self-hosted-runner.md`). If the run doesn't start within a few minutes, the runner is
offline: say so instead of waiting.

## Before you finish

- The docs page and `Resources/AgentGuide.md` match the change; `scripts/llms.sh` ran.
- New UI has tooltips and captions (the help tests check), and you looked at both screenshots.
- Commit messages are imperative, with no attribution trailers.
