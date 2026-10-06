#include "vault_crypto.h"
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <gnutls/abstract.h>
#include <gnutls/x509.h>

typedef struct {
    guint8 *data;
    gsize size;
} VaultBuffer;

static void
vault_buffer_free (gpointer pointer)
{
    VaultBuffer *buffer = pointer;
    gnutls_memset (buffer->data, 0, buffer->size);
    g_free (buffer->data);
    g_free (buffer);
}

static GBytes *
vault_buffer_take (guint8 *data, gsize size)
{
    VaultBuffer *buffer = g_new (VaultBuffer, 1);
    buffer->data = data;
    buffer->size = size;
    return g_bytes_new_with_free_func (data, size, vault_buffer_free, buffer);
}

GBytes *
browser_vault_random (guint length)
{
    if (length == 0 || length > 4096)
        return NULL;
    guint8 *data = g_malloc (length);
    if (gnutls_rnd (GNUTLS_RND_KEY, data, length) < 0) {
        g_free (data);
        return NULL;
    }
    return vault_buffer_take (data, length);
}

GBytes *
browser_vault_authenticate (GBytes *key, GBytes *data)
{
    if (!key || !data || g_bytes_get_size (key) < 16 || g_bytes_get_size (key) > 4096 ||
        g_bytes_get_size (data) > 32 * 1024 * 1024)
        return NULL;
    guint8 *output = g_malloc (32);
    if (gnutls_hmac_fast (GNUTLS_MAC_SHA256, g_bytes_get_data (key, NULL), g_bytes_get_size (key),
                         g_bytes_get_data (data, NULL), g_bytes_get_size (data), output) < 0) {
        gnutls_memset (output, 0, 32);
        g_free (output);
        return NULL;
    }
    return vault_buffer_take (output, 32);
}

GBytes *
browser_vault_derive (GBytes *key, GBytes *salt, GBytes *info)
{
    if (!key || !salt || !info || g_bytes_get_size (key) != 32 ||
        g_bytes_get_size (salt) > 4096 || g_bytes_get_size (info) > 4096)
        return NULL;
    gnutls_datum_t input = { (guint8 *) g_bytes_get_data (key, NULL), 32 };
    gnutls_datum_t s = { (guint8 *) g_bytes_get_data (salt, NULL), (guint) g_bytes_get_size (salt) };
    gnutls_datum_t context = { (guint8 *) g_bytes_get_data (info, NULL), (guint) g_bytes_get_size (info) };
    guint8 extracted[32];
    guint8 *output = g_malloc (32);
    int rc = gnutls_hkdf_extract (GNUTLS_MAC_SHA256, &input, &s, extracted);
    if (rc == 0) {
        gnutls_datum_t prk = { extracted, 32 };
        rc = gnutls_hkdf_expand (GNUTLS_MAC_SHA256, &prk, &context, output, 32);
    }
    gnutls_memset (extracted, 0, sizeof extracted);
    if (rc < 0) {
        gnutls_memset (output, 0, 32);
        g_free (output);
        return NULL;
    }
    return vault_buffer_take (output, 32);
}

static GBytes *
vault_cipher (GBytes *key, GBytes *nonce, GBytes *header, GBytes *input, gboolean decrypt)
{
    if (!key || !nonce || !header || !input || g_bytes_get_size (key) != 32 ||
        g_bytes_get_size (nonce) != 12 || g_bytes_get_size (header) > 4096 ||
        g_bytes_get_size (input) > 32 * 1024 * 1024 ||
        (decrypt && g_bytes_get_size (input) < 16))
        return NULL;
    gnutls_datum_t k = { (guint8 *) g_bytes_get_data (key, NULL), 32 };
    gnutls_aead_cipher_hd_t handle;
    if (gnutls_aead_cipher_init (&handle, GNUTLS_CIPHER_AES_256_GCM, &k) < 0)
        return NULL;
    gsize allocated = g_bytes_get_size (input) + 16;
    guint8 *output = g_malloc (allocated);
    size_t length = allocated;
    int rc;
    if (decrypt)
        rc = gnutls_aead_cipher_decrypt (handle, g_bytes_get_data (nonce, NULL), 12,
            g_bytes_get_data (header, NULL), g_bytes_get_size (header), 16,
            g_bytes_get_data (input, NULL), g_bytes_get_size (input), output, &length);
    else
        rc = gnutls_aead_cipher_encrypt (handle, g_bytes_get_data (nonce, NULL), 12,
            g_bytes_get_data (header, NULL), g_bytes_get_size (header), 16,
            g_bytes_get_data (input, NULL), g_bytes_get_size (input), output, &length);
    gnutls_aead_cipher_deinit (handle);
    if (rc < 0) {
        gnutls_memset (output, 0, allocated);
        g_free (output);
        return NULL;
    }
    return vault_buffer_take (output, length);
}

