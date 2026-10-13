#!/bin/bash
# lab.yml's intents job: AirSCP's App Intents run for real, through Shortcuts and Spotlight, on
# a registered copy of the app and a throwaway AirSCP (testenv/AGENT.md) with one lab host.
#   testenv/intents-smoke.sh <outdir>     run the checks (the Docker lab must be up: testenv/up.sh)
#   testenv/intents-smoke.sh --setup      once per Mac: starts the same throwaway AirSCP and says which three shortcuts
#                                         to make in the Shortcuts app (it can't be done from a script)
# AIRSCP_APP picks the app (default build/AirSCP.app; lab.yml passes the xcode job's build). Nothing is left behind:
# the copy is unregistered and deleted, the throwaway quits (taking its Spotlight entries out).
set -euo pipefail
cd "$(dirname "$0")/.."
setup=false
if [ "${1:-}" = "--setup" ]; then setup=true; out=$(mktemp -d /tmp/intents-setup.XXXX); else out=${1:?usage: $0 <outdir> | --setup}; fi
mkdir -p "$out"
app=${AIRSCP_APP:-build/AirSCP.app}
[ -d "$app" ] || { echo "No app at $app: build it (./build.sh --native) or set AIRSCP_APP" >&2; exit 1; }
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

T=$(mktemp -d /tmp/intXXXX)  # short: the agent socket's path must stay under 104 bytes
copy=$T/Apps/AirSCP.app
bin=$copy/Contents/MacOS/AirSCP
cleanup() {
    AIRSCP_SUPPORT_DIR=$T/support "$bin" --agent menu path="AirSCP > Quit AirSCP" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$copy" >/dev/null || break; sleep 1; done
    pkill -f "$copy" 2>/dev/null || true
    "$lsregister" -u "$copy" 2>/dev/null || true
    rm -rf "$T"
}
trap cleanup EXIT

# The throwaway's ssh folder (never ~/.ssh) and its one host: the lab's target with the lab key, a tunnel to the
# target's own sshd, its key trusted as new (the same ids every run, so the shortcuts made once keep finding them).
mkdir -p "$T/ssh" "$T/support" "$T/Apps"
chmod 700 "$T/ssh"
printf 'UserKnownHostsFile %s/ssh/known_hosts\nIdentityAgent none\nIdentityFile none\n' "$T" > "$T/ssh/config"
tunnel_port=42290
cat > "$T/support/airscp.json" <<EOF
{"hosts":[{"id":"5A1F0000-0000-4000-8000-00000000A1F0","label":"smoke-target","hostname":"127.0.0.1","port":42201,
  "username":"dev","auth":"keyFile","keyFile":"$PWD/testenv/.keys/id_lab","hostKeyCheck":"acceptNew",
  "tunnels":[{"id":"5A1F0000-0000-4000-8000-00000000A1F1","kind":"local","listenPort":$tunnel_port,"targetHost":"localhost","targetPort":22}]}],
 "settings":{"welcomeShown":true,"askBeforeAgentChanges":false}}
EOF
ditto "$app" "$copy"
"$lsregister" -f "$copy"
open -n "$copy" --env AIRSCP_SUPPORT_DIR="$T/support" --env AIRSCP_SSH_DIR="$T/ssh" --env AIRSCP_AGENT=1 \
    --env AIRSCP_SPOTLIGHT=1
agent() { AIRSCP_SUPPORT_DIR=$T/support "$bin" --agent "$@"; }
for _ in $(seq 30); do agent snapshot >/dev/null 2>&1 && break; sleep 1; done
agent snapshot > "$out/started.json"

if $setup; then
    cat <<'EOF'
AirSCP is running with the host "smoke-target". In the Shortcuts app, make these three shortcuts (exact names):
  1. "AirSCP Smoke Find Files": action AirSCP ▸ Find Files; Host smoke-target, Folder /etc, Name Pattern hostname.
  2. "AirSCP Smoke Start Tunnel": action AirSCP ▸ Start Tunnel; Tunnel: the one of smoke-target.
  3. "AirSCP Smoke Stop Tunnel": action AirSCP ▸ Stop Tunnel; the same tunnel.
Then press Return here (AirSCP quits and the copy is removed).
EOF
    read -r _
    exit 0
fi

failed=0
check() { if "$@"; then echo "✔ $label"; else echo "✘ $label" >&2; failed=1; fi; }

# Spotlight: AirSCP indexed its hosts (CoreSpotlight's index-items in the throwaway's log; its items are private to
# the app, so mdfind can't search them).
pid=$(pgrep -f "$bin" | head -n 1)
label="Spotlight indexes the saved hosts"
check bash -c "for i in \$(seq 20); do log show --last 2m --predicate 'processID == $pid AND eventMessage CONTAINS \"index-items\"' 2>/dev/null | grep -q index-items && exit 0; sleep 1; done; exit 1"

# An sftp:// link: the saved host at the path, in the copy that was registered.
label="An sftp:// link opens the saved host at its folder"
check bash -c "open -a '$copy' 'sftp://dev@127.0.0.1:42201/etc' && for i in \$(seq 30); do
    AIRSCP_SUPPORT_DIR='$T/support' '$bin' --agent snapshot 2>/dev/null | grep -q '\"dir\" *: *\"/etc\"' && exit 0; sleep 1; done; exit 1"
# Shortcuts runs the intents.
for name in "AirSCP Smoke Find Files" "AirSCP Smoke Start Tunnel" "AirSCP Smoke Stop Tunnel"; do
    shortcuts list | grep -qx "$name" || {
        echo "✘ The shortcut \"$name\" isn't on this Mac: run testenv/intents-smoke.sh --setup once" >&2
        exit 1
    }
done
label="Find Files returns the server's paths"
check bash -c "shortcuts run 'AirSCP Smoke Find Files' --output-path '$out/find.txt' && grep -q /etc/hostname '$out/find.txt'"
label="Start Tunnel opens the tunnel's port on this Mac"
check bash -c "shortcuts run 'AirSCP Smoke Start Tunnel' && for i in \$(seq 30); do nc -z 127.0.0.1 $tunnel_port && exit 0; sleep 1; done; exit 1"
label="Stop Tunnel closes it"
check bash -c "shortcuts run 'AirSCP Smoke Stop Tunnel' && for i in \$(seq 30); do nc -z 127.0.0.1 $tunnel_port || exit 0; sleep 1; done; exit 1"
agent snapshot > "$out/end.json" 2>&1 || true
agent screenshot --out "$out/end.png" >/dev/null 2>&1 || true
exit $failed
