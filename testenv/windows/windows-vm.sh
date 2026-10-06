#!/bin/bash
# Porter's Windows RDP test server: Windows 11 Pro ARM64 in UTM. See README.md next to this script.
#
#   windows-vm.sh create [ISO]   create "Porter Test Windows", install Windows unattended, wait for RDP (~30 min)
#   windows-vm.sh finish         resume an interrupted create: wait for setup, remove the install discs, wait for RDP
#   windows-vm.sh start          start it and wait until RDP answers; prints the IP
#   windows-vm.sh stop           shut Windows down (forced after 3 minutes)
#   windows-vm.sh status         status, IP, whether 3389 answers
#   windows-vm.sh ip             print the IP
#   windows-vm.sh destroy        delete the VM and its disk
set -euo pipefail
umask 077

VM="Porter Test Windows"
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$(dirname "$HERE")/.windows"   # gitignored: credentials, answer ISO, guest tools ISO, serial log
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
BUNDLE="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents/$VM.utm"
SERIAL_PORT=41389   # the VM's serial console on 127.0.0.1, only attached while installing
# UTM's guest tools: the release getutm.app/downloads/utm-guest-tools-latest.iso led to on 2026-10-05, and its SHA-256
TOOLS_URL=https://github.com/utmapp/qemu/releases/download/v10.0.2-utm/utm-guest-tools-0.1.271.iso
TOOLS_SHA256=65b6a69b392ee01dd314c10f3dad9ebbf9c4160be43f5f0dd6bb715944d9095b
READY_FILE='C:\Users\Public\porter-ready.txt'   # written by the last FirstLogonCommand in autounattend.xml

say() { echo "windows-vm: $*" >&2; }
die() { say "$*"; exit 1; }

# AppleScript (stdin) against UTM, arguments in argv. -1743 means macOS has not allowed us to control UTM.
utm_script() {
  local out
  if out=$(osascript - "$@" 2>&1); then [[ -z $out ]] || echo "$out"; return 0; fi
  [[ $out != *-1743* ]] || die "macOS blocked controlling UTM (error -1743). Click Allow when macOS asks, or turn it on in System Settings > Privacy & Security > Automation > (your terminal app) > UTM, then re-run."
  die "UTM AppleScript failed: $out"
}

vm_status() { "$UTMCTL" status "$VM" 2>/dev/null || true; }   # started, stopped, ...; empty when there is no VM
need_vm() { [[ -n $(vm_status) ]] || die "there is no VM \"$VM\" (run: $0 create)"; }
rdp_open() { nc -z -G 3 "$1" 3389 >/dev/null 2>&1; }

# IPv4 from the QEMU guest agent, else from macOS's DHCP lease for the VM's MAC (UTM "Shared" network)
vm_ip() {
  local ip mac
  ip=$("$UTMCTL" ip-address "$VM" 2>/dev/null | grep -E '^([0-9]+\.){3}[0-9]+$' | grep -v '^169\.254\.' | head -1 || true)
  if [[ -z $ip ]]; then
    mac=$(/usr/libexec/PlistBuddy -c 'Print :Network:0:MacAddress' "$BUNDLE/config.plist" 2>/dev/null |
      tr 'A-F' 'a-f' | sed -E 's/(^|:)0([0-9a-f])/\1\2/g' || true)
    [[ -z $mac ]] || ip=$(awk -v hw="1,$mac" '/^\{/ { a = h = "" } /ip_address=/ { sub(/.*=/, ""); a = $0 }
      /hw_address=/ { sub(/.*=/, ""); h = $0 } /^\}/ && h == hw { print a }' /var/db/dhcpd_leases 2>/dev/null | head -1)
  fi
  [[ -n $ip ]] && echo "$ip"
}

wait_rdp() {   # $1 = minutes; prints the IP once 3389 answers
  local end=$((SECONDS + $1 * 60)) ip
  while ((SECONDS < end)); do
    if ip=$(vm_ip) && rdp_open "$ip"; then echo "$ip"; return 0; fi
    sleep 10
  done
  return 1
}

