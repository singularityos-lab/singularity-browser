using Singularity;
using Singularity.Apps.Browser;

namespace Singularity.Apps.Browser.Config {
    public const string VERSION = "vault-enrollment-check";
}

private string shared;

private void retain (string name, string value) throws Error {
    var stream = File.new_for_path (Path.build_filename (shared, name)).replace (null, false, FileCreateFlags.PRIVATE | FileCreateFlags.REPLACE_DESTINATION, null);
    stream.write_all (value.data, null, null);
    stream.close (null);
}

private string saved (string name) throws Error {
    string value;
    FileUtils.get_contents (Path.build_filename (shared, name), out value);
    return value;
}

private Json.Object session () {
    var object = new Json.Object ();
    object.set_int_member ("version", 1);
    object.set_array_member ("windows", new Json.Array ());
    return object;
}

private string request_variant (string request, VaultKeys keys, string field, string value) throws Error {
    var parser = new Json.Parser ();
    var wire = Base64.decode (request.substring (6));
    parser.load_from_data ((string) wire, wire.length);
    var document = Base64.decode (parser.get_root ().get_object ().get_string_member ("document"));
    parser.load_from_data ((string) document, document.length);
    var object = parser.get_root ().get_object ();
    if (field == "expires" || field == "format") object.set_int_member (field, int64.parse (value));
    else object.set_string_member (field, value);
    var generator = new Json.Generator ();
    generator.set_root (parser.get_root ());
    var bytes = new Bytes (generator.to_data (null).data);
    var wrapper = new Json.Object ();
    wrapper.set_string_member ("document", Base64.encode (bytes.get_data ()));
    wrapper.set_string_member ("signature", Base64.encode (VaultCrypto.sign (keys.signing, bytes).get_data ()));
    var node = new Json.Node (Json.NodeType.OBJECT);
    node.set_object (wrapper);
    generator.set_root (node);
    return "SBRQ1:" + Base64.encode (generator.to_data (null).data);
}

private async void request_archive (Accounts.Account account, Profile profile) throws Error {
    var collection = yield VaultKeys.default_collection (false, true);
    assert (collection != null);
    var schema = new Secret.Schema ("dev.sinty.BrowserRequestArchive", Secret.SchemaFlags.NONE,
        "scope", Secret.SchemaAttributeType.STRING, "profile", Secret.SchemaAttributeType.STRING, "nonce", Secret.SchemaAttributeType.STRING);
    var attributes = new HashTable<string, string> (str_hash, str_equal);
    attributes["scope"] = VaultKeys.account_scope (account, profile);
    attributes["profile"] = profile.id;
    attributes["nonce"] = saved ("expired-nonce");
    var items = yield collection.search (schema, attributes, Secret.SearchFlags.ALL, null);
    assert (items.length () == 1);
    var value = yield items.data.retrieve_secret (null);
    assert (value != null && value.get_content_type () == "text/plain");
    var parser = new Json.Parser ();
    parser.load_from_data ((string) value.get (), value.get ().length);
    var object = parser.get_root ().get_object ();
    assert (object.get_string_member ("dataset") == saved ("expired-nonce") && object.get_string_member ("writer") == saved ("expired-writer"));
    assert (VaultCrypto.public_key (new Bytes (Base64.decode (object.get_string_member ("signing")))).compare (new Bytes (Base64.decode (saved ("expired-signing")))) == 0);
    assert (VaultCrypto.exchange_public (new Bytes (Base64.decode (object.get_string_member ("exchange")))).compare (new Bytes (Base64.decode (saved ("expired-exchange")))) == 0);
    assert (object.get_object_member ("roots").get_size () == 0 && object.get_string_member ("roster") == "");
}

