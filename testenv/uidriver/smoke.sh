#!/bin/bash
# Real-screen checks: what agent control can't show, on the Mac's real screen with the ui tool (README.md here). A
# throwaway AirSCP connects to the Docker lab's target; then AirSCP's real menu bar, Quick Look, an Open panel and dark
# mode, each with a real screenshot. lab.yml's "screen" job runs it; it works by hand too. It types no keys: menus and
# buttons are pressed through Accessibility, and AirSCP is told the rest through agent control.
#
#   testenv/uidriver/smoke.sh [output folder]     default: build/screen-smoke
#
# Needs an unlocked screen that nobody is using, testenv/.uidriver (testenv/uidriver/build.sh) with Accessibility for
# the app this runs in and Screen Recording for "Porter Screenshot", the Docker lab (testenv/up.sh) and build/AirSCP.app.
set -euo pipefail
cd "$(dirname "$0")/../.."

ui=$PWD/testenv/.uidriver/ui
bin=$PWD/build/AirSCP.app/Contents/MacOS/AirSCP
out=${1:-build/screen-smoke}
rm -rf "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)
[[ -x $bin ]] || { echo "No build/AirSCP.app: run ./build.sh --native first." >&2; exit 1; }
[[ -x $ui ]] || { echo "No testenv/.uidriver/ui: run testenv/uidriver/build.sh (and see README.md there)." >&2; exit 1; }
if [[ ! -f testenv/.keys/id_lab ]] || ! nc -z -G 3 127.0.0.1 42201 2>/dev/null; then
    echo "The Docker lab isn't up: run testenv/up.sh." >&2
    exit 1
fi
if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q true; then
    echo "The screen is locked: unlock it (and leave the Mac alone) to run the real-screen checks." >&2
    exit 1
fi

T=$(mktemp -d /tmp/airscp-screen.XXXXXX)
T=$(cd "$T" && pwd -P)
export AIRSCP_SUPPORT_DIR=$T/support
# A throwaway AirSCP leaves AirSCP's defaults alone, but a real Open panel saves its folder and size there: the user's
# come back at the end.
domain=com.kleash.airscp
defaults export "$domain" "$T/defaults.plist" 2>/dev/null || rm -f "$T/defaults.plist"
pid=""
cleanup() {
    set +e
    [[ -n $pid ]] && kill "$pid" 2>/dev/null && sleep 1
    pkill -f "$T/ssh/config" 2>/dev/null
    if [[ -f $T/defaults.plist ]]; then defaults import "$domain" "$T/defaults.plist"
    else defaults delete "$domain" > /dev/null 2>&1; fi
    rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/support" "$T/ssh" "$T/mac"
chmod 700 "$T/ssh"
cp testenv/.keys/id_lab "$T/ssh/id_lab"
chmod 600 "$T/ssh/id_lab"
printf 'UserKnownHostsFile %s/ssh/known_hosts\nIdentityAgent none\nIdentityFile none\n' "$T" > "$T/ssh/config"
printf 'Notes for the real-screen check.\n' > "$T/mac/notes.txt"
cat > "$T/support/airscp.json" <<EOF
{"hosts": [{"id": "5C2EE000-0000-4000-8000-000000000000", "label": "lab target", "hostname": "127.0.0.1", "port": 42201,
  "username": "dev", "auth": "keyFile", "keyFile": "$T/ssh/id_lab", "hostKeyCheck": "acceptNew", "autoReconnect": false,
  "lastLocalDir": "$T/mac"}],
 "settings": {"appearance": "light", "welcomeShown": true, "agentControl": true}}
EOF
AIRSCP_SSH_DIR=$T/ssh AIRSCP_AGENT=1 "$bin" > "$out/app.log" 2>&1 &
pid=$!

log=$out/steps.log
failed() {  # what was on the real screen and in AirSCP when a step failed
    echo "Failed: $1" >&2
    "$ui" shot "$out/failed.png" > /dev/null 2>&1 || true
    "$bin" --agent snapshot include='["windows", "sheets"]' > "$out/failed.json" 2>&1 || true
    echo "What the screen showed: $out/failed.png (AirSCP's state: failed.json)" >&2
    exit 1
}
a() { echo "+ agent $*" >> "$log"; "$bin" --agent "$@" >> "$log" 2>&1 || failed "agent $*"; }
u() { echo "+ ui $*" >> "$log"; "$ui" "$@" >> "$log" 2>&1 || failed "ui $*"; }
shot() { sleep 0.8; u shot "$out/$1.png"; echo "  $1.png"; }
until_window() {  # until_window <text> <present|gone>: one of AirSCP's windows has (or no longer has) the text
    for _ in $(seq 1 20); do
        if "$ui" windows "$pid" 2>/dev/null | grep -q "$1"; then [[ $2 == present ]] && return 0
        else [[ $2 == gone ]] && return 0; fi
        sleep 0.5
    done
    if [[ $2 == present ]]; then failed "no window showing $1 appeared"; else failed "the window showing $1 didn't close"; fi
}
menu_has() { "$bin" --agent snapshot include='["menus"]' | grep -q "$1" || failed "the menu bar has no $1"; }

for _ in $(seq 1 60); do "$bin" --agent snapshot include='[]' > /dev/null 2>&1 && break; sleep 0.5; done
a select pane=sidebar names='["lab target"]'
a menu path='Host > Connect'
a wait until=connected host='lab target' timeout=30
a wait until=listed pane=right timeout=30
u activate "$pid"
echo "Real screenshots:"
shot 01-window

# The real menu bar, through Accessibility.
u menu "$pid" "View>Show Command Log"
menu_has 'View > Hide Command Log'
shot 02-command-log
u menu "$pid" "View>Hide Command Log"

# Quick Look, which agents can't open.
a select pane=left names='["notes.txt"]'
u menu "$pid" "File>Quick Look"
until_window notes.txt present
shot 03-quick-look
u menu "$pid" "File>Quick Look"
until_window notes.txt gone

# An Open panel (another process draws it), then Cancel.
u menu "$pid" "File>Import Hosts…"
sleep 2
shot 04-open-panel
a press title=Cancel
a wait until=no_sheet timeout=10

# Dark mode on the real screen.
a menu path='AirSCP > Settings…'
a set id=settings.appearance value=Dark in=window:Settings
a menu path='Window > AirSCP'
u activate "$pid"
shot 05-dark
a set id=settings.appearance value=Light in=window:Settings

a menu path='Host > Disconnect'
a menu path='AirSCP > Quit AirSCP'
for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
pid=""
echo "Real-screen checks passed: the pictures are in $out"
