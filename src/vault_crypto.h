#ifndef BROWSER_VAULT_CRYPTO_H
#define BROWSER_VAULT_CRYPTO_H

#include <glib.h>

GBytes *browser_vault_random (guint length);
GBytes *browser_vault_authenticate (GBytes *key, GBytes *data);
GBytes *browser_vault_derive (GBytes *key, GBytes *salt, GBytes *info);
GBytes *browser_vault_seal (GBytes *key, GBytes *nonce, GBytes *header, GBytes *plain);
GBytes *browser_vault_open (GBytes *key, GBytes *nonce, GBytes *header, GBytes *sealed);
GBytes *browser_vault_signing_key (void);
GBytes *browser_vault_public_key (GBytes *key);
GBytes *browser_vault_exchange_key (void);
GBytes *browser_vault_exchange_public (GBytes *key);
GBytes *browser_vault_exchange (GBytes *key, GBytes *peer);
GBytes *browser_vault_sign (GBytes *key, GBytes *data);
gboolean browser_vault_verify (GBytes *key, GBytes *data, GBytes *signature);

#endif
