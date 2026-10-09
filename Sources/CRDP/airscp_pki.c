// The Certificate Manager (PLAN.md AA) over the OpenSSL that is linked for FreeRDP: in process, no openssl command.

#include "airscp_pki.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <openssl/bio.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/objects.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/pkcs7.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

// MARK: Reading

static int report_certificate(X509 *certificate, airscp_pki_found found, void *context) {
    unsigned char *der = NULL;
    int length = i2d_X509(certificate, &der);
    if (length <= 0) return 0;
    int alias_length = 0;
    unsigned char *alias = X509_alias_get0(certificate, &alias_length);
    char name[256] = {0};
    if (alias && alias_length > 0) memcpy(name, alias, alias_length < 255 ? (size_t)alias_length : 255);
    found(AIRSCP_PKI_CERTIFICATE, der, (size_t)length, name[0] ? name : NULL, context);
    OPENSSL_free(der);
    return 1;
}

static int report_key(EVP_PKEY *key, const char *name, airscp_pki_found found, void *context) {
    unsigned char *der = NULL;
    PKCS8_PRIV_KEY_INFO *info = EVP_PKEY2PKCS8(key);
    if (!info) return 0;
    int length = i2d_PKCS8_PRIV_KEY_INFO(info, &der);
    PKCS8_PRIV_KEY_INFO_free(info);
    if (length <= 0) return 0;
    found(AIRSCP_PKI_PRIVATE_KEY, der, (size_t)length, name, context);
    OPENSSL_clear_free(der, (size_t)length);
    return 1;
}

static int report_pkcs7(PKCS7 *pkcs7, airscp_pki_found found, void *context) {
    STACK_OF(X509) *certificates = NULL;
    int type = OBJ_obj2nid(pkcs7->type);
    if (type == NID_pkcs7_signed && pkcs7->d.sign) certificates = pkcs7->d.sign->cert;
    else if (type == NID_pkcs7_signedAndEnveloped && pkcs7->d.signed_and_enveloped) certificates = pkcs7->d.signed_and_enveloped->cert;
    int count = 0;
    for (int i = 0; certificates && i < sk_X509_num(certificates); i++) count += report_certificate(sk_X509_value(certificates, i), found, context);
    return count;
}

static int password_callback(char *buffer, int size, int rwflag, void *user) {
    (void)rwflag;
    const char *password = user;
    if (!password) return -1;
    int length = (int)strlen(password);
    if (length > size) length = size;
    memcpy(buffer, password, (size_t)length);
    return length;
}

static int read_pkcs12(PKCS12 *pkcs12, const char *password, airscp_pki_found found, void *context) {
    EVP_PKEY *key = NULL;
    X509 *certificate = NULL;
    STACK_OF(X509) *chain = NULL;
    // A file without a password may have "" or none at all as its password.
    int parsed = PKCS12_parse(pkcs12, password ? password : "", &key, &certificate, &chain);
    if (!parsed && !password) parsed = PKCS12_parse(pkcs12, NULL, &key, &certificate, &chain);
    if (!parsed) {
        // The password is right but a part is encrypted with a cipher this OpenSSL lacks (RC2-40: openssl -legacy, old
        // Windows exports), else the password is wrong.
        int right = PKCS12_verify_mac(pkcs12, password ? password : "", -1) || (!password && PKCS12_verify_mac(pkcs12, NULL, 0));
        return right ? -3 : -1;
    }
    int count = 0;
    char name[256] = {0};
    if (certificate) {
        int alias_length = 0;
        unsigned char *alias = X509_alias_get0(certificate, &alias_length);
        if (alias && alias_length > 0) memcpy(name, alias, alias_length < 255 ? (size_t)alias_length : 255);
    }
    if (key) count += report_key(key, name[0] ? name : NULL, found, context);
    if (certificate) count += report_certificate(certificate, found, context);
    for (int i = 0; chain && i < sk_X509_num(chain); i++) count += report_certificate(sk_X509_value(chain, i), found, context);
    EVP_PKEY_free(key);
    X509_free(certificate);
    sk_X509_pop_free(chain, X509_free);
    return count;
}

