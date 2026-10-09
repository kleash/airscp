#!/bin/bash
# Makes the pictures of AirSCP Help (PLAN.md Y): docs/assets/shots/<name>-light.png and <name>-dark.png, always under
# the same names, so the docs never show an old AirSCP. A throwaway AirSCP (its own settings, ssh folder and demo
# data, nothing of yours) is driven through agent control, and its screenshot tool draws each window in light and in
# dark mode. The server is a demo container made from the Docker lab's target image (user dev in /home/dev), so the
# pictures show neutral names only: web-01.example.com, a small website, its logs.
#
#   scripts/docs-screenshots.sh     every picture; the Remote Desktop ones too when the Windows test VM answers
#
# Needs build/AirSCP.app (./build.sh --native makes it), Docker Desktop with the lab's images (testenv/up.sh builds
# them; the lab's containers aren't touched: the demo server is a container of its own, porter-docs-web, removed at
# the end) and python3 with Pillow (pip3 install pillow), which makes the PNGs small. AIRSCP_DOCS_WINDOWS=0 leaves out
# the Windows VM. A step that fails stops the script and says what AirSCP showed (build/docs-shot-failed.png).
set -euo pipefail
cd "$(dirname "$0")/.."

repo=$PWD
bin=$repo/build/AirSCP.app/Contents/MacOS/AirSCP
out=$repo/docs/assets/shots
docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker
port=42290

[[ -x $bin ]] || { echo "No build/AirSCP.app: run ./build.sh --native first." >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "python3 needs Pillow: pip3 install pillow" >&2; exit 1; }
"$docker" image inspect porter-lab-target >/dev/null 2>&1 || { echo "No lab image: run testenv/up.sh first." >&2; exit 1; }
[[ -f testenv/.keys/id_lab ]] || { echo "No lab key: run testenv/up.sh first." >&2; exit 1; }

# One fixed, short folder: the pictures show its path (so it stays the same from run to run), and AirSCP's sockets
# live in it (a socket's path can't be long).
T=/tmp/airscp-docs
# The throwaway AirSCP: the one whose environment names this folder (ps -E shows it).
instance() {
    ps -E -ww -x -o pid=,command= | awk -v d="AIRSCP_SUPPORT_DIR=$T/support" 'index($0, "/MacOS/AirSCP ") && index($0, d) { print $1 }'
}
stop() {
    local pid
    pid=$(instance)
    [[ -n $pid ]] || return 0
    for _ in 1 2 3; do "$bin" --agent key combo=escape >/dev/null 2>&1; done  # a sheet left open refuses Quit
    "$bin" --agent menu path='AirSCP > Quit AirSCP' >/dev/null 2>&1
    for _ in $(seq 1 10); do kill -0 $pid 2>/dev/null || return 0; sleep 1; done
    kill $pid 2>/dev/null
}
export AIRSCP_SUPPORT_DIR=$T/support
stop
"$docker" rm -f porter-docs-web >/dev/null 2>&1 || true
rm -rf /tmp/airscp-docs
mkdir -p "$T/raw" "$T/support" "$T/ssh" "$T/Shared with Windows"
chmod 700 "$T/ssh"
cleanup() {
    set +e
    stop
    "$docker" rm -f porter-docs-web >/dev/null 2>&1
    rm -rf /tmp/airscp-docs
}
trap cleanup EXIT

# MARK: Demo data

# Files with fixed dates, so the pictures stay the same from run to run.
file() {  # file <path> <YYYYMMDDhhmm> [text]
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "${3:-}" > "$1"
    touch -t "$2" "$1"
}
site() {  # a small website in $1, as of $2
    file "$1/index.html" "$2" '<!doctype html><title>Example Shop</title><h1>Welcome to Example Shop</h1>'
    file "$1/about.html" 202609211012 '<!doctype html><title>About us</title><h1>About us</h1>'
    file "$1/contact.html" 202609211014 '<!doctype html><title>Contact</title><p>hello@example.com</p>'
    file "$1/css/site.css" "$2" 'body { font-family: system-ui; margin: 2rem; }'
    file "$1/js/app.js" 202609211020 'document.title += " ✓";'
    file "$1/images/logo.svg" 202609150930 '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><circle cx="32" cy="32" r="30"/></svg>'
    head -c 48000 /dev/urandom > "$1/images/team.jpg"
    touch -t 202609150931 "$1/images/team.jpg" "$1/css" "$1/js" "$1/images" "$1"
}
mac=$T/Projects
site "$mac/website" 202610021630
file "$mac/website/blog.html" 202610021645 '<!doctype html><title>Blog</title><h1>News</h1>'
file "$mac/website/README.md" 202609150920 '# Example Shop website'
head -c 31000 /dev/urandom > "$mac/website/images/office.jpg"
mkdir -p "$mac/website/downloads"
head -c 210000 /dev/urandom > "$mac/website/downloads/price-list.pdf"
head -c 1400000 /dev/urandom > "$mac/website/downloads/catalogue.pdf"
touch -t 202610021640 "$mac/website/images/office.jpg" "$mac/website/images" "$mac/website/downloads/"* \
    "$mac/website/downloads" "$mac/website"
