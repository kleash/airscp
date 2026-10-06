#!/bin/bash
# Removes AirSCP from ~/Applications. No administrator rights needed. Saved hosts and passwords are kept.
#   ./uninstall.sh            uninstall
#   ./uninstall.sh --dry-run  print the commands instead of running them
set -euo pipefail

dry=false
case "$*" in
    "") ;;
    --dry-run) dry=true ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
run() { if $dry; then echo "+ $*"; else "$@"; fi; }

app=$HOME/Applications/AirSCP.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The app only (it runs without arguments; its helpers have some). Its connections outlive it: close them too.
running='AirSCP\.app/Contents/MacOS/AirSCP$'
if pgrep -qf "$running"; then
    run pkill -f "$running"
    $dry || for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -qf "$running" || break; sleep 0.5; done
fi
for socket in "/tmp/airscp-$(id -u)"/*; do
    if [ -S "$socket" ]; then run /usr/bin/ssh -F /dev/null -o ControlPath="$socket" -O exit airscp 2>/dev/null || true; fi
done
if [ -d "$app" ]; then
    run "$lsregister" -u "$app" || true
    run rm -rf "$app"
else
    echo "AirSCP is not installed in ~/Applications."
fi

cat <<'EOF'
AirSCP is uninstalled. Your saved hosts and settings are still in ~/Library/Application Support/AirSCP, and saved
passwords in the login Keychain item "com.kleash.airscp" (Keychain Access). Delete them too if you don't need them.
EOF
