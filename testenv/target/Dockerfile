# Porter lab "target": a Debian server with PAM passwords, a shell and the usual tools (PLAN.md J and Q).
#   dev       password porter-dev or the lab key; bash with a noisy .bashrc; sudo (asks for the password)
#   sftponly  password porter-sftp or the lab key; sftp only, locked into /srv/sftp (it sees /upload)
FROM debian:stable-slim@sha256:5bc3287b25407c965a30f38e32603dc253a3869e1b12a21ac09bfc27fd8b13ce

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server procps file zip unzip python3 sudo \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

RUN useradd -m -u 1000 -s /bin/bash -G sudo dev \
 && echo 'dev:porter-dev' | chpasswd \
 && useradd -M -u 1001 -d /upload -s /usr/sbin/nologin sftponly \
 && echo 'sftponly:porter-sftp' | chpasswd \
 && mkdir -p /srv/sftp/upload \
 && chown sftponly:sftponly /srv/sftp/upload

# Login noise: what Porter's parsed shell output must survive (the MOTD shows in terminals only).
RUN { echo 'echo "Porter lab: welcome, this line is .bashrc noise"'; \
      echo 'echo "Porter lab: .bashrc noise on standard error" >&2'; \
      cat /etc/skel/.bashrc; } > /home/dev/.bashrc \
 && echo 'Porter lab target. This message of the day is noise for terminal logins.' > /etc/motd

# Performance fixtures, read-only for dev: 50 000 small files and a 2 GiB file (sparse: it takes no disk space).
RUN mkdir -p /home/dev/perf/many \
 && python3 -c 'import os; os.chdir("/home/dev/perf/many"); [open("file-%05d.txt" % i, "w").write("small file %d\n" % i) for i in range(1, 50001)]' \
 && truncate -s 2G /home/dev/perf/2g.bin

# The long-running process to kill from the Monitor tab (lab-start runs it again 2 s after it ends).
COPY --chmod=755 <<'EOF' /usr/local/bin/porter-busy
#!/bin/sh
while :; do
    i=0
    while [ "$i" -lt 3000 ]; do i=$((i + 1)); done
    sleep 1
done
EOF

COPY <<'EOF' /etc/ssh/sshd_config
UsePAM yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
PrintMotd no
Subsystem sftp internal-sftp
AcceptEnv LANG LC_*
# Every connection from the Mac comes from Docker's gateway: don't lock it out after failed or cancelled logins.
PerSourcePenalties no
MaxStartups 100

Match User sftponly
    ChrootDirectory /srv/sftp
    ForceCommand internal-sftp
    AllowTcpForwarding no
EOF

COPY --chmod=755 <<'EOF' /usr/local/sbin/lab-start
#!/bin/sh
(while :; do runuser -u dev -- /usr/local/bin/porter-busy; sleep 2; done) &
exec /usr/sbin/sshd -D -e
EOF

# The lab key (testenv/.keys/id_lab.pub, made by up.sh).
COPY --from=keys id_lab.pub /etc/ssh/authorized_keys/dev
COPY --from=keys id_lab.pub /etc/ssh/authorized_keys/sftponly

EXPOSE 22
CMD ["/usr/local/sbin/lab-start"]
