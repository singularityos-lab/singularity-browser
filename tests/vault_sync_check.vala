using Singularity;
using Singularity.Apps.Browser;

namespace Singularity.Apps.Browser.Config {
    public const string VERSION = "vault-sync-check";
}

private Soup.Session fixture;
private string endpoint;

private async Json.Object control (string provider, string mode) throws Error {
    var message = new Soup.Message ("GET", endpoint + "/fixture/" + provider + "/" + mode);
    var response = yield fixture.send_and_read_async (message, Priority.DEFAULT, null);
    assert (message.status_code == 200);
    var parser = new Json.Parser ();
    parser.load_from_data ((string) response.get_data (), (ssize_t) response.get_size ());
    return parser.get_root ().get_object ();
}

private Json.Object payload (string value) {
    var object = new Json.Object ();
    object.set_string_member ("title", value);
    return object;
}

private async void key_storage_probe (VaultSync sync, Accounts.Account account, Profile profile) throws Error {
    string path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "keyrings", "login.skr");
    string backup = path + ".probe-backup";
    assert (path.has_prefix (Environment.get_variable ("HOME") + "/"));
    assert (FileUtils.rename (path, backup) == 0 && DirUtils.create (path, 0700) == 0);
    string epoch = sync.ledger.epoch;
    var devices = new Gee.HashMap<string, Bytes> ();
    devices.set_all (sync.ledger.roster ().devices);
    VaultRoster? rotation = null;
    try {
        rotation = yield sync.rotate (devices);
        stdout.printf ("PROBE keyring storage failure: rotation returned success, epoch changed=%s\n", (sync.ledger.epoch != epoch).to_string ());
        stdout.flush ();
    } catch (Error e) {
        stdout.printf ("PROBE keyring storage failure rejected: %s\n", e.message);
        assert (sync.ledger.epoch == epoch);
    } finally {
        assert (DirUtils.remove (path) == 0 && FileUtils.rename (backup, path) == 0);
    }
    var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
    var sentinel = yield Secret.Collection.create (service, "sentinel" + account.id.replace ("-", ""), "", Secret.CollectionCreateFlags.NONE, null);
    assert (sentinel != null && !sentinel.get_locked ());
    var collection = yield Secret.Collection.for_alias (service, "default", Secret.CollectionFlags.NONE, null);
    var targets = new GLib.List<GLib.DBusProxy> ();
    targets.append (collection);
    GLib.List<GLib.DBusProxy>? locked;
    yield service.lock (targets, null, out locked);
    GLib.List<GLib.DBusProxy>? unlocked;
    yield service.unlock (targets, null, out unlocked);
    collection.refresh ();
    assert (unlocked != null && unlocked.length () == 1 && !collection.get_locked ());
    var disk = yield VaultKeys.load (account, profile, true);
    if (rotation != null) {
        try {
            disk.root (rotation.epoch);
            assert_not_reached ();
        } catch (IOError.NOT_FOUND e) {
            stdout.printf ("UNSAFE keyring storage failure: confirmed in-memory root absent after collection reload; retired epoch=%s\n", sync.ledger.is_retired (epoch).to_string ());
        }
        throw new IOError.FAILED ("UNSAFE: rotation was accepted without durable root storage");
    }
    stdout.printf ("PASS keyring storage failure: rotation refused and prior epoch/keys preserved\n");
}

