#!/bin/bash
# Installs AirSCP into ~/Applications and registers it with Launch Services. No administrator rights needed.
#   ./install.sh                      installs build/AirSCP.app (from ./build.sh), else an AirSCP.app next to this script
#   ./install.sh path/to/AirSCP.app   installs that app
#   ./install.sh --dry-run [app]      prints the commands instead of running them
set -euo pipefail

usage() { echo "usage: $0 [--dry-run] [path/to/AirSCP.app]" >&2; exit 2; }
dry=false
src=
for arg in "$@"; do
    case $arg in
        --dry-run) dry=true ;;
        -*) usage ;;
        *) if [ -n "$src" ]; then usage; fi; src=$arg ;;
    esac
done
# A relative path means relative to where the script was started, not to the script's folder.
case $src in ""|/*) ;; *) src=$PWD/$src ;; esac
cd "$(dirname "$0")"
run() { if $dry; then echo "+ $*"; else "$@"; fi; }

if [ -z "$src" ]; then
    if [ -d build/AirSCP.app ]; then src=build/AirSCP.app; else src=AirSCP.app; fi
fi
dest=$HOME/Applications/AirSCP.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

version=$(sw_vers -productVersion)
IFS=. read -r major minor _ <<< "$version"
if (( major < 13 || (major == 13 && ${minor:-0} < 1) )); then
    echo "AirSCP needs macOS 13.1 or later; this Mac has macOS $version." >&2
    exit 1
fi
if [ ! -x "$src/Contents/MacOS/AirSCP" ]; then
    echo "No AirSCP.app at $src. Build it first with ./build.sh, or pass the path to a prebuilt AirSCP.app." >&2
    exit 1
fi
src=$(cd "$src" && pwd)

# Quit a running AirSCP so the new copy is the one that runs. Its open connections are picked up again (adopted)
# when it next starts. Only the app itself (it runs without arguments): a proxied connection's ProxyCommand is
# AirSCP's binary too, with arguments, and must keep running.
app='AirSCP\.app/Contents/MacOS/AirSCP$'
if pgrep -qf "$app"; then
    run pkill -f "$app"
    $dry || for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -qf "$app" || break; sleep 0.5; done
fi
run mkdir -p "$HOME/Applications"
if [ "$src" != "$dest" ]; then
    run rm -rf "$dest"
    run ditto "$src" "$dest"
fi
# A downloaded, ad-hoc signed app that is still quarantined is reported as "damaged" on macOS 15 and later.
run xattr -dr com.apple.quarantine "$dest"
run "$lsregister" -f -R "$dest"
# Forget the copy we installed from, so Spotlight and Launchpad show the installed one. lsregister fails (-10814)
# when that copy was never registered, which is fine.
if [ "$src" != "$dest" ]; then run "$lsregister" -u "$src" 2>/dev/null || true; fi

cat <<'EOF'

AirSCP is installed in ~/Applications.

  Hosts        Add servers in the sidebar, or import the aliases from ~/.ssh/config. AirSCP runs the ssh, scp and
               sftp that come with macOS and shows every command it runs in the window's command log.
  Passwords    Saved passwords live in one login-Keychain item ("com.kleash.airscp"). After each new build macOS asks
               once whether AirSCP may read it: choose Always Allow.
  Terminal     Double-click a host to open ssh in Terminal (or iTerm, in Settings) over AirSCP's connection.
  AI agents    Settings ▸ Allow AI agents to control AirSCP, then for Claude Code:
               claude mcp add --scope user airscp -- ~/Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp

EOF
run open "$dest"
