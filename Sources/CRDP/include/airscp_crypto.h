#ifndef AIRSCP_CRYPTO_H
#define AIRSCP_CRYPTO_H

// AirSCP's two uses of the OpenSSL that is linked for FreeRDP (airscp_crypto.c). No OpenSSL headers here, so Swift
// never parses them.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Argon2 version 1.3 with no secret and no associated data, as PuTTY's key files (version 3) use it. flavour: 0
/// Argon2d, 1 Argon2i, 2 Argon2id. False when OpenSSL refuses the parameters.
bool airscp_argon2(int flavour, const uint8_t *password, size_t password_length, const uint8_t *salt,
                   size_t salt_length, uint32_t memory_kib, uint32_t passes, uint32_t lanes, uint8_t *out,
                   size_t out_length);

/// Puts the certificates of `ca_file` (PEM with one or more, or one DER certificate) into `folder`, named as OpenSSL
/// looks them up (<subject hash>.<n>), after removing what was there: FreeRDP verifies a server's certificate with the
/// certificates in <ConfigPath>/certs. Returns how many it put there: 0 when the file holds none, -1 when it can't be
/// read or the folder can't be written.
int airscp_install_ca(const char *ca_file, const char *folder);

#endif
