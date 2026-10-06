#include "cable_crypto.h"
#include <string.h>
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <gnutls/abstract.h>

static gnutls_datum_t
cable_datum (GBytes *bytes)
{
    gsize size = 0;
    const guint8 *data = bytes ? g_bytes_get_data (bytes, &size) : NULL;
    gnutls_datum_t d = { (guint8 *) (data ? data : (const guint8 *) ""), (guint) size };
    return d;
}

GBytes *
browser_cable_hkdf (GBytes *ikm, GBytes *salt, GBytes *info, guint length)
{
    if (length == 0 || length > 255 * 32)
        return NULL;
    guint8 zero[32] = { 0 };
    gnutls_datum_t key = cable_datum (ikm);
    gnutls_datum_t s = cable_datum (salt);
    if (s.size == 0) {
        s.data = zero;
        s.size = sizeof (zero);
    }
    gnutls_datum_t i = cable_datum (info);
    guint8 prk[32];
    if (gnutls_hkdf_extract (GNUTLS_MAC_SHA256, &key, &s, prk) < 0)
        return NULL;
    gnutls_datum_t p = { prk, sizeof (prk) };
    guint8 *out = g_malloc (length);
    int rc = gnutls_hkdf_expand (GNUTLS_MAC_SHA256, &p, &i, out, length);
    gnutls_memset (prk, 0, sizeof (prk));
    if (rc < 0) {
        g_free (out);
        return NULL;
    }
    return g_bytes_new_take (out, length);
}

GBytes *
browser_cable_hmac (GBytes *key, GBytes *data)
{
    gnutls_datum_t k = cable_datum (key), d = cable_datum (data);
    guint8 *out = g_malloc (32);
    if (gnutls_hmac_fast (GNUTLS_MAC_SHA256, k.data, k.size, d.data, d.size, out) < 0) {
        g_free (out);
        return NULL;
    }
    return g_bytes_new_take (out, 32);
}

static GBytes *
cable_block (GBytes *key, GBytes *block, gboolean decrypt)
{
    gnutls_datum_t k = cable_datum (key), b = cable_datum (block);
    if (k.size != 32 || b.size != 16)
        return NULL;
    guint8 iv_bytes[16] = { 0 };
    gnutls_datum_t iv = { iv_bytes, sizeof (iv_bytes) };
    gnutls_cipher_hd_t handle;
    if (gnutls_cipher_init (&handle, GNUTLS_CIPHER_AES_256_CBC, &k, &iv) < 0)
        return NULL;
    guint8 *out = g_malloc (16);
    int rc = decrypt ? gnutls_cipher_decrypt2 (handle, b.data, 16, out, 16)
                     : gnutls_cipher_encrypt2 (handle, b.data, 16, out, 16);
    gnutls_cipher_deinit (handle);
    if (rc < 0) {
        g_free (out);
        return NULL;
    }
    return g_bytes_new_take (out, 16);
}

GBytes *
browser_cable_block_decrypt (GBytes *key, GBytes *block)
{
    return cable_block (key, block, TRUE);
}

GBytes *
browser_cable_block_encrypt (GBytes *key, GBytes *block)
{
    return cable_block (key, block, FALSE);
}

static GBytes *
cable_aead (GBytes *key, GBytes *nonce, GBytes *aad, GBytes *input, gboolean decrypt)
{
    gnutls_datum_t k = cable_datum (key), n = cable_datum (nonce), a = cable_datum (aad), in = cable_datum (input);
    if (k.size != 32 || n.size != 12 || (decrypt && in.size < 16))
        return NULL;
    gnutls_aead_cipher_hd_t handle;
    if (gnutls_aead_cipher_init (&handle, GNUTLS_CIPHER_AES_256_GCM, &k) < 0)
        return NULL;
    size_t out_size = decrypt ? in.size : in.size + 16;
    guint8 *out = g_malloc (out_size ? out_size : 1);
    int rc = decrypt ? gnutls_aead_cipher_decrypt (handle, n.data, n.size, a.data, a.size, 16, in.data, in.size, out, &out_size)
                     : gnutls_aead_cipher_encrypt (handle, n.data, n.size, a.data, a.size, 16, in.data, in.size, out, &out_size);
    gnutls_aead_cipher_deinit (handle);
    if (rc < 0) {
        g_free (out);
        return NULL;
    }
    return g_bytes_new_take (out, out_size);
}

GBytes *
browser_cable_seal (GBytes *key, GBytes *nonce, GBytes *aad, GBytes *plain)
{
    return cable_aead (key, nonce, aad, plain, FALSE);
}

GBytes *
browser_cable_open (GBytes *key, GBytes *nonce, GBytes *aad, GBytes *sealed)
{
    return cable_aead (key, nonce, aad, sealed, TRUE);
}

GBytes *
browser_cable_ecdh (GBytes *private_key, GBytes *peer_point)
{
    gnutls_datum_t raw = cable_datum (private_key), point = cable_datum (peer_point);
    if (raw.size == 0 || point.size != 64)
        return NULL;
    gnutls_privkey_t key;
    if (gnutls_privkey_init (&key) < 0)
        return NULL;
    if (gnutls_privkey_import_x509_raw (key, &raw, GNUTLS_X509_FMT_DER, NULL, 0) < 0) {
        gnutls_privkey_deinit (key);
        return NULL;
    }
    gnutls_pubkey_t peer;
    if (gnutls_pubkey_init (&peer) < 0) {
        gnutls_privkey_deinit (key);
        return NULL;
    }
    gnutls_datum_t x = { point.data, 32 }, y = { point.data + 32, 32 };
    gnutls_datum_t secret = { NULL, 0 };
    int rc = gnutls_pubkey_import_ecc_raw (peer, GNUTLS_ECC_CURVE_SECP256R1, &x, &y);
    if (rc == 0)
        rc = gnutls_privkey_derive_secret (key, peer, NULL, &secret, 0);
    gnutls_pubkey_deinit (peer);
    gnutls_privkey_deinit (key);
    if (rc < 0 || secret.size == 0 || secret.size > 32) {
        gnutls_free (secret.data);
        return NULL;
    }
    guint8 *out = g_malloc0 (32);
    memcpy (out + 32 - secret.size, secret.data, secret.size);
    gnutls_memset (secret.data, 0, secret.size);
    gnutls_free (secret.data);
    return g_bytes_new_take (out, 32);
}
