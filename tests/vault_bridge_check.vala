using Singularity;
using Singularity.Apps.Browser;

namespace Singularity.Apps.Browser.Config {
    public const string VERSION = "vault-bridge-check";
}

private Json.Object session () {
    var object = new Json.Object ();
    object.set_int_member ("version", 1);
    object.set_array_member ("windows", new Json.Array ());
    return object;
}

private async void check () throws Error {
    var manager = Accounts.Manager.get_default ();
    yield manager.load ();
    var settings = new GLib.Settings ("dev.sinty.browser");
    foreach (var account in manager.get_accounts_for (Accounts.Capability.FILES)) {
        string id = account.id;
        string dir = Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser", "profiles", id);
        var store = new Store (Path.build_filename (dir, "browser.db"));
        var profile = new Profile (id, false, store, settings);
        var sync = yield VaultSync.open (account, profile, true, true);
        yield Passwords.store_synced (new Credential ("https://example.invalid", "synthetic", "old-password", id));
        store.add_visit ("https://example.invalid/history", "Synthetic history");
        int64 folder = store.add_folder (0, "Synthetic folder");
        int64 child = store.add_bookmark (folder, "Synthetic bookmark", "https://example.invalid/bookmark");
        var bridge = new VaultBridge (sync, profile);
        yield bridge.capture (session ());
        assert (sync.items ().length == 5);
        assert (store.sync_links (sync.keys.scope).length == 5);
        yield sync.sync ();
        yield bridge.capture (session (), false);
        assert ((yield bridge.apply ()) == 0);
        sync = yield VaultSync.open (account, profile);
        bridge = new VaultBridge (sync, profile);
        yield bridge.capture (session ());
        assert (sync.items ().length == 5 && sync.ledger.pending ().length == 0);
        VaultItem? password = null;
        VaultItem? bookmark = null;
        foreach (var item in sync.items ()) {
            if (item.kind == "password") password = item;
            if (item.kind == "bookmark" && !item.versions[0].payload.get_object ().get_boolean_member ("folder")) bookmark = item;
        }
        assert (password != null && bookmark != null);
        var login = password.versions[0].payload.get_object ();
        login.set_string_member ("password", "new-password");
        sync.update (password.id, "password", login);
        var payload = bookmark.versions[0].payload.get_object ();
        payload.set_string_member ("title", "Received bookmark");
        sync.update (bookmark.id, "bookmark", payload);
        assert ((yield bridge.apply ()) == 2);
        var logins = yield Passwords.all (id, false);
        assert (logins.length == 1 && logins[0].password == "new-password");
        assert (store.bookmark (child).title == "Received bookmark" && store.bookmark (child).parent == folder);
        yield bridge.capture (session ());
        assert (sync.items ().length == 5);
        store.remove_history ("https://example.invalid/history");
        yield bridge.capture (session ());
        bool tombstone = false;
        foreach (var item in sync.items ()) if (item.kind == "history") tombstone = item.versions[0].deleted;
        assert (tombstone && store.sync_history ().length == 0);
        payload.set_string_member ("parent", bookmark.id);
        sync.update (bookmark.id, "bookmark", payload);
        try { yield bridge.apply (); assert_not_reached (); }
        catch (IOError.INVALID_DATA e) { assert (store.bookmark (child).parent == folder); }
        payload.set_string_member ("parent", bookmark.versions[0].payload.get_object ().get_string_member ("parent"));
        sync.update (bookmark.id, "bookmark", payload);
        yield bridge.apply ();
        store.update_bookmark (child, "Local edit while syncing", "https://example.invalid/bookmark", folder);
        try { yield bridge.capture (session (), false); assert_not_reached (); }
        catch (IOError.BUSY e) { assert (store.bookmark (child).title == "Local edit while syncing"); }
        yield bridge.capture (session ());
        yield sync.sync ();
        sync = yield VaultSync.open (account, profile);
        bridge = new VaultBridge (sync, profile);
        yield bridge.capture (session ());
        assert (sync.ledger.pending ().length == 0 && store.sync_links (sync.keys.scope).length == 5);
        string path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "keyrings", "login.skr");
        string backup = path + ".bridge-backup";
        login.set_string_member ("password", "rejected-password");
        sync.update (password.id, "password", login);
        assert (FileUtils.rename (path, backup) == 0 && DirUtils.create (path, 0700) == 0);
        try { yield bridge.apply (); assert_not_reached (); }
        catch (Error e) {
            assert (e.message.contains ("login.skr") && e.message.contains ("directory"));
            stdout.printf ("PASS %s intended Keyring rejection: %s\n", account.provider, e.message);
            logins = yield Passwords.all (id, false);
            assert (logins.length == 1 && logins[0].password == "new-password");
        } finally { assert (DirUtils.remove (path) == 0 && FileUtils.rename (backup, path) == 0); }
        yield bridge.apply ();
        logins = yield Passwords.all (id, false);
        assert (logins.length == 1 && logins[0].password == "rejected-password");
        sync.update (password.id, "password", null);
        assert ((yield bridge.apply ()) == 1);
        assert ((yield Passwords.all (id, false)).length == 0);
        Sqlite.Database archive;
        assert (Sqlite.Database.open (Path.build_filename (dir, "browser.db"), out archive) == Sqlite.OK);
        var received = new Json.Object ();
        received.set_string_member ("title", "Received new bookmark");
        received.set_string_member ("url", "https://example.invalid/new");
        received.set_boolean_member ("folder", false);
        received.set_string_member ("parent", "");
        received.set_int_member ("position", 1);
        string received_id = sync.create ("bookmark", received);
        assert (archive.exec ("CREATE TRIGGER reject_sync_link BEFORE INSERT ON sync_links BEGIN SELECT RAISE(ABORT,'synthetic map disk failure'); END") == Sqlite.OK);
        int before = store.sync_bookmarks ().length;
        try { yield bridge.apply (); assert_not_reached (); }
        catch (IOError.FAILED e) {
            assert (e.message.contains ("synthetic map disk failure"));
            assert (store.sync_bookmarks ().length == before);
        }
        assert (archive.exec ("DROP TRIGGER reject_sync_link") == Sqlite.OK);
        assert ((yield bridge.apply ()) == 1);
        assert (store.sync_bookmarks ().length == before + 1);
        assert ((yield bridge.apply ()) == 0);
        var duplicate = new Json.Object ();
        duplicate.set_string_member ("origin", "https://example.invalid");
        duplicate.set_string_member ("username", "duplicate");
        duplicate.set_string_member ("password", "first");
        string duplicate_id = sync.create ("password", duplicate);
        duplicate.set_string_member ("password", "second");
        string second_id = sync.create ("password", duplicate);
        try { yield bridge.apply (); assert_not_reached (); }
        catch (IOError.BUSY e) { assert ((yield Passwords.all (id, false)).length == 0); }
        sync.update (duplicate_id, "password", null);
        sync.update (second_id, "password", null);
        yield bridge.apply ();
        var http = new Soup.Session ();
        string provider = account.provider == "microsoft" ? "graph" : account.provider == "nextcloud" ? "dav" : "google";
        var denied = new Soup.Message ("GET", Environment.get_variable ("BROWSER_FIXTURE_ORIGIN") + "/fixture/" + provider + "/upload-denied");
        yield http.send_and_read_async (denied, Priority.DEFAULT, null);
        assert (denied.status_code == 200 && sync.ledger.pending ().length > 0);
        try { yield sync.sync (); assert_not_reached (); }
        catch (Error e) {
            assert (e is Accounts.AccountsError.AUTH_FAILED && sync.ledger.pending ().length > 0);
            assert (store.sync_bookmarks ().length == before + 1 && store.bookmark (child).title == "Local edit while syncing");
        }
        var retry = new Soup.Message ("GET", Environment.get_variable ("BROWSER_FIXTURE_ORIGIN") + "/fixture/" + provider + "/success");
        yield http.send_and_read_async (retry, Priority.DEFAULT, null);
        yield sync.sync ();
        assert (sync.ledger.pending ().length == 0);
        stdout.printf ("PASS %s atomic bookmark/map failure rollback, ambiguous-login refusal, actual upload403 source preservation and retry\n", account.provider);
        stdout.printf ("PASS %s real Store/password bridge stable IDs, hierarchy, tombstones, retry, changed-local refusal\n", account.provider);
    }
}

