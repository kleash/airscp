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
    if [[ $1 == 4228[01] ]]; then printf 'CONNECT target:22 HTTP/1.0\r\n\r\n' >&3; fi
    IFS= read -r -t 3 reply <&3 || true
    exec 3<&-
    [[ $reply == SSH-* || $reply == HTTP/* ]]
}
for port in 42201 42202 42203 42204 42280 42281; do
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
  proxy    port 42280  HTTP proxy, porter / porter-proxy (CONNECT to port 22 only: bastion, target)
  openproxy port 42281 the same HTTP proxy with no password
  private  (no port)    dev / porter-private (Alpine; only inside the lab: via bastion, or a proxy, as host "private")
Lab tests: AIRSCP_DOCKER=1 ./test.sh    Remove the lab: testenv/down.sh
EOF
