# The self-hosted runner on the maintainer's Mac

`.github/workflows/lab.yml` runs what GitHub's Macs can't: the Docker lab suite, the Windows VM's Remote Desktop
suite and the real-screen checks (`testenv/uidriver/smoke.sh`). It runs on a self-hosted runner on the maintainer's
Mac, label `porter-mac-lab`, and only when the repository owner starts it (Actions ▸ Lab ▸ Run workflow, or
`gh workflow run lab.yml -r <branch> -f suite=all|docker|windows|screen`). It never runs for pull requests or forks.

## Why it is safe on a public repository

- lab.yml has only `workflow_dispatch`, and every job also requires `github.actor == github.repository_owner` and
  `github.repository == 'kleash/airscp'`. Only people with write access can dispatch a workflow at all, and fork pull
  requests can't.
- No other workflow uses the label (ci.yml and release.yml run on GitHub's `macos-26`), so the runner never picks up
  anything else.
- Repository settings to keep: Settings ▸ Actions ▸ General ▸ Fork pull request workflows from outside collaborators:
  **Require approval for all outside collaborators**. Register the runner on this repository only (not an
  organisation).
- The runner is idle (a long poll, no CPU) unless a job comes. Stop it with Ctrl-C when it isn't wanted.

## Setup (once, after the repository is public)

1. Prerequisites on the Mac: the Command Line Tools; Docker Desktop with the lab built once (`testenv/up.sh` in the
   maintainer's checkout, which also makes the lab key); the Windows VM (`testenv/windows/README.md`); the `ui` tool
   (`testenv/uidriver/build.sh`) with Accessibility for Terminal and Screen Recording for "Porter Screenshot".
2. Register the runner (macOS, ARM64; the newest runner version from https://github.com/actions/runner/releases):
   ```sh
   mkdir ~/actions-runner && cd ~/actions-runner
   curl -fLO https://github.com/actions/runner/releases/download/v<version>/actions-runner-osx-arm64-<version>.tar.gz
   echo "<its SHA-256 from the release notes>  actions-runner-osx-arm64-<version>.tar.gz" | shasum -a 256 -c -
   tar xzf actions-runner-osx-arm64-<version>.tar.gz
   ./config.sh --url https://github.com/kleash/airscp --labels porter-mac-lab --name airscp-mac-lab --unattended \
       --token "$(gh api -X POST repos/kleash/airscp/actions/runners/registration-token --jq .token)"
   ```
3. Tell its jobs where the maintainer's checkout is (they link its lab key, VM credentials and `ui` tool, which are
   gitignored and tied to that checkout: `testenv/lab-files.sh`):
   ```sh
   echo "AIRSCP_LAB_HOME=/path/to/your/airscp/checkout" >> ~/actions-runner/.env
   ```
4. Start it **in a Terminal window**: `cd ~/actions-runner && ./run.sh`. Not as a launchd service (`svc.sh`): jobs
   started from Terminal inherit Terminal's Accessibility grant (the real-screen job needs it) and the user's access to
   Docker and UTM.

## What each job needs at run time

| Job | Needs | Runs |
|---|---|---|
| docker | Docker Desktop running | `./build.sh --native`, then `AIRSCP_DOCKER=1 ./test.sh` (starts or updates the lab with `testenv/up.sh`; includes `AgentLabTests`, agent control end to end) |
| windows | the VM up with RDP answering (`testenv/windows/windows-vm.sh status` says `rdp:open`) | `AIRSCP_WINDOWS=1 ./test.sh --filter RDPWindowsTests` |
| screen | the lab up, an **unlocked** screen nobody is using | `testenv/uidriver/smoke.sh`: real menu bar, Quick Look, an Open panel, dark mode, each with a real screenshot (artifact `screen-smoke`) |

Each job writes a short summary (test totals and failures) to the run page. The jobs run one after another (one
runner).

## When something goes wrong

- The run stays **Queued**: the runner isn't running (or the Mac is asleep). Start `./run.sh`.
- "AIRSCP_LAB_HOME isn't set": step 3.
- The screen job says the screen is locked: unlock the Mac and run `-f suite=screen` again. "no Accessibility
  permission": the runner wasn't started from Terminal, or Terminal lost the grant.
- The Windows job fails right after a long uptime: restart the VM gracefully (`utmctl stop --request`, then
  `testenv/windows/windows-vm.sh start`). Never toggle its network adapter (it crashes Windows).
- Remove the runner: Settings ▸ Actions ▸ Runners, or `./config.sh remove --token "$(gh api -X POST
  repos/kleash/airscp/actions/runners/remove-token --jq .token)"`.