mkdir -p "$mac/media"
mkfile -n 150m "$mac/media/product-demo.mov"
mkfile -n 30m "$mac/media/brochure.pdf"
head -c 900000 /dev/urandom > "$mac/media/logo-pack.zip"
touch -t 202610011100 "$mac/media/"*
server=$T/server
site "$server/www" 202609281015
mkdir -p "$server/logs/archive" "$server/backups"
for day in 01 02 03; do
    for n in 1 2 3 4 5 6; do echo "203.0.113.$n - - [$day/Oct/2026:10:1$n:00 +0000] \"GET / HTTP/1.1\" 200 512"; done
done > "$server/logs/access.log"
touch -t 202610031011 "$server/logs/access.log"
file "$server/logs/error.log" 202610030812 '[error] File does not exist: /home/dev/www/favicon.ico'
file "$server/logs/archive/access-2026-09.log" 202609302359 '203.0.113.9 - - [30/Sep/2026:23:59:00 +0000] "GET / HTTP/1.1" 200 512'
head -c 2400000 /dev/urandom > "$server/backups/site-2026-09-28.tar.gz"
head -c 2300000 /dev/urandom > "$server/backups/site-2026-09-21.tar.gz"
head -c 830000 /dev/urandom > "$server/backups/db-2026-09-28.sql.gz"
touch -t 202609280300 "$server/backups/site-2026-09-28.tar.gz" "$server/backups/db-2026-09-28.sql.gz"
touch -t 202609210300 "$server/backups/site-2026-09-21.tar.gz"
file "$server/deploy.sh" 202609280950 $'#!/bin/sh\n# Copies the website into place.\necho "Deployed www at $(date)"'
chmod 755 "$server/deploy.sh"
file "$server/notes.txt" 202610011530 $'To do\n- Renew the certificate before 15 October\n- Ask Anna about the new team photo'
file "$server/.profile" 202609150900 '# ~/.profile'
touch -t 202610031011 "$server/logs" "$server/logs/archive" "$server/backups" "$server/www"

# MARK: The demo server

"$docker" run -d --rm --name porter-docs-web --hostname web-01 -p "127.0.0.1:$port:22" \
    --tmpfs /home/dev:rw,exec,uid=1000,gid=1000,mode=0755,size=400m \
    porter-lab-target /usr/sbin/sshd -D -e >/dev/null
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$server" -cf - . \
    | "$docker" exec -i -u dev porter-docs-web tar -xf - -C /home/dev --delay-directory-restore
"$docker" exec -d -u dev porter-docs-web python3 -m http.server 8080 --directory /home/dev/www

