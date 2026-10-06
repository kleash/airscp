# Porter lab "proxy": tinyproxy, an HTTP proxy that wants user porter / password porter-proxy and only CONNECTs to
# port 22 (the lab's sshds, by their service names).
FROM alpine:latest@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk add --no-cache tinyproxy

COPY <<'EOF' /etc/tinyproxy/tinyproxy.conf
User tinyproxy
Group tinyproxy
Port 8888
Timeout 600
LogLevel Info
MaxClients 100
# Docker's networks: connections from the Mac arrive from a gateway address in one of them.
Allow 127.0.0.1
Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16
BasicAuth porter porter-proxy
ConnectPort 22
DisableViaHeader Yes
EOF

EXPOSE 8888
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
