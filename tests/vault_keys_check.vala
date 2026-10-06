using Singularity;
using Singularity.Apps.Browser;

namespace Singularity.Apps.Browser.Config {
    public const string VERSION = "vault-key-check";
}

private async void check () throws Error {
    var manager = Accounts.Manager.get_default ();
    yield manager.load ();
    var account = manager.get_account ("synthetic-google");
    assert (account != null);
    var settings = new GLib.Settings ("dev.sinty.browser");
    var store = new Store (null);
    var profile = new Profile ("default", false, store, settings);
    var work = new Profile ("work", false, store, settings);
    var private_profile = new Profile ("arbitrary-private-name", true, store, settings);
    try {
        yield VaultKeys.load (account, profile, false);
        assert_not_reached ();
    } catch (IOError.PERMISSION_DENIED e) {
        assert (e.message.contains ("locked"));
    }
    try {
        yield VaultKeys.load (account, profile, true);
        assert_not_reached ();
    } catch (IOError.NOT_FOUND e) {}
    var keys = VaultKeys.create (account, profile);
    string epoch = Uuid.string_random ();
    var root = VaultCrypto.random (32);
    keys.add_root (epoch, root);
    yield keys.save (account, profile);
    var saved = yield VaultKeys.load (account, profile, false);
    assert (saved.dataset == keys.dataset && saved.writer == keys.writer);
    assert (saved.root (epoch).compare (root) == 0);
    assert (VaultCrypto.public_key (saved.signing).compare (VaultCrypto.public_key (keys.signing)) == 0);
    assert (VaultCrypto.exchange_public (saved.exchange).compare (VaultCrypto.exchange_public (keys.exchange)) == 0);
    string rotated = Uuid.string_random ();
    var rotated_root = VaultCrypto.random (32);
    saved.add_root (rotated, rotated_root);
    yield saved.save (account, profile);
    yield keys.save (account, profile);
    var reopened = yield VaultKeys.load (account, profile, false);
    assert (reopened.root (epoch).compare (root) == 0 && reopened.root (rotated).compare (rotated_root) == 0);
    try {
        reopened.add_root (Uuid.string_random (), root);
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {}
    try {
        reopened.add_root (epoch, rotated_root);
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {}
    var different = VaultKeys.create (account, profile);
    different.add_root (Uuid.string_random (), VaultCrypto.random (32));
    try {
        yield different.save (account, profile);
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {
        assert (e.message.contains ("already has another"));
    }
    try {
        yield keys.save (account, work);
        assert_not_reached ();
    } catch (IOError.PERMISSION_DENIED e) {}
    try {
        VaultKeys.create (account, private_profile);
        assert_not_reached ();
    } catch (IOError.PERMISSION_DENIED e) {}
    try {
        yield VaultKeys.load (account, private_profile);
        assert_not_reached ();
    } catch (IOError.PERMISSION_DENIED e) {}
    var work_keys = VaultKeys.create (account, work);
    string work_epoch = Uuid.string_random ();
    var work_root = VaultCrypto.random (32);
    work_keys.add_root (work_epoch, work_root);
    yield work_keys.save (account, work);
    var work_saved = yield VaultKeys.load (account, work, false);
    assert (work_saved.root (work_epoch).compare (work_root) == 0 && work_saved.dataset != saved.dataset);
    var schema = new Secret.Schema ("dev.sinty.BrowserSync", Secret.SchemaFlags.NONE,
        "scope", Secret.SchemaAttributeType.STRING, "profile", Secret.SchemaAttributeType.STRING);
    var attributes = new HashTable<string, string> (str_hash, str_equal);
    attributes["scope"] = keys.scope;
    attributes["profile"] = profile.id;
    var items = yield Secret.password_searchv (schema, attributes, Secret.SearchFlags.ALL, null);
    assert (items.length () == 1);
    var item = items.data as Secret.Item;
    var valid = yield item.retrieve_secret (null);
    assert (valid != null);
    foreach (string malformed in new string[] { "{\"format\":{}}", "{\"format\":1}", "{Synthetic-private-key" }) {
        yield item.set_secret (new Secret.Value (malformed, -1, "text/plain"), null);
        try {
            yield VaultKeys.load (account, profile, false);
            assert_not_reached ();
        } catch (IOError.INVALID_DATA e) {
            assert (!e.message.contains ("Synthetic-private-key"));
        }
    }
    yield item.set_secret (valid, null);
    var confirmed = yield VaultKeys.load (account, profile, false);
    assert (confirmed.dataset == keys.dataset && confirmed.root (rotated).compare (rotated_root) == 0);
    stdout.printf ("PASS vault keys: save/reread/reload/profile/private/stale-root-preservation/replacement/malformed\n");
}

int main (string[] args) {
    Gtk.init ();
    assert (Environment.get_variable ("GDK_BACKEND") == "wayland" && Environment.get_variable ("DISPLAY") == null);
    assert (Environment.get_variable ("SINGULARITY_SYSTEM_BUS") == Environment.get_variable ("DBUS_SYSTEM_BUS_ADDRESS"));
    int result = 0;
    var loop = new MainLoop ();
    check.begin ((object, response) => {
        try { check.end (response); }
        catch (Error e) { stderr.printf ("Vault key check failed: %s\n", e.message); result = 1; }
        loop.quit ();
    });
    loop.run ();
    return result;
}
