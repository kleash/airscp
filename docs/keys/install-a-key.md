---
title: Put your key on a server
parent: Keys
nav_order: 2
---

# Put your key on a server

The server must know your public key before you can log in with it. AirSCP adds it for you (like `ssh-copy-id`).

## Steps

1. Choose **Window ▸ Keys** and select the key.
2. Click **Install on Host…**.
3. Choose the **Host**.
4. Click **Install**. AirSCP connects, asks the server's password once, and adds the public key to the account's
   `~/.ssh/authorized_keys`.
5. Set the host to use the key: **Host ▸ Edit… ▸ Log in with**.

{% include shot.html name="install-key" alt="Install id_ed25519 on a host: the Host pop-up set to web-01" %}

## Tips

- Accounts that allow file transfers only (sftp) work too: AirSCP adds the key over sftp.
- Made the key from a host's settings? Its result sheet has **Install on This Host** and **Use for This Host**.
- Your server has a web console instead (cloud providers)? Use **Copy Public Key** and paste it there.
