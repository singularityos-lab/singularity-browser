using Singularity;
using Singularity.Apps.Browser;

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

private async void provider_check (string provider, Accounts.Account account) throws Error {
    yield control (provider, "reset");
    string directory = Path.build_filename (Environment.get_variable ("TMPDIR"), "transport-" + provider);
    string dataset = Uuid.string_random ();
    string writer = Uuid.string_random ();
    string other = Uuid.string_random ();
    string epoch = Uuid.string_random ();
    string scope = VaultTransport.scope_for (account, "default");
    var administrator = VaultCrypto.signing_key ();
    var key = VaultCrypto.signing_key ();
    var other_key = VaultCrypto.signing_key ();
    var root = VaultCrypto.random (32);
    var devices = new Gee.HashMap<string, Bytes> ();
    devices[writer] = VaultCrypto.public_key (key);
    devices[other] = VaultCrypto.public_key (other_key);
    var roster = VaultRoster.issue (administrator, dataset, epoch, scope, 1, devices, root);
    var source = new VaultLedger (directory + "/source.sqlite", dataset, writer, scope, VaultCrypto.public_key (administrator));
    var destination = new VaultLedger (directory + "/destination.sqlite", dataset, other, scope, VaultCrypto.public_key (administrator));
    source.install_roster (roster);
    destination.install_roster (roster);
    var outgoing = yield VaultTransport.open (account, source, "default", directory + "/spool");
    var incoming = yield VaultTransport.open (account, destination, "default", directory + "/spool-in");
    var plain = new Bytes ("Synthetic-transport-password https://secret.example.invalid/history".data);
    source.stage (root, key, plain);
    yield outgoing.publish ();
    assert (source.pending ().length == 0);
    assert ((yield incoming.receive (root)) == 1);
    assert (destination.pending (true).length == 1);
    assert (destination.reopen_received (destination.pending (true)[0], root).compare (plain) == 0);
    assert ((yield incoming.receive (root)) == 0);
    stdout.printf ("PASS %s success/readback/replay\n", provider);
    foreach (string mode in new string[] { "upload-denied", "commit-error", "corrupt-read", "download-error", "page-error", "cancel-upload", "ack-storage" }) {
        var record = source.stage (root, key, plain);
        var before = yield control (provider, mode);
        int64 writes = before.get_int_member ("writes");
        Sqlite.Database? db = null;
        if (mode == "ack-storage") {
            assert (Sqlite.Database.open (directory + "/source.sqlite", out db) == Sqlite.OK);
            assert (db.exec ("CREATE TRIGGER reject_ack BEFORE UPDATE OF remote_id ON records BEGIN SELECT RAISE(FAIL,'Synthetic transport acknowledgement failure'); END") == Sqlite.OK);
        }
        var cancel = new Cancellable ();
        bool canceled = false;
        uint timer = 0;
        if (mode == "cancel-upload") timer = Timeout.add (150, () => { canceled = true; cancel.cancel (); return Source.REMOVE; });
        bool failed = false;
        try {
            yield outgoing.publish (cancel);
        } catch (Error e) {
            failed = true;
            stdout.printf ("EXPECTED %s %s: %s\n", provider, mode, e.message);
            if (mode == "upload-denied") assert (e is Accounts.AccountsError.AUTH_FAILED);
            else if (mode == "corrupt-read") assert (e is Accounts.AccountsError.CONFLICT);
            else if (mode == "cancel-upload") assert (e is IOError.CANCELLED);
            else if (mode == "ack-storage") assert (e is IOError.FAILED && e.message.contains ("Synthetic transport acknowledgement failure"));
            else assert (e.message.contains ("HTTP 500"));
        }
        if (timer != 0 && !canceled) Source.remove (timer);
        assert (failed && source.pending ().length == 1 && source.pending ()[0].id == record.id);
        if (mode == "cancel-upload") {
            Timeout.add (650, () => { provider_check.callback (); return Source.REMOVE; });
            yield;
        }
        if (mode == "ack-storage") assert (db.exec ("DROP TRIGGER reject_ack") == Sqlite.OK);
        var after_failure = yield control (provider, "success");
        bool committed = mode != "upload-denied" && mode != "page-error";
        assert (after_failure.get_int_member ("writes") == writes + (committed ? 1 : 0));
        source = new VaultLedger (directory + "/source.sqlite", dataset, writer, scope, VaultCrypto.public_key (administrator));
        outgoing = yield VaultTransport.open (account, source, "default", directory + "/spool");
        yield outgoing.publish ();
        assert (source.pending ().length == 0);
        var after_retry = yield control (provider, "success");
        assert (after_retry.get_int_member ("writes") == writes + 1);
        assert (after_retry.get_int_member ("records") == after_retry.get_int_member ("writes"));
        assert ((yield incoming.receive (root)) == 1);
        stdout.printf ("PASS %s %s retry/reopen/unique/readback-ack\n", provider, mode);
    }
    var third = new VaultLedger (directory + "/third.sqlite", dataset, other, scope, VaultCrypto.public_key (administrator));
    third.install_roster (roster);
    var fresh = yield VaultTransport.open (account, third, "default", directory + "/spool-third");
    try {
        yield fresh.receive (VaultCrypto.random (32));
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {
        assert (third.pending (true).length == 0);
    }
    assert ((yield fresh.receive (root)) == 8);
    var reopened = new VaultLedger (directory + "/third.sqlite", dataset, other, scope, VaultCrypto.public_key (administrator));
    fresh = yield VaultTransport.open (account, reopened, "default", directory + "/spool-third");
    assert ((yield fresh.receive (root)) == 0);
    string new_writer = Uuid.string_random ();
    var new_key = VaultCrypto.signing_key ();
    devices[new_writer] = VaultCrypto.public_key (new_key);
    string current_epoch = Uuid.string_random ();
    var current_root = VaultCrypto.random (32);
    var retired = new Gee.HashSet<string> ();
    retired.add (epoch);
    var rotation = VaultRoster.issue (administrator, dataset, current_epoch, scope, 2, devices, current_root, retired);
    source.install_roster (rotation);
    var current = source.stage (current_root, key, plain);
    yield outgoing.publish ();
    var enrolled = new VaultLedger (directory + "/enrolled.sqlite", dataset, new_writer, scope, VaultCrypto.public_key (administrator));
    enrolled.install_roster (rotation);
    var enrolled_transport = yield VaultTransport.open (account, enrolled, "default", directory + "/spool-enrolled");
    yield control (provider, "corrupt-current");
    try {
        yield enrolled_transport.receive (current_root);
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {
        assert (e.message.contains ("no valid enrolled writer signature"));
        assert (enrolled.pending (true).length == 0);
    }
    yield control (provider, "success");
    assert ((yield enrolled_transport.receive (current_root)) == 1);
    assert (enrolled.pending (true).length == 1 && enrolled.pending (true)[0].id == current.id);
    assert (enrolled.reopen_received (enrolled.pending (true)[0], current_root).compare (plain) == 0);
    assert ((yield enrolled_transport.receive (current_root)) == 0);
    yield control (provider, "unknown-epoch");
    try {
        yield enrolled_transport.receive (current_root);
        assert_not_reached ();
    } catch (IOError.INVALID_DATA e) {
        assert (e.message.contains ("epoch is no longer active"));
    }
    yield control (provider, "success");
    assert ((yield enrolled_transport.receive (current_root)) == 0);
    stdout.printf ("PASS %s new-device/retired-epoch/current-signature/unknown-epoch\n", provider);
    try {
        yield VaultTransport.open (account, source, "private", directory + "/private");
        assert_not_reached ();
    } catch (IOError.PERMISSION_DENIED e) {}
    yield control (provider, "disable");
    yield Accounts.Manager.get_default ().reload ();
    assert (!account.has_capability (Accounts.Capability.FILES));
    try {
        yield outgoing.publish ();
        assert_not_reached ();
    } catch (Accounts.AccountsError.NEEDS_REAUTH e) {}
    yield control (provider, "success");
    yield Accounts.Manager.get_default ().reload ();
    assert (account.has_capability (Accounts.Capability.FILES));
    stdout.printf ("PASS %s wrong-key/restart/private/disabled-account\n", provider);
}

int main (string[] args) {
    Gtk.init ();
    assert (Environment.get_variable ("GDK_BACKEND") == "wayland");
    assert (Environment.get_variable ("DISPLAY") == null);
    assert (Environment.get_variable ("DBUS_SYSTEM_BUS_ADDRESS") == Environment.get_variable ("SINGULARITY_SYSTEM_BUS"));
    endpoint = args[1];
    fixture = new Soup.Session ();
    var loop = new MainLoop ();
    int result = 0;
    run_checks.begin ((object, response) => {
        try { run_checks.end (response); }
        catch (Error e) { stderr.printf ("Transport check failed: %s\n", e.message); result = 1; }
        loop.quit ();
    });
    loop.run ();
    return result;
}

private async void run_checks () throws Error {
    var manager = Accounts.Manager.get_default ();
    yield manager.load ();
    foreach (string provider in new string[] { "google", "graph", "dav" }) {
        var account = manager.get_account ("synthetic-" + provider);
        assert (account != null);
        yield provider_check (provider, account);
    }
}
