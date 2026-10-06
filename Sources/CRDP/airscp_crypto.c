// Argon2 for PuTTY's key files, and a Remote Desktop's company certificate authority: both from the OpenSSL that is
// linked for FreeRDP (scripts/build-freerdp.sh), so AirSCP needs no other crypto library.

#include "airscp_crypto.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include <openssl/bio.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/kdf.h>
#include <openssl/params.h>
#include <openssl/pem.h>
#include <openssl/x509.h>

bool airscp_argon2(int flavour, const uint8_t *password, size_t password_length, const uint8_t *salt,
                   size_t salt_length, uint32_t memory_kib, uint32_t passes, uint32_t lanes, uint8_t *out,
                   size_t out_length) {
    static const char *const names[] = { "ARGON2D", "ARGON2I", "ARGON2ID" };
    if (flavour < 0 || flavour > 2)
        return false;
    EVP_KDF *kdf = EVP_KDF_fetch(NULL, names[flavour], NULL);
    if (!kdf)
        return false;
    EVP_KDF_CTX *context = EVP_KDF_CTX_new(kdf);
    EVP_KDF_free(kdf);
    if (!context)
        return false;
    uint32_t threads = 1, version = 0x13;  // the lanes are computed one after the other
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_PASSWORD, (void *)password, password_length),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_SALT, (void *)salt, salt_length),
        OSSL_PARAM_construct_uint32(OSSL_KDF_PARAM_ITER, &passes),
        OSSL_PARAM_construct_uint32(OSSL_KDF_PARAM_ARGON2_MEMCOST, &memory_kib),
        OSSL_PARAM_construct_uint32(OSSL_KDF_PARAM_ARGON2_LANES, &lanes),
        OSSL_PARAM_construct_uint32(OSSL_KDF_PARAM_THREADS, &threads),
        OSSL_PARAM_construct_uint32(OSSL_KDF_PARAM_ARGON2_VERSION, &version),
        OSSL_PARAM_construct_end(),
    };
    const bool ok = EVP_KDF_derive(context, out, out_length, params) == 1;
    EVP_KDF_CTX_free(context);
    ERR_clear_error();
    return ok;
}

/// Writes `certificate` into `folder` as <subject hash>.<n>, n the first number not taken.
static bool write_hashed(X509 *certificate, const char *folder) {
    const unsigned long hash = X509_NAME_hash_ex(X509_get_subject_name(certificate), NULL, NULL, NULL);
    for (int n = 0; n < 100; n++) {
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s/%08lx.%d", folder, hash, n);
        const int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd < 0) {
            if (errno == EEXIST)
                continue;
            return false;
        }
        BIO *out = BIO_new_fd(fd, BIO_CLOSE);
        if (!out) {
            close(fd);
            return false;
        }
        const bool ok = PEM_write_bio_X509(out, certificate) == 1;
        BIO_free(out);
        return ok;
    }
    return false;
}

int airscp_install_ca(const char *ca_file, const char *folder) {
    if (mkdir(folder, 0700) != 0 && errno != EEXIST)
        return -1;
    DIR *dir = opendir(folder);
    if (!dir)
        return -1;
    for (struct dirent *entry; (entry = readdir(dir));) {
        if (entry->d_name[0] != '.')
            unlinkat(dirfd(dir), entry->d_name, 0);
    }
    closedir(dir);

    BIO *in = BIO_new_file(ca_file, "rb");
    if (!in) {
        ERR_clear_error();
        return -1;
    }
    int count = 0;
    bool failed = false;
    for (X509 *certificate; (certificate = PEM_read_bio_X509(in, NULL, NULL, NULL));) {
        if (write_hashed(certificate, folder))
            count++;
        else
            failed = true;
        X509_free(certificate);
    }
    if (count == 0 && !failed && BIO_reset(in) == 0) {  // not PEM: one certificate in DER (.cer, .crt)
        ERR_clear_error();
        X509 *certificate = d2i_X509_bio(in, NULL);
        if (certificate) {
            if (write_hashed(certificate, folder))
                count++;
            else
                failed = true;
            X509_free(certificate);
        }
    }
    BIO_free(in);
    ERR_clear_error();
    return failed ? -1 : count;
}