static int read_pem(const uint8_t *data, size_t length, const char *password, airscp_pki_found found, void *context) {
    BIO *bio = BIO_new_mem_buf(data, (int)length);
    if (!bio) return -2;
    int count = 0, blocks = 0, locked = 0;
    char *name = NULL, *header = NULL;
    unsigned char *der = NULL;
    long der_length = 0;
    while (PEM_read_bio(bio, &name, &header, &der, &der_length)) {
        blocks++;
        const unsigned char *p = der;
        if (!strcmp(name, "CERTIFICATE") || !strcmp(name, "X509 CERTIFICATE")) {
            X509 *certificate = d2i_X509(NULL, &p, der_length);
            if (certificate) count += report_certificate(certificate, found, context);
            X509_free(certificate);
        } else if (!strcmp(name, "TRUSTED CERTIFICATE")) {
            X509 *certificate = d2i_X509_AUX(NULL, &p, der_length);
            if (certificate) count += report_certificate(certificate, found, context);
            X509_free(certificate);
        } else if (!strcmp(name, "CERTIFICATE REQUEST") || !strcmp(name, "NEW CERTIFICATE REQUEST")) {
            found(AIRSCP_PKI_REQUEST, der, (size_t)der_length, NULL, context);
            count++;
        } else if (!strcmp(name, "PKCS7")) {
            PKCS7 *pkcs7 = d2i_PKCS7(NULL, &p, der_length);
            if (pkcs7) count += report_pkcs7(pkcs7, found, context);
            PKCS7_free(pkcs7);
        } else if (!strcmp(name, "PUBLIC KEY")) {
            found(AIRSCP_PKI_PUBLIC_KEY, der, (size_t)der_length, NULL, context);
            count++;
        } else if (strstr(name, "PRIVATE KEY")) {
            // Written back as one block and read as a key: OpenSSL then handles every key format and encryption.
            BIO *one = BIO_new(BIO_s_mem());
            PEM_write_bio(one, name, header, der, der_length);
            int encrypted = strstr(name, "ENCRYPTED") || (header && strstr(header, "ENCRYPTED"));
            EVP_PKEY *key = PEM_read_bio_PrivateKey(one, NULL, password_callback, encrypted ? (void *)password : (void *)"");
            BIO_free(one);
            if (key) {
                count += report_key(key, NULL, found, context);
                EVP_PKEY_free(key);
            } else if (encrypted) {
                locked = 1;
            }
        }
        OPENSSL_free(name);
        OPENSSL_free(header);
        OPENSSL_clear_free(der, (size_t)der_length);
        name = NULL;
        header = NULL;
        der = NULL;
    }
    ERR_clear_error();
    BIO_free(bio);
    if (locked) return -1;  // a key it couldn't open: ask for the password (again)
    return blocks == 0 ? -2 : count;
}

