using Singularity.Apps.Browser;

MainLoop loop;
string origin;
bool verify_ui;

async void check_ui () {
    var found = yield Passwords.lookup (origin);
    assert (found.length == 4);
    int saved = 0;
    foreach (var credential in found) {
        assert (credential.profile == "default");
        if (credential.username == "charlie") {
            assert (credential.password == "Synthetic-charlie");
            saved++;
        }
    }
    assert (saved == 1);
    var work = yield Passwords.lookup (origin, "work");
    assert (work.length == 1 && work[0].password == "Synthetic-work");
    print ("UI SAVE CHECK PASS: one persisted charlie, four default logins, work unchanged\n");
    loop.quit ();
}

async void run_checks () {
    try {
        assert (yield Passwords.save (new Credential (origin, "alice", "Synthetic-alice")));
        assert (yield Passwords.save (new Credential (origin, "bob", "Synthetic-bob")));
        assert (yield Passwords.save (new Credential (origin, "alice", "Synthetic-work", "work")));
        var legacy = new Secret.Schema ("dev.sinty.Password", Secret.SchemaFlags.NONE,
            "url", Secret.SchemaAttributeType.STRING, "username", Secret.SchemaAttributeType.STRING);
        var attrs = new HashTable<string, string> (str_hash, str_equal);
        attrs["url"] = origin;
        attrs["username"] = "legacy";
        var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
        var collection = yield Secret.Collection.for_alias (service, "default", Secret.CollectionFlags.NONE, null);
        assert (collection != null);
        yield Secret.Item.create (collection, legacy, attrs, "Synthetic legacy login",
            new Secret.Value ("Synthetic-legacy", -1, "text/plain"), Secret.ItemCreateFlags.NONE, null);
        var query = new HashTable<string, string> (str_hash, str_equal);
        query["url"] = origin;
        var raw = yield Secret.password_searchv (Passwords.schema (), query, Secret.SearchFlags.ALL, null);
        print ("Raw Secret Service matches: %u\n", raw.length ());
        foreach (var item in raw) {
            var attributes = item.get_attributes ();
            print ("Raw synthetic item: username=%s profile=%s\n", attributes["username"] ?? "<missing>", attributes["profile"] ?? "<legacy>");
            var secret = yield item.retrieve_secret (null);
            print ("Raw secret present=%s text=%s\n", (secret != null).to_string (), (secret != null && secret.get_text () != null).to_string ());
        }
        var found = yield Passwords.lookup (origin);
        print ("Default profile matches: %d\n", found.length);
        foreach (var credential in found) print ("Matched synthetic username: %s\n", credential.username);
        assert (found.length == 3);
        foreach (var credential in found) {
            assert (credential.profile == "default");
            assert (credential.password == "Synthetic-" + credential.username);
        }
        var work = yield Passwords.lookup (origin, "work");
        assert (work.length == 1);
        assert (work[0].username == "alice" && work[0].password == "Synthetic-work");
        var unrelated = yield Passwords.lookup (origin, "other");
        assert (unrelated.length == 0);
        var private_items = yield Passwords.lookup (origin, "private");
        assert (private_items.length == 0);
        var other_origin = yield Passwords.lookup ("https://different.example.invalid");
        assert (other_origin.length == 0);
        var deep = new HashTable<string, string> (str_hash, str_equal);
        deep["url"] = "https://Deep.example.invalid/login?return=1";
        deep["username"] = "imported";
        deep["profile"] = "deep";
        yield Secret.password_storev (Passwords.schema (), deep, Secret.COLLECTION_DEFAULT, "imported", "Synthetic-imported", null);
        var deep_found = yield Passwords.lookup ("https://deep.example.invalid", "deep");
        assert (deep_found.length == 1 && deep_found[0].username == "imported" && deep_found[0].password == "Synthetic-imported");
        assert (deep_found[0].origin == "https://deep.example.invalid");
        assert (!yield Passwords.save (new Credential (origin, "rejected", "Synthetic-only", "private")));
        assert (!yield Passwords.save (new Credential ("http://insecure.example.invalid", "rejected", "Synthetic-only")));
        assert (yield Passwords.save (new Credential (origin, "alice", "Synthetic-updated")));
        found = yield Passwords.lookup (origin);
        assert (found.length == 3);
        int updated = 0;
        foreach (var credential in found) {
            if (credential.username == "alice") {
                assert (credential.password == "Synthetic-updated");
                updated++;
            }
        }
        assert (updated == 1);
        var exported = yield Passwords.all ("default");
        assert (exported.length == 3);
        foreach (var credential in exported) assert (credential.origin == origin && credential.profile == "default");
        assert ((yield Passwords.all ("work")).length == 1);
        assert ((yield Passwords.all ("other")).length == 0);
        try {
            yield Passwords.all ("private");
            assert_not_reached ();
        } catch (IOError.PERMISSION_DENIED e) {}
        var duplicate = new HashTable<string, string> (str_hash, str_equal);
        duplicate["url"] = origin;
        duplicate["username"] = "alice";
        duplicate["profile"] = "default";
        var extra = yield Secret.Item.create (collection, Passwords.schema (), duplicate, "Synthetic duplicate",
            new Secret.Value ("Synthetic-duplicate", -1, "text/plain"), Secret.ItemCreateFlags.NONE, null);
        try {
            yield Passwords.all ("default");
            assert_not_reached ();
        } catch (IOError.INVALID_DATA e) {
            assert (e.message.contains ("ambiguous"));
        }
        yield extra.delete (null);
        assert ((yield Passwords.all ("default")).length == 3);
        work = yield Passwords.lookup (origin, "work");
        assert (work.length == 1 && work[0].password == "Synthetic-work");
        var targets = new GLib.List<GLib.DBusProxy> ();
        targets.append (collection);
        GLib.List<GLib.DBusProxy>? locked;
        yield service.lock (targets, null, out locked);
        assert (locked != null && locked.length () == 1);
        try {
            yield Passwords.all ("default", false);
            assert_not_reached ();
        } catch (IOError.PERMISSION_DENIED e) {}
        print ("STRICT EXPORT PASS: legacy/default/work/private/duplicate rejection and recovery/actual locked collection refusal\n");
        print ("SECRET CHECKS PASS: profile, legacy default, private exclusion, origin, update without duplicates\n");
    } catch (Error e) {
        error ("Secret check: %s", e.message);
    }
    loop.quit ();
}

int main (string[] args) {
    assert (Environment.get_variable ("DISPLAY") == null);
    assert (Environment.get_variable ("GDK_BACKEND") == "wayland");
    assert (Environment.get_variable ("SINGULARITY_SYSTEM_BUS") == Environment.get_variable ("DBUS_SYSTEM_BUS_ADDRESS"));
    origin = args.length > 1 ? args[1] : "https://synthetic.example.invalid";
    verify_ui = args.length > 2 && args[2] == "verify-ui";
    Gtk.init ();
    loop = new MainLoop ();
    Timeout.add_seconds (60, () => { error ("Secret checks timed out"); });
    if (verify_ui) check_ui.begin ();
    else run_checks.begin ();
    loop.run ();
    return 0;
}