# ssh's own folder for this AirSCP: the lab key under a neutral name and comment, a known_hosts of its own, no agent,
# and the demo names, which all lead to the container.
cp testenv/.keys/id_lab "$T/ssh/id_ed25519"
chmod 600 "$T/ssh/id_ed25519"
ssh-keygen -q -c -C me@my-mac -f "$T/ssh/id_ed25519" >/dev/null
ssh-keygen -y -f "$T/ssh/id_ed25519" > "$T/ssh/id_ed25519.pub"
ssh-keygen -q -t rsa -b 3072 -N '' -C old-servers@my-mac -f "$T/ssh/id_rsa_legacy"
{
    printf 'UserKnownHostsFile %s/ssh/known_hosts\nIdentityAgent none\nIdentityFile none\n' "$T"
    for alias in web-01.example.com backup.example.com files.example.com; do
        printf '\nHost %s\n  HostName 127.0.0.1\n  Port %s\n  HostKeyAlias %s\n' "$alias" "$port" "$alias"
    done
    printf '\nHost old-server.example.com\n  HostName 127.0.0.1\n  Port 1\n'
    printf '\nHost bastion.example.com\n  HostName 127.0.0.1\n  Port 42203\n  HostKeyAlias bastion.example.com\n'
    printf '\nHost staging\n  HostName staging.example.com\n  User deploy\n\nHost build-box\n  HostName 10.0.4.20\n  User ci\n'
} > "$T/ssh/config"
for _ in $(seq 1 30); do ssh-keyscan -p "$port" 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done
# The other names' server keys are known already: only web-01 asks to be trusted.
ssh-keyscan -p "$port" -t ed25519 127.0.0.1 2>/dev/null \
    | awk '{ print "backup.example.com", $2, $3; print "files.example.com", $2, $3 }' > "$T/ssh/known_hosts"

# The Windows test VM, when it answers: Remote Desktop pictures with a real desktop, through the lab's bastion
# ("bastion" here), which reaches the VM (and AirSCP needs no Local Network permission for a tunnel on this Mac).
windows=""
if [[ ${AIRSCP_DOCS_WINDOWS:-1} != 0 && -f testenv/.windows/credentials ]] && nc -z -G 3 127.0.0.1 42203 2>/dev/null; then
    windows=$(testenv/windows/windows-vm.sh ip 2>/dev/null || true)
    if [[ -n $windows ]] && ! nc -z -G 3 "$windows" 3389 2>/dev/null; then windows=""; fi
    ssh-keyscan -p 42203 -t ed25519 127.0.0.1 2>/dev/null | awk '{ print "bastion.example.com", $2, $3 }' >> "$T/ssh/known_hosts"
fi

key=$T/ssh/id_ed25519
cat > "$T/support/airscp.json" <<EOF
{
  "groups": [
    {"id": "D0C51001-0000-4000-8000-000000000000", "name": "Production"},
    {"id": "D0C51002-0000-4000-8000-000000000000", "name": "Internal"}
  ],
  "proxies": [
    {"id": "D0C53001-0000-4000-8000-000000000000", "name": "Office proxy", "host": "proxy.example.com", "port": 3128, "username": "me"}
  ],
  "hosts": [
    {"id": "D0C52001-0000-4000-8000-000000000000", "label": "web-01", "hostname": "web-01.example.com", "username": "dev",
     "auth": "keyFile", "keyFile": "$key", "groupID": "D0C51001-0000-4000-8000-000000000000", "color": "green",
     "lastLocalDir": "$mac/website",
     "tunnels": [
       {"id": "D0C54001-0000-4000-8000-000000000000", "kind": "local", "listenPort": 18080, "targetHost": "localhost", "targetPort": 8080},
       {"id": "D0C54002-0000-4000-8000-000000000000", "kind": "local", "listenPort": 15432, "targetHost": "db-01.internal", "targetPort": 5432},
       {"id": "D0C54003-0000-4000-8000-000000000000", "kind": "dynamic", "listenPort": 1080, "targetHost": "localhost", "targetPort": 0}
     ]},
    {"id": "D0C52002-0000-4000-8000-000000000000", "label": "backup", "hostname": "backup.example.com", "username": "dev",
     "auth": "keyFile", "keyFile": "$key", "groupID": "D0C51001-0000-4000-8000-000000000000", "lastLocalDir": "$mac/website"},
    {"id": "D0C52003-0000-4000-8000-000000000000", "label": "bastion", "hostname": "bastion.example.com", "username": "jump",
     "auth": "keyFile", "keyFile": "$key", "groupID": "D0C51002-0000-4000-8000-000000000000"},
    {"id": "D0C52004-0000-4000-8000-000000000000", "label": "db-01", "hostname": "db-01.internal", "username": "dev",
     "jumpHostID": "D0C52003-0000-4000-8000-000000000000", "groupID": "D0C51002-0000-4000-8000-000000000000", "color": "blue"},
    {"id": "D0C52005-0000-4000-8000-000000000000", "label": "partner-sftp", "hostname": "sftp.partner.example", "username": "shop",
     "proxyID": "D0C53001-0000-4000-8000-000000000000", "groupID": "D0C51002-0000-4000-8000-000000000000"},
    {"id": "D0C52006-0000-4000-8000-000000000000", "label": "files", "hostname": "files.example.com", "username": "dev",
     "auth": "password", "lastLocalDir": "$mac/website"},
    {"id": "D0C52007-0000-4000-8000-000000000000", "label": "old-server", "hostname": "old-server.example.com", "username": "dev",
     "auth": "keyFile", "keyFile": "$key", "autoReconnect": false, "lastLocalDir": "$mac/website"}
  ],
  "rdpEntries": [
    {"id": "D0C55001-0000-4000-8000-000000000000", "label": "Office PC", "hostname": "${windows:-pc-01.example.com}",
     "viaHostID": "D0C52003-0000-4000-8000-000000000000",
     "sharedFolder": "$T/Shared with Windows"}
  ],
  "snippets": [
    {"id": "D0C56001-0000-4000-8000-000000000000", "name": "Disk space", "command": "df -h", "runInTerminal": false},
    {"id": "D0C56002-0000-4000-8000-000000000000", "name": "Last errors", "command": "tail -n 20 ~/logs/error.log", "runInTerminal": false},
    {"id": "D0C56003-0000-4000-8000-000000000000", "name": "Deploy the website", "command": "~/deploy.sh", "runInTerminal": false},
    {"id": "D0C56004-0000-4000-8000-000000000000", "name": "Restart the web server", "command": "sudo systemctl restart nginx",
     "runInTerminal": true}
  ],
  "settings": {"appearance": "light", "welcomeShown": true, "agentControl": true}
}
EOF