int airscp_pki_read(const uint8_t *data, size_t length, const char *password, airscp_pki_found found, void *context) {
    if (!data || length == 0) return -2;
    // PEM text: a BEGIN line somewhere in the first part.
    size_t look = length < 65536 ? length : 65536;
    for (size_t i = 0; i + 11 <= look; i++) {
        if (!memcmp(data + i, "-----BEGIN ", 11)) {
            int count = read_pem(data, length, password, found, context);
            if (count != -2) return count;
            break;
        }
    }
    const unsigned char *p = data;
    PKCS12 *pkcs12 = d2i_PKCS12(NULL, &p, (long)length);
    if (pkcs12) {
        int count = read_pkcs12(pkcs12, password, found, context);
        PKCS12_free(pkcs12);
        ERR_clear_error();
        return count;
    }
    p = data;
    X509 *certificate = d2i_X509(NULL, &p, (long)length);
    if (certificate && p == data + length) {
        int count = report_certificate(certificate, found, context);
        X509_free(certificate);
        return count;
    }
    X509_free(certificate);
    p = data;
    PKCS7 *pkcs7 = d2i_PKCS7(NULL, &p, (long)length);
    if (pkcs7) {
        int count = report_pkcs7(pkcs7, found, context);
        PKCS7_free(pkcs7);
        if (count > 0) return count;
    }
    p = data;
    X509_REQ *request = d2i_X509_REQ(NULL, &p, (long)length);
    if (request && p == data + length) {
        X509_REQ_free(request);
        found(AIRSCP_PKI_REQUEST, data, length, NULL, context);
        return 1;
    }
    X509_REQ_free(request);
    p = data;
    EVP_PKEY *key = d2i_AutoPrivateKey(NULL, &p, (long)length);
    if (key) {
        int count = report_key(key, NULL, found, context);
        EVP_PKEY_free(key);
        return count;
    }
    p = data;
    // An encrypted PKCS#8 key in DER.
    X509_SIG *sealed = d2i_X509_SIG(NULL, &p, (long)length);
    if (sealed && p == data + length) {
        int count = -1;
        if (password) {
            PKCS8_PRIV_KEY_INFO *info = PKCS8_decrypt(sealed, password, (int)strlen(password));
            EVP_PKEY *opened = info ? EVP_PKCS82PKEY(info) : NULL;
            if (opened) count = report_key(opened, NULL, found, context);
            EVP_PKEY_free(opened);
            PKCS8_PRIV_KEY_INFO_free(info);
        }
        X509_SIG_free(sealed);
        ERR_clear_error();
        return count;
    }
    X509_SIG_free(sealed);
    p = data;
    EVP_PKEY *public_key = d2i_PUBKEY(NULL, &p, (long)length);
    if (public_key) {
        EVP_PKEY_free(public_key);
        found(AIRSCP_PKI_PUBLIC_KEY, data, length, NULL, context);
        return 1;
    }
    ERR_clear_error();
    return -2;
}

// MARK: Describing

typedef struct {
    char *text;
    size_t length, capacity;
} Lines;

static void add(Lines *lines, const char *name, const char *value) {
    if (!value) return;
    size_t needed = strlen(name) + strlen(value) + 3;
    if (lines->length + needed > lines->capacity) {
        size_t capacity = (lines->capacity + needed) * 2;
        char *grown = realloc(lines->text, capacity);
        if (!grown) return;
        lines->text = grown;
        lines->capacity = capacity;
    }
    lines->length += (size_t)snprintf(lines->text + lines->length, lines->capacity - lines->length, "%s\t%s\n", name, value);
}

static void add_number(Lines *lines, const char *name, long long value) {
    char text[32];
    snprintf(text, sizeof text, "%lld", value);
    add(lines, name, text);
}

static void add_name(Lines *lines, const char *label, const X509_NAME *name) {
    BIO *bio = BIO_new(BIO_s_mem());
    X509_NAME_print_ex(bio, name, 0, (XN_FLAG_ONELINE & ~ASN1_STRFLGS_ESC_MSB) | ASN1_STRFLGS_UTF8_CONVERT);
    BIO_write(bio, "", 1);
    char *text = NULL;
    BIO_get_mem_data(bio, &text);
    add(lines, label, text);
    BIO_free(bio);
}

static void add_key(Lines *lines, EVP_PKEY *key) {
    if (!key) return;
    const char *type = "unknown";
    switch (EVP_PKEY_get_base_id(key)) {
    case EVP_PKEY_RSA: case EVP_PKEY_RSA_PSS: type = "RSA"; break;
    case EVP_PKEY_EC: type = "EC"; break;
    case EVP_PKEY_ED25519: type = "Ed25519"; break;
    case EVP_PKEY_ED448: type = "Ed448"; break;
    case EVP_PKEY_DSA: type = "DSA"; break;
    }
    add(lines, "keyType", type);
    add_number(lines, "keyBits", EVP_PKEY_get_bits(key));
    char curve[80] = {0};
    size_t curve_length = 0;
    if (EVP_PKEY_get_utf8_string_param(key, OSSL_PKEY_PARAM_GROUP_NAME, curve, sizeof curve, &curve_length)) add(lines, "curve", curve);
}