private async void check (string stage) throws Error {
    var manager = Accounts.Manager.get_default ();
    yield manager.load ();
    var account = manager.get_account (Environment.get_variable ("BROWSER_ENROLLMENT_ACCOUNT") ?? "synthetic-google");
    assert (account != null);
    var dir = Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser");
    var profile = new Profile ("default", false, new Store (dir + "/browser.db"), new GLib.Settings ("dev.sinty.browser"));
    var setup = new VaultEnrollment (account, profile);
    if (stage == "expire") {
        string request = yield setup.request ();
        var keys = yield VaultKeys.pending (account, profile);
        try { yield setup.request (true); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("Only an expired")); }
        assert ((yield setup.request ()) == request && (yield VaultKeys.pending (account, profile)).writer == keys.writer);
        int64 expires = new DateTime.now_utc ().to_unix () - 1;
        string expired = request_variant (request, keys, "expires", expires.to_string ());
        Sqlite.Database db;
        string path = Path.build_filename (profile.data_dir, "sync", VaultKeys.account_scope (account, profile), "enrollment", "invitations.sqlite");
        assert (Sqlite.Database.open (path, out db) == Sqlite.OK);
        Sqlite.Statement update;
        assert (db.prepare_v2 ("UPDATE invitations SET request=?1,expires=?2 WHERE nonce=?3 AND state=0", -1, out update) == Sqlite.OK);
        update.bind_text (1, expired);
        update.bind_int64 (2, expires);
        update.bind_text (3, keys.dataset);
        assert (update.step () == Sqlite.DONE && db.changes () == 1);
        retain ("expired-request", expired);
        retain ("expired-nonce", keys.dataset);
        retain ("expired-writer", keys.writer);
        retain ("expired-signing", Base64.encode (VaultCrypto.public_key (keys.signing).get_data ()));
        retain ("expired-exchange", Base64.encode (VaultCrypto.exchange_public (keys.exchange).get_data ()));
        profile.store.add_visit ("https://example.invalid/history", "Synthetic enrollment history");
        int64 folder = profile.store.add_folder (0, "Enrollment folder");
        profile.store.add_bookmark (folder, "Enrollment child", "https://example.invalid/bookmark");
        yield Passwords.store_synced (new Credential ("https://example.invalid", "enrollment", "Synthetic-enrollment-password", "default"));
        try { yield setup.request (); assert_not_reached (); }
        catch (IOError.TIMED_OUT e) {}
        stdout.printf ("PASS unexpired renewal refused; authentic signed expired request reached shipping expiry gate, pending identity and local data retained\n");
    } else if (stage == "renew-fail") {
        var before = yield VaultKeys.pending (account, profile);
        assert (before.dataset == saved ("expired-nonce") && before.writer == saved ("expired-writer"));
        string path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "keyrings", "login.skr");
        assert (path.has_prefix (Environment.get_variable ("HOME") + "/") && FileUtils.test (path, FileTest.IS_REGULAR));
        assert (FileUtils.rename (path, path + ".renewal-backup") == 0 && DirUtils.create (path, 0700) == 0);
        try {
            try { yield setup.request (true); assert_not_reached (); }
            catch (Error e) {
                stdout.printf ("Reached intended previous-key archive write failure: %s (%d)\n", e.message, e.code);
                assert (e.message.contains ("Is a directory") || e.message.contains ("is a directory"));
                assert (FileUtils.test (path, FileTest.IS_DIR));
            }
        } finally { assert (DirUtils.remove (path) == 0 && FileUtils.rename (path + ".renewal-backup", path) == 0); }
        var after = yield VaultKeys.pending (account, profile);
        assert (after.dataset == before.dataset && after.writer == before.writer && after.signing.compare (before.signing) == 0 && after.exchange.compare (before.exchange) == 0);
        assert (after.epochs ().length == 0 && profile.store.sync_history ().length == 1 && profile.store.sync_bookmarks ().length == 2);
        assert ((yield Passwords.all ("default"))[0].password == "Synthetic-enrollment-password");
        try { yield VaultKeys.load (account, profile); assert_not_reached (); }
        catch (IOError.NOT_FOUND e) {}
        stdout.printf ("PASS failed archive write leaves pending identity, private key pairs and Browser data unchanged, no active authorization\n");
    } else if (stage == "renew" || stage == "audit-renew") {
        if (stage == "renew") {
            var canceled = new Cancellable ();
            canceled.cancel ();
            try { yield setup.request (true, canceled); assert_not_reached (); }
            catch (IOError.CANCELLED e) {}
            assert ((yield VaultKeys.pending (account, profile)).writer == saved ("expired-writer"));
            retain ("renewed-request", yield setup.request (true));
        }
        string renewed = yield setup.request ();
        if (stage == "audit-renew" && !FileUtils.test (Path.build_filename (shared, "renewed-request"), FileTest.EXISTS)) retain ("renewed-request", renewed);
        assert (renewed == saved ("renewed-request") && renewed != saved ("expired-request"));
        var keys = yield VaultKeys.pending (account, profile);
        assert (keys.dataset != saved ("expired-nonce") && keys.writer != saved ("expired-writer") && keys.epochs ().length == 0);
        assert (Base64.encode (VaultCrypto.public_key (keys.signing).get_data ()) != saved ("expired-signing"));
        assert (Base64.encode (VaultCrypto.exchange_public (keys.exchange).get_data ()) != saved ("expired-exchange"));
        yield request_archive (account, profile);
        assert (profile.store.sync_history ().length == 1 && profile.store.sync_bookmarks ().length == 2);
        var credentials = yield Passwords.all ("default");
        assert (credentials.length == 1 && credentials[0].password == "Synthetic-enrollment-password");
        try { yield VaultKeys.load (account, profile); assert_not_reached (); }
        catch (IOError.NOT_FOUND e) {}
        try { setup.request_fingerprint (saved ("expired-request")); assert_not_reached (); }
        catch (IOError.TIMED_OUT e) {}
        stdout.printf ("PASS renewal changes nonce/writer/both public keys, retains exact previous private key archive and Browser data, survives fresh lookup, old request refused\n");
    } else if (stage == "create") {
        var sync = yield VaultSync.open (account, profile, true);
        profile.store.add_visit ("https://example.invalid/history", "Synthetic enrollment history");
        int64 folder = profile.store.add_folder (0, "Enrollment folder");
        profile.store.add_bookmark (folder, "Enrollment child", "https://example.invalid/bookmark");
        yield Passwords.store_synced (new Credential ("https://example.invalid", "enrollment", "Synthetic-enrollment-password", "default"));
        var bridge = new VaultBridge (sync, profile);
        yield bridge.capture (session ());
        yield sync.sync ();
        retain ("recovery", yield setup.recovery_code (sync));
        retain ("administrator", VaultEnrollment.fingerprint (sync.keys.administrator));
        retain ("source-writer", sync.keys.writer);
        retain ("source-epoch", sync.ledger.epoch);
        assert (sync.items ().length == 5 && sync.ledger.pending ().length == 0);
    } else if (stage == "request") {
        string request = yield setup.request ();
        assert ((yield setup.request ()) == request);
        retain ("request", request);
        retain ("request-fingerprint", setup.request_fingerprint (request));
        var pending = yield VaultKeys.pending (account, profile);
        retain ("target-writer", pending.writer);
        assert (pending.epochs ().length == 0);
        string[] fields = { "scope", "profile", "writer", "nonce", "format", "exchange", "signing", "expires", "expires" };
        string[] values = { string.nfill (64, '0'), "another-profile", "not-a-device", "not-an-invitation", "2", Base64.encode (new uint8[32]),
            Base64.encode (VaultCrypto.public_key (VaultCrypto.signing_key ()).get_data ()),
            (new DateTime.now_utc ().to_unix () - 1).to_string (), (new DateTime.now_utc ().to_unix () + 7200).to_string () };
        for (int i = 0; i < fields.length; i++) {
            try { setup.request_fingerprint (request_variant (request, pending, fields[i], values[i])); assert_not_reached (); }
            catch (Error e) {
                assert (e.domain == IOError.quark ());
                assert (e.code == (i < 5 ? IOError.PERMISSION_DENIED : i < 7 ? IOError.INVALID_DATA : IOError.TIMED_OUT));
                stdout.printf ("PASS signed request boundary %s variant%d: %s\n", fields[i], i, e.message);
            }
        }
        assert ((yield setup.request ()) == request);
        try { yield VaultKeys.load (account, profile); assert_not_reached (); }
        catch (IOError.NOT_FOUND e) {}
    } else if (stage == "approve-denied" || stage == "approve-unknown") {
        var sync = yield VaultSync.open (account, profile);
        var before = sync.ledger.roster ();
        var root = sync.keys.root (before.epoch);
        try { yield setup.approve (sync, saved ("request"), saved ("request-fingerprint")); assert_not_reached (); }
        catch (Error e) {
            stdout.printf ("Reached intended %s: %s (%d)\n", stage, e.message, e.code);
            if (stage == "approve-denied") assert (e is Accounts.AccountsError.AUTH_FAILED);
            else assert (e is Accounts.AccountsError.PROTOCOL && e.message.contains ("HTTP 500"));
        }
        var active = yield VaultKeys.load (account, profile);
        assert (active.enrollment.document.compare (before.document) == 0 && active.root (before.epoch).compare (root) == 0);
        assert (sync.ledger.roster ().document.compare (before.document) == 0 && sync.items ().length == 5 && sync.ledger.pending ().length == 0);
        assert (profile.store.sync_history ().length == 1 && profile.store.sync_bookmarks ().length == 2);
        var credentials = yield Passwords.all ("default");
        assert (credentials.length == 1 && credentials[0].password == "Synthetic-enrollment-password");
        var pending = yield VaultKeys.pending (account, profile);
        assert (pending.enrollment.revision == 2 && pending.enrollment.epoch != before.epoch);
        assert (pending.root (pending.enrollment.epoch).compare (root) != 0);
        retain ("approval-retry-epoch", pending.enrollment.epoch);
        retain ("approval-retry-writer", pending.writer);
        stdout.printf ("PASS failed approval preserves authorized roster/root and all source data; prepared epoch retained for fresh retry\n");
    } else if (stage == "approve") {
        var sync = yield VaultSync.open (account, profile);
        string epoch = sync.ledger.epoch;
        try { yield setup.approve (sync, saved ("request"), "unverified"); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("fingerprint")); }
        assert (sync.ledger.epoch == epoch);
        string response = yield setup.approve (sync, saved ("request"), saved ("request-fingerprint"));
        retain ("approval", response);
        assert (sync.ledger.epoch != epoch && sync.ledger.roster ().devices.size == 2 && sync.ledger.is_retired (epoch));
        assert (sync.keys.writer == saved ("source-writer"));
        if (FileUtils.test (Path.build_filename (shared, "approval-retry-epoch"), FileTest.EXISTS))
            assert (sync.ledger.epoch == saved ("approval-retry-epoch") && sync.keys.writer == saved ("approval-retry-writer"));
        try { yield setup.approve (sync, saved ("request"), saved ("request-fingerprint")); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("already been used")); }
        yield sync.sync ();
    } else if (stage == "previous") {
        var sync = yield VaultSync.open (account, profile);
        var before = sync.ledger.roster ();
        try { yield setup.previous_approval (sync, saved ("request"), "unverified"); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("fingerprint")); }
        var canceled = new Cancellable ();
        canceled.cancel ();
        try { yield setup.previous_approval (sync, saved ("request"), saved ("request-fingerprint"), canceled); assert_not_reached (); }
        catch (IOError.CANCELLED e) {}
        assert ((yield setup.previous_approval (sync, saved ("request"), saved ("request-fingerprint"))) == saved ("approval"));
        assert ((yield setup.previous_approval (sync, saved ("request"), saved ("request-fingerprint"))) == saved ("approval"));
        assert (sync.ledger.roster ().document.compare (before.document) == 0 && sync.ledger.pending ().length == 0);
        stdout.printf ("PASS exact existing ciphertext retrieved twice with current authenticated roster, no reauthorization; wrong pin/cancel refused\n");
    } else if (stage == "previous-stale") {
        var sync = yield VaultSync.open (account, profile);
        var before = sync.ledger.roster ();
        var root = sync.keys.root (before.epoch);
        try { yield setup.previous_approval (sync, saved ("request"), saved ("request-fingerprint")); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("no longer current")); }
        assert (before.epoch != saved ("recovered-epoch") && sync.ledger.roster ().document.compare (before.document) == 0 && sync.ledger.pending ().length == 0);
        var active = yield VaultKeys.load (account, profile);
        assert (active.enrollment.document.compare (before.document) == 0 && active.root (before.epoch).compare (root) == 0);
        stdout.printf ("PASS retained approval refused after authenticated epoch rotation; existing authorized keys/roster unchanged and no upload staged\n");
    } else if (stage == "accept") {
        try { yield setup.accept (saved ("approval"), "unverified"); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("fingerprint")); }
        var canceled = new Cancellable ();
        canceled.cancel ();
        try { yield setup.accept (saved ("approval"), saved ("administrator"), canceled); assert_not_reached (); }
        catch (IOError.CANCELLED e) {}
        try { yield VaultKeys.load (account, profile); assert_not_reached (); }
        catch (IOError.NOT_FOUND e) {}
        var sync = yield setup.accept (saved ("approval"), saved ("administrator"));
        assert (sync.keys.authority == null && sync.keys.writer == saved ("target-writer") && sync.keys.writer != saved ("source-writer"));
        assert (sync.ledger.roster ().devices.size == 2);
        try { yield setup.accept (saved ("approval"), saved ("administrator")); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("already used")); }
        yield sync.sync ();
        var bridge = new VaultBridge (sync, profile);
        int changed = yield bridge.apply ();
        stdout.printf ("Applied incoming items: %d (history1, bookmarks2, password1, session1)\n", changed);
        assert (changed == 5);
        assert (profile.store.sync_history ().length == 1 && profile.store.sync_bookmarks ().length == 2);
        var credentials = yield Passwords.all ("default");
        assert (credentials.length == 1 && credentials[0].password == "Synthetic-enrollment-password");
        assert (sync.items ().length == 5);
    } else if (stage == "accept-stale") {
        var before = yield VaultKeys.pending (account, profile);
        assert (before.epochs ().length == 0 && before.writer == saved ("target-writer"));
        try { yield setup.accept (saved ("approval"), saved ("administrator")); assert_not_reached (); }
        catch (IOError.PERMISSION_DENIED e) { assert (e.message.contains ("roster changed")); }
        try { yield VaultKeys.load (account, profile); assert_not_reached (); }
        catch (IOError.NOT_FOUND e) {}
        var after = yield VaultKeys.pending (account, profile);
        assert (after.epochs ().length == 0 && after.writer == before.writer);
        assert ((yield setup.request ()) == saved ("request"));
        assert (profile.store.sync_history ().length == 0 && profile.store.sync_bookmarks ().length == 0);
        assert ((yield Passwords.all ("default")).length == 0);
        stdout.printf ("PASS stale signed approval refused after authenticated epoch rotation; no active key or Browser data written, pending identity retained\n");
    } else if (stage == "recover-storage-fail") {
        string path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "keyrings", "login.skr");
        string marker = Path.build_filename (Environment.get_variable ("TMPDIR"), "recovery-storage-fault");
        FileUtils.set_contents (marker, path);
        try { yield setup.recover (saved ("recovery")); assert_not_reached (); }
        catch (Error e) {
            stdout.printf ("Reached recovery key persistence failure: %s (%d)\n", e.message, e.code);
            assert (FileUtils.test (marker + ".reached", FileTest.EXISTS));
            assert (FileUtils.test (path, FileTest.IS_DIR) && FileUtils.test (path + ".recovery-backup", FileTest.IS_REGULAR));
            try { yield VaultKeys.load (account, profile); assert_not_reached (); }
            catch (IOError.NOT_FOUND missing) {}
        }
        assert (DirUtils.remove (path) == 0 && FileUtils.rename (path + ".recovery-backup", path) == 0);
        try { yield VaultKeys.load (account, profile); assert_not_reached (); }
        catch (IOError.NOT_FOUND missing) {}
        var pending = yield VaultKeys.pending (account, profile);
        assert (pending.enrollment.revision == 3);
        retain ("recovery-retry-writer", pending.writer);
        retain ("recovery-retry-epoch", pending.enrollment.epoch);
    } else if (stage == "recover-fail") {
        string path = Path.build_filename (profile.data_dir, "sync", VaultKeys.account_scope (account, profile), "journal.sqlite");
        assert (DirUtils.create_with_parents (Path.get_dirname (path), 0700) == 0);
        Sqlite.Database archive;
        assert (Sqlite.Database.open (path, out archive) == Sqlite.OK);
        assert (archive.exec ("CREATE TABLE records (id TEXT NOT NULL, direction INTEGER NOT NULL, data BLOB NOT NULL, signer BLOB, remote_id TEXT NOT NULL DEFAULT '', applied INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(id,direction))") == Sqlite.OK);
        assert (archive.exec ("CREATE TRIGGER reject_recovery BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic recovery journal failure'); END") == Sqlite.OK);
        try { yield setup.recover (saved ("recovery")); assert_not_reached (); }
        catch (IOError.FAILED e) {
            stdout.printf ("Reached actual post-commit journal failure: %s\n", e.message);
            assert (e.message.contains ("synthetic recovery journal failure"));
        }
        var pending = yield VaultKeys.pending (account, profile);
        var active = yield VaultKeys.load (account, profile);
        assert (pending.writer == active.writer && pending.enrollment.document.compare (active.enrollment.document) == 0);
        retain ("recovery-retry-writer", active.writer);
        retain ("recovery-retry-epoch", active.enrollment.epoch);
        assert (archive.exec ("DROP TRIGGER reject_recovery") == Sqlite.OK);
    } else if (stage == "recover") {
        var sync = yield setup.recover (saved ("recovery"));
        if (FileUtils.test (Path.build_filename (shared, "recovery-retry-writer"), FileTest.EXISTS)) {
            assert (sync.keys.writer == saved ("recovery-retry-writer") && sync.ledger.epoch == saved ("recovery-retry-epoch"));
            stdout.printf ("PASS post-commit recovery retry keeps the original prepared writer and epoch\n");
        }
        assert (sync.keys.authority != null && sync.keys.writer != saved ("source-writer") && sync.keys.writer != saved ("target-writer"));
        assert (sync.ledger.roster ().devices.size == 3 && sync.ledger.roster ().revision == 3);
        var bridge = new VaultBridge (sync, profile);
        int changed = yield bridge.apply ();
        stdout.printf ("Applied incoming items: %d (history1, bookmarks2, password1, session1)\n", changed);
        assert (changed == 5);
        assert (sync.items ().length == 5);
        var credentials = yield Passwords.all ("default");
        assert (credentials.length == 1 && credentials[0].password == "Synthetic-enrollment-password");
        retain ("recovered-epoch", sync.ledger.epoch);
    } else if (stage == "audit-pair" || stage == "audit-recovery" || stage == "audit-unlock" || stage == "audit-approval") {
        var sync = yield VaultSync.open (account, profile);
        assert ((sync.keys.authority == null) == (stage == "audit-pair"));
        int expected = stage == "audit-unlock" ? 1 : 2;
        int expected_sessions = stage == "audit-approval" ? 1 : expected;
        assert (sync.ledger.roster ().devices.size == expected && sync.ledger.roster ().revision == expected);
        assert (profile.store.sync_history ().length == 1 && profile.store.sync_bookmarks ().length == 2);
        var bookmarks = profile.store.sync_bookmarks ();
        int64 folder = 0;
        foreach (var bookmark in bookmarks) if (bookmark.is_folder) folder = bookmark.id;
        assert (folder != 0);
        foreach (var bookmark in bookmarks) if (!bookmark.is_folder) assert (bookmark.parent == folder && bookmark.title == "Enrollment child");
        var credentials = yield Passwords.all ("default");
        assert (credentials.length == 1 && credentials[0].password == "Synthetic-enrollment-password");
        int histories = 0, folders = 0, passwords = 0, sessions = 0;
        foreach (var item in sync.items ()) {
            if (item.kind == "history") histories++;
            else if (item.kind == "bookmark") folders++;
            else if (item.kind == "password") passwords++;
            else if (item.kind == "session") sessions++;
            else assert_not_reached ();
        }
        assert (histories == 1 && folders == 2 && passwords == 1 && sessions == expected_sessions && sync.ledger.pending ().length == 0);
        stdout.printf ("PASS actual UI %s profile: history1 bookmarks2 password1 sessions%d, parent preserved, exact Secret Service login, roster%d/revision%d, expected authority role, pending0\n", stage, expected_sessions, expected, expected);
    } else if (stage == "refresh") {
        var sync = yield VaultSync.open (account, profile);
        yield setup.refresh (sync);
        assert (sync.ledger.epoch == saved ("recovered-epoch") && sync.ledger.roster ().devices.size == 3);
        yield sync.sync ();
        assert (sync.items ().length == 5 && sync.ledger.pending ().length == 0);
    } else throw new IOError.INVALID_ARGUMENT ("Unknown enrollment stage");
    stdout.printf ("PASS actual shipping enrollment stage %s\n", stage);
}

private int main (string[] args) {
    Gtk.init ();
    assert (args.length == 2);
    shared = Environment.get_variable ("BROWSER_ENROLLMENT_SHARED");
    assert (shared != null && shared.has_prefix (Environment.get_variable ("TMPDIR")));
    DirUtils.create_with_parents (shared, 0700);
    var loop = new MainLoop ();
    int result = 0;
    check.begin (args[1], (object, response) => {
        try { check.end (response); }
        catch (Error e) { stderr.printf ("FAIL intended enrollment stage %s: %s (%d)\n", args[1], e.message, e.code); result = 1; }
        loop.quit ();
    });
    loop.run ();
    return result;
}
