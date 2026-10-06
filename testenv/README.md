# AirSCP's Docker test lab

Four small servers in Docker for the scenarios a throwaway user-mode `sshd` can't play: PAM and password logins,
a jump host into a private network, an HTTP proxy, a chroot sftp-only account, login noise, BusyBox, and the
performance fixtures. Everything listens on 127.0.0.1 only. It needs Docker Desktop (and internet access for
the first build, which pulls Debian and Alpine).

```sh
testenv/up.sh               # builds (first time about a minute) and starts the lab, waits until it answers
AIRSCP_DOCKER=1 ./test.sh   # all tests, including the lab's (it runs up.sh itself)
testenv/down.sh             # removes the containers and networks (--images removes the images too)
```

`up.sh` makes a throwaway key pair, `testenv/.keys/id_lab` (gitignored), and builds it into the images: every
account below takes that key as well as its password. The Docker project is `porter-lab` (containers
`porter-lab-*`): the lab, its accounts and its passwords keep the names from before the app was renamed AirSCP.

| Server | From the Mac | Inside the lab | Accounts (password) | What it is |
|---|---|---|---|---|
| target | 127.0.0.1:42201 | `target:22` | `dev` (`porter-dev`), `sftponly` (`porter-sftp`) | Debian with PAM, bash, sudo, procps, file, zip, unzip, python3 |
| minimal | 127.0.0.1:42202 | | `dev` (`porter-min`) | Alpine with BusyBox `ps`, `tar` and `gzip`; no zip, unzip, python3 or `file` |
| bastion | 127.0.0.1:42203 | `bastion:22` | `jump` (`porter-jump`) | Alpine, TCP forwarding allowed: the jump host to `target` |
| twofactor | 127.0.0.1:42204 | | `dev` (the key, then a code) | Debian: the lab key, then a verification code (Google Authenticator's PAM module) |
| proxy | 127.0.0.1:42280 | `proxy:8888` | `porter` (`porter-proxy`) | tinyproxy: HTTP CONNECT to port 22 only, Basic authentication |

- **target**: passwords come as PAM keyboard-interactive prompts (`(dev@127.0.0.1) Password: `); `dev`'s
  `.bashrc` prints a line to standard output and one to standard error before anything else, and terminals get a
  message of the day. `sudo` asks for dev's password. `/home/dev/perf` (read-only) holds `many/` with 50 000 small
  files and `2g.bin`, a 2 GiB file (sparse, so it takes no disk space). `porter-busy`, a long-running process of
  dev's, is there to be killed in the Monitor tab; it comes back 2 s later. `sftponly` is locked into
  `/srv/sftp` and sees `/upload`, which holds `other-disk`, a separate file system (a move onto it can't be a
  rename).
- **minimal** and **bastion** have no PAM, so their passwords use ssh's `password` method
  (`dev@127.0.0.1's password: `). minimal refuses TCP forwarding (Alpine's default).
- **twofactor** takes only the lab key, and then asks `(dev@127.0.0.1) Verification code: `: the 6-digit TOTP code
  of the secret `GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ` (add it to any authenticator app; the tests compute it).
- The internal network has no way out. `target` is on it and on the published one; `bastion` and `proxy` reach it
  there by name. The bastion can also reach the Windows test VM (`192.168.66.2:3389`), for RDP through an SSH host.
- The sshds don't penalise addresses for failed or cancelled logins (`PerSourcePenalties no`): every connection
  from the Mac comes from the same Docker gateway address.

## In AirSCP

- Direct: host `127.0.0.1`, port `42201`, user `dev`, key file `testenv/.keys/id_lab` (or the password).
- Jump host: bastion = `127.0.0.1`, port `42203`, user `jump`; target = host `target`, port `22`, user `dev`,
  jump host bastion.
- Proxy chain: proxy `127.0.0.1:42280`, user `porter`; bastion = host `bastion`, port `22`, user `jump`, that
  proxy; target = host `target`, port `22`, user `dev`, jump host bastion.

To keep ssh away from your own `~/.ssh` while trying the app, start it with `AIRSCP_SSH_DIR` (see the main
README) and put `UserKnownHostsFile`, `IdentityAgent none` and `IdentityFile none` in that folder's `config`.

## The tests

`Tests/AirSCPTests/Lab*.swift` run only with `AIRSCP_DOCKER=1`. They reach the lab the way AirSCP does, with
the lab key or the passwords, and keep ssh away from `~/.ssh` (`-F` test config, own known_hosts, no agent). Each
test works in a folder of its own on the servers (`porter-lab-*`, removed afterwards). Two of them time things
against plain `sftp`/`scp` and print the numbers (`Lab: …` lines); for steady numbers run each alone, e.g.
`AIRSCP_DOCKER=1 ./test.sh --filter largeFilesMoveAtPlainScpSpeed`.
