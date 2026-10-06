#!/bin/bash
# For lab.yml on the self-hosted runner: links this Mac's lab files into the runner's checkout, so that its tests use
# what the maintainer's own checkout has: the lab key (testenv/.keys, built into the Docker lab's images), the Windows
# VM's credentials (testenv/.windows) and the ui tool with its Screen Recording grant (testenv/.uidriver).
# AIRSCP_LAB_HOME is that checkout, set in the runner's .env file (docs/dev/self-hosted-runner.md).
set -euo pipefail
cd "$(dirname "$0")"
home=${AIRSCP_LAB_HOME:?"isn't set: see docs/dev/self-hosted-runner.md"}
for dir in .keys .windows .uidriver; do
    [ -L "$dir" ] || rm -rf "$dir"
    if [ -e "$home/testenv/$dir" ]; then ln -sfn "$home/testenv/$dir" "$dir"; fi
done
[ -f .keys/id_lab ] || { echo "No lab key in $home/testenv/.keys: run testenv/up.sh there once." >&2; exit 1; }
echo "Using the lab files of $home"
