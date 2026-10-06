#ifndef BROWSER_CABLE_CRYPTO_H
#define BROWSER_CABLE_CRYPTO_H

#include <glib.h>

GBytes *browser_cable_hkdf (GBytes *ikm, GBytes *salt, GBytes *info, guint length);
GBytes *browser_cable_hmac (GBytes *key, GBytes *data);
GBytes *browser_cable_block_decrypt (GBytes *key, GBytes *block);
GBytes *browser_cable_block_encrypt (GBytes *key, GBytes *block);
GBytes *browser_cable_seal (GBytes *key, GBytes *nonce, GBytes *aad, GBytes *plain);
GBytes *browser_cable_open (GBytes *key, GBytes *nonce, GBytes *aad, GBytes *sealed);
GBytes *browser_cable_ecdh (GBytes *private_key, GBytes *peer_point);

#endif
