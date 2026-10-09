---
title: See a server's certificate
parent: Certificates and keystores
nav_order: 3
---

# See a server's certificate

Check what certificate a website, LDAP or mail server sends, and whether this Mac trusts it.

## Steps

1. Choose **Tools ▸ View Server Certificate…** (or click **Server…** in the Certificate Manager).
2. Type the server, with its port when it isn't 443: `example.com`, `ldap.example.com:636`, `mail.example.com:465`.
3. Click **View**.

The server's certificates appear in the list, its own first, with a line that says whether this Mac trusts them for
that name, and why not.

## Tips

- Only the TLS handshake happens: nothing else is sent to the server.
- Save the server's certificates like any other: for example **Save Chain…** to give a Java truststore the server's
  CA.
- The command shown is `openssl s_client`, to look again from a server that has openssl.

## If something goes wrong

- **“Can't get the certificate”**: the server isn't reachable from this Mac on that port, or it doesn't speak TLS
  there (STARTTLS ports such as 25 and 587 start in plain text and aren't read).
- It stays at **“Connecting…”**: a firewall app on this Mac (such as LuLu or Little Snitch) may be asking whether
  AirSCP may connect. Allow it.
