#include "extension_crypto.h"
#include <gnutls/gnutls.h>
#include <gnutls/abstract.h>

gboolean
browser_extension_crypto_verify (GBytes *public_key, GBytes *data, GBytes *signature, gboolean ecdsa)
{
    gnutls_pubkey_t key;
    gsize key_size, data_size, signature_size;
    const guint8 *key_data = g_bytes_get_data (public_key, &key_size);
    const guint8 *data_bytes = g_bytes_get_data (data, &data_size);
    const guint8 *signature_bytes = g_bytes_get_data (signature, &signature_size);
    if (key_size == 0 || signature_size == 0 || key_size > G_MAXUINT || data_size > G_MAXUINT || signature_size > G_MAXUINT)
        return FALSE;
    if (gnutls_pubkey_init (&key) < 0)
        return FALSE;
    gnutls_datum_t der = { (unsigned char *) key_data, (unsigned int) key_size };
    gboolean ok = FALSE;
    if (gnutls_pubkey_import (key, &der, GNUTLS_X509_FMT_DER) >= 0) {
        gnutls_datum_t message = { (unsigned char *) data_bytes, (unsigned int) data_size };
        gnutls_datum_t proof = { (unsigned char *) signature_bytes, (unsigned int) signature_size };
        gnutls_sign_algorithm_t algorithm = ecdsa ? GNUTLS_SIGN_ECDSA_SHA256 : GNUTLS_SIGN_RSA_SHA256;
        ok = gnutls_pubkey_verify_data2 (key, algorithm, 0, &message, &proof) >= 0;
    }
    gnutls_pubkey_deinit (key);
    return ok;
}
