---
title: Open and check certificates
parent: Certificates and keystores
nav_order: 1
---

# Open and check certificates

## Steps

1. Choose **Tools ▸ Certificate Manager…**.
2. Click **Open…**, or drop files on the window. It reads:
   - certificates: `.pem`, `.crt`, `.cer`, `.der`, one or many in a file;
   - chains: `.p7b`, `.p7c`;
   - PKCS#12: `.p12`, `.pfx`;
   - Java keystores: `.jks`;
   - private keys (RSA, EC, Ed25519; PKCS#1, SEC1, PKCS#8, encrypted or not), public keys and certificate requests.
3. A file with a password (PKCS#12, a keystore, an encrypted key) asks for it.
4. Select an item in the list to see its details.

## What the details show

- **Subject** and **Issuer**: who the certificate is for, and who signed it.
- **Names (SAN)**: the host names and addresses it is valid for.
- **Valid until**: orange when it expires within 30 days, red once it has expired. The list's icons use the same
  colours.
- **Key usage**, **Extended key usage** and **Certificate authority**: what the certificate may be used for.
- **Private key**: whether a key that goes with it is open. A key's line says which certificate it goes with.
- **Issued by (open)**: the certificate that signed it, when that one is open too. The list shows each file's
  certificates in chain order, the server's own first.
- **SHA-256** and **SHA-1**: fingerprints, to compare with what someone sent you.

## Tips

- Open the certificate, its key and the CA's certificate together: AirSCP matches them, and can then make a chain or a
  PKCS#12 file. See [Convert and export](convert-and-export.md).
- **Close File** takes a file out of the list. The file itself stays where it is.

## If something goes wrong

- **“That password didn't open it”**: check the password; PKCS#12 passwords are case-sensitive.
- **“The key … has a password of its own”**: in a Java keystore, a key can have another password than the store.
  Type the key's password.
- **“AirSCP doesn't read RC2-40 encryption”**: the file was made with `openssl pkcs12 -legacy` or by an old Windows.
  Export it again with AES or 3DES.
- **“AirSCP doesn't read JCEKS”**: convert the keystore to PKCS#12 with `keytool -importkeystore`.
