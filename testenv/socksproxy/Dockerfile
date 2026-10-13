# Porter lab "socksproxy": a SOCKS5 proxy (Dante) that wants user porter / password porter-proxy, a system user here:
# the way to the bastion and the private server, as the HTTP proxy is.
FROM alpine:latest@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache dante-server \
 && adduser -D -H -s /sbin/nologin porter \
 && echo "porter:porter-proxy" | chpasswd

COPY <<'EOF2' /etc/sockd.conf
logoutput: stderr
internal: 0.0.0.0 port = 1080
# Out through whichever network leads to the server (the lab's edge and inner networks).
external: eth0
external: eth1
external.rotation: route
socksmethod: username
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 port = 22 command: connect }
EOF2

EXPOSE 1080
CMD ["sockd", "-f", "/etc/sockd.conf"]
