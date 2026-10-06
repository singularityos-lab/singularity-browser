#include "fido_device.h"
#include <fido.h>
#include <string.h>

static GMutex busy_lock;
static fido_dev_t *busy_device = NULL;

static GBytes *
fido_copy (const unsigned char *data, size_t size)
{
    if (!data || size == 0)
        return NULL;
    return g_bytes_new (data, size);
}

gchar *
browser_fido_find (void)
{
    fido_init (0);
    fido_dev_info_t *list = fido_dev_info_new (16);
    size_t found = 0;
    gchar *path = NULL;
    if (list && fido_dev_info_manifest (list, 16, &found) == FIDO_OK && found > 0)
        path = g_strdup (fido_dev_info_path (fido_dev_info_ptr (list, 0)));
    fido_dev_info_free (&list, 16);
    return path;
}

static fido_dev_t *
fido_open_device (const gchar *path, int *rc)
{
    fido_init (0);
    fido_dev_t *dev = fido_dev_new ();
    if (!dev) {
        *rc = FIDO_ERR_INTERNAL;
        return NULL;
    }
    *rc = fido_dev_open (dev, path);
    if (*rc != FIDO_OK) {
        fido_dev_free (&dev);
        return NULL;
    }
    return dev;
}

static void
fido_close_device (fido_dev_t *dev)
{
    g_mutex_lock (&busy_lock);
    if (busy_device == dev)
        busy_device = NULL;
    g_mutex_unlock (&busy_lock);
    fido_dev_close (dev);
    fido_dev_free (&dev);
}

static void
fido_mark_busy (fido_dev_t *dev)
{
    g_mutex_lock (&busy_lock);
    busy_device = dev;
    g_mutex_unlock (&busy_lock);
}

void
browser_fido_cancel (void)
{
    g_mutex_lock (&busy_lock);
    if (busy_device)
        fido_dev_cancel (busy_device);
    g_mutex_unlock (&busy_lock);
}

gint
browser_fido_needs_pin (const gchar *path)
{
    int rc;
    fido_dev_t *dev = fido_open_device (path, &rc);
    if (!dev)
        return -rc;
    gint result = fido_dev_has_pin (dev) && !fido_dev_has_uv (dev) ? 1 : 0;
    fido_close_device (dev);
    return result;
}

typedef void (*FidoIdFunc) (const unsigned char *id, size_t size, gpointer data);

static void
fido_each_id (GBytes *packed, FidoIdFunc func, gpointer data)
{
    if (!packed)
        return;
    gsize size = 0;
    const guint8 *p = g_bytes_get_data (packed, &size);
    gsize at = 0;
    while (at + 2 <= size) {
        gsize len = ((gsize) p[at] << 8) | p[at + 1];
        at += 2;
        if (at + len > size)
            break;
        func (p + at, len, data);
        at += len;
    }
}

static void
fido_exclude (const unsigned char *id, size_t size, gpointer data)
{
    fido_cred_exclude ((fido_cred_t *) data, id, size);
}

static void
fido_allow (const unsigned char *id, size_t size, gpointer data)
{
    fido_assert_allow_cred ((fido_assert_t *) data, id, size);
}

gint
browser_fido_make_credential (const gchar *path, GBytes *client_hash, const gchar *rp_id, const gchar *rp_name,
                              GBytes *user_id, const gchar *user_name, const gchar *display_name,
                              GBytes *exclude, gboolean resident, gboolean verify, const gchar *pin,
                              GBytes **credential_id, GBytes **auth_data)
{
    *credential_id = NULL;
    *auth_data = NULL;
    int rc;
    fido_dev_t *dev = fido_open_device (path, &rc);
    if (!dev)
        return rc;
    fido_cred_t *cred = fido_cred_new ();
    gsize hash_size = 0, user_size = 0;
    const guint8 *hash = g_bytes_get_data (client_hash, &hash_size);
    const guint8 *user = g_bytes_get_data (user_id, &user_size);
    rc = fido_cred_set_type (cred, COSE_ES256);
    if (rc == FIDO_OK) rc = fido_cred_set_clientdata_hash (cred, hash, hash_size);
    if (rc == FIDO_OK) rc = fido_cred_set_rp (cred, rp_id, rp_name);
    if (rc == FIDO_OK) rc = fido_cred_set_user (cred, user, user_size, user_name, display_name, NULL);
    if (rc == FIDO_OK) rc = fido_cred_set_rk (cred, resident ? FIDO_OPT_TRUE : FIDO_OPT_OMIT);
    if (rc == FIDO_OK && verify && !pin && fido_dev_has_uv (dev)) rc = fido_cred_set_uv (cred, FIDO_OPT_TRUE);
    if (rc == FIDO_OK) fido_each_id (exclude, fido_exclude, cred);
    if (rc == FIDO_OK) {
        fido_mark_busy (dev);
        rc = fido_dev_make_cred (dev, cred, pin);
    }
    if (rc == FIDO_OK) {
        *credential_id = fido_copy (fido_cred_id_ptr (cred), fido_cred_id_len (cred));
        *auth_data = fido_copy (fido_cred_authdata_raw_ptr (cred), fido_cred_authdata_raw_len (cred));
        if (!*credential_id || !*auth_data)
            rc = FIDO_ERR_INTERNAL;
    }
    fido_cred_free (&cred);
    fido_close_device (dev);
    return rc;
}

gint
browser_fido_get_assertion (const gchar *path, GBytes *client_hash, const gchar *rp_id, GBytes *allow,
                            gboolean verify, const gchar *pin,
                            GBytes **credential_id, GBytes **auth_data, GBytes **signature, GBytes **user_id)
{
    *credential_id = NULL;
    *auth_data = NULL;
    *signature = NULL;
    *user_id = NULL;
    int rc;
    fido_dev_t *dev = fido_open_device (path, &rc);
    if (!dev)
        return rc;
    fido_assert_t *assert = fido_assert_new ();
    gsize hash_size = 0;
    const guint8 *hash = g_bytes_get_data (client_hash, &hash_size);
    rc = fido_assert_set_clientdata_hash (assert, hash, hash_size);
    if (rc == FIDO_OK) rc = fido_assert_set_rp (assert, rp_id);
    if (rc == FIDO_OK) rc = fido_assert_set_up (assert, FIDO_OPT_TRUE);
    if (rc == FIDO_OK && verify && !pin && fido_dev_has_uv (dev)) rc = fido_assert_set_uv (assert, FIDO_OPT_TRUE);
    if (rc == FIDO_OK) fido_each_id (allow, fido_allow, assert);
    if (rc == FIDO_OK) {
        fido_mark_busy (dev);
        rc = fido_dev_get_assert (dev, assert, pin);
    }
    if (rc == FIDO_OK && fido_assert_count (assert) > 0) {
        *credential_id = fido_copy (fido_assert_id_ptr (assert, 0), fido_assert_id_len (assert, 0));
        *auth_data = fido_copy (fido_assert_authdata_raw_ptr (assert, 0), fido_assert_authdata_raw_len (assert, 0));
        *signature = fido_copy (fido_assert_sig_ptr (assert, 0), fido_assert_sig_len (assert, 0));
        *user_id = fido_copy (fido_assert_user_id_ptr (assert, 0), fido_assert_user_id_len (assert, 0));
        if (!*credential_id || !*auth_data || !*signature)
            rc = FIDO_ERR_INTERNAL;
    } else if (rc == FIDO_OK) {
        rc = FIDO_ERR_NO_CREDENTIALS;
    }
    fido_assert_free (&assert);
    fido_close_device (dev);
    return rc;
}
