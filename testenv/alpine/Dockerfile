# Porter lab "minimal" and "bastion": Alpine with OpenSSH and BusyBox (ps, tar and gzip; no zip, unzip or python3).
# No PAM, so passwords go through ssh's "password" method. The user and password come from docker-compose.yml.
FROM alpine:latest@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
ARG LAB_USER
ARG LAB_PASSWORD

RUN apk add --no-cache openssh-server \
 && ssh-keygen -A \
 && rm -f /usr/bin/unzip \
 && adduser -D -s /bin/sh "$LAB_USER" \
 && echo "$LAB_USER:$LAB_PASSWORD" | chpasswd

COPY <<'EOF' /etc/ssh/sshd_config
PasswordAuthentication yes
KbdInteractiveAuthentication no
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
Subsystem sftp internal-sftp
AllowTcpForwarding no
# Every connection from the Mac comes from Docker's gateway: don't lock it out after failed or cancelled logins.
PerSourcePenalties no
MaxStartups 100
EOF

# The lab key (testenv/.keys/id_lab.pub, made by up.sh).
COPY --from=keys id_lab.pub /etc/ssh/authorized_keys/$LAB_USER

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
