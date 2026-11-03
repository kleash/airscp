---
title: Get started on iPhone and iPad
parent: iPhone and iPad
nav_order: 1
---

# Get started on iPhone and iPad

Save a server once, then tap it to connect. You need the server's address and your user name on it. Your server admin
or hosting company gives you these.

## Add a server

1. In **Servers**, tap **+** (Add Server).
2. Type the server's **Address**, for example `web-01.example.com` or `192.168.1.20`.
3. Type your **User** name on the server. AirSCP needs it: an iPhone has no user name of its own to try.
4. Leave **Port** empty for 22, the usual port. **Name** is optional: the list shows it instead of the address.
5. Under **Log in with**, choose **Password** or **Key**.
   - **Password**: type it to keep it in the Keychain. Or leave it empty: AirSCP then asks when it connects.
   - **Key**: choose one of your keys. No keys yet? See [Log in with a key](#log-in-with-a-key).
6. Behind a bastion? Choose it under **Jump host**: AirSCP connects through that server first. Save the bastion as a
   server before.
7. Tap **Save** (the check mark). The server shows under **Saved**.
8. Tap the server to connect. It moves to **Open**, and shows **Connected** with a green dot once it is ready.

<!-- picture: iphone-server-editor; iPhone, portrait; New Server: a name, an address, a user, Log in with Key and a key chosen -->

## Trust a server the first time

The first time you connect to a server, AirSCP shows its key's fingerprint and asks **Trust this server?**

1. At the top you see the way to the server, for example **iPhone → bastion → db-01**. The one with the key icon is the
   server that asks.
2. Compare the fingerprint with the one your server admin gave you. The coloured squares are the same fingerprint as a
   picture: another key looks different. **Copy to Compare** copies the text.
3. Tap **Trust** if it matches. AirSCP remembers the key and warns you if it ever changes. **Cancel** doesn't connect.

<!-- picture: iphone-trust; iPhone, portrait; Trust this server?: iPhone → db-01, the fingerprint as coloured squares and as text, Copy to Compare, and Trust -->

If the key of a server you trust changes, AirSCP doesn't connect. Someone may be listening in, or the server was
installed again. Only if you know why it changed: tap **Settings** (the gear) in **Servers**, swipe left on the server
under **Trusted servers**, tap **Delete**, and connect again.

## Log in with a password

When the server asks for a password, AirSCP asks you. Type it and tap **Connect**. Turn on **Remember in Keychain** (for
saved servers) if you don't want to type it again.

A server that also asks for a code (two-factor) asks for it the same way: type it and tap **Continue**.

## Log in with a key

A key lets you log in without a password. Keys stay on your iPhone or iPad, in the Keychain. When AirSCP logs in with
one, Face ID (or Touch ID, or your passcode) unlocks it.

1. In **Servers**, tap **Settings** (the gear).
2. Under **Keys**, tap **Make a New Key**, type a name (or keep the one AirSCP suggests) and tap **Make**. AirSCP makes
   an Ed25519 key, the kind most servers take.

   Have a key already? Tap **Import from Files** and choose the private key file: OpenSSH, PEM or PuTTY (`.ppk`). Choose
   the key itself, not its `.pub` file.
3. Tap **…** next to the key, then **Copy Public Key**. Or tap **Share Public Key** to send it, for example to your
   server admin.
4. Put the public key on the server, as a line of `~/.ssh/authorized_keys`. Can you log in with a password? Then
   AirSCP's [terminal](terminal.md) can do it: type `echo '`, paste the key, type `' >> ~/.ssh/authorized_keys` and
   run it.
5. In **Servers**, swipe left on the server (disconnect it first if it is open), tap **Edit**, choose **Key** under
   **Log in with**, choose your key and tap **Save**.

<!-- picture: iphone-settings; iPhone, portrait; Settings: two keys with their type and fingerprint, Make a New Key, Import from Files, and the trusted servers -->

- A key with a passphrase: AirSCP asks for it when it logs in. A PuTTY key's passphrase is asked when you import it.
- Keys don't go to another iPhone or iPad, not even with a backup. Keep a copy of the keys you import.
- If you turn off the device's passcode, iOS deletes the keys.

## Add S3 storage

1. In **Servers**, tap **+**, then choose **S3 storage** at the top.
2. Leave **Endpoint** empty for Amazon S3. For other storage, type the address your provider gives, for example
   `https://<account>.r2.cloudflarestorage.com`.
3. **Region** is optional for Amazon S3. Other storage names its own (Cloudflare R2: `auto`).
4. **Bucket** is optional. Type it when your key may not list the buckets.
5. Type the **Access key ID** and the **Secret key**. The secret goes to the Keychain.
6. Tap **Save**. Then tap the storage under **Saved** to open it. Its buckets show in **Files**, with orange folders.

S3 storage keeps files only: it has no terminal and no monitor, and **Zip** doesn't work there.

## Connect without saving

Type `user@host` (or `user@host:port`) in the field at the top of **Servers** and tap **Go**. AirSCP connects without
saving the server. To keep it, swipe left on it under **Open** and tap **Save**.

## Find servers on your network

1. In **Servers**, tap **Nearby** (the radio waves).
2. Macs with Remote Login and many NAS boxes show under **On this network**. Tap one: a new server opens with its address
   filled in. Type your user name and tap **Save**.
3. Not there? Tap **Scan This Network**. AirSCP tries each address of your Wi-Fi or wired network (254 at most) and
   lists those that answer on port 22 (SSH). Tap one to add it.

The first time, iOS asks whether AirSCP may find devices on your local network. Tap **Allow**.

<!-- picture: iphone-nearby; iPhone, portrait; Nearby Servers: two servers on this network, and a finished scan with the addresses that answered -->

## Change, disconnect or delete a server

- Swipe left on a saved server, or touch and hold it: **Edit** or **Delete**. **Delete** forgets the server and its
  saved password at once.
- Swipe left on an open server: **Disconnect**. To change an open server, disconnect it first.
- A server's state shows under its name: **Connecting…**, **Connected** (green), **Reconnecting…** (orange) or
  **Disconnected** (red, with the reason). Tap a disconnected server to connect again.
- When you come back to AirSCP, it checks each open connection. A lost one connects again by itself, or says why it
  can't.

## If something goes wrong

- **“Can't connect”**: the message says why. Check the address, the port and the user name.
- **A server on your network doesn't answer**: in iOS's Settings app, turn on **Privacy & Security ▸ Local Network ▸
  AirSCP**.
- **Nearby finds nothing**: many servers don't announce themselves. Tap **Scan This Network**, or add the server by its
  address.
