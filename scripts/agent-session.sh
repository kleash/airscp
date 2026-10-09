#!/bin/bash
# A scripted agent-control session, the one CI runs after ./build.sh (.github/workflows/ci.yml). A throwaway AirSCP
# (its own settings and ssh folders, agent control on) connects to a throwaway sshd on this Mac, trusts its key,
# uploads a folder through its sheet, renames and deletes a file through their questions, previews Synchronize,
# answers MCP, edits a file that changes on the server meanwhile, disconnects and reconnects from the emptied pane,
# and quits. Each step leaves its snapshot (JSON) and screenshots (light and dark) in the output folder; a failed step
# leaves what AirSCP showed instead (failed.png, failed.json) and stops the script.
#
#   scripts/agent-session.sh [output folder]     default: build/agent-session
#
# Needs build/AirSCP.app (./build.sh --native). Uses nothing of yours: no ~/.ssh, no ssh agent, no Keychain (a
# throwaway AirSCP never reads or writes it), no settings; everything lives in a temporary folder that goes at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

bin=$PWD/build/AirSCP.app/Contents/MacOS/AirSCP
[[ -x $bin ]] || { echo "No build/AirSCP.app: run ./build.sh --native first." >&2; exit 1; }
out=${1:-build/agent-session}
rm -rf "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)