# MARK: Driving AirSCP

log=$T/agent.log
a() {  # one agent tool call; a failure stops the script with what AirSCP showed
    if ! "$bin" --agent "$@" >>"$log" 2>&1; then
        echo "Failed: $*" >&2
        tail -n 3 "$log" >&2
        "$bin" --agent snapshot include='["sheets","windows"]' >&2 || true
        "$bin" --agent screenshot --out "$repo/build/docs-shot-failed.png" >/dev/null 2>&1 \
            && echo "What AirSCP showed: build/docs-shot-failed.png" >&2
        exit 1
    fi
}
try() { "$bin" --agent "$@" >>"$log" 2>&1 || true; }  # a call that may fail (a field this AirSCP lacks)
sheet() { a wait until=sheet timeout=20 ${1:+text="$1"}; sleep 0.4; }  # SwiftUI's controls, a moment after the sheet
closed() { a wait until=no_sheet timeout=20; }
appearance() { a set id=settings.appearance value="$1" in=window:Settings; sleep 0.6; }
# The sidebar's agent indicator is lit for 5 s after every request (a snapshot too: asking AirSCP whether it is quiet
# would light it again), and a screenshot shows the window as the request found it: a picture of the main window (no
# target) waits until the indicator is quiet. Sheets and other windows have no indicator.
quiet() { [[ $* == *target=* ]] || sleep 5; }
shot() {  # shot <name> [screenshot arguments]: <name>-light.png and <name>-dark.png
    local name=$1
    shift
    appearance Light
    quiet "$@"
    a screenshot scale=2 "$@" --out "$T/raw/$name-light.png"
    appearance Dark
    quiet "$@"
    a screenshot scale=2 "$@" --out "$T/raw/$name-dark.png"
    appearance Light
    echo "  $name"
}
frame() {  # frame <window title or main> <id>: the control's x, y, width and height, in points from the window's top left
    "$bin" --agent snapshot include='["elements"]' $([[ $1 == main ]] || echo "in=window:$1") | python3 -c '
import json, sys
found = [e["frame"] for e in json.load(sys.stdin).get("elements", []) if e.get("id") == sys.argv[1]]
print(*found[0])' "$2"
}
crop() {  # crop <name> <x> <y> <width> <height>, in points from the top left
    python3 - "$T/raw/$1" "$2" "$3" "$4" "$5" <<'PY'
import sys
from PIL import Image
base, x, y, w, h = sys.argv[1], *(float(v) * 2 for v in sys.argv[2:])
for mode in ("light", "dark"):
    path = f"{base}-{mode}.png"
    image = Image.open(path)
    image.crop((int(x), int(y), int(min(x + w, image.width)), int(min(y + h, image.height)))).save(path)
PY
}

