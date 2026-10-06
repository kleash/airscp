# Windows test server for RDP ("Porter Test Windows")

The Docker lab's `rdp` service is xrdp, which has no NLA. This VM is a real Windows 11 Pro machine with
Windows' own RDP stack (TLS, NLA/CredSSP, NTLM), the same as Windows Server. Use it to test AirSCP's built-in
RDP client against real Windows.

Windows can't run in Docker on this Mac (no KVM), and x86 Windows in UTM is fully emulated and far too slow. So
this is **Windows 11 Pro ARM64 in UTM** with Apple's hypervisor (HVF), which runs at close to native speed.

| File | What it is |
|---|---|
| `windows-vm.sh` | `create` / `start` / `stop` / `status` / `ip` / `destroy` |
| `autounattend.xml` | Template for the unattended install. `create` fills in the password and the ISO's language. |
| `../.windows/` (gitignored) | `credentials` (mode 600), `answer.iso`, `utm-guest-tools.iso` (cache), `serial.log` |

## The VM

- **Name:** `Porter Test Windows`. It's a new UTM VM; the other VMs in UTM are never touched. The VM, its account and
  its credentials file keep the names from before the app was renamed AirSCP.
- **Hardware:** QEMU `virt` (aarch64) with HVF, 4 cores, 6 GB RAM and a 64 GB NVMe disk (grows as it fills).
  UEFI + TPM 2.0 + Secure Boot (UTM's Windows preset). Display is `virtio-ramfb`.
- **Network:** virtio-net on UTM's **Shared** network. The VM gets a 192.168.64.x address from macOS's DHCP;
  the address stays the same because the MAC address doesn't change.
- **Windows:** computer name `PORTER-WIN`, time zone UTC. Local administrator `porter`, no Microsoft account.
  Remote Desktop is on, with **NLA required**. The firewall group "Remote Desktop" is on for all profiles.
  The network profile is Private. The VM never sleeps and the password never expires.
  The UTM guest tools are installed: QEMU guest agent (used by `utmctl ip-address`), SPICE agent and virtio drivers.

## Create it once

1. Download the Windows 11 ARM64 ISO in a browser (Microsoft blocks scripted downloads):
   <https://www.microsoft.com/software-download/windows11arm64>. Any language works.
2. Run `testenv/windows/windows-vm.sh create [path/to/Win11_..._Arm64.iso]`.
   Without a path, it uses the newest `~/Downloads/Win11*Arm64*.iso`.
   It takes about 30 minutes and prints the VM's IP at the end.

What `create` does:

1. Generates the `porter` password into `testenv/.windows/credentials`.
2. Builds the answer ISO with `hdiutil makehybrid -iso -joliet`. It holds the rendered `autounattend.xml`,
   the UTM guest tools installer and the NetKVM (virtio-net) ARM64 driver. Windows ARM64 has no built-in
   driver for UTM's network card.

   The guest tools ISO itself isn't attached, because it contains its own `Autounattend.xml` that Windows
   Setup could pick instead of ours.
3. Creates the VM with UTM's AppleScript (`make new virtual machine with properties {backend:qemu, ...}`).
4. UTM's AppleScript can't turn on the TPM (which also selects UTM's Secure Boot firmware) or add a display.
   So `create` quits UTM once and sets both in the VM's `config.plist`, like UTM's Windows wizard does.

   If another UTM VM is running, it skips this step. The VM then has no TPM, Secure Boot or display; Setup's
   checks are bypassed in `autounattend.xml` either way.
5. Boots the installer. The Windows disc waits about 5 seconds at "Press any key to boot from CD or DVD".
   The script answers that prompt once, through the VM's serial console (127.0.0.1:41389, only during the
   install). The NVMe disk comes first in the boot order, so later boots go straight to Windows and never hit
   that prompt again.
6. Waits until the last first-logon command writes `C:\Users\Public\porter-ready.txt` (read through the guest
   agent).
7. Shuts Windows down, removes the install discs and the serial port, starts it again and waits for port 3389.

The first time, macOS asks whether your terminal app may control UTM. Click **Allow**. If you clicked Don't
Allow, or the script stops with error -1743, turn it on in **System Settings ▸ Privacy & Security ▸ Automation
▸ (your terminal app) ▸ UTM** and run `create` again (after `destroy` if the VM was half made).

## Use it

```sh
testenv/windows/windows-vm.sh start     # boots it and waits until RDP answers, prints the IP
testenv/windows/windows-vm.sh status    # e.g. "started 192.168.64.7 rdp:open"
testenv/windows/windows-vm.sh ip        # IP only
testenv/windows/windows-vm.sh stop      # clean Windows shutdown (forced after 3 minutes)
testenv/windows/windows-vm.sh destroy   # deletes the VM and its disk (keeps the password file)
```

When the VM runs, UTM shows its console in a window. Minimize it rather than closing it: closing the window
stops the VM.

**Credentials:** `testenv/.windows/credentials` (mode 600):

```sh
PORTER_WIN_USER=porter
PORTER_WIN_PASSWORD=...
```

**Address:** `@IP@` (from `windows-vm.sh ip`), port 3389, user `porter`, no domain.

## Verify an NLA login (headless, from Docker)

```sh
. testenv/.windows/credentials
ip=$(testenv/windows/windows-vm.sh ip)
docker run --rm -e PW="$PORTER_WIN_PASSWORD" -e IP="$ip" debian:stable-slim bash -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends freerdp3-x11 >/dev/null &&
  xfreerdp3 /auth-only /sec:nla /cert:ignore /v:"$IP" /u:porter /p:"$PW"'
echo "exit $?"   # 0 = NLA login accepted
```

`/auth-only` only authenticates (CredSSP/NTLM over TLS), so no X display is needed.

@VERIFY@

## How AirSCP's tests should use it

- Treat it like the Docker lab: run the Windows tests only when asked (for example `AIRSCP_WINDOWS=1`), and
  skip them unless `windows-vm.sh status` reports `rdp:open`.
- Source `testenv/.windows/credentials` and connect to `$(windows-vm.sh ip):3389` as `porter`.
- Checks that only real Windows can cover:
  - NLA/CredSSP with the right and the wrong password.
  - The certificate prompt: self-signed, CN=`PORTER-WIN`.
  - Desktop drawing, keyboard and mouse, clipboard, and resizing through the display channel.
- Through SSH: @BASTION@
- A second connection as `porter` takes over the existing session. That's normal Windows client behaviour:
  one interactive session at a time.

## Licensing

Windows is installed with Microsoft's generic Windows 11 Pro install key. The key picks the edition but
doesn't activate Windows. An unactivated copy is fine for a short-lived test VM; it shows a watermark and
locks personalization. If you keep the VM, activate it with a valid Windows 11 Pro licence (Settings ▸
System ▸ Activation) or delete it. Microsoft's licence terms apply either way.

## Troubleshooting

- **Setup seems stuck:** watch the UTM window. `testenv/.windows/serial.log` shows the firmware's output up to
  the CD prompt. Start over with `destroy` and then `create`.
- **No IP:** `windows-vm.sh ip` asks the guest agent first, then macOS's DHCP leases (`/var/db/dhcpd_leases`).
- **Windows Update** may install updates and restart the VM now and then. Run `windows-vm.sh start` again; it
  waits until RDP answers.

## Don't switch the VM's network off from inside Windows

`Disable-NetAdapter` (or turning the network adapter off in Windows' settings) bugchecks this VM (stop code 0x7E,
SYSTEM_THREAD_EXCEPTION_NOT_HANDLED). To test a lost connection, stop the RDP session
from the Mac side instead (Disconnect, or quit AirSCP); restart the VM only gracefully (`utmctl stop --request`, then
wait up to 10 minutes).
