---
title: Certificates and keystores
nav_order: 12
has_children: true
---

# Certificates and keystores

**Tools ▸ Certificate Manager…** does the everyday certificate work without `openssl` or `keytool` commands. Open a
certificate, key or keystore, see what is in it and when it expires, and save it in the format another system wants.
Everything happens on this Mac.

## Pages

- [Open and check certificates](open-and-check.md): details, expiry, which key goes with which certificate.
- [Convert and export](convert-and-export.md): PEM, DER, the chain, keys, PKCS#12.
- [See a server's certificate](server-certificate.md): what an HTTPS, LDAPS or mail server sends.

## Tips

- After each action AirSCP shows the `openssl` (or `keytool`) command that does the same. **Copy Command** puts it on
  the clipboard, to reuse it on a server.
- **Tools ▸ New Key Pair…** and **Tools ▸ Import PuTTY Key…** open the [Keys](../keys/index.md) window for SSH keys.