GBytes *
browser_vault_seal (GBytes *key, GBytes *nonce, GBytes *header, GBytes *plain)
{
    return vault_cipher (key, nonce, header, plain, FALSE);
}

GBytes *
browser_vault_open (GBytes *key, GBytes *nonce, GBytes *header, GBytes *sealed)
{
    return vault_cipher (key, nonce, header, sealed, TRUE);
}

static GBytes *
vault_datum_take (gnutls_datum_t *datum)
{
    GBytes *result = vault_buffer_take (g_memdup2 (datum->data, datum->size), datum->size);
    gnutls_memset (datum->data, 0, datum->size);
    gnutls_free (datum->data);
    return result;
}

static GBytes *
vault_key_generate (gnutls_pk_algorithm_t algorithm, gnutls_ecc_curve_t curve)
{
    gnutls_x509_privkey_t key;
    if (gnutls_x509_privkey_init (&key) < 0)
        return NULL;
    int rc = gnutls_x509_privkey_generate (key, algorithm, GNUTLS_CURVE_TO_BITS (curve), 0);
    gnutls_datum_t exported = { NULL, 0 };
    if (rc == 0)
        rc = gnutls_x509_privkey_export2_pkcs8 (key, GNUTLS_X509_FMT_DER, NULL, GNUTLS_PKCS_PLAIN, &exported);
    gnutls_x509_privkey_deinit (key);
    return rc < 0 ? NULL : vault_datum_take (&exported);
}

GBytes *
browser_vault_signing_key (void)
{
    return vault_key_generate (GNUTLS_PK_EDDSA_ED25519, GNUTLS_ECC_CURVE_ED25519);
}

GBytes *
browser_vault_exchange_key (void)
{
    return vault_key_generate (GNUTLS_PK_ECDH_X25519, GNUTLS_ECC_CURVE_X25519);
}

static gnutls_privkey_t
vault_key_import (GBytes *bytes, gnutls_pk_algorithm_t algorithm)
{
    if (!bytes || g_bytes_get_size (bytes) == 0 || g_bytes_get_size (bytes) > 4096)
        return NULL;
    gnutls_privkey_t key;
    if (gnutls_privkey_init (&key) < 0)
        return NULL;
    gnutls_datum_t raw = { (guint8 *) g_bytes_get_data (bytes, NULL), (guint) g_bytes_get_size (bytes) };
    if (gnutls_privkey_import_x509_raw (key, &raw, GNUTLS_X509_FMT_DER, NULL, 0) < 0 ||
        gnutls_privkey_get_pk_algorithm (key, NULL) != algorithm) {
        gnutls_privkey_deinit (key);
        return NULL;
    }
    return key;
}

static GBytes *
vault_public_key (GBytes *bytes, gnutls_pk_algorithm_t algorithm)
{
    gnutls_privkey_t key = vault_key_import (bytes, algorithm);
    if (!key)
        return NULL;
    gnutls_pubkey_t public_key;
    int rc = gnutls_pubkey_init (&public_key);
    gnutls_datum_t exported = { NULL, 0 };
    if (rc == 0) {
        rc = gnutls_pubkey_import_privkey (public_key, key, 0, 0);
        if (rc == 0)
            rc = gnutls_pubkey_export2 (public_key, GNUTLS_X509_FMT_DER, &exported);
        gnutls_pubkey_deinit (public_key);
    }
    gnutls_privkey_deinit (key);
    return rc < 0 ? NULL : vault_datum_take (&exported);
}