# A throwaway AirSCP leaves your window sizes alone: its windows open at their own sizes (the main window 1100 × 700,
# the sidebar 218 points wide), whatever yours are.
open -n -g build/AirSCP.app --env AIRSCP_SUPPORT_DIR="$T/support" --env AIRSCP_SSH_DIR="$T/ssh" --env AIRSCP_AGENT=1
for _ in $(seq 1 60); do "$bin" --agent snapshot include='["windows"]' >/dev/null 2>&1 && break; sleep 0.5; done
[[ -f $T/support/airscp.json.unreadable ]] && { echo "AirSCP couldn't read the demo airscp.json." >&2; exit 1; }
a menu path='AirSCP > Settings…'
a menu path='Window > Zoom' in=window:Settings  # the whole form (it opens 600 points tall and scrolls)
# AirSCP draws its windows as they look in use, also behind other apps or with the screen locked: no need to bring it
# to the front (agent control never does).
main() { a menu path='Window > AirSCP'; }  # the main window in front of AirSCP's others again
main
echo "Pictures:"

# MARK: Getting started

a menu path='Help > Welcome to AirSCP…'
sheet
shot welcome target=sheet
a press title=Start
closed
a menu path='Help > AirSCP Tips'
shot tips 'target=window:AirSCP Tips'
a menu path='File > Close' 'in=window:AirSCP Tips'
main

# MARK: Hosts, the sidebar and the host editor

shot sidebar
crop sidebar 0 0 218 700
a menu path='File > New Host…'
sheet
a set id=hostEditor.name value=app-02
a set id=hostEditor.hostname value=app-02.example.com
a set id=hostEditor.username value=deploy
a set id=hostEditor.login value=id_ed25519
a set id=hostEditor.group value=Production
shot host-editor target=sheet
a press title=Advanced
sleep 0.4
a set id=hostEditor.hostKey value='Trust new servers automatically'
a set id=hostEditor.options value=$'Compression=yes\nConnectTimeout=10'
sleep 1
shot host-editor-advanced target=sheet
a set id=hostEditor.hostKey value="Don't check (insecure)"
sleep 0.4
shot host-editor-insecure target=sheet
a press title=Cancel
closed
a select pane=sidebar names='["db-01"]'
a menu path='Host > Edit…'
sheet
shot host-editor-jump target=sheet
a press title=Cancel
closed
a menu path='Host > Proxies…'
sheet
a select in=sheet names='["Office proxy"]'
shot proxies target=sheet
a press title='Edit…'
a wait until=sheet text=proxyEditor timeout=10
sleep 0.4
shot proxy-editor target=sheet
a press title=Cancel
sleep 0.5
a press title=Done
closed
a menu path='File > Import from ~/.ssh/config…'
sheet
sleep 2  # ssh -G fills in each alias's user@host
shot import-ssh-config target=sheet
a press title=Cancel
closed

# MARK: Connecting

a select pane=sidebar names='["web-01"]'
a menu path='Host > Connect'
sheet Trust
shot trust-server target=sheet
a press title=Trust
a wait until=connected host=web-01 timeout=30
a wait until=listed pane=right timeout=30
a focus target=path pane=right
a type text=/home/dev/www
a key combo=return
a wait until=listed pane=right path=/home/dev/www timeout=20
a select pane=left names='["blog.html"]'
shot files
a select pane=sidebar names='["files"]'
a menu path='Host > Connect'
sheet Password
shot password-prompt target=sheet
a press title=Cancel
closed
a select pane=sidebar names='["old-server"]'
a menu path='Host > Connect'
sheet "Can't connect"
shot connect-failed target=sheet
# Its "Turn On Debug Logging and Try Again": the same failure, now with Show Debug Log and the sidebar's "Debug logging
# on" (Troubleshooting ▸ Turn on debug logs). Then off again, for the other pictures.
a press title='Turn On Debug Logging and Try Again'
sheet 'Show Debug Log'
shot debug-log
a press title=OK
closed
a set id=settings.debugLogging value=false in=window:Settings
a select pane=sidebar names='["web-01"]'
a wait until=listed pane=right timeout=20

# MARK: Files

