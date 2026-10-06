# Porter lab "twofactor": the lab key, then a verification code (keyboard-interactive through PAM with Google
# Authenticator's module, as real two-factor servers ask it).
#   dev  the lab key, then the 6-digit TOTP code of the secret GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ (the bytes
#        "12345678901234567890", RFC 6238's test key): any authenticator app, or the tests' Lab.verificationCode().
FROM debian:stable-slim@sha256:5bc3287b25407c965a30f38e32603dc253a3869e1b12a21ac09bfc27fd8b13ce

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server libpam-google-authenticator \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && useradd -m -s /bin/bash dev

# No rate limit and codes may be used again: the tests log in several times a minute.
COPY --chown=dev:dev --chmod=400 <<'EOF2' /home/dev/.google_authenticator
GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
" WINDOW_SIZE 17
" TOTP_AUTH
EOF2

# The code is the whole of PAM's authentication: the key comes first (AuthenticationMethods).
COPY <<'EOF2' /etc/pam.d/sshd
auth required pam_google_authenticator.so
@include common-account
@include common-session
EOF2

COPY <<'EOF2' /etc/ssh/sshd_config
UsePAM yes
KbdInteractiveAuthentication yes
PasswordAuthentication no
AuthenticationMethods publickey,keyboard-interactive
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
Subsystem sftp internal-sftp
PrintMotd no
# Every connection from the Mac comes from Docker's gateway: don't lock it out after failed or cancelled logins.
PerSourcePenalties no
MaxStartups 100
EOF2

# The lab key (testenv/.keys/id_lab.pub, made by up.sh).
COPY --from=keys id_lab.pub /etc/ssh/authorized_keys/dev

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
