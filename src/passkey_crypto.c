#include "passkey_crypto.h"
#include <string.h>
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <gnutls/abstract.h>
#include <gnutls/x509.h>

static void
passkey_free (gpointer data)
{
    gnutls_free (data);
}

static GBytes *
passkey_take (gnutls_datum_t *datum)
{
    return g_bytes_new_with_free_func (datum->data, datum->size, passkey_free, datum->data);
}

GBytes *
browser_passkey_random (guint length)
{
    if (length == 0 || length > 4096)
        return NULL;
    guint8 *data = g_malloc (length);
    if (gnutls_rnd (GNUTLS_RND_KEY, data, length) < 0) {
        g_free (data);
        return NULL;
    }
    return g_bytes_new_take (data, length);
}

GBytes *
browser_passkey_generate (void)
{
    gnutls_x509_privkey_t key;
    if (gnutls_x509_privkey_init (&key) < 0)
        return NULL;
    int rc = gnutls_x509_privkey_generate (key, GNUTLS_PK_ECDSA, GNUTLS_CURVE_TO_BITS (GNUTLS_ECC_CURVE_SECP256R1), 0);
    gnutls_datum_t exported = { NULL, 0 };
    if (rc == 0)
        rc = gnutls_x509_privkey_export2_pkcs8 (key, GNUTLS_X509_FMT_DER, NULL, GNUTLS_PKCS_PLAIN, &exported);
    gnutls_x509_privkey_deinit (key);
    return rc < 0 ? NULL : passkey_take (&exported);
}

static gnutls_privkey_t
passkey_import (GBytes *bytes)
{
    if (!bytes || g_bytes_get_size (bytes) == 0 || g_bytes_get_size (bytes) > 4096)
        return NULL;
    gnutls_privkey_t key;
    if (gnutls_privkey_init (&key) < 0)
        return NULL;
    gnutls_datum_t raw = { (guint8 *) g_bytes_get_data (bytes, NULL), (guint) g_bytes_get_size (bytes) };
    if (gnutls_privkey_import_x509_raw (key, &raw, GNUTLS_X509_FMT_DER, NULL, 0) < 0 ||
        gnutls_privkey_get_pk_algorithm (key, NULL) != GNUTLS_PK_ECDSA) {
        gnutls_privkey_deinit (key);
        return NULL;
    }
    return key;
}

static gnutls_pubkey_t
passkey_public (GBytes *bytes)
{
    gnutls_privkey_t key = passkey_import (bytes);
    if (!key)
        return NULL;
    gnutls_pubkey_t public_key;
    if (gnutls_pubkey_init (&public_key) < 0) {
        gnutls_privkey_deinit (key);
        return NULL;
    }
    int rc = gnutls_pubkey_import_privkey (public_key, key, 0, 0);
    gnutls_privkey_deinit (key);
    if (rc < 0) {
        gnutls_pubkey_deinit (public_key);
        return NULL;
    }
    return public_key;
}

static void
passkey_pad (guint8 *out, const gnutls_datum_t *value)
{
    memset (out, 0, 32);
    guint size = value->size;
    const guint8 *data = value->data;
    while (size > 32 && *data == 0) {
        data++;
        size--;
    }
    if (size <= 32)
        memcpy (out + 32 - size, data, size);
}

GBytes *
browser_passkey_public_point (GBytes *bytes)
{
    gnutls_pubkey_t public_key = passkey_public (bytes);
    if (!public_key)
        return NULL;
    gnutls_ecc_curve_t curve;
    gnutls_datum_t x = { NULL, 0 }, y = { NULL, 0 };
    int rc = gnutls_pubkey_export_ecc_raw2 (public_key, &curve, &x, &y, 0);
    gnutls_pubkey_deinit (public_key);
    if (rc < 0 || curve != GNUTLS_ECC_CURVE_SECP256R1) {
        gnutls_free (x.data);
        gnutls_free (y.data);
        return NULL;
    }
    guint8 *point = g_malloc (64);
    passkey_pad (point, &x);
    passkey_pad (point + 32, &y);
    gnutls_free (x.data);
    gnutls_free (y.data);
    return g_bytes_new_take (point, 64);
}

GBytes *
browser_passkey_public_der (GBytes *bytes)
{
    gnutls_pubkey_t public_key = passkey_public (bytes);
    if (!public_key)
        return NULL;
    gnutls_datum_t exported = { NULL, 0 };
    int rc = gnutls_pubkey_export2 (public_key, GNUTLS_X509_FMT_DER, &exported);
    gnutls_pubkey_deinit (public_key);
    return rc < 0 ? NULL : passkey_take (&exported);
}

GBytes *
browser_passkey_sign (GBytes *bytes, GBytes *data)
{
    if (!data || g_bytes_get_size (data) > 1024 * 1024)
        return NULL;
    gnutls_privkey_t key = passkey_import (bytes);
    if (!key)
        return NULL;
    gnutls_datum_t raw = { (guint8 *) g_bytes_get_data (data, NULL), (guint) g_bytes_get_size (data) };
    gnutls_datum_t signature = { NULL, 0 };
    int rc = gnutls_privkey_sign_data2 (key, GNUTLS_SIGN_ECDSA_SHA256, 0, &raw, &signature);
    gnutls_privkey_deinit (key);
    return rc < 0 ? NULL : passkey_take (&signature);
}

GBytes *
browser_passkey_digest (GBytes *data)
{
    guint8 *out = g_malloc (32);
    gsize size = 0;
    const guint8 *raw = data ? g_bytes_get_data (data, &size) : NULL;
    if (gnutls_hash_fast (GNUTLS_DIG_SHA256, raw ? raw : (const guint8 *) "", size, out) < 0) {
        g_free (out);
        return NULL;
    }
    return g_bytes_new_take (out, 32);
}

gboolean
browser_passkey_verify (GBytes *point, GBytes *data, GBytes *signature)
{
    if (!point || g_bytes_get_size (point) != 64 || !data || !signature)
        return FALSE;
    const guint8 *p = g_bytes_get_data (point, NULL);
    gnutls_datum_t x = { (guint8 *) p, 32 }, y = { (guint8 *) p + 32, 32 };
    gnutls_pubkey_t public_key;
    if (gnutls_pubkey_init (&public_key) < 0)
        return FALSE;
    gboolean ok = FALSE;
    if (gnutls_pubkey_import_ecc_raw (public_key, GNUTLS_ECC_CURVE_SECP256R1, &x, &y) == 0) {
        gnutls_datum_t raw = { (guint8 *) g_bytes_get_data (data, NULL), (guint) g_bytes_get_size (data) };
        gnutls_datum_t sig = { (guint8 *) g_bytes_get_data (signature, NULL), (guint) g_bytes_get_size (signature) };
        ok = gnutls_pubkey_verify_data2 (public_key, GNUTLS_SIGN_ECDSA_SHA256, 0, &raw, &sig) >= 0;
    }
    gnutls_pubkey_deinit (public_key);
    return ok;
}