private async void provider_check (string provider, Accounts.Account account) throws Error {
    yield control (provider, "reset");
    var profile = new Profile ("sync-" + provider, false, new Store (null), new GLib.Settings ("dev.sinty.browser"));
    var sync = yield VaultSync.open (account, profile, true);
    var ids = new Gee.HashMap<string, string> ();
    foreach (string kind in new string[] { "history", "bookmark", "password", "session" })
        ids[kind] = sync.create (kind, payload (kind == "password" ? "Synthetic-controller-password" : "https://secret.example.invalid/" + kind));
    sync.update (ids["history"], "history", null);
    assert (sync.ledger.pending ().length == 5);
    yield sync.sync ();
    assert (sync.ledger.pending ().length == 0 && sync.ledger.pending (true).length == 0);
    assert (sync.get_item (ids["history"]).versions[0].deleted);
    sync = yield VaultSync.open (account, profile);
    assert (sync.items ().length == 4);
    assert (sync.get_item (ids["password"]).versions[0].payload.get_object ().get_string_member ("title") == "Synthetic-controller-password");
    assert (sync.get_item (ids["history"]).versions[0].deleted);
    if (Environment.get_variable ("BROWSER_FIXTURE_RESTART_KEYS") == "1") {
        yield control (provider, "restart-keyring");
        sync = yield VaultSync.open (account, profile);
        assert (sync.get_item (ids["password"]).versions[0].payload.get_object ().get_string_member ("title") == "Synthetic-controller-password");
        assert (sync.get_item (ids["history"]).versions[0].deleted);
        stdout.printf ("PASS %s complete Secret Service restart preserves keys and acknowledged model\n", provider);
    }
    stdout.printf ("PASS %s controller acknowledged-history/reopen/tombstone/four-kinds\n", provider);
    if (Environment.get_variable ("BROWSER_FIXTURE_KEY_STORAGE_PROBE") == "1") {
        yield key_storage_probe (sync, account, profile);
        return;
    }
    string journal = Path.build_filename (profile.data_dir, "sync", sync.keys.scope, "journal.sqlite");
    Sqlite.Database db;
    assert (Sqlite.Database.open (journal, out db) == Sqlite.OK);
    assert (db.exec ("CREATE TRIGGER reject_snapshot BEFORE INSERT ON records WHEN NEW.direction=0 BEGIN SELECT RAISE(FAIL,'Synthetic controller snapshot failure'); END") == Sqlite.OK);
    try {
        sync.update (ids["bookmark"], "bookmark", payload ("must-not-appear"));
        assert_not_reached ();
    } catch (IOError.FAILED e) {
        assert (e.message.contains ("Synthetic controller snapshot failure"));
    }
    assert (sync.get_item (ids["bookmark"]).versions[0].payload.get_object ().get_string_member ("title") != "must-not-appear");
    assert (db.exec ("DROP TRIGGER reject_snapshot") == Sqlite.OK);
    sync.update (ids["bookmark"], "bookmark", payload ("pending-before-rotation"));
    string old_epoch = sync.ledger.epoch;
    var old_root = sync.keys.root (old_epoch);
    string enrolled = Uuid.string_random ();
    var enrolled_key = VaultCrypto.signing_key ();
    var devices = new Gee.HashMap<string, Bytes> ();
    devices.set_all (sync.ledger.roster ().devices);
    devices[enrolled] = VaultCrypto.public_key (enrolled_key);
    assert (db.exec ("CREATE TRIGGER reject_rotation BEFORE INSERT ON records WHEN NEW.direction=0 BEGIN SELECT RAISE(FAIL,'Synthetic rotation snapshot failure'); END") == Sqlite.OK);
    try {
        yield sync.rotate (devices);
        assert_not_reached ();
    } catch (IOError.FAILED e) {
        assert (e.message.contains ("Synthetic rotation snapshot failure"));
    }
    assert (sync.ledger.epoch == old_epoch && sync.ledger.pending ().length == 1);
    var after_failure = yield VaultKeys.load (account, profile, false);
    assert (after_failure.epochs ().length == 2 && after_failure.root (old_epoch).compare (old_root) == 0);
    sync = yield VaultSync.open (account, profile);
    assert (sync.get_item (ids["bookmark"]).versions[0].payload.get_object ().get_string_member ("title") == "pending-before-rotation");
    assert (db.exec ("DROP TRIGGER reject_rotation") == Sqlite.OK);
    var roster = yield sync.rotate (devices);
    assert (sync.ledger.epoch != old_epoch && sync.ledger.pending ().length == 2 && sync.ledger.is_retired (old_epoch));
    var keys = yield VaultKeys.load (account, profile, false);
    var current_root = keys.root (roster.epoch);
    assert (current_root.compare (old_root) != 0 && keys.epochs ().length == 3);
    sync = yield VaultSync.open (account, profile);
    assert (sync.get_item (ids["history"]).versions[0].deleted && sync.ledger.pending ().length == 2);
    if (Environment.get_variable ("BROWSER_FIXTURE_RESTART_KEYS") == "1") {
        yield control (provider, "restart-keyring");
        sync = yield VaultSync.open (account, profile);
        assert (sync.keys.root (roster.epoch).compare (current_root) == 0 && sync.ledger.pending ().length == 2);
        stdout.printf ("PASS %s complete Secret Service restart preserves rotated root and pending state\n", provider);
    }
    var before = yield control (provider, "commit-error");
    int64 writes = before.get_int_member ("writes");
    try {
        yield sync.sync ();
        assert_not_reached ();
    } catch (Error e) {
        assert (e.message.contains ("HTTP 500"));
    }
    assert (sync.ledger.pending ().length == 2);
    var failed = yield control (provider, "success");
    assert (failed.get_int_member ("writes") == writes + 1);
    sync = yield VaultSync.open (account, profile);
    yield sync.sync ();
    assert (sync.ledger.pending ().length == 0);
    var completed = yield control (provider, "success");
    assert (completed.get_int_member ("writes") == writes + 2 && completed.get_int_member ("records") == writes + 2);
    string directory = Path.build_filename (Environment.get_variable ("TMPDIR"), "controller-" + provider);
    var receiver = new VaultLedger (directory + "/fresh.sqlite", keys.dataset, enrolled, keys.scope, keys.administrator);
    receiver.install_roster (roster);
    var incoming = yield VaultTransport.open (account, receiver, profile.id, directory + "/spool");
    assert ((yield incoming.receive (current_root)) == 1);
    var record = receiver.pending (true)[0];
    var restored = new VaultDataset (enrolled);
    restored.merge (receiver.reopen_received (record, current_root));
    assert (restored.items ().length == 4 && restored.get_item (ids["history"]).versions[0].deleted);
    assert (restored.get_item (ids["bookmark"]).versions[0].payload.get_object ().get_string_member ("title") == "pending-before-rotation");
    assert (restored.get_item (ids["password"]).versions[0].payload.get_object ().get_string_member ("title") == "Synthetic-controller-password");
    assert (restored.get_item (ids["session"]) != null);
    var envelope = VaultEnvelope.parse (new Bytes.from_bytes (record.bytes, 68, record.bytes.get_size () - 68));
    try {
        envelope.open (old_root, keys.dataset, roster.epoch, keys.scope, 0);
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {}
    yield control (provider, "corrupt-epoch-" + roster.epoch);
    var corrupted = new VaultLedger (directory + "/corrupted.sqlite", keys.dataset, enrolled, keys.scope, keys.administrator);
    corrupted.install_roster (roster);
    var guarded = yield VaultTransport.open (account, corrupted, profile.id, directory + "/corrupt-spool");
    try {
        yield guarded.receive (current_root);
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {
        assert (e.message.contains ("no valid enrolled writer signature"));
        assert (corrupted.pending (true).length == 0);
    }
    yield control (provider, "success");
    assert ((yield guarded.receive (current_root)) == 1);
    restored.update (ids["bookmark"], "bookmark", payload ("peer-offline-edit"));
    receiver.stage (current_root, enrolled_key, restored.snapshot ());
    yield incoming.publish ();
    sync.update (ids["bookmark"], "bookmark", payload ("source-offline-edit"));
    yield sync.sync ();
    assert (sync.get_item (ids["bookmark"]).versions.size == 2);
    sync = yield VaultSync.open (account, profile);
    assert (sync.get_item (ids["bookmark"]).versions.size == 2);
    sync.update (ids["bookmark"], "bookmark", payload ("explicit-resolution"));
    yield sync.sync ();
    assert (sync.get_item (ids["bookmark"]).versions.size == 1);
    var after_conflict = yield control (provider, "success");
    assert (after_conflict.get_int_member ("writes") == writes + 6);
    assert ((yield incoming.receive (current_root)) == 4);
    foreach (var received in receiver.pending (true)) restored.merge (receiver.reopen_received (received, current_root));
    assert (restored.get_item (ids["bookmark"]).versions.size == 1);
    assert (restored.get_item (ids["bookmark"]).versions[0].payload.get_object ().get_string_member ("title") == "explicit-resolution");
    stdout.printf ("PASS %s controller concurrent-provider-edits/reopen-conflict/explicit-resolution/peer-convergence\n", provider);
    yield control (provider, "disable");
    yield Accounts.Manager.get_default ().reload ();
    try {
        yield sync.sync ();
        assert_not_reached ();
    } catch (IOError.PERMISSION_DENIED e) {}
    yield control (provider, "success");
    yield Accounts.Manager.get_default ().reload ();
    stdout.printf ("PASS %s controller storage-rollback/rotation-current-full-model/pending-preserved/unknown-commit-retry/new-device/current-corrupt/disabled\n", provider);
}

private async void check () throws Error {
    var manager = Accounts.Manager.get_default ();
    yield manager.load ();
    foreach (string provider in new string[] { "google", "graph", "dav" })
        yield provider_check (provider, manager.get_account ("synthetic-" + provider));
}

int main (string[] args) {
    Gtk.init ();
    assert (Environment.get_variable ("GDK_BACKEND") == "wayland" && Environment.get_variable ("DISPLAY") == null);
    assert (Environment.get_variable ("SINGULARITY_SYSTEM_BUS") == Environment.get_variable ("DBUS_SYSTEM_BUS_ADDRESS"));
    endpoint = args[1];
    fixture = new Soup.Session ();
    int result = 0;
    var loop = new MainLoop ();
    check.begin ((object, response) => {
        try { check.end (response); }
        catch (Error e) { stderr.printf ("Vault controller check failed: %s\n", e.message); result = 1; }
        loop.quit ();
    });
    loop.run ();
    return result;
}
