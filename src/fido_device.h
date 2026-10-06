#ifndef BROWSER_FIDO_DEVICE_H
#define BROWSER_FIDO_DEVICE_H

#include <glib.h>

gchar *browser_fido_find (void);
gint browser_fido_needs_pin (const gchar *path);
gint browser_fido_make_credential (const gchar *path, GBytes *client_hash, const gchar *rp_id, const gchar *rp_name,
                                   GBytes *user_id, const gchar *user_name, const gchar *display_name,
                                   GBytes *exclude, gboolean resident, gboolean verify, const gchar *pin,
                                   GBytes **credential_id, GBytes **auth_data);
gint browser_fido_get_assertion (const gchar *path, GBytes *client_hash, const gchar *rp_id, GBytes *allow,
                                 gboolean verify, const gchar *pin,
                                 GBytes **credential_id, GBytes **auth_data, GBytes **signature, GBytes **user_id);
void browser_fido_cancel (void);

#endif
