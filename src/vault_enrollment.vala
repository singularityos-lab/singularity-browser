namespace Singularity.Apps.Browser {

    private class EnrollmentSink : OutputStream {
        private ByteArray data = new ByteArray ();

        public override ssize_t write (uint8[] buffer, Cancellable? cancel = null) throws IOError {
            if (cancel != null) cancel.set_error_if_cancelled ();
            if (buffer.length > 262144 - data.len) throw new IOError.NO_SPACE (_("The stored device code is too large"));
            data.append (buffer);
            return buffer.length;
        }

        public override bool close (Cancellable? cancel = null) throws IOError {
            if (cancel != null) cancel.set_error_if_cancelled ();
            return true;
        }

        public Bytes bytes () { return new Bytes (data.data); }
    }

    public class VaultEnrollment : Object {
        private Accounts.Account account;
        private Profile profile;
        private string scope;
        private string directory;
        private Sqlite.Database db;

        public VaultEnrollment (Accounts.Account account, Profile profile) throws Error {
            this.account = account;
            this.profile = profile;
            scope = VaultKeys.account_scope (account, profile);
            directory = Path.build_filename (profile.data_dir, "sync", scope, "enrollment");
            if (DirUtils.create_with_parents (directory, 0700) != 0)
                throw new IOError.FAILED (_("The device setup directory could not be created"));
            string path = Path.build_filename (directory, "invitations.sqlite");
            if (Sqlite.Database.open_v2 (path, out db, Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE | Sqlite.OPEN_FULLMUTEX) != Sqlite.OK
                || FileUtils.chmod (path, 0600) != 0) throw new IOError.FAILED (_("The device setup state could not be protected"));
            db.busy_timeout (2000);
            execute ("PRAGMA synchronous=FULL");
            execute ("CREATE TABLE IF NOT EXISTS invitations (nonce TEXT PRIMARY KEY, request TEXT NOT NULL, expires INTEGER NOT NULL, state INTEGER NOT NULL DEFAULT 0, response TEXT NOT NULL DEFAULT '', snapshot TEXT NOT NULL DEFAULT '')");
        }

        private void check () throws Error {
            if (VaultKeys.account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The device setup account changed"));
        }

        private void execute (string sql) throws Error {
            if (db.exec (sql) != Sqlite.OK) throw new IOError.FAILED (_("The device setup state could not be saved"));
        }

        private Sqlite.Statement statement (string sql) throws Error {
            Sqlite.Statement result;
            if (db.prepare_v2 (sql, -1, out result) != Sqlite.OK) throw new IOError.FAILED (_("The device setup state could not be read"));
            return result;
        }

        private static Bytes encode (Json.Object object) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (object);
            var generator = new Json.Generator ();
            generator.set_root (node);
            return new Bytes (generator.to_data (null).data);
        }

        private static Json.Object parse (Bytes bytes) throws Error {
            if (bytes.get_size () == 0 || bytes.get_size () > 262144) throw new IOError.INVALID_DATA (_("The device code is too large or empty"));
            foreach (uint8 c in bytes.get_data ()) if (c == 0) throw new IOError.INVALID_DATA (_("Invalid device code encoding"));
            var parser = new Json.Parser ();
            try { parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ()); }
            catch (Error e) { throw new IOError.INVALID_DATA (_("The device code could not be read")); }
            var node = parser.get_root ();
            if (node == null || node.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid device code"));
            return node.get_object ();
        }

        private static string text (Json.Object object, string key) throws Error {
            if (!object.has_member (key) || object.get_member (key).get_node_type () != Json.NodeType.VALUE
                || object.get_member (key).get_value_type () != typeof (string)) throw new IOError.INVALID_DATA (_("The device code is incomplete"));
            return object.get_string_member (key);
        }

        private static int64 number (Json.Object object, string key) throws Error {
            if (!object.has_member (key) || object.get_member (key).get_node_type () != Json.NodeType.VALUE
                || object.get_member (key).get_value_type () != typeof (int64)) throw new IOError.INVALID_DATA (_("Invalid device code version"));
            return object.get_int_member (key);
        }

        private static Bytes binary (Json.Object object, string key) throws Error {
            string value = text (object, key);
            if (value.length > 350000) throw new IOError.INVALID_DATA (_("The device code is too large"));
            var result = new Bytes (Base64.decode (value));
            if (Base64.encode (result.get_data ()) != value) throw new IOError.INVALID_DATA (_("Invalid device code encoding"));
            return result;
        }

        private static Json.Object code (string input, string prefix) throws Error {
            string value = input.strip ();
            if (!value.has_prefix (prefix) || value.length > 500000) throw new IOError.INVALID_DATA (_("This is not the expected device code"));
            string body = value.substring (prefix.length);
            var bytes = new Bytes (Base64.decode (body));
            if (Base64.encode (bytes.get_data ()) != body) throw new IOError.INVALID_DATA (_("Invalid device code encoding"));
            return parse (bytes);
        }

        private static string format (Json.Object object, string prefix) {
            return prefix + Base64.encode (encode (object).get_data ());
        }

        public static string fingerprint (Bytes administrator) {
            return Checksum.compute_for_bytes (ChecksumType.SHA256, administrator);
        }

        private static Json.Object signed (Json.Object object, Bytes key) throws Error {
            var document = encode (object);
            var signature = VaultCrypto.sign (key, document);
            if (signature == null) throw new IOError.FAILED (_("The device code could not be signed"));
            var result = new Json.Object ();
            result.set_string_member ("document", Base64.encode (document.get_data ()));
            result.set_string_member ("signature", Base64.encode (signature.get_data ()));
            return result;
        }

        private static Json.Object verified (Json.Object wrapper, Bytes key) throws Error {
            var document = binary (wrapper, "document");
            if (!VaultCrypto.verify (key, document, binary (wrapper, "signature"))) throw new IOError.INVALID_DATA (_("The device code signature is invalid"));
            return parse (document);
        }

        private Json.Object request_info (string request, bool allow_expired = false) throws Error {
            var wrapper = code (request, "SBRQ1:");
            var object = parse (binary (wrapper, "document"));
            object = verified (wrapper, binary (object, "signing"));
            if (number (object, "format") != 1 || text (object, "scope") != scope || text (object, "profile") != profile.id
                || !VaultRoster.valid_id (text (object, "nonce")) || !VaultRoster.valid_id (text (object, "writer")))
                throw new IOError.PERMISSION_DENIED (_("The device request belongs to another account or profile"));
            int64 now = new DateTime.now_utc ().to_unix ();
            int64 expires = number (object, "expires");
            if ((!allow_expired && expires <= now) || expires > now + 3600) throw new IOError.TIMED_OUT (_("The device request has expired"));
            if (!VaultRoster.valid_public_key (binary (object, "signing"))) throw new IOError.INVALID_DATA (_("Invalid requested signing key"));
            var probe = VaultCrypto.exchange_key ();
            if (probe == null || VaultCrypto.exchange (probe, binary (object, "exchange")) == null)
                throw new IOError.INVALID_DATA (_("Invalid requested exchange key"));
            return object;
        }

        public string request_fingerprint (string request) throws Error {
            request_info (request);
            return Checksum.compute_for_bytes (ChecksumType.SHA256, binary (code (request, "SBRQ1:"), "document"));
        }

        private Sqlite.Statement invitation (string nonce) throws Error {
            var row = statement ("SELECT request,expires,state,response,snapshot FROM invitations WHERE nonce=?1");
            row.bind_text (1, nonce);
            return row;
        }

        private void remember_request (string request, Json.Object info) throws Error {
            string nonce = text (info, "nonce");
            var existing = invitation (nonce);
            int rc = existing.step ();
            if (rc == Sqlite.ROW) {
                if (existing.column_text (0) != request) throw new IOError.PERMISSION_DENIED (_("The invitation nonce was reused with another request"));
                if (existing.column_int (2) == 2) throw new IOError.PERMISSION_DENIED (_("This device invitation has already been used"));
                return;
            }
            if (rc != Sqlite.DONE) throw new IOError.FAILED (_("The device invitation could not be read"));
            var added = statement ("INSERT INTO invitations(nonce,request,expires) VALUES(?1,?2,?3)");
            added.bind_text (1, nonce);
            added.bind_text (2, request);
            added.bind_int64 (3, number (info, "expires"));
            if (added.step () != Sqlite.DONE) throw new IOError.FAILED (_("The device invitation was not retained"));
        }

        public async string request (bool renew = false, Cancellable? cancel = null) throws Error {
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            try {
                yield VaultKeys.load (account, profile);
                throw new IOError.EXISTS (_("This profile is already enrolled. Use its device settings"));
            } catch (IOError.NOT_FOUND e) {}
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            VaultKeys keys;
            try { keys = yield VaultKeys.pending (account, profile); }
            catch (IOError.NOT_FOUND e) {
                keys = VaultKeys.create (account, profile);
                yield keys.save_pending (account, profile);
            }
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            if (keys.epochs ().length != 0) throw new IOError.BUSY (_("A recovery or approval is already pending for this profile"));
            var row = invitation (keys.dataset);
            if (row.step () == Sqlite.ROW) {
                string saved = row.column_text (0);
                var info = request_info (saved, renew);
                if (text (info, "nonce") != keys.dataset || text (info, "writer") != keys.writer
                    || binary (info, "signing").compare (VaultCrypto.public_key (keys.signing)) != 0
                    || binary (info, "exchange").compare (VaultCrypto.exchange_public (keys.exchange)) != 0)
                    throw new IOError.PERMISSION_DENIED (_("The saved request differs from this device's pending identity"));
                if (row.column_int (2) != 0) throw new IOError.PERMISSION_DENIED (_("This device request was already accepted"));
                if (!renew) return saved;
                if (number (info, "expires") > new DateTime.now_utc ().to_unix ())
                    throw new IOError.PERMISSION_DENIED (_("Only an expired device request can be renewed"));
                if (cancel != null) cancel.set_error_if_cancelled ();
                yield keys.archive_request (account, profile);
                check ();
                if (cancel != null) cancel.set_error_if_cancelled ();
                keys = VaultKeys.create (account, profile);
                yield keys.save_pending (account, profile);
            } else if (renew) throw new IOError.NOT_FOUND (_("There is no saved expired device request to renew"));
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            var info = new Json.Object ();
            info.set_int_member ("format", 1);
            info.set_string_member ("nonce", keys.dataset);
            info.set_string_member ("writer", keys.writer);
            info.set_string_member ("scope", scope);
            info.set_string_member ("profile", profile.id);
            info.set_string_member ("signing", Base64.encode (VaultCrypto.public_key (keys.signing).get_data ()));
            info.set_string_member ("exchange", Base64.encode (VaultCrypto.exchange_public (keys.exchange).get_data ()));
            info.set_int_member ("expires", new DateTime.now_utc ().to_unix () + 3600);
            string request = format (signed (info, keys.signing), "SBRQ1:");
            remember_request (request, info);
            check ();
            return request;
        }

        private Json.Object payload (VaultKeys keys, bool recovery) throws Error {
            if (keys.enrollment == null) throw new IOError.INVALID_DATA (_("The device has no signed enrollment"));
            var result = new Json.Object ();
            result.set_string_member ("root", Base64.encode (keys.root (keys.enrollment.epoch).get_data ()));
            result.set_string_member ("roster", Base64.encode (keys.enrollment.document.get_data ()));
            result.set_string_member ("roster-signature", Base64.encode (keys.enrollment.signature.get_data ()));
            result.set_string_member ("authority", recovery ? Base64.encode (keys.authority.get_data ()) : "");
            var peers = new Json.Object ();
            foreach (var peer in keys.peers.entries) peers.set_string_member (peer.key, Base64.encode (peer.value.get_data ()));
            result.set_object_member ("peers", peers);
            return result;
        }

        private Json.Object header (VaultKeys keys, string kind, string recipient, string nonce, int64 expires) throws Error {
            var result = new Json.Object ();
            result.set_int_member ("format", 1);
            result.set_string_member ("kind", kind);
            result.set_string_member ("scope", scope);
            result.set_string_member ("profile", profile.id);
            result.set_string_member ("dataset", keys.dataset);
            result.set_string_member ("epoch", keys.enrollment.epoch);
            result.set_int_member ("revision", keys.enrollment.revision);
            result.set_string_member ("administrator", Base64.encode (keys.administrator.get_data ()));
            result.set_string_member ("recipient", recipient);
            result.set_string_member ("request", nonce);
            result.set_int_member ("expires", expires);
            result.set_string_member ("roster-hash", Checksum.compute_for_bytes (ChecksumType.SHA256, keys.enrollment.document));
            return result;
        }

        private Json.Object encrypt (VaultKeys keys, Json.Object info, Bytes secret, Json.Object plain) throws Error {
            var nonce = VaultCrypto.random (12);
            if (nonce == null) throw new IOError.FAILED (_("The device code nonce could not be created"));
            info.set_string_member ("nonce", Base64.encode (nonce.get_data ()));
            var aad = encode (info);
            var key = VaultCrypto.derive (secret, new Bytes (scope.data), new Bytes (("browser-enrollment-v1\n" + text (info, "kind") + "\n" + keys.dataset).data));
            var encrypted = VaultCrypto.seal (key, nonce, aad, encode (plain));
            if (encrypted == null) throw new IOError.FAILED (_("The device keys could not be encrypted"));
            var document = new Json.Object ();
            document.set_string_member ("header", Base64.encode (aad.get_data ()));
            document.set_string_member ("encrypted", Base64.encode (encrypted.get_data ()));
            return signed (document, keys.authority);
        }

        private Json.Object decrypt (Json.Object wrapper, Bytes administrator, Bytes secret, string kind, out Json.Object info) throws Error {
            var document = verified (wrapper, administrator);
            var aad = binary (document, "header");
            info = parse (aad);
            if (number (info, "format") != 1 || text (info, "kind") != kind || text (info, "scope") != scope
                || text (info, "profile") != profile.id || binary (info, "administrator").compare (administrator) != 0
                || !VaultRoster.valid_id (text (info, "dataset")) || !VaultRoster.valid_id (text (info, "epoch")) || number (info, "revision") <= 0)
                throw new IOError.PERMISSION_DENIED (_("The encrypted device code belongs to another profile or account"));
            var key = VaultCrypto.derive (secret, new Bytes (scope.data), new Bytes (("browser-enrollment-v1\n" + kind + "\n" + text (info, "dataset")).data));
            var plain = VaultCrypto.open (key, binary (info, "nonce"), aad, binary (document, "encrypted"));
            if (plain == null) throw new IOError.INVALID_DATA (_("The device code could not be decrypted"));
            return parse (plain);
        }

        private VaultRoster approved (Json.Object plain, Json.Object info, Bytes administrator) throws Error {
            var roster = VaultRoster.parse (binary (plain, "roster"), binary (plain, "roster-signature"), administrator);
            if (roster.dataset != text (info, "dataset") || roster.scope != scope || roster.epoch != text (info, "epoch")
                || roster.revision != number (info, "revision") || Checksum.compute_for_bytes (ChecksumType.SHA256, roster.document) != text (info, "roster-hash")
                || roster.root_commitment != VaultRoster.commitment (roster.dataset, scope, binary (plain, "root")))
                throw new IOError.INVALID_DATA (_("The root key does not match the signed device approval"));
            return roster;
        }

        private async Accounts.CloudDrive drive (Cancellable? cancel) throws Error {
            check ();
            var result = yield Accounts.CloudDrive.for_app_data (account, cancel);
            check ();
            if (result == null) throw new IOError.NOT_SUPPORTED (_("This account has no Browser app-data storage"));
            return result;
        }

        private async Accounts.CloudEntry folder (Accounts.CloudDrive drive, string dataset, bool create, Cancellable? cancel) throws Error {
            Accounts.CloudEntry? found = null;
            foreach (var entry in (yield drive.list (drive.root_id, cancel))) {
                if (entry.name != "browser-" + dataset) continue;
                if (found != null || !entry.is_folder) throw new IOError.INVALID_DATA (_("The Browser dataset folder is ambiguous"));
                found = entry;
            }
            check ();
            if (found == null) {
                if (!create) throw new IOError.NOT_FOUND (_("The encrypted Browser dataset is missing from the account"));
                found = yield drive.create_folder (drive.root_id, "browser-" + dataset, cancel);
            }
            check ();
            if (!found.is_folder || found.name != "browser-" + dataset) throw new IOError.INVALID_DATA (_("The account returned another dataset folder"));
            return found;
        }

        private async Bytes read (Accounts.CloudDrive drive, Accounts.CloudEntry entry, Cancellable? cancel) throws Error {
            if (entry.is_folder || entry.size > 262144) throw new IOError.INVALID_DATA (_("The stored device code is invalid"));
            var output = new EnrollmentSink ();
            yield drive.download_to (entry, output, cancel);
            yield output.close_async (Priority.DEFAULT, cancel);
            check ();
            return output.bytes ();
        }

        private async void publish (VaultKeys keys, string name, Json.Object wrapper, Cancellable? cancel) throws Error {
            var drive = yield drive (cancel);
            var destination = yield folder (drive, keys.dataset, true, cancel);
            string path = Path.build_filename (directory, name);
            Bytes wire = encode (wrapper);
            if (FileUtils.test (path, FileTest.EXISTS)) {
                uint8[] bytes;
                FileUtils.get_data (path, out bytes);
                wire = new Bytes (bytes);
                var saved_document = verified (parse (wire), keys.administrator);
                var expected_document = verified (wrapper, keys.administrator);
                var saved_info = saved_document.has_member ("header") ? parse (binary (saved_document, "header")) : saved_document;
                var expected_info = expected_document.has_member ("header") ? parse (binary (expected_document, "header")) : expected_document;
                foreach (string field in new string[] { "kind", "dataset", "epoch", "scope", "profile", "roster-hash" }) {
                    if (text (saved_info, field) != text (expected_info, field)) throw new IOError.INVALID_DATA (_("The retained device code belongs to another setup operation"));
                }
                if (number (saved_info, "revision") != number (expected_info, "revision")) throw new IOError.INVALID_DATA (_("The retained device revision differs"));
                if (saved_info.has_member ("recipient") && text (saved_info, "recipient") != text (expected_info, "recipient"))
                    throw new IOError.INVALID_DATA (_("The retained device recipient differs"));
            } else {
                var stream = File.new_for_path (path).create (FileCreateFlags.PRIVATE, cancel);
                try { stream.write_all (wire.get_data (), null, cancel); stream.close (cancel); }
                catch (Error e) { try { stream.close (null); } catch (Error ignored) {} throw e; }
            }
            Accounts.CloudEntry? existing = null;
            foreach (var entry in (yield drive.list (destination.id, cancel))) {
                if (entry.name != name) continue;
                if (existing != null) throw new IOError.INVALID_DATA (_("The stored device code is repeated"));
                existing = entry;
            }
            if (existing == null) existing = yield drive.upload (destination.id, name, File.new_for_path (path), cancel);
            check ();
            if (existing.name != name || (yield read (drive, existing, cancel)).compare (wire) != 0)
                throw new IOError.FAILED (_("The account did not retain the encrypted device code"));
            if (cancel != null) cancel.set_error_if_cancelled ();
        }

        private Json.Object peer_packet (VaultKeys keys, string writer, Bytes exchange, Json.Object? request = null) throws Error {
            var ephemeral = VaultCrypto.exchange_key ();
            var shared = VaultCrypto.exchange (ephemeral, exchange);
            if (shared == null) throw new IOError.INVALID_DATA (_("The requested device key is invalid"));
            var info = header (keys, request == null ? "update" : "approval", writer,
                request == null ? "" : text (request, "nonce"), request == null ? 0 : number (request, "expires"));
            info.set_string_member ("exchange", Base64.encode (VaultCrypto.exchange_public (ephemeral).get_data ()));
            info.set_string_member ("recipient-exchange", Base64.encode (exchange.get_data ()));
            info.set_string_member ("signing", Base64.encode (keys.enrollment.devices[writer].get_data ()));
            return encrypt (keys, info, shared, payload (keys, false));
        }

        private Json.Object recovery_packet (VaultKeys keys) throws Error {
            if (keys.recovery == null || keys.authority == null) throw new IOError.PERMISSION_DENIED (_("Only the administrator can prepare recovery"));
            return encrypt (keys, header (keys, "recovery", "", "", 0), keys.recovery, payload (keys, true));
        }

        private async void distribute (VaultKeys keys, VaultRecord record, Cancellable? cancel) throws Error {
            foreach (var peer in keys.peers.entries) {
                if (keys.enrollment.devices[peer.key] == null) continue;
                yield publish (keys, "device." + keys.enrollment.revision.to_string () + "." + peer.key + ".sbe", peer_packet (keys, peer.key, peer.value), cancel);
            }
            yield publish (keys, "recovery." + keys.enrollment.revision.to_string () + ".sbr", recovery_packet (keys), cancel);
            var committed = header (keys, "commit", "", "", 0);
            committed.set_string_member ("roster", Base64.encode (keys.enrollment.document.get_data ()));
            committed.set_string_member ("roster-signature", Base64.encode (keys.enrollment.signature.get_data ()));
            committed.set_string_member ("snapshot", record.id);
            committed.set_string_member ("snapshot-hash", Checksum.compute_for_bytes (ChecksumType.SHA256, record.bytes));
            yield publish (keys, "commit." + keys.enrollment.revision.to_string () + ".sbc", signed (committed, keys.authority), cancel);
        }

        public async string recovery_code (VaultSync sync, Cancellable? cancel = null) throws Error {
            check ();
            if (sync.keys.authority == null) throw new IOError.PERMISSION_DENIED (_("Use the administrator device to create a recovery key"));
            var keys = sync.keys.copy ();
            keys.recovery = keys.recovery ?? VaultCrypto.random (32);
            if (keys.recovery == null) throw new IOError.FAILED (_("The recovery key could not be created"));
            keys.authorize (sync.ledger.roster (), keys.administrator, keys.root (sync.ledger.epoch), keys.authority);
            keys.peers[keys.writer] = VaultCrypto.exchange_public (keys.exchange);
            yield keys.save (account, profile);
            yield sync.reload_keys ();
            var records = sync.ledger.saved (false);
            if (records.length == 0) throw new IOError.NOT_FOUND (_("Sync this profile before creating its recovery key"));
            VaultRecord? checkpoint = null;
            uint64 sequence = 0;
            foreach (var record in records) {
                var envelope = VaultEnvelope.parse (new Bytes.from_bytes (record.bytes, 68, record.bytes.get_size () - 68));
                if (envelope.epoch == sync.ledger.epoch && envelope.sequence > sequence) { checkpoint = record; sequence = envelope.sequence; }
            }
            if (checkpoint == null) throw new IOError.NOT_FOUND (_("Sync the current encryption epoch before creating recovery"));
            yield distribute (keys, checkpoint, cancel);
            var code = new Json.Object ();
            code.set_int_member ("format", 1);
            code.set_string_member ("scope", scope);
            code.set_string_member ("profile", profile.id);
            code.set_string_member ("dataset", keys.dataset);
            code.set_string_member ("administrator", Base64.encode (keys.administrator.get_data ()));
            code.set_string_member ("key", Base64.encode (keys.recovery.get_data ()));
            check ();
            return format (code, "SBR1:");
        }

        public async string approve (VaultSync sync, string request, string trusted_request, Cancellable? cancel = null) throws Error {
            check ();
            sync.check_scope ();
            if (sync.keys.authority == null) throw new IOError.PERMISSION_DENIED (_("Only the administrator can approve a device"));
            yield sync.reload_keys ();
            var info = request_info (request);
            if (request_fingerprint (request) != trusted_request.strip ().down ())
                throw new IOError.PERMISSION_DENIED (_("Verify the request fingerprint on the new device before approving"));
            string nonce = text (info, "nonce");
            string writer = text (info, "writer");
            remember_request (request, info);
            VaultKeys keys;
            var row = invitation (nonce);
            row.step ();
            if (row.column_int (2) == 1) {
                keys = yield VaultKeys.pending (account, profile);
                if (keys.dataset != sync.keys.dataset || keys.writer != sync.keys.writer || keys.enrollment == null || keys.enrollment.devices[writer] == null
                    || keys.enrollment.devices[writer].compare (binary (info, "signing")) != 0
                    || keys.peers[writer] == null || keys.peers[writer].compare (binary (info, "exchange")) != 0)
                    throw new IOError.INVALID_DATA (_("The pending approval belongs to another device"));
            } else {
                if (sync.ledger.roster ().devices[writer] != null) throw new IOError.PERMISSION_DENIED (_("The requested device is already enrolled"));
                keys = sync.keys.copy ();
                keys.recovery = keys.recovery ?? VaultCrypto.random (32);
                keys.peers[keys.writer] = VaultCrypto.exchange_public (keys.exchange);
                foreach (string enrolled in sync.ledger.roster ().devices.keys) {
                    if (keys.peers[enrolled] == null) throw new IOError.NOT_SUPPORTED (_("An existing device has no exchange key. Recover or re-enroll it before adding another device"));
                }
                keys.peers[writer] = binary (info, "exchange");
                var devices = new Gee.HashMap<string, Bytes> ();
                devices.set_all (sync.ledger.roster ().devices);
                devices[writer] = binary (info, "signing");
                var retired = new Gee.HashSet<string> ();
                retired.add_all (sync.ledger.roster ().retired_epochs);
                retired.add (sync.ledger.epoch);
                var root = VaultCrypto.random (32);
                if (root == null) throw new IOError.FAILED (_("The new encryption root could not be created"));
                var roster = VaultRoster.issue (keys.authority, keys.dataset, Uuid.string_random (), scope, sync.ledger.roster ().revision + 1, devices, root, retired);
                keys.authorize (roster, keys.administrator, root, keys.authority);
                yield keys.save_pending (account, profile);
                var prepared = statement ("UPDATE invitations SET state=1,snapshot=?2 WHERE nonce=?1");
                prepared.bind_text (1, nonce);
                prepared.bind_text (2, Checksum.compute_for_bytes (ChecksumType.SHA256, VaultCrypto.authenticate (sync.keys.signing, sync.snapshot ())));
                if (prepared.step () != Sqlite.DONE) throw new IOError.FAILED (_("The pending approval was not retained"));
            }
            row = invitation (nonce);
            row.step ();
            var snapshot = sync.snapshot ();
            if (Checksum.compute_for_bytes (ChecksumType.SHA256, VaultCrypto.authenticate (sync.keys.signing, snapshot)) != row.column_text (4)) throw new IOError.BUSY (_("Browser data changed during approval. Keep the pending request and retry after syncing"));
            string pending_path = Path.build_filename (directory, nonce, "journal.sqlite");
            var staged = new VaultLedger (pending_path, keys.dataset, keys.writer, scope, keys.administrator);
            if (staged.epoch == "") staged.install_roster (keys.enrollment);
            var saved = staged.saved (false);
            VaultRecord record;
            if (saved.length == 0) record = staged.stage (keys.root (staged.epoch), keys.signing, snapshot);
            else if (saved.length == 1) {
                record = saved[0];
                if (staged.reopen_saved (record, keys.root (staged.epoch)).compare (snapshot) != 0)
                    throw new IOError.INVALID_DATA (_("The prepared approval snapshot changed"));
            }
            else throw new IOError.INVALID_DATA (_("The prepared approval contains repeated snapshots"));
            var transport = yield VaultTransport.open (account, staged, profile.id, Path.build_filename (directory, nonce, "spool"), cancel);
            yield transport.publish (cancel);
            yield distribute (keys, record, cancel);
            string response = row.column_text (3);
            if (response == "") {
                response = format (peer_packet (keys, writer, binary (info, "exchange"), info), "SBRA1:");
                var retained = statement ("UPDATE invitations SET response=?2 WHERE nonce=?1");
                retained.bind_text (1, nonce);
                retained.bind_text (2, response);
                if (retained.step () != Sqlite.DONE) throw new IOError.FAILED (_("The encrypted approval could not be retained"));
            }
            check ();
            request_info (request);
            if (sync.ledger.epoch != keys.enrollment.epoch) yield sync.commit_enrollment (keys, record, snapshot);
            else if (sync.ledger.roster ().document.compare (keys.enrollment.document) != 0)
                throw new IOError.INVALID_DATA (_("The retained approval differs from the active roster"));
            var consumed = statement ("UPDATE invitations SET state=2 WHERE nonce=?1");
            consumed.bind_text (1, nonce);
            if (consumed.step () != Sqlite.DONE) throw new IOError.FAILED (_("The invitation completion was not retained"));
            return response;
        }

        private async Json.Object? latest (Accounts.CloudDrive drive, Accounts.CloudEntry directory, Bytes administrator, string dataset, Cancellable? cancel) throws Error {
            Json.Object? latest = null;
            var revisions = new Gee.HashSet<string> ();
            foreach (var entry in (yield drive.list (directory.id, cancel))) {
                if (!entry.name.has_prefix ("commit.") || !entry.name.has_suffix (".sbc")) continue;
                var info = verified (parse (yield read (drive, entry, cancel)), administrator);
                if (number (info, "format") != 1 || text (info, "kind") != "commit" || text (info, "dataset") != dataset
                    || text (info, "scope") != scope || text (info, "profile") != profile.id || number (info, "revision") <= 0
                    || entry.name != "commit." + number (info, "revision").to_string () + ".sbc")
                    throw new IOError.INVALID_DATA (_("Invalid committed device setup state"));
                var roster = VaultRoster.parse (binary (info, "roster"), binary (info, "roster-signature"), administrator);
                if (roster.dataset != dataset || roster.scope != scope || roster.epoch != text (info, "epoch")
                    || roster.revision != number (info, "revision") || Checksum.compute_for_bytes (ChecksumType.SHA256, roster.document) != text (info, "roster-hash")
                    || !revisions.add (roster.revision.to_string ())) throw new IOError.INVALID_DATA (_("The committed device roster is inconsistent or repeated"));
                if (latest == null || number (info, "revision") > number (latest, "revision")) latest = info;
            }
            check ();
            return latest;
        }

        public async string previous_approval (VaultSync sync, string request, string trusted_request, Cancellable? cancel = null) throws Error {
            check ();
            sync.check_scope ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            if (sync.keys.authority == null) throw new IOError.PERMISSION_DENIED (_("Only the administrator can retrieve a device approval"));
            var info = request_info (request);
            if (request_fingerprint (request) != trusted_request.strip ().down ())
                throw new IOError.PERMISSION_DENIED (_("Verify the request fingerprint on the new device before retrieving approval"));
            var row = invitation (text (info, "nonce"));
            if (row.step () != Sqlite.ROW || row.column_int (2) != 2 || row.column_text (0) != request || row.column_text (3) == "")
                throw new IOError.NOT_FOUND (_("This device has no completed approval to retrieve"));
            string response = row.column_text (3);
            yield sync.reload_keys ();
            var drive = yield drive (cancel);
            var folder = yield folder (drive, sync.keys.dataset, false, cancel);
            var current = yield latest (drive, folder, sync.keys.administrator, sync.keys.dataset, cancel);
            if (current == null) throw new IOError.PERMISSION_DENIED (_("The retained approval has no authenticated account acknowledgement"));
            var roster = VaultRoster.parse (binary (current, "roster"), binary (current, "roster-signature"), sync.keys.administrator);
            if (roster.revision < sync.ledger.roster ().revision)
                throw new IOError.PERMISSION_DENIED (_("The account returned an older device roster"));
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            if (sync.keys.authority == null) throw new IOError.PERMISSION_DENIED (_("The administrator authorization changed"));
            request_info (request);
            var document = verified (code (response, "SBRA1:"), sync.keys.administrator);
            var header = parse (binary (document, "header"));
            string writer = text (info, "writer");
            if (number (header, "format") != 1 || text (header, "kind") != "approval" || text (header, "scope") != scope
                || text (header, "profile") != profile.id || text (header, "dataset") != sync.keys.dataset
                || binary (header, "administrator").compare (sync.keys.administrator) != 0
                || text (header, "request") != text (info, "nonce") || text (header, "recipient") != writer
                || number (header, "expires") != number (info, "expires")
                || binary (header, "signing").compare (binary (info, "signing")) != 0
                || binary (header, "recipient-exchange").compare (binary (info, "exchange")) != 0)
                throw new IOError.INVALID_DATA (_("The retained approval differs from the original device request"));
            if (text (header, "epoch") != roster.epoch || number (header, "revision") != roster.revision
                || text (header, "roster-hash") != Checksum.compute_for_bytes (ChecksumType.SHA256, roster.document)
                || roster.devices[writer] == null || roster.devices[writer].compare (binary (info, "signing")) != 0
                || sync.keys.peers[writer] == null || sync.keys.peers[writer].compare (binary (info, "exchange")) != 0)
                throw new IOError.PERMISSION_DENIED (_("This approval is no longer current. Obtain a new request from the device"));
            return response;
        }

        private async Json.Object blob (Accounts.CloudDrive drive, Accounts.CloudEntry directory, string name, Cancellable? cancel) throws Error {
            Accounts.CloudEntry? found = null;
            foreach (var entry in (yield drive.list (directory.id, cancel))) {
                if (entry.name != name) continue;
                if (found != null) throw new IOError.INVALID_DATA (_("The encrypted device code is repeated"));
                found = entry;
            }
            if (found == null) throw new IOError.NOT_FOUND (_("The committed device code is missing"));
            return parse (yield read (drive, found, cancel));
        }

        private void peers (VaultKeys keys, Json.Object plain, VaultRoster roster) throws Error {
            if (!plain.has_member ("peers") || plain.get_member ("peers").get_node_type () != Json.NodeType.OBJECT)
                throw new IOError.INVALID_DATA (_("The device exchange roster is missing"));
            var peers = plain.get_object_member ("peers");
            if (peers.get_size () != roster.devices.size) throw new IOError.INVALID_DATA (_("The device exchange roster is incomplete"));
            foreach (string writer in peers.get_members ()) {
                var key = binary (peers, writer);
                if (roster.devices[writer] == null || VaultCrypto.exchange (keys.exchange, key) == null)
                    throw new IOError.INVALID_DATA (_("Invalid enrolled device exchange key"));
                keys.peers[writer] = key;
            }
        }

        public async void refresh (VaultSync sync, Cancellable? cancel = null) throws Error {
            check ();
            var drive = yield drive (cancel);
            var folder = yield folder (drive, sync.keys.dataset, false, cancel);
            var current = yield latest (drive, folder, sync.keys.administrator, sync.keys.dataset, cancel);
            if (current == null) return;
            var roster = VaultRoster.parse (binary (current, "roster"), binary (current, "roster-signature"), sync.keys.administrator);
            var previous = sync.ledger.roster ();
            if (roster.revision < previous.revision) throw new IOError.PERMISSION_DENIED (_("The account returned an older device roster"));
            if (roster.revision == previous.revision) {
                if (roster.document.compare (previous.document) != 0) throw new IOError.INVALID_DATA (_("The account returned another roster at the same revision"));
                return;
            }
            var member = roster.devices[sync.keys.writer];
            if (member == null || member.compare (VaultCrypto.public_key (sync.keys.signing)) != 0)
                throw new IOError.PERMISSION_DENIED (_("This device was removed. Its old encryption keys cannot open future changes"));
            var packet = yield blob (drive, folder, "device." + roster.revision.to_string () + "." + sync.keys.writer + ".sbe", cancel);
            var document = verified (packet, sync.keys.administrator);
            var header = parse (binary (document, "header"));
            if (text (header, "recipient") != sync.keys.writer || text (header, "request") != "" || number (header, "expires") != 0
                || binary (header, "signing").compare (member) != 0 || binary (header, "recipient-exchange").compare (VaultCrypto.exchange_public (sync.keys.exchange)) != 0)
                throw new IOError.PERMISSION_DENIED (_("The new encryption root is not addressed to this device"));
            var shared = VaultCrypto.exchange (sync.keys.exchange, binary (header, "exchange"));
            if (shared == null) throw new IOError.INVALID_DATA (_("Invalid device update exchange key"));
            Json.Object info;
            var plain = decrypt (packet, sync.keys.administrator, shared, "update", out info);
            var approved = approved (plain, info, sync.keys.administrator);
            if (approved.document.compare (roster.document) != 0 || text (plain, "authority") != "")
                throw new IOError.INVALID_DATA (_("The device root update differs from the committed roster"));
            var keys = sync.keys.copy ();
            keys.authorize (roster, keys.administrator, binary (plain, "root"), keys.authority);
            peers (keys, plain, roster);
            yield sync.adopt_enrollment (keys);
            check ();
        }

        private async VaultSync finish_recovery (VaultKeys keys, VaultLedger prepared, VaultRecord snapshot, Cancellable? cancel) throws Error {
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            yield keys.save (account, profile);
            var active = new VaultLedger (Path.build_filename (profile.data_dir, "sync", scope, "journal.sqlite"), keys.dataset, keys.writer, scope, keys.administrator);
            if (active.epoch == "") active.commit_prepared (keys.enrollment, keys.root (prepared.epoch), keys.signing,
                prepared.reopen_saved (snapshot, keys.root (prepared.epoch)), snapshot);
            else {
                if (active.roster ().document.compare (keys.enrollment.document) != 0)
                    throw new IOError.INVALID_DATA (_("The active recovery journal differs from its prepared roster"));
                bool retained = false;
                foreach (var record in active.saved (false)) if (record.id == snapshot.id) {
                    if (record.bytes.compare (snapshot.bytes) != 0) throw new IOError.INVALID_DATA (_("The retained recovery snapshot changed"));
                    retained = true;
                }
                if (!retained) active.receive (snapshot.bytes, keys.root (prepared.epoch));
            }
            return yield VaultSync.open (account, profile);
        }

        public async VaultSync recover (string recovery, Cancellable? cancel = null) throws Error {
            check ();
            VaultKeys? active_keys = null;
            try { active_keys = yield VaultKeys.load (account, profile); }
            catch (IOError.NOT_FOUND e) {}
            if (active_keys != null) {
                VaultKeys pending;
                try { pending = yield VaultKeys.pending (account, profile); }
                catch (IOError.NOT_FOUND e) { throw new IOError.EXISTS (_("This profile already has authorized keys. Recovery requires a new profile")); }
                if (pending.enrollment == null || active_keys.enrollment == null || pending.recovery == null
                    || pending.writer != active_keys.writer || pending.enrollment.document.compare (active_keys.enrollment.document) != 0)
                    throw new IOError.EXISTS (_("This profile already has authorized keys. Recovery requires a new profile"));
            }
            var code = code (recovery, "SBR1:");
            if (number (code, "format") != 1 || text (code, "scope") != scope || text (code, "profile") != profile.id
                || !VaultRoster.valid_id (text (code, "dataset")) || binary (code, "key").get_size () != 32
                || !VaultRoster.valid_public_key (binary (code, "administrator")))
                throw new IOError.PERMISSION_DENIED (_("The recovery capability belongs to another account or profile"));
            string dataset = text (code, "dataset");
            var administrator = binary (code, "administrator");
            var drive = yield drive (cancel);
            var folder = yield folder (drive, dataset, false, cancel);
            var committed = yield latest (drive, folder, administrator, dataset, cancel);
            if (committed == null) throw new IOError.NOT_FOUND (_("This dataset has no committed recovery state"));
            var packet = yield blob (drive, folder, "recovery." + number (committed, "revision").to_string () + ".sbr", cancel);
            Json.Object info;
            var plain = decrypt (packet, administrator, binary (code, "key"), "recovery", out info);
            var roster = approved (plain, info, administrator);
            if (roster.document.compare (binary (committed, "roster")) != 0 || VaultCrypto.public_key (binary (plain, "authority")) == null
                || VaultCrypto.public_key (binary (plain, "authority")).compare (administrator) != 0)
                throw new IOError.INVALID_DATA (_("The recovery authority differs from the committed roster"));
            VaultKeys keys;
            try { keys = yield VaultKeys.pending (account, profile); }
            catch (IOError.NOT_FOUND e) { keys = VaultKeys.create (account, profile); }
            if (keys.enrollment != null && keys.enrollment.document.compare (roster.document) == 0) {
                if (keys.dataset != dataset || keys.administrator.compare (administrator) != 0 || keys.recovery == null
                    || keys.recovery.compare (binary (code, "key")) != 0 || roster.devices[keys.writer] == null
                    || roster.devices[keys.writer].compare (VaultCrypto.public_key (keys.signing)) != 0
                    || keys.root (roster.epoch).compare (binary (plain, "root")) != 0)
                    throw new IOError.PERMISSION_DENIED (_("The committed recovery does not match this profile's pending identity"));
                var prepared = new VaultLedger (Path.build_filename (directory, keys.writer, "recovery-ready.sqlite"), dataset, keys.writer, scope, administrator);
                var saved = prepared.saved (false);
                if (prepared.epoch != roster.epoch || saved.length != 1 || saved[0].id != text (committed, "snapshot")
                    || Checksum.compute_for_bytes (ChecksumType.SHA256, saved[0].bytes) != text (committed, "snapshot-hash"))
                    throw new IOError.INVALID_DATA (_("The committed recovery has no matching durable snapshot"));
                var outgoing = yield VaultTransport.open (account, prepared, profile.id, Path.build_filename (directory, keys.writer, "send"), cancel);
                yield outgoing.publish (cancel);
                yield distribute (keys, saved[0], cancel);
                return yield finish_recovery (keys, prepared, saved[0], cancel);
            }
            if (active_keys != null) throw new IOError.EXISTS (_("This profile already has authorized keys. Recovery requires a new profile"));
            if (keys.epochs ().length == 0) {
                keys.recover_identity (dataset, administrator, binary (plain, "authority"), roster, binary (plain, "root"), binary (code, "key"));
                peers (keys, plain, roster);
                keys.peers[keys.writer] = VaultCrypto.exchange_public (keys.exchange);
                var devices = new Gee.HashMap<string, Bytes> ();
                devices.set_all (roster.devices);
                devices[keys.writer] = VaultCrypto.public_key (keys.signing);
                var retired = new Gee.HashSet<string> ();
                retired.add_all (roster.retired_epochs);
                retired.add (roster.epoch);
                var root = VaultCrypto.random (32);
                if (root == null || roster.revision == int64.MAX) throw new IOError.FAILED (_("A fresh recovery epoch could not be created"));
                keys.authorize (VaultRoster.issue (keys.authority, dataset, Uuid.string_random (), scope, roster.revision + 1, devices, root, retired), administrator, root, keys.authority);
                yield keys.save_pending (account, profile);
            } else if (keys.dataset != dataset || keys.administrator.compare (administrator) != 0 || keys.recovery == null
                || keys.recovery.compare (binary (code, "key")) != 0 || keys.enrollment == null || keys.enrollment.revision != roster.revision + 1)
                throw new IOError.BUSY (_("Recovery state changed. Keep this profile's pending keys and obtain the current recovery capability"));
            var source = new VaultLedger (Path.build_filename (directory, keys.writer, "recovery-source.sqlite"), dataset, keys.writer, scope, administrator);
            if (source.epoch == "") source.install_roster (roster);
            var incoming = yield VaultTransport.open (account, source, profile.id, Path.build_filename (directory, keys.writer, "receive"), cancel);
            yield incoming.receive (keys.root (source.epoch), cancel);
            var restored = new VaultDataset (keys.writer);
            bool checkpoint = false;
            foreach (var record in source.saved (true)) {
                restored.merge (source.reopen_received (record, keys.root (source.epoch)));
                if (record.id == text (committed, "snapshot") && Checksum.compute_for_bytes (ChecksumType.SHA256, record.bytes) == text (committed, "snapshot-hash")) checkpoint = true;
            }
            if (!checkpoint) throw new IOError.NOT_FOUND (_("The committed recovery snapshot is missing"));
            var prepared = new VaultLedger (Path.build_filename (directory, keys.writer, "recovery-ready.sqlite"), dataset, keys.writer, scope, administrator);
            if (prepared.epoch == "") prepared.install_roster (keys.enrollment);
            var saved = prepared.saved (false);
            VaultRecord snapshot;
            if (saved.length == 0) snapshot = prepared.stage (keys.root (prepared.epoch), keys.signing, restored.snapshot ());
            else if (saved.length == 1) snapshot = saved[0];
            else throw new IOError.INVALID_DATA (_("Recovery contains repeated prepared snapshots"));
            var outgoing = yield VaultTransport.open (account, prepared, profile.id, Path.build_filename (directory, keys.writer, "send"), cancel);
            yield outgoing.publish (cancel);
            yield distribute (keys, snapshot, cancel);
            return yield finish_recovery (keys, prepared, snapshot, cancel);
        }

        public async VaultSync accept (string response, string trusted_fingerprint, Cancellable? cancel = null) throws Error {
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            var wrapper = code (response, "SBRA1:");
            var document = parse (binary (wrapper, "document"));
            var header = parse (binary (document, "header"));
            var administrator = binary (header, "administrator");
            if (!VaultRoster.valid_public_key (administrator) || fingerprint (administrator) != trusted_fingerprint.strip ().down ())
                throw new IOError.PERMISSION_DENIED (_("Verify the administrator fingerprint on the trusted device before accepting"));
            document = verified (wrapper, administrator);
            header = parse (binary (document, "header"));
            var keys = yield VaultKeys.pending (account, profile);
            string nonce = text (header, "request");
            var row = invitation (nonce);
            if (row.step () != Sqlite.ROW || row.column_int (2) == 2) throw new IOError.PERMISSION_DENIED (_("This device invitation is absent or already used"));
            var request = request_info (row.column_text (0));
            if (nonce != keys.dataset || text (header, "recipient") != keys.writer
                || binary (header, "signing").compare (VaultCrypto.public_key (keys.signing)) != 0
                || binary (header, "recipient-exchange").compare (VaultCrypto.exchange_public (keys.exchange)) != 0
                || number (header, "expires") != number (request, "expires"))
                throw new IOError.PERMISSION_DENIED (_("The approval does not match this pending device request"));
            var shared = VaultCrypto.exchange (keys.exchange, binary (header, "exchange"));
            if (shared == null) throw new IOError.INVALID_DATA (_("Invalid approval exchange key"));
            Json.Object info;
            var plain = decrypt (wrapper, administrator, shared, "approval", out info);
            var roster = approved (plain, info, administrator);
            if (text (plain, "authority") != "") throw new IOError.INVALID_DATA (_("A paired device must not inherit the administrator private key"));
            var drive = yield drive (cancel);
            var folder = yield folder (drive, roster.dataset, false, cancel);
            var current = yield latest (drive, folder, administrator, roster.dataset, cancel);
            if (current == null) throw new IOError.PERMISSION_DENIED (_("The device approval has no authenticated account acknowledgement"));
            var committed = VaultRoster.parse (binary (current, "roster"), binary (current, "roster-signature"), administrator);
            if (committed.document.compare (roster.document) != 0)
                throw new IOError.PERMISSION_DENIED (_("The device roster changed after this approval. Obtain a current approval from the trusted device"));
            check ();
            if (cancel != null) cancel.set_error_if_cancelled ();
            request_info (row.column_text (0));
            keys.authorize (roster, administrator, binary (plain, "root"));
            peers (keys, plain, roster);
            if (keys.peers[keys.writer].compare (VaultCrypto.exchange_public (keys.exchange)) != 0) throw new IOError.INVALID_DATA (_("The enrolled exchange key differs from the pending request"));
            yield keys.save (account, profile);
            var sync = yield VaultSync.open (account, profile);
            check ();
            var consumed = statement ("UPDATE invitations SET state=2,response=?2 WHERE nonce=?1");
            consumed.bind_text (1, nonce);
            consumed.bind_text (2, response);
            if (consumed.step () != Sqlite.DONE) throw new IOError.FAILED (_("The accepted invitation was not retained"));
            return sync;
        }
    }
}
