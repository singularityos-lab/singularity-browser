namespace Singularity.Apps.Browser {

    public class VaultSync : Object {
        public VaultLedger ledger { get; private set; }
        public VaultKeys keys { get; private set; }
        private Accounts.Account account;
        private Profile profile;
        private VaultDataset model;
        private bool busy;

        private VaultSync (Accounts.Account account, Profile profile, VaultKeys keys, VaultLedger ledger) throws Error {
            this.account = account;
            this.profile = profile;
            this.keys = keys;
            this.ledger = ledger;
            check_scope ();
            model = restore ();
        }

        internal void check_scope () throws Error {
            if (profile.ephemeral || !account.healthy || !account.has_capability (Accounts.Capability.FILES))
                throw new IOError.PERMISSION_DENIED (_("This profile or account cannot sync browser data"));
            if (VaultTransport.scope_for (account, profile.id) != keys.scope || keys.scope != ledger.scope
                || keys.dataset != ledger.dataset || keys.writer != ledger.writer)
                throw new IOError.PERMISSION_DENIED (_("The encrypted dataset belongs to another account or profile"));
        }

        public static async VaultSync open (Accounts.Account account, Profile profile, bool create = false, bool unlock = true) throws Error {
            VaultKeys keys;
            try { keys = yield VaultKeys.load (account, profile, unlock); }
            catch (IOError.NOT_FOUND e) {
                if (!create) throw e;
                keys = VaultKeys.create (account, profile);
                keys.add_root (Uuid.string_random (), VaultCrypto.random (32));
                yield keys.save (account, profile);
            }
            var ledger = new VaultLedger (Path.build_filename (profile.data_dir, "sync", keys.scope, "journal.sqlite"),
                keys.dataset, keys.writer, keys.scope, keys.administrator);
            if (ledger.epoch == "") {
                if (keys.enrollment != null) {
                    ledger.install_roster (keys.enrollment);
                } else {
                var epochs = keys.epochs ();
                if (keys.authority == null || epochs.length != 1) throw new IOError.INVALID_DATA (_("The saved sync keys need device enrollment recovery"));
                var devices = new Gee.HashMap<string, Bytes> ();
                devices[keys.writer] = VaultCrypto.public_key (keys.signing);
                ledger.install_roster (VaultRoster.issue (keys.authority, keys.dataset, epochs[0], keys.scope, 1, devices, keys.root (epochs[0])));
                }
            }
            var roster = ledger.roster ();
            if (roster.devices[keys.writer] == null || roster.devices[keys.writer].compare (VaultCrypto.public_key (keys.signing)) != 0)
                throw new IOError.PERMISSION_DENIED (_("This device has no active enrollment in the signed roster"));
            if (roster.root_commitment != VaultRoster.commitment (keys.dataset, keys.scope, keys.root (roster.epoch)))
                throw new IOError.INVALID_DATA (_("The saved keys do not match the device roster"));
            return new VaultSync (account, profile, keys, ledger);
        }

        internal Bytes snapshot () throws Error {
            check_scope ();
            return model.snapshot ();
        }

        internal async void reload_keys () throws Error {
            check_scope ();
            var saved = yield VaultKeys.load (account, profile);
            if (saved.dataset != keys.dataset || saved.writer != keys.writer || saved.administrator.compare (keys.administrator) != 0)
                throw new IOError.PERMISSION_DENIED (_("The saved enrollment belongs to another device"));
            keys = saved;
            check_scope ();
        }

        internal async void adopt_enrollment (VaultKeys prepared) throws Error {
            check_scope ();
            if (busy || prepared.enrollment == null || prepared.dataset != keys.dataset || prepared.writer != keys.writer)
                throw new IOError.BUSY (_("The device enrollment cannot be changed during sync"));
            var snapshot = model.snapshot ();
            yield prepared.save (account, profile);
            check_scope ();
            ledger.rotate (prepared.enrollment, prepared.root (prepared.enrollment.epoch), prepared.signing, snapshot);
            keys = prepared;
            model = restore ();
        }

        internal async void commit_enrollment (VaultKeys prepared, VaultRecord record, Bytes snapshot) throws Error {
            check_scope ();
            if (busy || model.snapshot ().compare (snapshot) != 0)
                throw new IOError.BUSY (_("Browser data changed during device approval"));
            if (prepared.enrollment == null || prepared.dataset != keys.dataset || prepared.writer != keys.writer)
                throw new IOError.INVALID_DATA (_("The prepared device approval is invalid"));
            yield prepared.save (account, profile);
            check_scope ();
            ledger.commit_prepared (prepared.enrollment, prepared.root (prepared.enrollment.epoch), prepared.signing, snapshot, record);
            keys = prepared;
            model = restore ();
        }

        private static VaultEnvelope envelope (VaultRecord record) throws Error {
            if (record.bytes.get_size () < 68 + VaultEnvelope.HEADER_SIZE + 16) throw new IOError.INVALID_DATA (_("The saved browser snapshot is truncated"));
            return VaultEnvelope.parse (new Bytes.from_bytes (record.bytes, 68, record.bytes.get_size () - 68));
        }

        private VaultDataset restore () throws Error {
            var restored = new VaultDataset (keys.writer);
            foreach (bool incoming in new bool[] { false, true }) {
                foreach (var record in ledger.saved (incoming))
                    restored.merge (ledger.reopen_saved (record, keys.root (envelope (record).epoch), incoming));
            }
            return restored;
        }

        private VaultDataset candidate () throws Error {
            check_scope ();
            if (busy) throw new IOError.BUSY (_("The browser dataset is syncing"));
            var copy = new VaultDataset (keys.writer);
            copy.merge (model.snapshot ());
            return copy;
        }

        public VaultItem[] items () {
            return model.items ();
        }

        public VaultItem? get_item (string id) {
            return model.get_item (id);
        }

        public string create (string kind, Json.Object payload) throws Error {
            var copy = candidate ();
            string id = copy.create (kind, payload);
            ledger.stage (keys.root (ledger.epoch), keys.signing, copy.snapshot ());
            model = copy;
            return id;
        }

        public void update (string id, string kind, Json.Object? payload) throws Error {
            var copy = candidate ();
            copy.update (id, kind, payload);
            ledger.stage (keys.root (ledger.epoch), keys.signing, copy.snapshot ());
            model = copy;
        }

        public async void sync (Cancellable? cancellable = null) throws Error {
            check_scope ();
            if (busy) throw new IOError.BUSY (_("The browser dataset is syncing"));
            busy = true;
            try {
                var transport = yield VaultTransport.open (account, ledger, profile.id, Path.build_filename (profile.data_dir, "sync", keys.scope, "spool"), cancellable);
                check_scope ();
                yield transport.publish (cancellable);
                check_scope ();
                yield transport.receive (keys.root (ledger.epoch), cancellable);
                check_scope ();
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                var restored = restore ();
                if (restored.snapshot ().compare (model.snapshot ()) != 0)
                    ledger.stage (keys.root (ledger.epoch), keys.signing, restored.snapshot ());
                model = restored;
                foreach (var record in ledger.pending (true)) ledger.applied (record.id);
                yield transport.publish (cancellable);
                check_scope ();
            } finally { busy = false; }
        }

        public async VaultRoster rotate (Gee.Map<string, Bytes> devices) throws Error {
            check_scope ();
            if (busy) throw new IOError.BUSY (_("The browser dataset is syncing"));
            if (keys.authority == null) throw new IOError.PERMISSION_DENIED (_("Only the enrolled administrator can change devices"));
            var public_key = VaultCrypto.public_key (keys.signing);
            if (devices[keys.writer] == null || devices[keys.writer].compare (public_key) != 0)
                throw new IOError.PERMISSION_DENIED (_("Rotation must retain this device's enrolled signing key"));
            var previous = ledger.roster ();
            if (previous.revision == int64.MAX) throw new IOError.NO_SPACE (_("The device roster revision is exhausted"));
            var restored = restore ();
            var snapshot = restored.snapshot ();
            string epoch = Uuid.string_random ();
            var root = VaultCrypto.random (32);
            var retired = new Gee.HashSet<string> ();
            retired.add_all (previous.retired_epochs);
            retired.add (previous.epoch);
            var roster = VaultRoster.issue (keys.authority, keys.dataset, epoch, keys.scope, previous.revision + 1, devices, root, retired);
            busy = true;
            try {
                var saved = yield VaultKeys.load (account, profile);
                saved.add_root (epoch, root);
                yield saved.save (account, profile);
                check_scope ();
                ledger.rotate (roster, root, saved.signing, snapshot);
                keys = saved;
                model = restored;
                return roster;
            } finally { busy = false; }
        }
    }
}
