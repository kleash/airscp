#!/bin/bash
# Removes AirSCP's Docker test lab: its containers and networks. The images stay for a quick next start
# (--images removes them too); so does the client key in testenv/.keys.
set -euo pipefail
cd "$(dirname "$0")"

docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker

case "${1:-}" in
    "") "$docker" compose down --remove-orphans ;;
    --images) "$docker" compose down --remove-orphans --rmi local ;;
    *) echo "usage: $0 [--images]" >&2; exit 2 ;;
esac
