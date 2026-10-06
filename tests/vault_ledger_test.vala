using Singularity.Apps.Browser;

private delegate void Checked () throws Error;

private void fails (Checked action, int expected, string message = "") {
    try {
        action ();
        assert_not_reached ();
    } catch (Error e) {
        assert (e.domain == IOError.quark () && e.code == expected);
        if (message != "") assert (e.message.contains (message));
    }
}

private Bytes signed_wire (Bytes root, Bytes key, string dataset, string writer, string epoch, string scope, uint64 sequence) throws Error {
    var envelope = VaultEnvelope.seal (root, dataset, writer, epoch, scope, sequence, new Bytes ("Synthetic untrusted record".data));
    var wire = new ByteArray ();
    wire.append ("SBS1".data);
    wire.append (VaultCrypto.sign (key, envelope.bytes ()).get_data ());
    wire.append (envelope.bytes ().get_data ());
    return ByteArray.free_to_bytes ((owned) wire);
}

public void ledger_tests () {
    try {
        string directory = DirUtils.make_tmp ("browser-vault-ledger-XXXXXX");
        assert (directory.has_prefix (Environment.get_variable ("TMPDIR") + "/"));
        string dataset = Uuid.string_random ();
        string a = Uuid.string_random ();
        string b = Uuid.string_random ();
        string epoch = Uuid.string_random ();
        string scope = Checksum.compute_for_string (ChecksumType.SHA256, "synthetic account/default profile");
        var admin = VaultCrypto.signing_key ();
        var administrator = VaultCrypto.public_key (admin);
        var a_key = VaultCrypto.signing_key ();
        var b_key = VaultCrypto.signing_key ();
        var root = VaultCrypto.random (32);
        var devices = new Gee.HashMap<string, Bytes> ();
        devices[a] = VaultCrypto.public_key (a_key);
        devices[b] = VaultCrypto.public_key (b_key);
        var roster = VaultRoster.issue (admin, dataset, epoch, scope, 1, devices, root);
        var first = new VaultLedger (directory + "/first.sqlite", dataset, a, scope, administrator);
        var second = new VaultLedger (directory + "/second.sqlite", dataset, b, scope, administrator);
        first.install_roster (roster);
        second.install_roster (roster);
        fails (() => second.install_roster (roster), IOError.INVALID_DATA);
        var wrong_admin = VaultCrypto.signing_key ();
        var forged_roster = VaultRoster.issue (wrong_admin, dataset, epoch, scope, 2, devices, root);
        fails (() => second.install_roster (forged_roster), IOError.INVALID_DATA);
        fails (() => new VaultLedger (directory + "/first.sqlite", dataset, a, Checksum.compute_for_string (ChecksumType.SHA256, "other account"), administrator), IOError.INVALID_DATA);
        fails (() => first.reserve (b_key), IOError.PERMISSION_DENIED);
        var plain = new Bytes ("Synthetic-password-do-not-store-plaintext https://private.example.invalid/history".data);
        fails (() => first.stage (VaultCrypto.random (32), a_key, plain), IOError.INVALID_DATA);
        assert (first.pending ().length == 0);
        var staged = first.stage (root, a_key, plain);
        assert (VaultEnvelope.parse (new Bytes.from_bytes (staged.bytes, 68, staged.bytes.get_size () - 68)).sequence == 1);
        assert (first.pending ().length == 1);
        var same_device = new VaultLedger (directory + "/same-device.sqlite", dataset, a, scope, administrator);
        same_device.install_roster (roster);
        assert (same_device.receive (staged.bytes, root).compare (plain) == 0);
        var after_restore = same_device.stage (root, a_key, plain);
        assert (VaultEnvelope.parse (new Bytes.from_bytes (after_restore.bytes, 68, after_restore.bytes.get_size () - 68)).sequence == 2);
        fails (() => first.acknowledge (staged.id, "remote-1", new Bytes ("wrong record".data)), IOError.INVALID_DATA);
        assert (first.pending ().length == 1);
        fails (() => second.receive (staged.bytes, VaultCrypto.random (32)), IOError.INVALID_DATA);
        assert (second.pending (true).length == 0);
        assert (second.receive (staged.bytes, root).compare (plain) == 0);
        fails (() => second.receive (staged.bytes, root), IOError.INVALID_DATA);
        var reopened = new VaultLedger (directory + "/second.sqlite", dataset, b, scope, administrator);
        fails (() => reopened.receive (staged.bytes, root), IOError.INVALID_DATA);
        assert (reopened.pending (true).length == 1);
        assert (reopened.reopen_received (new VaultRecord (staged.id, staged.bytes), root).compare (plain) == 0);
        reopened.applied (staged.id);
        assert (reopened.pending (true).length == 0);
        fails (() => reopened.reopen_received (new VaultRecord (staged.id, staged.bytes), root), IOError.NOT_FOUND);
        first.acknowledge (staged.id, "remote-1", staged.bytes);
        assert (first.pending ().length == 0);
        assert (first.saved ().length == 1 && reopened.saved (true).length == 1);
        assert (first.reopen_saved (first.saved ()[0], root).compare (plain) == 0);
        assert (reopened.reopen_saved (reopened.saved (true)[0], root, true).compare (plain) == 0);
        fails (() => first.reopen_saved (first.saved ()[0], VaultCrypto.random (32)), IOError.INVALID_DATA);
        Sqlite.Database db;
        assert (Sqlite.Database.open (directory + "/first.sqlite", out db) == Sqlite.OK);
        uint8[] altered = staged.bytes.get_data ().copy ();
        altered[0] ^= 1;
        Sqlite.Statement tamper;
        assert (db.prepare_v2 ("UPDATE records SET data=?1 WHERE id=?2 AND direction=0", -1, out tamper) == Sqlite.OK);
        tamper.bind_blob (1, altered, altered.length);
        tamper.bind_text (2, staged.id);
        assert (tamper.step () == Sqlite.DONE);
        fails (() => first.reopen_saved (first.saved ()[0], root), IOError.INVALID_DATA);
        tamper.reset ();
        tamper.bind_blob (1, staged.bytes.get_data (), (int) staged.bytes.get_size ());
        assert (tamper.step () == Sqlite.DONE);
        assert (db.exec ("CREATE TRIGGER reject_ack BEFORE UPDATE OF remote_id ON records BEGIN SELECT RAISE(FAIL,'Synthetic acknowledgement storage failure'); END") == Sqlite.OK);
        var next = first.stage (root, a_key, plain);
        fails (() => first.acknowledge (next.id, "remote-2", next.bytes), IOError.FAILED);
        assert (first.pending ().length == 1 && first.pending ()[0].id == next.id);
        assert (db.exec ("DROP TRIGGER reject_ack") == Sqlite.OK);
        Sqlite.Database incoming;
        assert (Sqlite.Database.open (directory + "/second.sqlite", out incoming) == Sqlite.OK);
        assert (incoming.exec ("CREATE TRIGGER reject_inbox BEFORE INSERT ON records WHEN NEW.direction=1 BEGIN SELECT RAISE(FAIL,'Synthetic inbox storage failure'); END") == Sqlite.OK);
        fails (() => reopened.receive (next.bytes, root), IOError.FAILED);
        assert (reopened.pending (true).length == 0);
        assert (incoming.exec ("DROP TRIGGER reject_inbox") == Sqlite.OK);
        assert (reopened.receive (next.bytes, root).compare (plain) == 0);
        var bad_writer = signed_wire (root, b_key, dataset, a, epoch, scope, 900);
        fails (() => reopened.receive (bad_writer, root), IOError.INVALID_DATA);
        var unknown = signed_wire (root, b_key, dataset, Uuid.string_random (), epoch, scope, 900);
        fails (() => reopened.receive (unknown, root), IOError.PERMISSION_DENIED);
        assert (db.exec ("CREATE TRIGGER reject_sequence BEFORE UPDATE OF sent ON counters BEGIN SELECT RAISE(FAIL,'Synthetic sequence storage failure'); END") == Sqlite.OK);
        fails (() => first.reserve (a_key), IOError.FAILED);
        assert (db.exec ("DROP TRIGGER reject_sequence") == Sqlite.OK);
        string[] child_env = Environ.get ();
        child_env = Environ.set_variable (child_env, "BROWSER_TEST_SIGNING_KEY", Base64.encode (a_key.get_data ()), true);
        string output;
        string errors;
        int status;
        Process.spawn_sync (null, { ledger_test_binary, "reserve-and-exit", directory + "/first.sqlite", dataset, a, scope, Base64.encode (administrator.get_data ()) }, child_env, (SpawnFlags) 0, null, out output, out errors, out status);
        assert (status == 0 && output.strip () == "RESERVED 3");
        var after_crash = new VaultLedger (directory + "/first.sqlite", dataset, a, scope, administrator);
        var after = after_crash.stage (root, a_key, plain);
        assert (VaultEnvelope.parse (new Bytes.from_bytes (after.bytes, 68, after.bytes.get_size () - 68)).sequence == 4);
        assert (reopened.receive (after.bytes, root).compare (plain) == 0);
        assert (after_crash.pending ().length == 2);
        devices.unset (a);
        var revoked = VaultRoster.issue (admin, dataset, epoch, scope, 2, devices, root);
        fails (() => reopened.install_roster (revoked), IOError.INVALID_DATA, "Device changes require");
        assert (reopened.epoch == epoch);
        devices[a] = VaultCrypto.public_key (b_key);
        var changed_key = VaultRoster.issue (admin, dataset, epoch, scope, 2, devices, root);
        fails (() => reopened.install_roster (changed_key), IOError.INVALID_DATA, "Device changes require");
        devices[a] = VaultCrypto.public_key (a_key);
        var changed_root = VaultRoster.issue (admin, dataset, epoch, scope, 2, devices, VaultCrypto.random (32));
        fails (() => reopened.install_roster (changed_root), IOError.INVALID_DATA, "changed root key requires");
        devices[Uuid.string_random ()] = VaultCrypto.public_key (wrong_admin);
        var added_device = VaultRoster.issue (admin, dataset, epoch, scope, 2, devices, root);
        fails (() => reopened.install_roster (added_device), IOError.INVALID_DATA, "Device changes require");
        devices.clear ();
        devices[b] = VaultCrypto.public_key (b_key);
        var revoked_record = after_crash.stage (root, a_key, plain);
        string rotated = Uuid.string_random ();
        var rotated_root = VaultCrypto.random (32);
        var retired = new Gee.HashSet<string> ();
        retired.add (epoch);
        var reused_root = VaultRoster.issue (admin, dataset, rotated, scope, 3, devices, root, retired);
        fails (() => reopened.install_roster (reused_root), IOError.INVALID_DATA, "requires a new root key");
        assert (reopened.epoch == epoch);
        var no_policy = VaultRoster.issue (admin, dataset, rotated, scope, 3, devices, rotated_root);
        fails (() => reopened.install_roster (no_policy), IOError.INVALID_DATA, "must retire the previous");
        var rotation = VaultRoster.issue (admin, dataset, rotated, scope, 3, devices, rotated_root, retired);
        reopened.install_roster (rotation);
        assert (reopened.is_retired (epoch));
        fails (() => reopened.receive (revoked_record.bytes, root), IOError.INVALID_DATA);
        var removed_writer = signed_wire (rotated_root, a_key, dataset, a, rotated, scope, 1);
        fails (() => reopened.receive (removed_writer, rotated_root), IOError.PERMISSION_DENIED);
        fails (() => reopened.receive (after.bytes, root), IOError.INVALID_DATA);
        var rotated_record = reopened.stage (rotated_root, b_key, plain);
        var rotated_envelope = VaultEnvelope.parse (new Bytes.from_bytes (rotated_record.bytes, 68, rotated_record.bytes.get_size () - 68));
        fails (() => rotated_envelope.open (root, dataset, rotated, scope, 0), IOError.INVALID_DATA);
        fails (() => reopened.receive (rotated_record.bytes, root), IOError.INVALID_DATA);
        assert (reopened.receive (rotated_record.bytes, rotated_root).compare (plain) == 0);
        assert (reopened.reopen_received (new VaultRecord (next.id, next.bytes), root).compare (plain) == 0);
        var rollback = VaultRoster.issue (admin, dataset, epoch, scope, 4, devices, rotated_root);
        fails (() => reopened.install_roster (rollback), IOError.INVALID_DATA);
        var dropped_policy = VaultRoster.issue (admin, dataset, rotated, scope, 4, devices, rotated_root);
        fails (() => reopened.install_roster (dropped_policy), IOError.INVALID_DATA, "policy cannot be removed");
        var persisted = new VaultLedger (directory + "/second.sqlite", dataset, b, scope, administrator);
        assert (persisted.epoch == rotated);
        assert (persisted.reopen_saved (new VaultRecord (staged.id, staged.bytes), root, true).compare (plain) == 0);
        fails (() => persisted.receive (rotated_record.bytes, rotated_root), IOError.INVALID_DATA);
        foreach (string path in new string[] { directory + "/first.sqlite", directory + "/second.sqlite" }) {
            string contents;
            size_t length;
            FileUtils.get_contents (path, out contents, out length);
            var raw = new Bytes (((uint8[]) contents)[0:length]);
            assert (!contains_bytes (raw, plain));
            assert (!contains_bytes (raw, new Bytes ("Synthetic-password-do-not-store-plaintext".data)));
            assert (!contains_bytes (raw, new Bytes ("https://private.example.invalid/history".data)));
        }
    } catch (Error e) {
        error ("Vault ledger test: %s", e.message);
    }
}

private bool contains_bytes (Bytes haystack, Bytes needle) {
    unowned uint8[] data = haystack.get_data ();
    unowned uint8[] query = needle.get_data ();
    for (int i = 0; i <= data.length - query.length; i++) {
        if (new Bytes.from_bytes (haystack, i, query.length).compare (needle) == 0) return true;
    }
    return false;
}

public string ledger_test_binary;

public void ledger_crash_child (string[] args) {
    try {
        var administrator = new Bytes (Base64.decode (args[6]));
        var key = new Bytes (Base64.decode (Environment.get_variable ("BROWSER_TEST_SIGNING_KEY")));
        var ledger = new VaultLedger (args[2], args[3], args[4], args[5], administrator);
        stdout.printf ("RESERVED %" + uint64.FORMAT + "\n", ledger.reserve (key));
        stdout.flush ();
        Process.exit (0);
    } catch (Error e) {
        stderr.printf ("Crash-reservation child: %s\n", e.message);
        Process.exit (1);
    }
}