static void add_san(Lines *lines, GENERAL_NAMES *names) {
    for (int i = 0; names && i < sk_GENERAL_NAME_num(names); i++) {
        const GENERAL_NAME *name = sk_GENERAL_NAME_value(names, i);
        char text[300] = {0};
        if (name->type == GEN_DNS || name->type == GEN_EMAIL || name->type == GEN_URI) {
            const ASN1_IA5STRING *string = name->d.ia5;
            snprintf(text, sizeof text, "%s:%.*s", name->type == GEN_DNS ? "DNS" : name->type == GEN_EMAIL ? "email" : "URI",
                     string->length, (const char *)string->data);
        } else if (name->type == GEN_IPADD) {
            const ASN1_OCTET_STRING *ip = name->d.ip;
            if (ip->length == 4) {
                snprintf(text, sizeof text, "IP:%d.%d.%d.%d", ip->data[0], ip->data[1], ip->data[2], ip->data[3]);
            } else if (ip->length == 16) {
                int at = snprintf(text, sizeof text, "IP:");
                for (int j = 0; j < 16; j += 2) at += snprintf(text + at, sizeof text - (size_t)at, j ? ":%x" : "%x", ip->data[j] << 8 | ip->data[j + 1]);
            }
        }
        if (text[0]) add(lines, "san", text);
    }
}

char *airscp_pki_describe_certificate(const uint8_t *der, size_t length) {
    const unsigned char *p = der;
    X509 *certificate = d2i_X509(NULL, &p, (long)length);
    if (!certificate) return NULL;
    Lines lines = {0};
    add_name(&lines, "subject", X509_get_subject_name(certificate));
    add_name(&lines, "issuer", X509_get_issuer_name(certificate));
    BIGNUM *serial = ASN1_INTEGER_to_BN(X509_get0_serialNumber(certificate), NULL);
    if (serial) {
        char *hex = BN_bn2hex(serial);
        add(&lines, "serial", hex);
        OPENSSL_free(hex);
        BN_free(serial);
    }
    struct tm moment;
    if (ASN1_TIME_to_tm(X509_get0_notBefore(certificate), &moment)) add_number(&lines, "notBefore", (long long)timegm(&moment));
    if (ASN1_TIME_to_tm(X509_get0_notAfter(certificate), &moment)) add_number(&lines, "notAfter", (long long)timegm(&moment));
    GENERAL_NAMES *names = X509_get_ext_d2i(certificate, NID_subject_alt_name, NULL, NULL);
    add_san(&lines, names);
    GENERAL_NAMES_free(names);
    uint32_t usage = X509_get_key_usage(certificate);
    if (usage != UINT32_MAX) {
        static const struct { uint32_t bit; const char *name; } usages[] = {
            {KU_DIGITAL_SIGNATURE, "Digital Signature"}, {KU_NON_REPUDIATION, "Non Repudiation"},
            {KU_KEY_ENCIPHERMENT, "Key Encipherment"}, {KU_DATA_ENCIPHERMENT, "Data Encipherment"},
            {KU_KEY_AGREEMENT, "Key Agreement"}, {KU_KEY_CERT_SIGN, "Certificate Sign"}, {KU_CRL_SIGN, "CRL Sign"},
            {KU_ENCIPHER_ONLY, "Encipher Only"}, {KU_DECIPHER_ONLY, "Decipher Only"}};
        char text[300] = {0};
        for (size_t i = 0; i < sizeof usages / sizeof *usages; i++) {
            if (usage & usages[i].bit) snprintf(text + strlen(text), sizeof text - strlen(text), "%s%s", text[0] ? ", " : "", usages[i].name);
        }
        add(&lines, "keyUsage", text);
    }
    uint32_t extended = X509_get_extended_key_usage(certificate);
    if (extended != UINT32_MAX) {
        static const struct { uint32_t bit; const char *name; } usages[] = {
            {XKU_SSL_SERVER, "TLS Server"}, {XKU_SSL_CLIENT, "TLS Client"}, {XKU_CODE_SIGN, "Code Signing"},
            {XKU_SMIME, "Email Protection"}, {XKU_TIMESTAMP, "Time Stamping"}, {XKU_OCSP_SIGN, "OCSP Signing"},
            {XKU_ANYEKU, "Any"}};
        char text[300] = {0};
        for (size_t i = 0; i < sizeof usages / sizeof *usages; i++) {
            if (extended & usages[i].bit) snprintf(text + strlen(text), sizeof text - strlen(text), "%s%s", text[0] ? ", " : "", usages[i].name);
        }
        add(&lines, "extendedKeyUsage", text);
    }
    add(&lines, "ca", X509_check_ca(certificate) > 0 ? "yes" : "no");
    long path = X509_get_pathlen(certificate);
    if (path >= 0) add_number(&lines, "pathLength", path);
    add(&lines, "signature", OBJ_nid2ln(X509_get_signature_nid(certificate)));
    add_key(&lines, X509_get0_pubkey(certificate));
    add(&lines, "selfIssued", X509_check_issued(certificate, certificate) == X509_V_OK ? "yes" : "no");
    X509_free(certificate);
    ERR_clear_error();
    return lines.text;
}

