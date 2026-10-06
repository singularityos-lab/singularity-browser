namespace Singularity.Apps.Browser {

    public class VaultRecord : Object {
        public string id { get; construct; }
        public Bytes bytes { get; construct; }
        public string remote_id { get; construct; }

        public VaultRecord (string id, Bytes bytes, string remote_id = "") {
            Object (id: id, bytes: bytes, remote_id: remote_id);
        }
    }

    public class VaultLedger : Object {
        public string dataset { get; private set; }
        public string writer { get; private set; }
        public string scope { get; private set; }
        public string epoch { owned get { return metadata ("epoch"); } }
        private Sqlite.Database db;
        private Bytes administrator;
        private Mutex mutex;

        public VaultLedger (string path, string dataset, string writer, string scope, Bytes administrator) throws Error {
            if (!VaultRoster.valid_id (dataset) || !VaultRoster.valid_id (writer) || !VaultRoster.valid_scope (scope)
                || !VaultRoster.valid_public_key (administrator) || path == ":memory:")
                throw new IOError.INVALID_ARGUMENT (_("Invalid encrypted dataset identity"));
            this.dataset = dataset;
            this.writer = writer;
            this.scope = scope;
            this.administrator = administrator;
            if (DirUtils.create_with_parents (Path.get_dirname (path), 0700) != 0)
                throw new IOError.FAILED (_("The encrypted dataset directory could not be created"));
            if (Sqlite.Database.open_v2 (path, out db, Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE | Sqlite.OPEN_FULLMUTEX) != Sqlite.OK)
                throw new IOError.FAILED (_("The encrypted dataset journal could not be opened"));
            if (FileUtils.chmod (path, 0600) != 0) throw new IOError.FAILED (_("The encrypted dataset journal could not be protected"));
            db.busy_timeout (2000);
            execute ("PRAGMA synchronous=FULL");
            execute ("PRAGMA journal_mode=DELETE");
            execute ("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
            execute ("CREATE TABLE IF NOT EXISTS epochs (id TEXT PRIMARY KEY)");
            execute ("CREATE TABLE IF NOT EXISTS roots (epoch TEXT PRIMARY KEY, commitment TEXT NOT NULL UNIQUE)");
            execute ("CREATE TABLE IF NOT EXISTS retired_epochs (id TEXT PRIMARY KEY)");
            execute ("CREATE TABLE IF NOT EXISTS devices (epoch TEXT NOT NULL, writer TEXT NOT NULL, key BLOB NOT NULL, PRIMARY KEY(epoch,writer))");
            execute ("CREATE TABLE IF NOT EXISTS counters (dataset TEXT NOT NULL, writer TEXT NOT NULL, epoch TEXT NOT NULL, sent INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(dataset,writer,epoch))");
            execute ("CREATE TABLE IF NOT EXISTS records (id TEXT NOT NULL, direction INTEGER NOT NULL, data BLOB NOT NULL, signer BLOB, remote_id TEXT NOT NULL DEFAULT '', applied INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(id,direction))");
            execute ("BEGIN IMMEDIATE");
            try {
                string fingerprint = Base64.encode (administrator.get_data ());
                if (metadata ("dataset") == "") {
                    set_metadata ("dataset", dataset);
                    set_metadata ("writer", writer);
                    set_metadata ("scope", scope);
                    set_metadata ("administrator", fingerprint);
                    set_metadata ("revision", "0");
                } else if (metadata ("dataset") != dataset || metadata ("writer") != writer || metadata ("scope") != scope || metadata ("administrator") != fingerprint) {
                    throw new IOError.INVALID_DATA (_("This journal belongs to another encrypted dataset or device"));
                }
                execute ("COMMIT");
            } catch (Error e) {
                db.exec ("ROLLBACK");
                throw e;
            }
        }

        private void execute (string sql) throws Error {
            if (db.exec (sql) != Sqlite.OK) throw new IOError.FAILED (_("Encrypted journal: %s").printf (db.errmsg ()));
        }

        private Sqlite.Statement statement (string sql) throws Error {
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sql, -1, out stmt) != Sqlite.OK) throw new IOError.FAILED (_("Encrypted journal: %s").printf (db.errmsg ()));
            return stmt;
        }

        private void done (Sqlite.Statement stmt) throws Error {
            if (stmt.step () != Sqlite.DONE) throw new IOError.FAILED (_("Encrypted journal: %s").printf (db.errmsg ()));
        }

        private string metadata (string key) {
            Sqlite.Statement stmt;
            if (db.prepare_v2 ("SELECT value FROM metadata WHERE key=?1", -1, out stmt) != Sqlite.OK) return "";
            stmt.bind_text (1, key);
            return stmt.step () == Sqlite.ROW ? stmt.column_text (0) : "";
        }

        private void set_metadata (string key, string value) throws Error {
            var stmt = statement ("INSERT INTO metadata VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
            stmt.bind_text (1, key);
            stmt.bind_text (2, value);
            done (stmt);
        }

        private static Bytes blob (Sqlite.Statement stmt, int column) {
            int length = stmt.column_bytes (column);
            unowned uint8[] raw = (uint8[]) stmt.column_blob (column);
            raw.length = length;
            return new Bytes (raw);
        }

        public void install_roster (VaultRoster signed_roster) throws Error {
            install (signed_roster);
        }

        public VaultRecord rotate (VaultRoster roster, Bytes root, Bytes signing_key, Bytes snapshot) throws Error {
            if (epoch == "" || epoch == roster.epoch) throw new IOError.INVALID_ARGUMENT (_("Rotation requires a new encryption epoch"));
            return install (roster, root, signing_key, snapshot);
        }

        internal void commit_prepared (VaultRoster roster, Bytes root, Bytes signing_key, Bytes snapshot, VaultRecord record) throws Error {
            if (epoch == roster.epoch || record.bytes.get_size () < 68 + VaultEnvelope.HEADER_SIZE + 16
                || record.bytes.get_size () > 68 + VaultEnvelope.MAX_SIZE
                || new Bytes.from_bytes (record.bytes, 0, 4).compare (new Bytes ("SBS1".data)) != 0)
                throw new IOError.INVALID_DATA (_("Invalid prepared encryption epoch"));
            var bytes = new Bytes.from_bytes (record.bytes, 68, record.bytes.get_size () - 68);
            var envelope = VaultEnvelope.parse (bytes);
            if (envelope.writer != writer || (envelope.sequence == 0 || envelope.sequence > int64.MAX) || record.id != record_id (envelope).printf (envelope.sequence)
                || !VaultCrypto.verify (VaultCrypto.public_key (signing_key), bytes, new Bytes.from_bytes (record.bytes, 4, 64))
                || envelope.open (root, dataset, roster.epoch, scope, 0).compare (snapshot) != 0)
                throw new IOError.INVALID_DATA (_("The prepared encrypted snapshot does not match this device"));
            install (roster, root, signing_key, snapshot, record);
        }

        public VaultRoster roster () throws Error {
            mutex.lock ();
            try {
                var roster = VaultRoster.parse (new Bytes (Base64.decode (metadata ("roster"))), new Bytes (Base64.decode (metadata ("roster-signature"))), administrator);
                if (roster.dataset != dataset || roster.scope != scope || roster.epoch != epoch
                    || roster.root_commitment != metadata ("root") || roster.revision.to_string () != metadata ("revision"))
                    throw new IOError.INVALID_DATA (_("The journal's device roster is inconsistent"));
                return roster;
            } finally { mutex.unlock (); }
        }

        private VaultRecord? install (VaultRoster signed_roster, Bytes? root = null, Bytes? signing_key = null, Bytes? snapshot = null, VaultRecord? prepared = null) throws Error {
            var roster = VaultRoster.parse (signed_roster.document, signed_roster.signature, administrator);
            if (roster.dataset != dataset || roster.scope != scope) throw new IOError.INVALID_DATA (_("The device roster belongs to another dataset"));
            VaultRecord? staged = null;
            mutex.lock ();
            try {
                execute ("BEGIN IMMEDIATE");
                try {
                    int64 revision = int64.parse (metadata ("revision"));
                    if (roster.revision <= revision) throw new IOError.INVALID_DATA (_("The device roster has already been received"));
                    var retired = statement ("SELECT id FROM retired_epochs");
                    int retired_rc;
                    while ((retired_rc = retired.step ()) == Sqlite.ROW) {
                        if (!roster.retired_epochs.contains (retired.column_text (0)))
                            throw new IOError.INVALID_DATA (_("The retired encryption epoch policy cannot be removed"));
                    }
                    if (retired_rc != Sqlite.DONE) throw new IOError.FAILED (_("The encryption epoch policy could not be read"));
                    if (retired_epoch (roster.epoch)) throw new IOError.INVALID_DATA (_("A retired encryption epoch cannot be reused"));
                    if (epoch != "" && epoch != roster.epoch && !roster.retired_epochs.contains (epoch))
                        throw new IOError.INVALID_DATA (_("Rotation must retire the previous encryption epoch"));
                    if (epoch == roster.epoch) {
                        if (metadata ("root") != roster.root_commitment)
                            throw new IOError.INVALID_DATA (_("A changed root key requires a new encryption epoch"));
                        var members = statement ("SELECT writer,key FROM devices WHERE epoch=?1");
                        members.bind_text (1, epoch);
                        int count = 0;
                        int rc;
                        while ((rc = members.step ()) == Sqlite.ROW) {
                            string writer = members.column_text (0);
                            var key = roster.devices[writer];
                            if (key == null || key.compare (blob (members, 1)) != 0)
                                throw new IOError.INVALID_DATA (_("Device changes require a new encryption epoch and root key"));
                            count++;
                        }
                        if (rc != Sqlite.DONE) throw new IOError.FAILED (_("The enrolled devices could not be read"));
                        if (count != roster.devices.size)
                            throw new IOError.INVALID_DATA (_("Device changes require a new encryption epoch and root key"));
                    }
                    if (epoch != roster.epoch) {
                        var known = statement ("SELECT id FROM epochs WHERE id=?1");
                        known.bind_text (1, roster.epoch);
                        if (known.step () == Sqlite.ROW) throw new IOError.INVALID_DATA (_("An old encryption epoch cannot be reused"));
                        var previous_root = statement ("SELECT epoch FROM roots WHERE commitment=?1");
                        previous_root.bind_text (1, roster.root_commitment);
                        if (previous_root.step () == Sqlite.ROW)
                            throw new IOError.INVALID_DATA (_("A new encryption epoch requires a new root key"));
                        var added_root = statement ("INSERT INTO roots VALUES(?1,?2)");
                        added_root.bind_text (1, roster.epoch);
                        added_root.bind_text (2, roster.root_commitment);
                        done (added_root);
                        var added = statement ("INSERT INTO epochs VALUES(?1)");
                        added.bind_text (1, roster.epoch);
                        done (added);
                    }
                    var removed = statement ("DELETE FROM devices WHERE epoch=?1");
                    removed.bind_text (1, roster.epoch);
                    done (removed);
                    foreach (var device in roster.devices.entries) {
                        var added = statement ("INSERT INTO devices VALUES(?1,?2,?3)");
                        added.bind_text (1, roster.epoch);
                        added.bind_text (2, device.key);
                        added.bind_blob (3, device.value.get_data (), (int) device.value.get_size ());
                        done (added);
                    }
                    foreach (string id in roster.retired_epochs) {
                        var added = statement ("INSERT OR IGNORE INTO retired_epochs VALUES(?1)");
                        added.bind_text (1, id);
                        done (added);
                    }
                    set_metadata ("epoch", roster.epoch);
                    set_metadata ("revision", roster.revision.to_string ());
                    set_metadata ("root", roster.root_commitment);
                    set_metadata ("roster", Base64.encode (roster.document.get_data ()));
                    set_metadata ("roster-signature", Base64.encode (roster.signature.get_data ()));
                    if (snapshot != null) {
                        check_root (root, roster.epoch);
                        var public_key = VaultCrypto.public_key (signing_key);
                        if (public_key == null || public_key.compare (enrolled_key (writer, roster.epoch)) != 0)
                            throw new IOError.PERMISSION_DENIED (_("This device has no enrolled signing key"));
                        int64 sequence = counter (writer, roster.epoch, true);
                        if (sequence == int64.MAX) throw new IOError.NO_SPACE (_("The encrypted sequence is exhausted"));
                        if (prepared != null && sequence != 0) throw new IOError.INVALID_DATA (_("The prepared encryption epoch was already used"));
                        staged = prepared ?? seal (root, signing_key, snapshot, roster.epoch, (uint64) sequence + 1);
                        insert (staged.id, 0, staged.bytes);
                        set_counter (writer, roster.epoch, prepared == null ? sequence + 1 : (int64) VaultEnvelope.parse (new Bytes.from_bytes (prepared.bytes, 68, prepared.bytes.get_size () - 68)).sequence, true);
                    }
                    execute ("COMMIT");
                } catch (Error e) {
                    db.exec ("ROLLBACK");
                    throw e;
                }
            } finally {
                mutex.unlock ();
            }
            return staged;
        }

        private Bytes enrolled_key (string writer, string epoch) throws Error {
            if (epoch == "" || epoch != this.epoch) throw new IOError.INVALID_DATA (_("The encryption epoch is no longer active"));
            var stmt = statement ("SELECT key FROM devices WHERE epoch=?1 AND writer=?2");
            stmt.bind_text (1, epoch);
            stmt.bind_text (2, writer);
            if (stmt.step () != Sqlite.ROW) throw new IOError.PERMISSION_DENIED (_("This device is not enrolled in the encrypted dataset"));
            return blob (stmt, 0);
        }

        private bool retired_epoch (string epoch) throws Error {
            var known = statement ("SELECT id FROM retired_epochs WHERE id=?1");
            known.bind_text (1, epoch);
            int rc = known.step ();
            if (rc != Sqlite.ROW && rc != Sqlite.DONE) throw new IOError.FAILED (_("The encryption epoch policy could not be read"));
            return rc == Sqlite.ROW;
        }

        public bool is_retired (string epoch) throws Error {
            mutex.lock ();
            try { return retired_epoch (epoch); }
            finally { mutex.unlock (); }
        }

        private int64 counter (string writer, string epoch, bool sent) throws Error {
            var stmt = statement (sent ? "SELECT sent FROM counters WHERE dataset=?1 AND writer=?2 AND epoch=?3" : "SELECT received FROM counters WHERE dataset=?1 AND writer=?2 AND epoch=?3");
            stmt.bind_text (1, dataset);
            stmt.bind_text (2, writer);
            stmt.bind_text (3, epoch);
            int rc = stmt.step ();
            if (rc == Sqlite.DONE) return 0;
            if (rc != Sqlite.ROW) throw new IOError.FAILED (_("The encrypted sequence could not be read"));
            return stmt.column_int64 (0);
        }

        private void set_counter (string writer, string epoch, int64 value, bool sent) throws Error {
            var stmt = statement (sent
                ? "INSERT INTO counters(dataset,writer,epoch,sent) VALUES(?1,?2,?3,?4) ON CONFLICT(dataset,writer,epoch) DO UPDATE SET sent=excluded.sent"
                : "INSERT INTO counters(dataset,writer,epoch,received) VALUES(?1,?2,?3,?4) ON CONFLICT(dataset,writer,epoch) DO UPDATE SET received=excluded.received");
            stmt.bind_text (1, dataset);
            stmt.bind_text (2, writer);
            stmt.bind_text (3, epoch);
            stmt.bind_int64 (4, value);
            done (stmt);
        }

        public uint64 reserve (Bytes signing_key) throws Error {
            string epoch;
            return reserve_epoch (signing_key, out epoch);
        }

        private void check_root (Bytes root, string epoch) throws Error {
            var known = statement ("SELECT commitment FROM roots WHERE epoch=?1");
            known.bind_text (1, epoch);
            if (known.step () != Sqlite.ROW || known.column_text (0) != VaultRoster.commitment (dataset, scope, root))
                throw new IOError.INVALID_DATA (_("The root key does not match the signed device roster"));
        }

        private uint64 reserve_epoch (Bytes signing_key, out string epoch, Bytes? root = null) throws Error {
            epoch = "";
            mutex.lock ();
            try {
                execute ("BEGIN IMMEDIATE");
                try {
                    epoch = this.epoch;
                    if (root != null) check_root (root, epoch);
                    var public_key = VaultCrypto.public_key (signing_key);
                    if (public_key == null || public_key.compare (enrolled_key (writer, epoch)) != 0)
                        throw new IOError.PERMISSION_DENIED (_("This device has no enrolled signing key"));
                    int64 sequence = counter (writer, epoch, true);
                    if (sequence == int64.MAX) throw new IOError.NO_SPACE (_("The encrypted sequence is exhausted"));
                    set_counter (writer, epoch, sequence + 1, true);
                    execute ("COMMIT");
                    return (uint64) sequence + 1;
                } catch (Error e) {
                    db.exec ("ROLLBACK");
                    throw e;
                }
            } finally {
                mutex.unlock ();
            }
        }

        private static string record_id (VaultEnvelope envelope) {
            return envelope.dataset + "." + envelope.epoch + "." + envelope.writer + "." + "%020" + uint64.FORMAT;
        }

        private void insert (string id, int direction, Bytes bytes, Bytes? signer = null) throws Error {
            var stmt = statement ("INSERT INTO records(id,direction,data,signer) VALUES(?1,?2,?3,?4)");
            stmt.bind_text (1, id);
            stmt.bind_int (2, direction);
            stmt.bind_blob (3, bytes.get_data (), (int) bytes.get_size ());
            if (signer != null) stmt.bind_blob (4, signer.get_data (), (int) signer.get_size ());
            done (stmt);
        }

        private VaultRecord seal (Bytes root, Bytes signing_key, Bytes plain, string epoch, uint64 sequence) throws Error {
            var envelope = VaultEnvelope.seal (root, dataset, writer, epoch, scope, sequence, plain);
            var signature = VaultCrypto.sign (signing_key, envelope.bytes ());
            if (signature == null) throw new IOError.FAILED (_("The encrypted record could not be signed"));
            var wire = new ByteArray ();
            wire.append ("SBS1".data);
            wire.append (signature.get_data ());
            wire.append (envelope.bytes ().get_data ());
            var bytes = ByteArray.free_to_bytes ((owned) wire);
            string id = record_id (envelope).printf (sequence);
            return new VaultRecord (id, bytes);
        }

        public VaultRecord stage (Bytes root, Bytes signing_key, Bytes plain) throws Error {
            string epoch;
            uint64 sequence = reserve_epoch (signing_key, out epoch, root);
            var record = seal (root, signing_key, plain, epoch, sequence);
            mutex.lock ();
            try {
                enrolled_key (writer, epoch);
                insert (record.id, 0, record.bytes);
            } finally {
                mutex.unlock ();
            }
            return record;
        }

        public Bytes receive (Bytes wire, Bytes root) throws Error {
            if (wire.get_size () < 68 + VaultEnvelope.HEADER_SIZE + 16 || wire.get_size () > 68 + VaultEnvelope.MAX_SIZE
                || new Bytes.from_bytes (wire, 0, 4).compare (new Bytes ("SBS1".data)) != 0)
                throw new IOError.INVALID_DATA (_("Invalid signed encrypted record"));
            var bytes = new Bytes.from_bytes (wire, 68, wire.get_size () - 68);
            var envelope = VaultEnvelope.parse (bytes);
            var signature = new Bytes.from_bytes (wire, 4, 64);
            mutex.lock ();
            try {
                execute ("BEGIN IMMEDIATE");
                try {
                    var public_key = enrolled_key (envelope.writer, envelope.epoch);
                    if (!VaultCrypto.verify (public_key, bytes, signature)) throw new IOError.INVALID_DATA (_("The encrypted record has no valid enrolled writer signature"));
                    if (envelope.sequence > int64.MAX) throw new IOError.INVALID_DATA (_("Invalid encrypted sequence"));
                    check_root (root, envelope.epoch);
                    int64 last = counter (envelope.writer, envelope.epoch, false);
                    var plain = envelope.open (root, dataset, epoch, scope, (uint64) last);
                    insert (record_id (envelope).printf (envelope.sequence), 1, wire, public_key);
                    set_counter (envelope.writer, envelope.epoch, (int64) envelope.sequence, false);
                    if (envelope.writer == writer && counter (writer, envelope.epoch, true) < (int64) envelope.sequence)
                        set_counter (writer, envelope.epoch, (int64) envelope.sequence, true);
                    execute ("COMMIT");
                    return plain;
                } catch (Error e) {
                    db.exec ("ROLLBACK");
                    throw e;
                }
            } finally {
                mutex.unlock ();
            }
        }

        public VaultRecord[] pending (bool incoming = false) throws Error {
            mutex.lock ();
            try {
                var stmt = statement (incoming ? "SELECT id,data,remote_id FROM records WHERE direction=1 AND applied=0 ORDER BY id" : "SELECT id,data,remote_id FROM records WHERE direction=0 AND remote_id='' ORDER BY id");
                VaultRecord[] result = {};
                int rc;
                while ((rc = stmt.step ()) == Sqlite.ROW) result += new VaultRecord (stmt.column_text (0), blob (stmt, 1), stmt.column_text (2));
                if (rc != Sqlite.DONE) throw new IOError.FAILED (_("The encrypted outbox could not be read"));
                return result;
            } finally {
                mutex.unlock ();
            }
        }

        public VaultRecord[] saved (bool incoming = false) throws Error {
            mutex.lock ();
            try {
                var stmt = statement ("SELECT id,data,remote_id FROM records WHERE direction=?1 ORDER BY id");
                stmt.bind_int (1, incoming ? 1 : 0);
                VaultRecord[] result = {};
                int rc;
                while ((rc = stmt.step ()) == Sqlite.ROW) result += new VaultRecord (stmt.column_text (0), blob (stmt, 1), stmt.column_text (2));
                if (rc != Sqlite.DONE) throw new IOError.FAILED (_("The encrypted dataset history could not be read"));
                return result;
            } finally { mutex.unlock (); }
        }

        public Bytes reopen_saved (VaultRecord record, Bytes root, bool incoming = false) throws Error {
            mutex.lock ();
            try {
                var found = statement ("SELECT data FROM records WHERE id=?1 AND direction=?2");
                found.bind_text (1, record.id);
                found.bind_int (2, incoming ? 1 : 0);
                if (found.step () != Sqlite.ROW || blob (found, 0).compare (record.bytes) != 0)
                    throw new IOError.NOT_FOUND (_("The encrypted snapshot is not in this journal"));
                if (record.bytes.get_size () < 68 + VaultEnvelope.HEADER_SIZE + 16 || record.bytes.get_size () > 68 + VaultEnvelope.MAX_SIZE
                    || new Bytes.from_bytes (record.bytes, 0, 4).compare (new Bytes ("SBS1".data)) != 0)
                    throw new IOError.INVALID_DATA (_("The journal's encrypted snapshot is truncated"));
                var bytes = new Bytes.from_bytes (record.bytes, 68, record.bytes.get_size () - 68);
                var envelope = VaultEnvelope.parse (bytes);
                if (record.id != record_id (envelope).printf (envelope.sequence))
                    throw new IOError.INVALID_DATA (_("The journal's encrypted snapshot has another identity"));
                var device = statement ("SELECT key FROM devices WHERE epoch=?1 AND writer=?2");
                device.bind_text (1, envelope.epoch);
                device.bind_text (2, envelope.writer);
                if (device.step () != Sqlite.ROW || !VaultCrypto.verify (blob (device, 0), bytes, new Bytes.from_bytes (record.bytes, 4, 64)))
                    throw new IOError.INVALID_DATA (_("The journal's encrypted snapshot has no enrolled signature"));
                check_root (root, envelope.epoch);
                return envelope.open (root, dataset, envelope.epoch, scope, 0);
            } finally { mutex.unlock (); }
        }

        public bool received (string id) throws Error {
            mutex.lock ();
            try {
                var stmt = statement ("SELECT id FROM records WHERE id=?1 AND direction=1");
                stmt.bind_text (1, id);
                int rc = stmt.step ();
                if (rc != Sqlite.ROW && rc != Sqlite.DONE) throw new IOError.FAILED (_("The encrypted receive journal could not be read"));
                return rc == Sqlite.ROW;
            } finally {
                mutex.unlock ();
            }
        }

        public Bytes reopen_received (VaultRecord record, Bytes root) throws Error {
            mutex.lock ();
            try {
                var found = statement ("SELECT data,signer FROM records WHERE id=?1 AND direction=1 AND applied=0");
                found.bind_text (1, record.id);
                if (found.step () != Sqlite.ROW || blob (found, 0).compare (record.bytes) != 0)
                    throw new IOError.NOT_FOUND (_("The received encrypted record is not pending"));
                var bytes = new Bytes.from_bytes (record.bytes, 68, record.bytes.get_size () - 68);
                var signature = new Bytes.from_bytes (record.bytes, 4, 64);
                if (!VaultCrypto.verify (blob (found, 1), bytes, signature)) throw new IOError.INVALID_DATA (_("The journal's received record could not be authenticated"));
                var envelope = VaultEnvelope.parse (bytes);
                check_root (root, envelope.epoch);
                return envelope.open (root, dataset, envelope.epoch, scope, 0);
            } finally {
                mutex.unlock ();
            }
        }

        public void acknowledge (string id, string remote_id, Bytes observed) throws Error {
            if (remote_id == "") throw new IOError.INVALID_ARGUMENT (_("The remote record has no identifier"));
            mutex.lock ();
            try {
                execute ("BEGIN IMMEDIATE");
                try {
                    var found = statement ("SELECT data FROM records WHERE id=?1 AND direction=0");
                    found.bind_text (1, id);
                    if (found.step () != Sqlite.ROW || blob (found, 0).compare (observed) != 0)
                        throw new IOError.INVALID_DATA (_("The provider did not acknowledge this encrypted record"));
                    var saved = statement ("UPDATE records SET remote_id=?2 WHERE id=?1 AND direction=0");
                    saved.bind_text (1, id);
                    saved.bind_text (2, remote_id);
                    done (saved);
                    execute ("COMMIT");
                } catch (Error e) {
                    db.exec ("ROLLBACK");
                    throw e;
                }
            } finally {
                mutex.unlock ();
            }
        }

        public void applied (string id) throws Error {
            mutex.lock ();
            try {
                var stmt = statement ("UPDATE records SET applied=1 WHERE id=?1 AND direction=1");
                stmt.bind_text (1, id);
                done (stmt);
                if (db.changes () != 1) throw new IOError.NOT_FOUND (_("The received record was not found"));
            } finally {
                mutex.unlock ();
            }
        }
    }
}
