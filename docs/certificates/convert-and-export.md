---
title: Convert and export
parent: Certificates and keystores
nav_order: 2
---

# Convert and export

Select an item in the Certificate Manager, then use the buttons below its details. Each asks where to save.

## For a certificate

- **Save PEM…**: Base64 text (`.pem`, `.crt`), what most Linux servers and tools want.
- **Save DER…**: binary (`.cer`, `.der`), for Windows and Java.
- **Save Chain…**: the certificate followed by its issuers (those open in the window), in one PEM file, as web servers
  such as nginx want.
- **PKCS#12…**: the certificate, its private key and its chain in one file protected by a password (`.p12`, `.pfx`).
  Open the certificate's private key first.
- **Public Key…**: only its public key.

## For a private key

- **Save Key…**: as PEM. Type a passphrase to encrypt it (AES-256), or leave it empty. **Traditional format** writes
  `BEGIN RSA PRIVATE KEY` (or `EC`) for older software.
- **PKCS#12…**: the key with its certificate, when that is open.

## PKCS#12 options

- **Friendly name**: the name Windows and keystores show for the entry. Optional.
- **Compatible with older systems**: 3DES and SHA-1 instead of AES-256 and SHA-256. Only for Java 8 or Windows before
  2019, which can't open the modern file.

## Tips

- Saved keys and PKCS#12 files are readable by you only.
- The line at the bottom shows the `openssl` command that makes the same file. **Copy Command** copies it.