char *airscp_pki_describe_request(const uint8_t *der, size_t length) {
    const unsigned char *p = der;
    X509_REQ *request = d2i_X509_REQ(NULL, &p, (long)length);
    if (!request) return NULL;
    Lines lines = {0};
    add_name(&lines, "subject", X509_REQ_get_subject_name(request));
    STACK_OF(X509_EXTENSION) *extensions = X509_REQ_get_extensions(request);
    for (int i = 0; extensions && i < sk_X509_EXTENSION_num(extensions); i++) {
        X509_EXTENSION *extension = sk_X509_EXTENSION_value(extensions, i);
        if (OBJ_obj2nid(X509_EXTENSION_get_object(extension)) == NID_subject_alt_name) {
            GENERAL_NAMES *names = X509V3_EXT_d2i(extension);
            add_san(&lines, names);
            GENERAL_NAMES_free(names);
        }
    }
    sk_X509_EXTENSION_pop_free(extensions, X509_EXTENSION_free);
    add(&lines, "signature", OBJ_nid2ln(X509_REQ_get_signature_nid(request)));
    EVP_PKEY *key = X509_REQ_get0_pubkey(request);
    add_key(&lines, key);
    add(&lines, "verified", key && X509_REQ_verify(request, key) == 1 ? "yes" : "no");
    X509_REQ_free(request);
    ERR_clear_error();
    return lines.text;
}

static EVP_PKEY *load_key(int kind, const uint8_t *der, size_t length) {
    const unsigned char *p = der;
    if (kind == AIRSCP_PKI_PRIVATE_KEY) return d2i_AutoPrivateKey(NULL, &p, (long)length);
    if (kind == AIRSCP_PKI_PUBLIC_KEY) return d2i_PUBKEY(NULL, &p, (long)length);
    return NULL;
}

char *airscp_pki_describe_key(int kind, const uint8_t *der, size_t length) {
    EVP_PKEY *key = load_key(kind, der, length);
    if (!key) return NULL;
    Lines lines = {0};
    add_key(&lines, key);
    EVP_PKEY_free(key);
    return lines.text;
}

uint8_t *airscp_pki_public_key(int kind, const uint8_t *der, size_t length, size_t *out_length) {
    EVP_PKEY *key = NULL;
    const unsigned char *p = der;
    if (kind == AIRSCP_PKI_CERTIFICATE) {
        X509 *certificate = d2i_X509(NULL, &p, (long)length);
        if (certificate) key = EVP_PKEY_dup(X509_get0_pubkey(certificate));
        X509_free(certificate);
    } else if (kind == AIRSCP_PKI_REQUEST) {
        X509_REQ *request = d2i_X509_REQ(NULL, &p, (long)length);
        if (request) key = EVP_PKEY_dup(X509_REQ_get0_pubkey(request));
        X509_REQ_free(request);
    } else {
        key = load_key(kind, der, length);
    }
    if (!key) return NULL;
    unsigned char *out = NULL;
    int written = i2d_PUBKEY(key, &out);
    EVP_PKEY_free(key);
    if (written <= 0) return NULL;
    uint8_t *copy = malloc((size_t)written);
    if (copy) memcpy(copy, out, (size_t)written);
    OPENSSL_free(out);
    *out_length = (size_t)written;
    return copy;
}

// MARK: Writing

