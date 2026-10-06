#ifndef BROWSER_PASSKEY_CRYPTO_H
#define BROWSER_PASSKEY_CRYPTO_H

#include <glib.h>

GBytes *browser_passkey_generate (void);
GBytes *browser_passkey_public_point (GBytes *key);
GBytes *browser_passkey_public_der (GBytes *key);
GBytes *browser_passkey_sign (GBytes *key, GBytes *data);
GBytes *browser_passkey_digest (GBytes *data);
GBytes *browser_passkey_random (guint length);
gboolean browser_passkey_verify (GBytes *point, GBytes *data, GBytes *signature);

#endif
