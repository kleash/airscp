#!/bin/bash
# Starts AirSCP's Docker test lab (docker-compose.yml): target, minimal, bastion and proxy, on 127.0.0.1 only.
# Makes the throwaway client key testenv/.keys/id_lab first. Safe to run again: it rebuilds what changed and waits
# until every server answers. testenv/down.sh removes the lab.
set -euo pipefail
cd "$(dirname "$0")"

# Docker Desktop's own command line tool, else the one on PATH.
docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker

mkdir -p .keys
chmod 700 .keys
[[ -f .keys/id_lab ]] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -C porter-lab -f .keys/id_lab

echo "Starting AirSCP's test lab (the first build takes a minute or two)..."
"$docker" compose up --detach --build --quiet-build --quiet-pull --remove-orphans

# Each sshd sends its greeting, and the proxy answers a CONNECT (with 407: no password given), once ready.
answers() {
    local reply=""
    exec 3<>"/dev/tcp/127.0.0.1/$1" || return 1
    if [[ $1 == 42283 ]]; then  # SOCKS5 speaks only when greeted: its answer starts with version 5
        printf '\005\001\002' >&3
        IFS= read -r -t 3 -n 1 reply <&3 || true
        exec 3<&-
        [[ $reply == $'\005' ]]
        return
    fi
    if [[ $1 == 4228[012] ]]; then printf 'CONNECT target:22 HTTP/1.0\r\n\r\n' >&3; fi
    if [[ $1 == 42284 ]]; then printf 'GET / HTTP/1.0\r\n\r\n' >&3; fi  # S3 answers 403 without keys
    IFS= read -r -t 3 reply <&3 || true
    exec 3<&-
    [[ $reply == SSH-* || $reply == HTTP/* ]]
}
for port in 42201 42202 42203 42204 42205 42206 42280 42281 42282 42283 42284; do
    tries=0
    until answers "$port" 2>/dev/null; do
        if (( ++tries == 60 )); then
            echo "Nothing answers on 127.0.0.1:$port. See: docker compose -f $PWD/docker-compose.yml logs" >&2
            exit 1
        fi
        sleep 1
    done
done

cat <<EOF
AirSCP's test lab is up, on 127.0.0.1 only. Key: testenv/.keys/id_lab (every user below also takes it).
  target   port 42201  dev / porter-dev (bash, sudo, noisy .bashrc); sftponly / porter-sftp (sftp only, chroot)
  minimal  port 42202  dev / porter-min (Alpine, BusyBox; no zip, unzip or python3)
  bastion  port 42203  jump / porter-jump (TCP forwarding on; reaches target, port 22, inside the lab)
  twofactor port 42204 dev: the key, then a verification code (TOTP secret GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ)
  sudo     port 42205  dev / porter-sudo (Alpine; sudo to root without a password, sftp-server: Browse and transfer as)
  passwd   port 42206  changer / Lab-Pass-Alpha-7 (Alpine with shadow's passwd: Change Password; tests set it back)
  proxy    port 42280  HTTP proxy, porter / porter-proxy (CONNECT to port 22 only: bastion, target)
  openproxy port 42281 the same HTTP proxy with no password
  digestproxy port 42282 squid, porter / porter-proxy with Digest login only
  socksproxy port 42283 SOCKS5 (Dante), porter / porter-proxy
  s3       port 42284  S3-compatible storage (Versity S3 Gateway): access key porter-s3, secret key porter-s3-secret
  private  (no port)    dev / porter-private (Alpine; only inside the lab: via bastion, or a proxy, as host "private")
Lab tests: AIRSCP_DOCKER=1 ./test.sh    Remove the lab: testenv/down.sh
EOF