uint8_t *airscp_pki_pkcs12(const uint8_t *key, size_t key_length, const uint8_t *certificate, size_t certificate_length,
                           const uint8_t *const *chain, const size_t *chain_lengths, int chain_count, const char *name,
                           const char *password, int legacy, size_t *out_length) {
    EVP_PKEY *private_key = key ? load_key(AIRSCP_PKI_PRIVATE_KEY, key, key_length) : NULL;
    const unsigned char *p = certificate;
    X509 *leaf = certificate ? d2i_X509(NULL, &p, (long)certificate_length) : NULL;
    STACK_OF(X509) *others = sk_X509_new_null();
    for (int i = 0; i < chain_count; i++) {
        p = chain[i];
        X509 *one = d2i_X509(NULL, &p, (long)chain_lengths[i]);
        if (one) sk_X509_push(others, one);
    }
    uint8_t *result = NULL;
    if ((key && !private_key) || (certificate && !leaf)) goto done;
    // Modern: AES-256-CBC with PBKDF2 and a SHA-256 MAC. Legacy: 3DES (and RC2-free 3DES for certificates) with SHA-1.
    int key_cipher = legacy ? NID_pbe_WithSHA1And3_Key_TripleDES_CBC : NID_aes_256_cbc;
    int cert_cipher = legacy ? NID_pbe_WithSHA1And3_Key_TripleDES_CBC : NID_aes_256_cbc;
    PKCS12 *pkcs12 = PKCS12_create_ex(password, name, private_key, leaf, sk_X509_num(others) ? others : NULL, key_cipher,
                                      cert_cipher, 2048, -1, 0, NULL, NULL);
    if (!pkcs12) goto done;
    if (!legacy) PKCS12_set_mac(pkcs12, password, -1, NULL, 0, 2048, EVP_sha256());
    unsigned char *der = NULL;
    int written = i2d_PKCS12(pkcs12, &der);
    PKCS12_free(pkcs12);
    if (written > 0 && (result = malloc((size_t)written))) {
        memcpy(result, der, (size_t)written);
        *out_length = (size_t)written;
    }
    OPENSSL_free(der);
done:
    EVP_PKEY_free(private_key);
    X509_free(leaf);
    sk_X509_pop_free(others, X509_free);
    ERR_clear_error();
    return result;
}

char *airscp_pki_key_pem(const uint8_t *key, size_t length, const char *passphrase, int traditional) {
    EVP_PKEY *private_key = load_key(AIRSCP_PKI_PRIVATE_KEY, key, length);
    if (!private_key) return NULL;
    BIO *bio = BIO_new(BIO_s_mem());
    int ok;
    if (passphrase && passphrase[0]) {
        ok = PEM_write_bio_PKCS8PrivateKey(bio, private_key, EVP_aes_256_cbc(), passphrase, (int)strlen(passphrase), NULL, NULL);
    } else if (traditional) {
        ok = PEM_write_bio_PrivateKey_traditional(bio, private_key, NULL, NULL, 0, NULL, NULL);
    } else {
        ok = PEM_write_bio_PKCS8PrivateKey(bio, private_key, NULL, NULL, 0, NULL, NULL);
    }
    EVP_PKEY_free(private_key);
    char *result = NULL;
    if (ok) {
        char *text = NULL;
        long size = BIO_get_mem_data(bio, &text);
        if ((result = malloc((size_t)size + 1))) {
            memcpy(result, text, (size_t)size);
            result[size] = 0;
        }
    }
    BIO_free(bio);
    ERR_clear_error();
    return result;
}

int airscp_pki_signed_by(const uint8_t *der, size_t length, const uint8_t *issuer, size_t issuer_length) {
    const unsigned char *p = der;
    X509 *certificate = d2i_X509(NULL, &p, (long)length);
    p = issuer;
    X509 *signer = d2i_X509(NULL, &p, (long)issuer_length);
    int result = -1;
    if (certificate && signer) result = X509_verify(certificate, X509_get0_pubkey(signer)) == 1 ? 1 : 0;
    X509_free(certificate);
    X509_free(signer);
    ERR_clear_error();
    return result;
}

void airscp_pki_free(void *pointer) { free(pointer); }