private async void audit (string account_id) throws Error {
    var manager = Accounts.Manager.get_default ();
    yield manager.load ();
    var account = manager.get_account (account_id);
    assert (account != null);
    string dir = Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser");
    var store = new Store (Path.build_filename (dir, "browser.db"));
    var profile = new Profile ("default", false, store, new GLib.Settings ("dev.sinty.browser"));
    var sync = yield VaultSync.open (account, profile, false, true);
    assert (sync.items ().length == 5 && sync.ledger.pending ().length == 0);
    assert (store.sync_links (sync.keys.scope).length == 5);
    int history = 0, bookmarks = 0, passwords = 0, sessions = 0;
    foreach (var item in sync.items ()) {
        assert (item.versions.size == 1 && !item.versions[0].deleted);
        var node = item.versions[0].payload;
        var payload = node.get_object ();
        if (item.kind == "history") {
            history++;
            assert (payload.get_string_member ("title") == "Synthetic history");
        } else if (item.kind == "bookmark") {
            bookmarks++;
            if (!payload.get_boolean_member ("folder")) assert (payload.get_string_member ("title") == "Synthetic bookmark");
        } else if (item.kind == "password") {
            passwords++;
            assert (payload.get_string_member ("password") == "Synthetic-bridge-password");
        } else if (item.kind == "session") {
            sessions++;
            assert (payload.get_array_member ("windows").get_length () == 1);
        }
    }
    assert (history == 1 && bookmarks == 2 && passwords == 1 && sessions == 1);
    var saved = yield Passwords.all ("default", false);
    assert (saved.length == 1 && saved[0].password == "Synthetic-bridge-password");
    assert (store.bookmark (2).parent == 1 && store.sync_history ().length == 1);
    stdout.printf ("PASS actual shipping UI encrypted model: history1 bookmarks2 password1 session1, five stable IDs, all acknowledged, saved login exact, parent retained\n");
}

private int main (string[] args) {
    Gtk.init ();
    var loop = new MainLoop ();
    int status = 0;
    if (args.length == 3 && args[1] == "--audit") {
        audit.begin (args[2], (obj, res) => {
            try { audit.end (res); }
            catch (Error e) { stderr.printf ("Shipping model audit failed: %s\n", e.message); status = 1; }
            loop.quit ();
        });
    } else check.begin ((obj, res) => {
        try { check.end (res); }
        catch (Error e) { stderr.printf ("Browser bridge check failed: %s\n", e.message); status = 1; }
        loop.quit ();
    });
    loop.run ();
    return status;
}
