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
- **Public Key…**: only its public key.
- **PKCS#12…**: the certificate, its private key and its chain in one file protected by a password (`.p12`, `.pfx`).
  Open the certificate's private key first.
- **JKS…**: the same in a Java keystore (`.jks`), for Java 8 and older. Newer Java reads PKCS#12 too.
- **Truststore…**: see [Make a truststore](#make-a-truststore).

## For a private key

- **Save Key…**: as PEM. Type a passphrase to encrypt it (AES-256), or leave it empty. **Traditional format** writes
  `BEGIN RSA PRIVATE KEY` (or `EC`) for older software.
- **PKCS#12…** and **JKS…**: the key with its certificate, when that is open.

## PKCS#12 options

- **Friendly name**: the name Windows and keystores show for the entry. Optional.
- **Compatible with older systems**: 3DES and SHA-1 instead of AES-256 and SHA-256. Only for Java 8 or Windows before
  2019, which can't open the modern file.

A Java keystore has an **Alias** (the entry's name, in lower case) and a **Password**, which protects the file and the
key in it.

## Convert between JKS and PKCS#12

1. Open the keystore and type its password.
2. Select the private key (or its certificate).
3. Click **PKCS#12…** to make a PKCS#12 file, or **JKS…** to make a Java keystore.

## Make a truststore

A truststore lists the certificate authorities an app trusts, such as a Java app's truststore.

1. Open the CA certificates the app should trust. A keystore or a bundle works too.
2. Select one of them and click **Truststore…**.
3. Tick the certificates that go in. CA certificates are ticked already.
4. Choose **PKCS#12 (.p12)** or **Java keystore (.jks)**, and type a password.
5. Click **Save…**.

Each entry is named after its certificate's common name. To add a certificate that isn't in the list, open its file
first.

## Tips

- Saved keys, PKCS#12 files and keystores are readable by you only.
- The line at the bottom shows the `openssl` or `keytool` command that makes the same file. **Copy Command** copies it.
