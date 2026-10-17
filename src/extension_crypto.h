#ifndef BROWSER_EXTENSION_CRYPTO_H
#define BROWSER_EXTENSION_CRYPTO_H

#include <glib.h>

gboolean browser_extension_crypto_verify (GBytes *public_key, GBytes *data, GBytes *signature, gboolean ecdsa);

#endif
