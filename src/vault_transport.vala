namespace Singularity.Apps.Browser {

    private class VaultSink : OutputStream {
        private ByteArray data = new ByteArray ();

        public override ssize_t write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            if (buffer.length > VaultEnvelope.MAX_SIZE + 68 - data.len) throw new IOError.NO_SPACE (_("The encrypted record is too large"));
            data.append (buffer);
            return buffer.length;
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            return true;
        }

        public Bytes bytes () {
            return new Bytes (data.data);
        }
    }

    public class VaultTransport : Object {
        private Accounts.CloudDrive drive;
        private VaultLedger ledger;
        private string folder;
        private string directory;
        private string profile;

        public static string scope_for (Accounts.Account account, string profile) {
            var object = new Json.Object ();
            object.set_int_member ("format", 1);
            object.set_string_member ("provider", account.provider);
            object.set_string_member ("identity", account.identity);
            object.set_string_member ("profile", profile);
            string endpoint = account.get_endpoint ("webdav") ?? account.get_endpoint ("graph") ?? account.get_endpoint ("google-drive") ?? "";
            object.set_string_member ("endpoint", endpoint);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (object);
            var generator = new Json.Generator ();
            generator.set_root (node);
            return Checksum.compute_for_string (ChecksumType.SHA256, generator.to_data (null));
        }

        private VaultTransport (Accounts.CloudDrive drive, VaultLedger ledger, string folder, string directory, string profile) {
            this.drive = drive;
            this.ledger = ledger;
            this.folder = folder;
            this.directory = directory;
            this.profile = profile;
        }

        private void check_scope () throws Error {
            if (!drive.account.healthy || !drive.account.has_capability (Accounts.Capability.FILES))
                throw new Accounts.AccountsError.NEEDS_REAUTH (_("The sync account is disabled or needs sign-in"));
            if (scope_for (drive.account, profile) != ledger.scope) throw new IOError.PERMISSION_DENIED (_("The sync account or profile has changed"));
        }

        public static async VaultTransport open (Accounts.Account account, VaultLedger ledger, string profile, string directory, Cancellable? cancellable = null) throws Error {
            if (profile == "" || profile == "private" || scope_for (account, profile) != ledger.scope)
                throw new IOError.PERMISSION_DENIED (_("This profile cannot access the encrypted dataset"));
            var drive = yield Accounts.CloudDrive.for_app_data (account, cancellable);
            if (drive == null) throw new IOError.NOT_SUPPORTED (_("This account has no application-data storage"));
            string name = "browser-" + ledger.dataset;
            var entries = yield drive.list (drive.root_id, cancellable);
            Accounts.CloudEntry? found = null;
            foreach (var entry in entries) {
                if (entry.name != name) continue;
                if (found != null || !entry.is_folder) throw new Accounts.AccountsError.CONFLICT (_("The encrypted dataset directory is ambiguous"));
                found = entry;
            }
            if (found == null) found = yield drive.create_folder (drive.root_id, name, cancellable);
            if (!found.is_folder || found.name != name) throw new Accounts.AccountsError.PROTOCOL (_("The account did not create the encrypted dataset directory"));
            var transport = new VaultTransport (drive, ledger, found.id, directory, profile);
            transport.check_scope ();
            return transport;
        }

        private async Bytes read (Accounts.CloudEntry entry, Cancellable? cancellable) throws Error {
            check_scope ();
            if (entry.is_folder || entry.size > VaultEnvelope.MAX_SIZE + 68) throw new IOError.INVALID_DATA (_("Invalid encrypted record in account storage"));
            var output = new VaultSink ();
            yield drive.download_to (entry, output, cancellable);
            check_scope ();
            return output.bytes ();
        }

        private async File spool (VaultRecord record, Cancellable? cancellable) throws Error {
            if (DirUtils.create_with_parents (directory, 0700) != 0) throw new IOError.FAILED (_("The encrypted upload directory could not be created"));
            var file = File.new_for_path (Path.build_filename (directory, record.id + ".sbs"));
            var stream = yield file.replace_async (null, false, FileCreateFlags.PRIVATE | FileCreateFlags.REPLACE_DESTINATION, Priority.DEFAULT, cancellable);
            try {
                yield stream.write_all_async (record.bytes.get_data (), Priority.DEFAULT, cancellable, null);
                yield stream.close_async (Priority.DEFAULT, cancellable);
            } catch (Error e) {
                try { yield stream.close_async (Priority.DEFAULT, null); } catch (Error ignored) {}
                throw e;
            }
            return file;
        }

        public async void publish (Cancellable? cancellable = null) throws Error {
            check_scope ();
            foreach (var record in ledger.pending ()) {
                check_scope ();
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                string name = record.id + ".sbs";
                var entries = yield drive.list (folder, cancellable);
                Accounts.CloudEntry? existing = null;
                foreach (var entry in entries) {
                    if (entry.name != name) continue;
                    if (existing != null) throw new Accounts.AccountsError.CONFLICT (_("The account contains repeated encrypted records"));
                    existing = entry;
                }
                if (existing == null) {
                    var file = yield spool (record, cancellable);
                    try {
                        check_scope ();
                        existing = yield drive.upload (folder, name, file, cancellable);
                        if (existing.name != name) throw new Accounts.AccountsError.PROTOCOL (_("The account acknowledged another encrypted record"));
                    } finally {
                        try { file.delete (null); } catch (Error ignored) {}
                    }
                }
                var observed = yield read (existing, cancellable);
                if (observed.compare (record.bytes) != 0) throw new Accounts.AccountsError.CONFLICT (_("The stored encrypted record differs from the pending record"));
                check_scope ();
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                ledger.acknowledge (record.id, existing.id, observed);
            }
        }

        public async int receive (Bytes root, Cancellable? cancellable = null) throws Error {
            check_scope ();
            var entries = yield drive.list (folder, cancellable);
            var records = new Gee.ArrayList<Accounts.CloudEntry> ();
            foreach (var entry in entries) {
                if (!entry.name.has_prefix (ledger.dataset + ".") || !entry.name.has_suffix (".sbs")) continue;
                records.add (entry);
            }
            records.sort ((a, b) => strcmp (a.name, b.name));
            int received = 0;
            foreach (var entry in records) {
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                var wire = yield read (entry, cancellable);
                if (wire.get_size () < 68 + VaultEnvelope.HEADER_SIZE + 16) throw new IOError.INVALID_DATA (_("The stored encrypted record is truncated"));
                var envelope = VaultEnvelope.parse (new Bytes.from_bytes (wire, 68, wire.get_size () - 68));
                string expected = envelope.dataset + "." + envelope.epoch + "." + envelope.writer + "." + ("%020" + uint64.FORMAT).printf (envelope.sequence) + ".sbs";
                if (entry.name != expected) throw new IOError.INVALID_DATA (_("The encrypted record name does not match its authenticated identity"));
                if (envelope.dataset != ledger.dataset || envelope.scope != ledger.scope)
                    throw new IOError.INVALID_DATA (_("The encrypted record belongs to another dataset or account"));
                if (ledger.is_retired (envelope.epoch)) continue;
                if (ledger.received (expected.substring (0, expected.length - 4))) continue;
                check_scope ();
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                ledger.receive (wire, root);
                received++;
            }
            return received;
        }
    }
}
