# Porter lab "digestproxy": squid asking for Digest login only (no Basic), user porter / password porter-proxy, and only
# CONNECTs to port 22 (the lab's sshds, by their service names), for AirSCP's Digest answer.
FROM alpine:latest@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache squid

COPY <<'EOF2' /etc/squid/digest_passwd
porter:porter-proxy
EOF2

COPY <<'EOF2' /etc/squid/squid.conf
http_port 8888
auth_param digest program /usr/lib/squid/digest_file_auth /etc/squid/digest_passwd
auth_param digest realm porter-lab
auth_param digest children 2
acl authed proxy_auth REQUIRED
acl ssh port 22
acl CONNECT method CONNECT
http_access deny CONNECT !ssh
http_access allow CONNECT authed
http_access deny all
cache deny all
access_log none
cache_log /dev/null
pid_filename none
EOF2

EXPOSE 8888
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