a drop files="[\"$mac/website/downloads\"]" pane=right
sheet Upload
a set id=transfer.leaveOut value='*.psd, .DS_Store'
shot upload-folder target=sheet
a press title=Upload
closed
a wait until=transfers_done timeout=60
a drop files="[\"$mac/website/index.html\"]" pane=right
sheet 'already exists'
shot conflict target=sheet
a press title=Skip
closed
a focus pane=right
a menu path='File > Synchronize…'
sheet
a wait until=compared timeout=60
shot synchronize target=sheet
a press title=Cancel
closed
a menu path='Go > Home'
a wait until=listed pane=right path=/home/dev timeout=20
a focus pane=right
a menu path='File > Find Files…'
sheet
a set id=find.pattern value='*.log'
a press title=Find
a wait until=found timeout=30
shot find target=sheet
a press title=Done
closed
a select pane=right names='["deploy.sh"]'
a menu path='File > Get Info'
sheet
shot get-info target=sheet
a press title=Done
closed
a select pane=right names='["deploy.sh"]'
a menu path='File > Permissions…'
sheet
shot permissions target=sheet
a press title=Cancel
closed
a select pane=right names='["logs"]'
a menu path='File > Compress…'
sheet
shot compress target=sheet
a press title=Cancel
closed
a select pane=right names='["logs"]'
a menu path='File > Download as .tar.gz…'
sheet
shot download-archive target=sheet
a press title=Cancel
closed
a select pane=right names='["notes.txt"]'
a menu path='File > Delete…'
sheet
shot delete target=sheet
a press title=Cancel
closed
a focus pane=right
a menu path='File > New Folder…'
sheet
a set id=prompt.name value=drafts
shot new-folder target=sheet
a press title=Cancel
closed
a select pane=right names='["notes.txt"]'
a menu path='File > Edit in AirSCP'
a wait until=text text='Renew the certificate' timeout=20
sleep 0.5
shot editor 'target=window:notes.txt'
a menu path='File > Close' 'in=window:notes.txt'
main

# Two servers: backup in the left pane.
a select pane=sidebar names='["backup"]'
a menu path='Host > Connect'
a wait until=connected host=backup timeout=30
a select pane=sidebar names='["web-01"]'
a set id=left.source value=backup
a wait until=listed pane=left timeout=20
a focus target=path pane=left
a type text=/home/dev/backups
a key combo=return
a wait until=listed pane=left path=/home/dev/backups timeout=20
shot files-two-servers
a set id=left.source value='This Mac'
a wait until=listed pane=left timeout=20

# MARK: Transfers

# Copies checked as they arrive (Settings ▸ Verify transfers with SHA-256): set before the steps the agent-activity
# picture lists.
a set id=settings.verifyTransfers value=true in=window:Settings
a select pane=right names='["www"]'
a menu path='Go > Open Selection'
a wait until=listed pane=right path=/home/dev/www timeout=20
a set id=transfers.speedLimit value='5 MB/s'
a drop files="[\"$mac/media/logo-pack.zip\", \"$mac/media/product-demo.mov\", \"$mac/media/brochure.pdf\"]" pane=right
sleep 6
a select pane=left names='["index.html"]'
# Agent control: the sidebar's indicator, clicked, lists what this script (an agent) just did.
a press id=agent.indicator
sleep 0.6
a screenshot scale=2 --out "$T/raw/agent-activity-light.png"
appearance Dark
a screenshot scale=2 --out "$T/raw/agent-activity-dark.png"
appearance Light
a press id=agent.indicator
echo "  agent-activity"
crop agent-activity 0 236 640 464
# The queued upload waits, paused (Transfers ▸ right-click ▸ Pause).
a select pane=transfers names='["brochure.pdf"]'
a menu path='context > Pause' pane=transfers
a select pane=transfers none=true
# The README's first picture, and its Transfers panel (the same moment: one upload running, one paused, one verified).
shot main-window
for mode in light dark; do cp "$T/raw/main-window-$mode.png" "$T/raw/transfers-$mode.png"; done
crop transfers 218 "$(frame main transfers.speedLimit | awk '{ print $2 - 10 }')" 882 700
a set id=transfers.speedLimit value=Unlimited
a press id=transfers.resumeAll
a wait until=transfers_done timeout=120
a press id=transfers.clearFinished
a set id=settings.verifyTransfers value=false in=window:Settings

# MARK: Commands, tunnels, monitor

