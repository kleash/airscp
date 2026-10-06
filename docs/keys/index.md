---
title: Keys
nav_order: 12
has_children: true
---

# Keys

An SSH key pair lets you log in without typing a password. The **Keys** window lists your keys and makes new ones.

## Steps

1. Choose **Window ▸ Keys**.
2. You see every private key in `~/.ssh`, with its type, comment and fingerprint.
3. Select a key for the buttons below the list:
   - **Copy Public Key**: the public key, to paste into a server or a web console. Its menu has other formats: SSH2
     (RFC 4716) and PEM (PKCS#8).
   - **Install on Host…**: put the public key on a server. See [Put your key on a server](install-a-key.md).
   - **Export for PuTTY…**: a `.ppk` copy for Windows tools. See [Use your PuTTY keys](putty-keys.md).
   - **Add to Agent**: keep the key in the ssh agent, with its passphrase in your Keychain.

{% include shot.html name="keys" alt="The Keys window with two keys, their type, comment and fingerprint" %}

## Pages

- [Make a new key pair](new-key-pair.md)
- [Put your key on a server](install-a-key.md)
- [Use your PuTTY (.ppk) keys](putty-keys.md)

## Tips

- **Other Key File…** adds a key that lives somewhere else.
- A key that needs its passphrase before it can be read shows “type unknown”.
- **Settings ▸ Keys** sets the folder for new keys: `~/.ssh` by default, where ssh finds them by itself.