# Short: AirSCP's sockets live in it, and a socket's path can't be long.
T=$(mktemp -d /tmp/airscp-session.XXXXXX)
T=$(cd "$T" && pwd -P)
export AIRSCP_SUPPORT_DIR=$T/support
app_pid="" sshd_pid=""
cleanup() {
    set +e
    if [[ -n $app_pid ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid"
        sleep 1
    fi
    # The connections a stopped AirSCP leaves (ssh -F <this folder>/ssh/config …), then the server.
    pkill -f "$T/ssh/config" 2>/dev/null
    [[ -n $sshd_pid ]] && kill "$sshd_pid" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

# MARK: A throwaway sshd: this user, its own host key, authorized_keys and home, on 127.0.0.1 only

mkdir -p "$T/server/home" "$T/ssh" "$T/support" "$T/mac/site/images"
chmod 700 "$T/ssh"
ssh-keygen -q -t ed25519 -N '' -C session-host -f "$T/server/host_key"
ssh-keygen -q -t ed25519 -N '' -C me@my-mac -f "$T/ssh/id_ed25519"
cp "$T/ssh/id_ed25519.pub" "$T/server/authorized_keys"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$T/server/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $T/server/host_key
AuthorizedKeysFile $T/server/authorized_keys
PidFile $T/server/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitUserRC no
PermitUserEnvironment no
SetEnv HOME=$T/server/home
Subsystem sftp internal-sftp -d $T/server/home
EOF
/usr/sbin/sshd -D -f "$T/server/sshd_config" -E "$out/sshd.log" &
sshd_pid=$!
for _ in $(seq 1 50); do grep -q 'Server listening' "$out/sshd.log" 2>/dev/null && break; sleep 0.2; done
grep -q 'Server listening' "$out/sshd.log" || { cat "$out/sshd.log" >&2; echo "The throwaway sshd didn't start." >&2; exit 1; }

# ssh's own folder for this AirSCP: its own known_hosts, no agent.
printf 'UserKnownHostsFile %s/ssh/known_hosts\nIdentityAgent none\nIdentityFile none\n' "$T" > "$T/ssh/config"

# Something to upload, and the host.
printf '<!doctype html><title>Example</title><h1>Hello</h1>\n' > "$T/mac/site/index.html"
printf 'body { font-family: system-ui; }\n' > "$T/mac/site/site.css"
head -c 40000 /dev/urandom > "$T/mac/site/images/photo.jpg"
cat > "$T/support/airscp.json" <<EOF
{
  "hosts": [
    {"id": "5E5510A1-0000-4000-8000-000000000000", "label": "test-server", "hostname": "127.0.0.1", "port": $port,
     "username": "$(id -un)", "auth": "keyFile", "keyFile": "$T/ssh/id_ed25519", "autoReconnect": false,
     "lastLocalDir": "$T/mac"}
  ],
  "settings": {"appearance": "light", "welcomeShown": true, "agentControl": true}
}
EOF

# MARK: Driving AirSCP

AIRSCP_SSH_DIR=$T/ssh AIRSCP_AGENT=1 "$bin" > "$out/app.log" 2>&1 &
app_pid=$!

log=$out/agent.log
# One agent tool call. A failure stops the script with what AirSCP showed, so a wait that ran out says why.
a() {
    echo "+ $*" >> "$log"
    if ! "$bin" --agent "$@" >> "$log" 2>&1; then
        echo "Failed: $*" >&2
        tail -n 5 "$log" >&2
        "$bin" --agent snapshot > "$out/failed.json" 2>&1 || true
        "$bin" --agent screenshot --out "$out/failed.png" > /dev/null 2>&1 || true
        echo "What AirSCP showed: failed.png and failed.json in $out" >&2
        exit 1
    fi
}
snapshot() {  # snapshot <name> [snapshot arguments]
    local name=$1
    shift
    "$bin" --agent snapshot "$@" > "$out/$name.json"
}
appearance() { a set id=settings.appearance value="$1" in=window:Settings; sleep 0.6; }
shot() {  # shot <name> [screenshot arguments]: <name>-light.png and <name>-dark.png
    local name=$1
    shift
    a screenshot scale=2 "$@" --out "$out/$name-light.png"
    appearance Dark
    a screenshot scale=2 "$@" --out "$out/$name-dark.png"
    appearance Light
}

for _ in $(seq 1 60); do "$bin" --agent snapshot include='[]' > /dev/null 2>&1 && break; sleep 0.5; done
a snapshot include='[]'
a menu path='AirSCP > Settings…'
a menu path='Window > AirSCP'
snapshot 01-start
shot 01-start

# Connect: the new server's key is asked about first.
a select pane=sidebar names='["test-server"]'
a menu path='Host > Connect'
a wait until=sheet text=Trust timeout=30
shot 02-trust target=sheet
a press title=Trust
a wait until=connected host=test-server timeout=30
a wait until=listed pane=right timeout=30

# A folder upload, through its sheet.
a drop files="[\"$T/mac/site\"]" pane=right
a wait until=sheet text=Upload timeout=30
a press title=Upload
a wait until=transfers_done timeout=60
a wait until=listed pane=right text=site timeout=30
snapshot 03-uploaded include='["panes", "transfers"]'
shot 03-uploaded

# Rename and delete in it, through their questions.
a select pane=right names='["site"]'
a menu path='Go > Open Selection'
a wait until=listed pane=right path="$T/server/home/site" timeout=30
a select pane=right names='["index.html"]'
a menu path='File > Rename…'
a wait until=sheet timeout=20
a set id=prompt.name value=home.html
a press title=Rename
a wait until=no_sheet timeout=20
a wait until=listed pane=right text=home.html timeout=30
a select pane=right names='["home.html"]'
a menu path='File > Delete…'
a wait until=sheet text=Delete timeout=20
shot 04-delete target=sheet
a press title=Delete
a wait until=no_sheet timeout=20

# Synchronize's preview of the Mac folder against the server's: the server lacks index.html now.
a select pane=left names='["site"]'
a menu path='Go > Open Selection'
a wait until=listed pane=left path="$T/mac/site" timeout=30
a focus pane=right
a menu path='File > Synchronize…'
a wait until=compared timeout=60
snapshot 05-synchronize include='["sync"]'
shot 05-synchronize target=sheet
a press title=Cancel
a wait until=no_sheet timeout=20

# MCP, as an MCP client sees it.
printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"snapshot","arguments":{"include":["sidebar"]}}}' \
    | "$bin" --mcp > "$out/06-mcp.jsonl"
if ! grep -q '"name":"snapshot"' "$out/06-mcp.jsonl" || ! grep -q 'test-server' "$out/06-mcp.jsonl"; then
    echo "MCP didn't answer as expected: $out/06-mcp.jsonl" >&2
    exit 1
fi

snapshot 07-log include='["log"]' log=50

# Edit a file that someone else saves on the server meanwhile: Save asks first, and shows their version beside it.
a select pane=right names='["site.css"]'
a menu path='File > Edit in AirSCP'
a wait until=text text='site.css — test-server' timeout=30
printf 'body { color: teal; }\n' > "$T/server/home/site/site.css"
a set id=editor.text value='body { color: navy; }' in=window:site.css
a press title=Save in=window:site.css
a wait until=sheet text='changed on the server' timeout=30
shot 08-changed-on-the-server target=window:site.css
a press title='Show Server Version' in=window:site.css
a wait until=text text='site.css on the server' timeout=30
snapshot 09-server-version include='["elements"]' in='window:site.css on the server'
shot 09-server-version target='window:site.css on the server'
grep -q 'color: teal' "$out/09-server-version.json" || { echo "The server's version isn't shown: $out/09-server-version.json" >&2; exit 1; }
a press title=Save in=window:site.css
for _ in $(seq 1 60); do grep -q navy "$T/server/home/site/site.css" && break; sleep 0.5; done
grep -q navy "$T/server/home/site/site.css" || { echo "Save didn't replace the server's version." >&2; exit 1; }
a menu path='File > Close' in=window:site.css

a menu path='Host > Disconnect'
a wait until=disconnected host=test-server timeout=30
# Disconnected, the server pane shows no rows (they'd be stale) and offers Reconnect, which lists that folder again.
snapshot 10-disconnected include='["panes"]'
shot 10-disconnected
a press id=right.reconnect
a wait until=listed pane=right path="$T/server/home/site" text=site.css timeout=30
a menu path='Host > Disconnect'
a wait until=disconnected host=test-server timeout=30
a menu path='AirSCP > Quit AirSCP'
for _ in $(seq 1 20); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$app_pid" 2>/dev/null; then echo "AirSCP didn't quit." >&2; exit 1; fi
app_pid=""
echo "Agent session passed: $(find "$out" -type f | wc -l | tr -d ' ') files in $out"