# The log scrolls to each new command, and the header's pulse strip runs one when a request (the light picture's
# screenshot, say) wakes it: the log opens afresh for each picture, at its top.
for mode in light dark; do
    appearance "$(tr '[:lower:]' '[:upper:]' <<<"${mode:0:1}")${mode:1}"
    a menu path='View > Show Command Log'
    quiet
    a screenshot scale=2 --out "$T/raw/command-log-$mode.png"
    a menu path='View > Hide Command Log'
done
appearance Light
echo "  command-log"
a menu path='Host > Run Command…'
sheet
a set id=runCommand.command value='df -h /home/dev'
a press title=Run
a wait until=sheet text='Exit status' timeout=30
shot run-command target=sheet
a press title=Close
closed
a menu path='Window > Snippets'
a select in=window:Snippets names='["Disk space"]'
sleep 0.4
shot snippets target=window:Snippets
a menu path='File > Close' in=window:Snippets
main
a press title=Tunnels
sleep 0.5
shot tunnels
a press title='Add Tunnel…'
sheet
a set id=tunnelEditor.listenPort value=8080
a set id=tunnelEditor.targetPort value=80
sleep 0.3
shot tunnel-editor target=sheet
a press title=Cancel
closed
a press title=Monitor
a wait until=monitor text=python3 timeout=30
sleep 3
shot monitor
a set id=monitor.search value=python3
a select pane=processes names='["python3"]'
a press title=Kill
sheet
shot monitor-kill target=sheet
a press title=Cancel
closed
a set id=monitor.search value=''
# Its ports, and who is connected to the website: two visits from the server itself and one from its own address,
# held open for the pictures.
"$docker" exec -d -u dev porter-docs-web python3 -c 'import socket, time; me = socket.gethostbyname(socket.gethostname()); held = [socket.create_connection((to, 8080)) for to in ("127.0.0.1", "127.0.0.1", me)]; time.sleep(300)'
a press title=Ports
a wait until=monitor text=8080 timeout=30
a select pane=ports names='["8080"]'
a wait until=monitor text=127.0.0.1 timeout=30
sleep 3
shot monitor-ports
a press title=Processes
a press title=Files

# A dropped connection: reconnecting by itself (the server holds new logins back meanwhile).
"$docker" kill --signal STOP porter-docs-web >/dev/null
"$docker" exec porter-docs-web pkill -f 'sshd-session: dev' || true
# The tries come 2, 5, 15 and 30 s apart, and each waits 15 s for the stopped server: the fourth wait is long enough
# for both pictures (each after the indicator's 5 s) to show the countdown.
for _ in 1 2 3; do
    a wait until=text text='Connecting to web-01' timeout=60
    a wait until=text text='next try in' timeout=60
done
shot reconnecting
"$docker" kill --signal CONT porter-docs-web >/dev/null
a wait until=connected host=web-01 timeout=60

# MARK: Keys

a menu path='Window > Keys'
sleep 1
shot keys target=window:Keys
a select in=window:Keys names='["id_ed25519"]'
a press 'title=Install on Host…' in=window:Keys
sheet
try set title=Host value=web-01 in=window:Keys
shot install-key target=sheet
a press title=Cancel in=window:Keys
a press 'title=New Key Pair…' in=window:Keys
sheet
a set id=newKey.name value=id_ed25519_web in=window:Keys
a set id=newKey.comment value=me@my-mac in=window:Keys
shot new-key-pair target=sheet
a set id=newKey.copy value=false in=window:Keys
a press title=Generate in=window:Keys
a wait until=sheet text='Key pair created' timeout=30
sleep 0.4
shot new-key-result target=sheet
a press 'title=Export as PuTTY Key (.ppk)…' in=window:Keys
sleep 0.5
shot export-putty-key target=sheet
a press 'title=Export…' in=window:Keys file="$T/web.ppk"
a wait until=sheet text='PuTTY key saved' timeout=30
a press title=Done in=window:Keys
a press 'title=Import Key…' in=window:Keys file="$T/web.ppk"
sleep 1
a set id=importKey.name value=id_ed25519_putty in=window:Keys
shot import-putty-key target=sheet
a press title=Cancel in=window:Keys
a menu path='File > Close' in=window:Keys
main

# MARK: Settings

