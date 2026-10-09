#ifndef AIRSCP_PKI_H
#define AIRSCP_PKI_H

// The Certificate Manager's use of the OpenSSL linked for FreeRDP (airscp_pki.c, PLAN.md AA): reading certificates,
// keys, requests and their containers, describing them, and writing PKCS#12 files and keys. No OpenSSL headers here.

#include <stddef.h>
#include <stdint.h>

/// What `airscp_pki_read` finds.
enum { AIRSCP_PKI_CERTIFICATE = 1, AIRSCP_PKI_PRIVATE_KEY = 2, AIRSCP_PKI_REQUEST = 3, AIRSCP_PKI_PUBLIC_KEY = 4 };

/// Called for each item: its kind, its DER (a private key as unencrypted PKCS#8, a public key as SubjectPublicKeyInfo)
/// and a name it had (a PKCS#12 friendly name; NULL without one).
typedef void (*airscp_pki_found)(int kind, const uint8_t *der, size_t length, const char *name, void *context);

/// Reads PEM text (one or more blocks of certificates, chains, PKCS#7, requests, keys: PKCS#1, SEC1, PKCS#8,
/// encrypted or not), DER (a certificate, PKCS#7, a request, a key) or PKCS#12 with `password` (NULL: none). Returns
/// how many items it found, -1 when a password is needed or wrong, -2 when it isn't a format it knows, -3 when the
/// password is right but the PKCS#12 file uses a cipher that isn't here (RC2: openssl -legacy, old Windows exports).
int airscp_pki_read(const uint8_t *data, size_t length, const char *password, airscp_pki_found found, void *context);

/// A certificate (DER) as "name\tvalue" lines: subject, issuer, serial, notBefore, notAfter (seconds since 1970),
/// san (one line each), keyUsage, extendedKeyUsage, ca (yes/no), pathLength, signature, keyType, keyBits, curve.
/// NULL when it can't be read. Free it with airscp_pki_free.
char *airscp_pki_describe_certificate(const uint8_t *der, size_t length);

/// A request (DER) as "name\tvalue" lines: subject, san, signature, keyType, keyBits, curve, verified (yes/no).
char *airscp_pki_describe_request(const uint8_t *der, size_t length);

/// A key (PKCS#8 or SubjectPublicKeyInfo DER, by `kind`) as "name\tvalue" lines: keyType, keyBits, curve.
char *airscp_pki_describe_key(int kind, const uint8_t *der, size_t length);

/// The SubjectPublicKeyInfo (DER) of a certificate, request or key, NULL when it can't be read. `*out_length` its size.
uint8_t *airscp_pki_public_key(int kind, const uint8_t *der, size_t length, size_t *out_length);

/// A PKCS#12 file: the key (PKCS#8 DER, may be NULL), its certificate and the chain (DER), the friendly name (may be
/// NULL) and its password. `legacy`: 3DES and SHA-1 (old Java and Windows), else AES-256 and SHA-256.
uint8_t *airscp_pki_pkcs12(const uint8_t *key, size_t key_length, const uint8_t *certificate, size_t certificate_length,
                           const uint8_t *const *chain, const size_t *chain_lengths, int chain_count, const char *name,
                           const char *password, int legacy, size_t *out_length);

/// A private key (PKCS#8 DER) as PEM: PKCS#8 encrypted with AES-256 when `passphrase` isn't empty, else unencrypted
/// PKCS#8, or (traditional) PKCS#1 for RSA and SEC1 for EC keys. NULL when it can't be written.
char *airscp_pki_key_pem(const uint8_t *key, size_t length, const char *passphrase, int traditional);

/// Whether `der` (a certificate, DER) was signed by `issuer`'s key: 1 yes, 0 no, -1 can't tell.
int airscp_pki_signed_by(const uint8_t *der, size_t length, const uint8_t *issuer, size_t issuer_length);

void airscp_pki_free(void *pointer);

#endif