GBytes *
browser_vault_public_key (GBytes *bytes)
{
    return vault_public_key (bytes, GNUTLS_PK_EDDSA_ED25519);
}

GBytes *
browser_vault_exchange_public (GBytes *bytes)
{
    return vault_public_key (bytes, GNUTLS_PK_ECDH_X25519);
}

GBytes *
browser_vault_exchange (GBytes *bytes, GBytes *peer)
{
    if (!peer || g_bytes_get_size (peer) == 0 || g_bytes_get_size (peer) > 4096)
        return NULL;
    gnutls_privkey_t key = vault_key_import (bytes, GNUTLS_PK_ECDH_X25519);
    if (!key)
        return NULL;
    gnutls_pubkey_t public_key;
    int rc = gnutls_pubkey_init (&public_key);
    gnutls_datum_t secret = { NULL, 0 };
    if (rc == 0) {
        gnutls_datum_t raw = { (guint8 *) g_bytes_get_data (peer, NULL), (guint) g_bytes_get_size (peer) };
        rc = gnutls_pubkey_import (public_key, &raw, GNUTLS_X509_FMT_DER);
        if (rc == 0 && gnutls_pubkey_get_pk_algorithm (public_key, NULL) == GNUTLS_PK_ECDH_X25519)
            rc = gnutls_privkey_derive_secret (key, public_key, NULL, &secret, 0);
        else
            rc = GNUTLS_E_INVALID_REQUEST;
        gnutls_pubkey_deinit (public_key);
    }
    gnutls_privkey_deinit (key);
    guint8 zero[32] = { 0 };
    if (rc < 0 || secret.size != 32 || gnutls_memcmp (secret.data, zero, 32) == 0) {
        if (secret.data) {
            gnutls_memset (secret.data, 0, secret.size);
            gnutls_free (secret.data);
        }
        return NULL;
    }
    return vault_datum_take (&secret);
}

GBytes *
browser_vault_sign (GBytes *bytes, GBytes *data)
{
    if (!data || g_bytes_get_size (data) > 32 * 1024 * 1024)
        return NULL;
    gnutls_privkey_t key = vault_key_import (bytes, GNUTLS_PK_EDDSA_ED25519);
    if (!key)
        return NULL;
    gnutls_datum_t raw = { (guint8 *) g_bytes_get_data (data, NULL), (guint) g_bytes_get_size (data) };
    gnutls_datum_t signature = { NULL, 0 };
    int rc = gnutls_privkey_sign_data2 (key, GNUTLS_SIGN_EDDSA_ED25519, 0, &raw, &signature);
    gnutls_privkey_deinit (key);
    return rc < 0 ? NULL : vault_datum_take (&signature);
}

gboolean
browser_vault_verify (GBytes *bytes, GBytes *data, GBytes *signature)
{
    if (!bytes || !data || !signature || g_bytes_get_size (bytes) == 0 ||
        g_bytes_get_size (bytes) > 4096 || g_bytes_get_size (data) > 32 * 1024 * 1024 ||
        g_bytes_get_size (signature) != 64)
        return FALSE;
    gnutls_pubkey_t key;
    if (gnutls_pubkey_init (&key) < 0)
        return FALSE;
    gnutls_datum_t encoded = { (guint8 *) g_bytes_get_data (bytes, NULL), (guint) g_bytes_get_size (bytes) };
    gnutls_datum_t raw = { (guint8 *) g_bytes_get_data (data, NULL), (guint) g_bytes_get_size (data) };
    gnutls_datum_t signed_data = { (guint8 *) g_bytes_get_data (signature, NULL), 64 };
    int rc = gnutls_pubkey_import (key, &encoded, GNUTLS_X509_FMT_DER);
    if (rc == 0 && gnutls_pubkey_get_pk_algorithm (key, NULL) == GNUTLS_PK_EDDSA_ED25519)
        rc = gnutls_pubkey_verify_data2 (key, GNUTLS_SIGN_EDDSA_ED25519, 0, &raw, &signed_data);
    else
        rc = GNUTLS_E_INVALID_REQUEST;
    gnutls_pubkey_deinit (key);
    return rc == 0;
}