shot settings target=window:Settings
# Without this throwaway AirSCP's own paths (its key folder, the command with its settings folder): two parts.
for mode in light dark; do cp "$T/raw/settings-$mode.png" "$T/raw/settings-agents-$mode.png"; done
keys=$(frame Settings settings.keyFolder)
agents=$(frame Settings settings.agentControl)
command=$(frame Settings settings.mcpCommand)
crop settings 0 0 540 "$(echo "$keys" | awk '{ print $2 - 64 }')"
crop settings-agents 0 "$(echo "$agents" | awk '{ print $2 - 58 }')" 540 \
    "$(echo "$agents $command" | awk '{ print $6 - $2 + 50 }')"
# Advanced (Debug logging), at the end of the form: set scrolls it into view (switching the appearance scrolls back up).
for mode in light dark; do
    appearance "$(tr '[:lower:]' '[:upper:]' <<<"${mode:0:1}")${mode:1}"
    a set id=settings.debugLogging value=false in=window:Settings
    sleep 0.4
    a screenshot scale=2 target=window:Settings --out "$T/raw/settings-advanced-$mode.png"
done
debug=$(frame Settings settings.debugLogging)
appearance Light
crop settings-advanced 0 "$(echo "$debug" | awk '{ print $2 - 52 }')" 540 1000
echo "  settings-advanced"

# MARK: Remote Desktop

a select pane=sidebar names='["Office PC"]'
shot rdp-idle
a menu path='Host > Edit…'
sheet
shot rdp-editor target=sheet
a press title=Advanced
sleep 0.4
shot rdp-editor-advanced target=sheet
a set id=rdpEditor.certificate value="Trust my company's certificate authority"
try set id=rdpEditor.caFile value=/Library/Certificates/company-ca.pem
sleep 0.4
shot rdp-editor-certificate target=sheet
a press title=Cancel
closed
if [[ -n $windows ]]; then
    # The Mac's clipboard stays on the Mac: Windows gets keys below, and with them it would get what the Mac copied.
    a menu path='Host > Edit…'
    sheet
    a set id=rdpEditor.clipboard value=false
    a press title=Save
    closed
    a menu path='Host > Connect'
    # (No picture: the test VM's certificate has its own name in it.) A Windows that just started can be slow to answer.
    a wait until=sheet text=certificate timeout=60
    a press title='Trust Once'
    sheet 'Log in'
    shot rdp-login target=sheet
    a set id=rdpLogin.username value="$(sed -n 's/^PORTER_WIN_USER=//p' testenv/.windows/credentials)"
    sed -n 's/^PORTER_WIN_PASSWORD=//p' testenv/.windows/credentials | a set id=rdpLogin.password value=-
    a press title='Log In'
    a wait until=rdp_connected timeout=90
    a wait until=rdp_drawn timeout=90
    sleep 20  # the first picture can be Windows' Welcome screen while it still logs on
    # Away with the windows an earlier session left open (Ctrl+W closes an Explorer window, and does nothing on the
    # desktop), then Explorer on the shared folder, from Start's search.
    for _ in 1 2 3 4; do a key combo=cmd+w target=rdp; sleep 1; done
    a drop files="[\"$mac/website/images/logo.svg\", \"$mac/website/downloads/price-list.pdf\"]" target=desktop
    a wait until=text text='In Windows:' timeout=60
    a key combo=control+escape target=rdp
    sleep 3
    a type text='\\tsclient\AirSCP' target=rdp
    sleep 3
    a key combo=return target=rdp
    sleep 10
    shot rdp-desktop
    a menu path='Host > Disconnect'
    a wait until=disconnected timeout=30
fi

# MARK: Small PNGs

python3 - "$T/raw" "$out" <<'PY'
import os, sys
from PIL import Image
raw, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for name in sorted(os.listdir(raw)):
    image = Image.open(os.path.join(raw, name))
    if image.mode == "RGBA" and image.getextrema()[3][0] == 255:
        image = image.convert("RGB")
    # 256 colours without dithering: the same to the eye for a screenshot, about a third of the bytes. Max coverage keeps
    # the few pixels of a status dot or a window button their colour (median cut gives them to big areas); k-means then
    # fits the palette to the big surfaces (Night Harbor's tinted greys).
    method = Image.Quantize.FASTOCTREE if image.mode == "RGBA" else Image.Quantize.MAXCOVERAGE
    image.quantize(colors=256, method=method, kmeans=4, dither=Image.Dither.NONE).save(os.path.join(out, name), optimize=True)
PY
echo "Wrote $(ls "$T/raw" | wc -l | tr -d ' ') pictures to docs/assets/shots"