disk_mb() {
  local f
  for f in "$BUNDLE"/Data/*.qcow2; do [[ -f $f ]] && { echo $(($(stat -f %z "$f") / 1048576)); return; }; done
  echo 0
}

find_iso() {
  local f=${1:-}
  if [[ -z $f ]]; then
    # shellcheck disable=SC2012 # ls -t: the newest download first
    f=$(ls -t "$HOME"/Downloads/Win11*Arm64*.iso 2>/dev/null | head -1 || true)
    [[ -n $f ]] || f=$(find "$HOME/Downloads" -maxdepth 1 -iname '*.iso' -size +4G 2>/dev/null | head -1 || true)
  fi
  [[ -n $f && -f $f ]] || die "no Windows 11 ARM64 ISO found. Download it from https://www.microsoft.com/software-download/windows11arm64, then: $0 create /path/to/Win11_..._Arm64.iso"
  echo "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
}

gen_password() {
  local p
  while :; do
    p=$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20)
    [[ $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] ]] && break
  done
  echo "${p:0:10}-${p:10}"
}

# First boot only: the installer disc waits ~5 s at "Press any key to boot from CD or DVD". UEFI reads keys from
# the serial console too, so answer it there. (The disk boots first, so later boots never reach the disc.)
press_boot_key() {
  local log="$STATE/serial.log" i
  : >"$log"
  for i in {1..60}; do nc -z 127.0.0.1 "$SERIAL_PORT" 2>/dev/null && break; sleep 1; done
  # shellcheck disable=SC2094 # the loop watches what nc writes to the log
  for i in {1..120}; do
    printf '\r'; sleep 1
    if grep -aq 'Press any key' "$log"; then printf '\r'; sleep 1; printf '\r'; break; fi
  done | nc 127.0.0.1 "$SERIAL_PORT" >"$log" 2>/dev/null || true
  grep -aq 'Press any key' "$log"
}

# The AppleScript API can't turn on the TPM (which also selects UTM's Secure Boot firmware) or add a display, so set
# them in config.plist like UTM's Windows preset does. UTM reads config.plist only at launch, so it is quit first.
apply_windows_preset() {
  if "$UTMCTL" list | awk 'NR > 1 && $2 != "stopped" { busy = 1 } END { exit !busy }'; then
    say "another UTM VM is running, so UTM is not restarted: no TPM/Secure Boot/display (Setup's checks are bypassed)"
    return 0
  fi
  osascript -e 'tell application "UTM" to quit' >/dev/null
  local i; for i in {1..30}; do pgrep -xq UTM || break; sleep 1; done
  ! pgrep -xq UTM || die "UTM did not quit"
  /usr/libexec/PlistBuddy -c 'Set :QEMU:TPMDevice true' -c 'Add :Display:0 dict' \
    -c 'Add :Display:0:Hardware string virtio-ramfb' -c 'Add :Display:0:DynamicResolution bool true' \
    -c 'Add :Display:0:NativeResolution bool false' -c 'Add :Display:0:UpscalingFilter string Nearest' \
    -c 'Add :Display:0:DownscalingFilter string Linear' "$BUNDLE/config.plist"
}

cmd_create() {
  local exists iso lang mnt
  exists=$(utm_script "$VM" <<<$'on run {n}\ntell application "UTM" to return exists virtual machine named n\nend run')
  [[ $exists == false ]] || die "\"$VM\" already exists (delete it first: $0 destroy)"
  iso=$(find_iso "${1:-}")
  mkdir -p "$STATE" && chmod 700 "$STATE"

  # Password: generated once, kept across re-creates
  [[ -s $STATE/credentials ]] || printf 'PORTER_WIN_USER=porter\nPORTER_WIN_PASSWORD=%s\n' "$(gen_password)" >"$STATE/credentials"
  chmod 600 "$STATE/credentials"
  # shellcheck source=/dev/null
  . "$STATE/credentials"

  # The ISO must be ARM64; the answer file takes its language (en-US, en-GB, ...)
  mnt=$(mktemp -d /tmp/porter-win.XXXXXX)
  hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$iso" >/dev/null || die "cannot open $iso"
  lang=$(awk -F' *= *' '/^\[Available UI Languages\]/ { f = 1; next } /^\[/ { f = 0 } f && NF > 1 { print $1; exit }' \
    "$mnt/sources/lang.ini" 2>/dev/null | tr -d '\r' || true)
  [[ -f $mnt/efi/boot/bootaa64.efi ]] || { hdiutil detach "$mnt" >/dev/null; die "$iso is not a Windows ARM64 ISO"; }
  hdiutil detach "$mnt" >/dev/null && rmdir "$mnt"
  [[ $lang =~ ^[A-Za-z]{2,3}-[A-Za-z]+$ ]] || lang=en-US

  # Answer disc: autounattend.xml + the UTM guest tools installer. The guest tools ISO itself is not attached:
  # it carries its own Autounattend.xml, which Windows Setup might pick instead of ours.
  if [[ $(shasum -a 256 "$STATE/utm-guest-tools.iso" 2>/dev/null | cut -d' ' -f1) != "$TOOLS_SHA256" ]]; then
    say "downloading UTM guest tools"
    curl -fsSL --retry 3 -o "$STATE/utm-guest-tools.iso.part" "$TOOLS_URL"
    [[ $(shasum -a 256 "$STATE/utm-guest-tools.iso.part" | cut -d' ' -f1) == "$TOOLS_SHA256" ]] \
      || { rm -f "$STATE/utm-guest-tools.iso.part"; die "the UTM guest tools download doesn't have the expected SHA-256"; }
    mv "$STATE/utm-guest-tools.iso.part" "$STATE/utm-guest-tools.iso"
  fi
  rm -rf "$STATE/answer" "$STATE/answer.iso"
  mkdir -p "$STATE/answer"
  mnt=$(mktemp -d /tmp/porter-win.XXXXXX)
  hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$STATE/utm-guest-tools.iso" >/dev/null
  cp "$mnt"/utm-guest-tools-*.exe "$STATE/answer/utm-guest-tools.exe"
  hdiutil detach "$mnt" >/dev/null && rmdir "$mnt"
  sed -e "s/@PASSWORD@/$PORTER_WIN_PASSWORD/g" -e "s/@LANG@/$lang/g" "$HERE/autounattend.xml" >"$STATE/answer/autounattend.xml"
  hdiutil makehybrid -iso -joliet -default-volume-name PORTER_ANSWER -o "$STATE/answer.iso" "$STATE/answer" >/dev/null

  # Disk first in the boot order: empty on the first boot (so the installer disc boots), Windows afterwards.
  # «class SrPt» is the "serial ports" property: UTM's dictionary also has a "serial port" class, which
  # AppleScript would compile the plain words to.
  say "creating \"$VM\" (ISO: $iso, language: $lang)"
  trap '[[ -n $(vm_status) ]] || rm -rf "$BUNDLE"' EXIT   # don't leave a half-made bundle behind if this fails
  utm_script "$VM" "$iso" "$STATE/answer.iso" "$SERIAL_PORT" >/dev/null <<'EOF'
on run {vmName, winIso, answerIso, serialPort}
  set winFile to POSIX file winIso
  set answerFile to POSIX file answerIso
  tell application "UTM"
    set theDrives to {{interface:NVMe, guest size:65536}, {removable:true, interface:USB, source:winFile}, {removable:true, interface:USB, source:answerFile}}
    set theNics to {{hardware:"virtio-net-pci", mode:shared}}
    set theSerials to {{interface:tcp, port:(serialPort as integer)}}
    make new virtual machine with properties {backend:qemu, configuration:{name:vmName, architecture:"aarch64", memory:6144, cpu cores:4, hypervisor:true, uefi:true, drives:theDrives, network interfaces:theNics, «class SrPt»:theSerials}}
  end tell
end run
EOF
  trap - EXIT
  apply_windows_preset

  say "installing Windows (about 20-40 minutes; the UTM window shows progress)"
  "$UTMCTL" start "$VM" >/dev/null
  press_boot_key || say "no CD boot prompt seen on the serial console ($STATE/serial.log)"
  cmd_finish
}

# The rest of create; run it on its own if create was interrupted while Windows was installing
cmd_finish() {
  local ip started=$SECONDS i
  need_vm
  # Done when the last FirstLogonCommand has written READY_FILE (read through the guest agent)
  for ((i = 1; ; i++)); do
    sleep 30
    [[ $("$UTMCTL" file pull "$VM" "$READY_FILE" 2>/dev/null || true) == ready* ]] && break
    [[ $(vm_status) == started ]] || die "the VM stopped during setup"
    ((SECONDS - started < 90 * 60)) || die "setup did not finish within 90 minutes; look at the UTM window"
    if ((i == 20 && $(disk_mb) < 1024)); then   # after 10 minutes nothing was installed: the disc prompt was missed
      say "the installer did not start; restarting the VM once"
      "$UTMCTL" stop --force "$VM" >/dev/null; sleep 3; "$UTMCTL" start "$VM" >/dev/null
      press_boot_key || true
    fi
    ((i % 10)) || say "still installing ($((i / 2)) min, disk $(disk_mb) MB)"
  done

  say "installed; removing the install discs and the serial port, then rebooting"
  cmd_stop
  utm_script "$VM" >/dev/null <<'EOF'
on run {vmName}
  tell application "UTM"
    set vm to virtual machine named vmName
    set cfg to configuration of vm
    set keep to {}
    repeat with d in (drives of cfg)
      if not (removable of d) then set end of keep to {id:(id of d)}
    end repeat
    update configuration vm with {drives:keep, «class SrPt»:{}}
  end tell
end run
EOF
  ip=$(cmd_start)
  say "ready: RDP at $ip:3389, user porter, password in $STATE/credentials"
  echo "$ip"
}

cmd_start() {
  local ip
  need_vm
  [[ $(vm_status) == started ]] || "$UTMCTL" start "$VM" >/dev/null
  ip=$(wait_rdp 15) || die "RDP did not answer within 15 minutes"
  echo "$ip"
}

cmd_stop() {
  local i
  need_vm
  [[ $(vm_status) != stopped ]] || return 0
  "$UTMCTL" stop --request "$VM" >/dev/null 2>&1 || true   # ACPI power button: Windows shuts down cleanly
  for i in {1..60}; do [[ $(vm_status) != stopped ]] || return 0; sleep 3; done
  say "Windows did not shut down within 3 minutes; powering off"
  "$UTMCTL" stop --force "$VM" >/dev/null
}

cmd_status() {
  local st ip
  st=$(vm_status)
  [[ -n $st ]] || { echo "absent"; return 1; }
  if [[ $st == started ]] && ip=$(vm_ip); then
    rdp_open "$ip" && echo "$st $ip rdp:open" || echo "$st $ip rdp:closed"
  else
    echo "$st"
  fi
}

cmd_ip() { need_vm; vm_ip || die "no IP yet (is it started?)"; }

cmd_destroy() {
  [[ -n $(vm_status) ]] || { say "there is no VM \"$VM\""; return 0; }
  [[ $(vm_status) == stopped ]] || "$UTMCTL" stop --force "$VM" >/dev/null
  "$UTMCTL" delete "$VM"
  rm -rf "$STATE/answer" "$STATE/answer.iso" "$STATE/serial.log"
  say "deleted \"$VM\" (the password and the guest tools ISO stay in $STATE)"
}

case "${1:-}" in
  create) cmd_create "${2:-}" ;;
  finish | start | stop | status | ip | destroy) "cmd_$1" ;;
  *) sed -n '2,11s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
