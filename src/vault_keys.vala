namespace Singularity.Apps.Browser {

    public class VaultKeys : Object {
        public string dataset { get; private set; }
        public string writer { get; private set; }
        public string scope { get; private set; }
        public Bytes signing { get; private set; }
        public Bytes exchange { get; private set; }
        public Bytes administrator { get; private set; }
        public Bytes? authority { get; private set; }
        public Bytes? recovery { get; internal set; }
        public VaultRoster? enrollment { get; private set; }
        public Gee.Map<string, Bytes> peers = new Gee.HashMap<string, Bytes> ();
        private Gee.HashMap<string, Bytes> roots = new Gee.HashMap<string, Bytes> ();
        private static Secret.Schema? _schema;

        private static Secret.Schema schema () {
            if (_schema == null) _schema = new Secret.Schema ("dev.sinty.BrowserSync", Secret.SchemaFlags.NONE,
                "scope", Secret.SchemaAttributeType.STRING, "profile", Secret.SchemaAttributeType.STRING);
            return _schema;
        }

        internal static async Secret.Collection? default_collection (bool create, bool unlock) throws Error {
            var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
            var collection = yield Secret.Collection.for_alias (service, "default", Secret.CollectionFlags.NONE, null);
            if (collection == null && create) collection = yield Secret.Collection.create (service, _("Browser Sync"), "default", Secret.CollectionCreateFlags.NONE, null);
            if (collection != null && collection.get_locked ()) {
                if (!unlock) throw new IOError.PERMISSION_DENIED (_("The sync keys are locked"));
                var locked = new GLib.List<GLib.DBusProxy> ();
                locked.append (collection);
                GLib.List<GLib.DBusProxy>? unlocked;
                yield service.unlock (locked, null, out unlocked);
                collection.refresh ();
                if (unlocked == null || unlocked.length () == 0 || collection.get_locked ()) throw new IOError.CANCELLED (_("Sync key unlock was canceled"));
            }
            return collection;
        }

        internal static string account_scope (Accounts.Account account, Profile profile) throws Error {
            if (profile.ephemeral || profile.id == "" || profile.id == "private")
                throw new IOError.PERMISSION_DENIED (_("Private browsing cannot access sync keys"));
            if (!account.healthy || !account.has_capability (Accounts.Capability.FILES))
                throw new Accounts.AccountsError.NEEDS_REAUTH (_("The sync account is disabled or needs sign-in"));
            return VaultTransport.scope_for (account, profile.id);
        }

        public static VaultKeys create (Accounts.Account account, Profile profile) throws Error {
            var keys = new VaultKeys ();
            keys.scope = account_scope (account, profile);
            keys.dataset = Uuid.string_random ();
            keys.writer = Uuid.string_random ();
            keys.signing = VaultCrypto.signing_key ();
            keys.exchange = VaultCrypto.exchange_key ();
            keys.authority = VaultCrypto.signing_key ();
            if (keys.signing == null || keys.exchange == null || keys.authority == null)
                throw new IOError.FAILED (_("The sync device keys could not be created"));
            keys.administrator = VaultCrypto.public_key (keys.authority);
            if (keys.administrator == null) throw new IOError.FAILED (_("The sync administrator key could not be created"));
            return keys;
        }

        internal VaultKeys copy () throws Error {
            return decode (encoded (), scope);
        }

        internal void authorize (VaultRoster roster, Bytes administrator, Bytes root, Bytes? authority = null) throws Error {
            var verified = VaultRoster.parse (roster.document, roster.signature, administrator);
            var public_key = VaultCrypto.public_key (signing);
            if (verified.scope != scope || verified.devices[writer] == null || verified.devices[writer].compare (public_key) != 0
                || verified.root_commitment != VaultRoster.commitment (verified.dataset, scope, root))
                throw new IOError.PERMISSION_DENIED (_("The device approval does not match this profile or device"));
            if (roots.size != 0 && (dataset != verified.dataset || this.administrator.compare (administrator) != 0))
                throw new IOError.PERMISSION_DENIED (_("The approval belongs to another encrypted dataset"));
            if (authority != null && (VaultCrypto.public_key (authority) == null || VaultCrypto.public_key (authority).compare (administrator) != 0))
                throw new IOError.INVALID_DATA (_("The recovery authority is invalid"));
            dataset = verified.dataset;
            this.administrator = administrator;
            this.authority = authority;
            add_root (verified.epoch, root);
            enrollment = verified;
        }

        internal void recover_identity (string dataset, Bytes administrator, Bytes authority, VaultRoster roster, Bytes root, Bytes recovery) throws Error {
            if (epochs ().length != 0 || roster.dataset != dataset || roster.scope != scope
                || VaultCrypto.public_key (authority) == null || VaultCrypto.public_key (authority).compare (administrator) != 0
                || roster.root_commitment != VaultRoster.commitment (dataset, scope, root) || recovery.get_size () != 32)
                throw new IOError.INVALID_DATA (_("Invalid authenticated recovery capability"));
            this.dataset = dataset;
            this.administrator = administrator;
            this.authority = authority;
            this.recovery = recovery;
            add_root (roster.epoch, root);
        }

        public void add_root (string epoch, Bytes root) throws Error {
            if (!VaultRoster.valid_id (epoch) || root.get_size () != 32) throw new IOError.INVALID_ARGUMENT (_("Invalid sync root key"));
            foreach (var known in roots.entries) {
                if (known.key == epoch) {
                    if (known.value.compare (root) != 0) throw new IOError.INVALID_DATA (_("The encryption epoch already has another root key"));
                    return;
                }
                if (known.value.compare (root) == 0) throw new IOError.INVALID_DATA (_("A new encryption epoch requires a new root key"));
            }
            if (roots.size >= 1024) throw new IOError.NO_SPACE (_("Too many stored sync root keys"));
            roots[epoch] = root;
        }

        public Bytes root (string epoch) throws Error {
            var key = roots[epoch];
            if (key == null) throw new IOError.NOT_FOUND (_("This device has no root key for the encryption epoch"));
            return key;
        }

        public string[] epochs () {
            var ids = new Gee.ArrayList<string> ();
            ids.add_all (roots.keys);
            ids.sort ();
            return ids.to_array ();
        }

        private Bytes encoded () {
            var object = new Json.Object ();
            object.set_int_member ("format", 1);
            object.set_string_member ("dataset", dataset);
            object.set_string_member ("writer", writer);
            object.set_string_member ("scope", scope);
            object.set_string_member ("signing", Base64.encode (signing.get_data ()));
            object.set_string_member ("exchange", Base64.encode (exchange.get_data ()));
            object.set_string_member ("administrator", Base64.encode (administrator.get_data ()));
            object.set_string_member ("authority", authority == null ? "" : Base64.encode (authority.get_data ()));
            object.set_string_member ("recovery", recovery == null ? "" : Base64.encode (recovery.get_data ()));
            object.set_string_member ("roster", enrollment == null ? "" : Base64.encode (enrollment.document.get_data ()));
            object.set_string_member ("roster-signature", enrollment == null ? "" : Base64.encode (enrollment.signature.get_data ()));
            var exchange_keys = new Json.Object ();
            var writers = new Gee.ArrayList<string> ();
            writers.add_all (peers.keys);
            writers.sort ();
            foreach (string writer in writers) exchange_keys.set_string_member (writer, Base64.encode (peers[writer].get_data ()));
            object.set_object_member ("peers", exchange_keys);
            var epochs = new Json.Object ();
            var ids = new Gee.ArrayList<string> ();
            ids.add_all (roots.keys);
            ids.sort ();
            foreach (string id in ids) epochs.set_string_member (id, Base64.encode (roots[id].get_data ()));
            object.set_object_member ("roots", epochs);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (object);
            var generator = new Json.Generator ();
            generator.set_root (node);
            return new Bytes (generator.to_data (null).data);
        }

        private static string text (Json.Object object, string key) throws Error {
            if (!object.has_member (key) || object.get_member (key).get_node_type () != Json.NodeType.VALUE
                || object.get_member (key).get_value ().type () != typeof (string)) throw new IOError.INVALID_DATA (_("Invalid stored sync key field"));
            return object.get_string_member (key);
        }

        private static Bytes binary (Json.Object object, string key) throws Error {
            string value = text (object, key);
            if (value.length > 8192) throw new IOError.INVALID_DATA (_("Invalid stored sync key size"));
            var bytes = new Bytes (Base64.decode (value));
            if (Base64.encode (bytes.get_data ()) != value) throw new IOError.INVALID_DATA (_("Invalid stored sync key encoding"));
            return bytes;
        }

        private static VaultKeys decode (Bytes bytes, string scope) throws Error {
            if (bytes.get_size () == 0 || bytes.get_size () > 131072) throw new IOError.INVALID_DATA (_("Invalid stored sync keys"));
            foreach (uint8 c in bytes.get_data ()) if (c == 0) throw new IOError.INVALID_DATA (_("Invalid stored sync key encoding"));
            var parser = new Json.Parser ();
            try { parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ()); }
            catch (Error e) { throw new IOError.INVALID_DATA (_("The stored sync keys could not be parsed")); }
            var node = parser.get_root ();
            if (node == null || node.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid stored sync keys"));
            var object = node.get_object ();
            if (!object.has_member ("format") || object.get_member ("format").get_node_type () != Json.NodeType.VALUE || object.get_member ("format").get_value_type () != typeof (int64)
                || object.get_int_member ("format") != 1) throw new IOError.INVALID_DATA (_("Unsupported stored sync keys"));
            var keys = new VaultKeys ();
            keys.dataset = text (object, "dataset");
            keys.writer = text (object, "writer");
            keys.scope = text (object, "scope");
            if (!VaultRoster.valid_id (keys.dataset) || !VaultRoster.valid_id (keys.writer) || keys.scope != scope)
                throw new IOError.INVALID_DATA (_("The stored sync keys belong to another account or device"));
            keys.signing = binary (object, "signing");
            keys.exchange = binary (object, "exchange");
            keys.administrator = binary (object, "administrator");
            if (VaultCrypto.public_key (keys.signing) == null || VaultCrypto.exchange_public (keys.exchange) == null || !VaultRoster.valid_public_key (keys.administrator))
                throw new IOError.INVALID_DATA (_("The stored sync device keys are invalid"));
            if (text (object, "authority") != "") {
                keys.authority = binary (object, "authority");
                var public_key = VaultCrypto.public_key (keys.authority);
                if (public_key == null || public_key.compare (keys.administrator) != 0) throw new IOError.INVALID_DATA (_("The stored sync administrator key is invalid"));
            }
            if (!object.has_member ("roots") || object.get_member ("roots").get_node_type () != Json.NodeType.OBJECT)
                throw new IOError.INVALID_DATA (_("The stored sync root keys are missing"));
            var roots = object.get_object_member ("roots");
            if (roots.get_size () > 1024) throw new IOError.INVALID_DATA (_("Too many stored sync root keys"));
            foreach (string epoch in roots.get_members ()) keys.add_root (epoch, binary (roots, epoch));
            if (object.has_member ("recovery") && text (object, "recovery") != "") {
                keys.recovery = binary (object, "recovery");
                if (keys.recovery.get_size () != 32) throw new IOError.INVALID_DATA (_("Invalid recovery key"));
            }
            if (object.has_member ("roster") && text (object, "roster") != "") {
                keys.enrollment = VaultRoster.parse (binary (object, "roster"), binary (object, "roster-signature"), keys.administrator);
                var member = keys.enrollment.devices[keys.writer];
                if (keys.enrollment.dataset != keys.dataset || keys.enrollment.scope != scope || member == null
                    || member.compare (VaultCrypto.public_key (keys.signing)) != 0
                    || keys.enrollment.root_commitment != VaultRoster.commitment (keys.dataset, scope, keys.root (keys.enrollment.epoch)))
                    throw new IOError.INVALID_DATA (_("The saved device approval is invalid"));
            }
            if (object.has_member ("peers")) {
                if (object.get_member ("peers").get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid device exchange keys"));
                var peers = object.get_object_member ("peers");
                if (peers.get_size () > 256) throw new IOError.INVALID_DATA (_("Too many device exchange keys"));
                foreach (string writer in peers.get_members ()) {
                    if (!VaultRoster.valid_id (writer)) throw new IOError.INVALID_DATA (_("Invalid device exchange identity"));
                    var key = binary (peers, writer);
                    if (VaultCrypto.exchange (keys.exchange, key) == null) throw new IOError.INVALID_DATA (_("Invalid device exchange key"));
                    keys.peers[writer] = key;
                }
            }
            return keys;
        }

        private static Secret.Schema pending_schema () {
            return new Secret.Schema ("dev.sinty.BrowserPairing", Secret.SchemaFlags.NONE,
                "scope", Secret.SchemaAttributeType.STRING, "profile", Secret.SchemaAttributeType.STRING);
        }

        internal static async VaultKeys pending (Accounts.Account account, Profile profile) throws Error {
            string scope = account_scope (account, profile);
            var collection = yield default_collection (false, true);
            if (collection == null) throw new IOError.NOT_FOUND (_("There is no pending device request"));
            var attributes = new HashTable<string, string> (str_hash, str_equal);
            attributes["scope"] = scope;
            attributes["profile"] = profile.id;
            var items = yield collection.search (pending_schema (), attributes, Secret.SearchFlags.ALL, null);
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The pairing account changed"));
            if (items.length () == 0) throw new IOError.NOT_FOUND (_("There is no pending device request"));
            if (items.length () != 1) throw new IOError.INVALID_DATA (_("The pending device request is ambiguous"));
            var value = yield items.data.retrieve_secret (null);
            if (value == null || value.get_content_type () != "text/plain") throw new IOError.INVALID_DATA (_("The pending device keys are unavailable"));
            return decode (new Bytes (value.get ()), scope);
        }

        internal async void save_pending (Accounts.Account account, Profile profile) throws Error {
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The pairing account changed"));
            var collection = yield default_collection (true, true);
            var attributes = new HashTable<string, string> (str_hash, str_equal);
            attributes["scope"] = scope;
            attributes["profile"] = profile.id;
            var bytes = encoded ();
            yield Secret.Item.create (collection, pending_schema (), attributes, _("Browser Device Request (%s)").printf (profile.id),
                new Secret.Value ((string) bytes.get_data (), (ssize_t) bytes.get_size (), "text/plain"), Secret.ItemCreateFlags.REPLACE, null);
            var observed = yield pending (account, profile);
            if (observed.encoded ().compare (bytes) != 0) throw new IOError.FAILED (_("The pending device keys were not retained"));
        }

        internal async void archive_request (Accounts.Account account, Profile profile) throws Error {
            if (enrollment != null || roots.size != 0 || recovery != null)
                throw new IOError.PERMISSION_DENIED (_("Authorized or prepared device keys cannot be replaced by a new request"));
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The pairing account changed"));
            var collection = yield default_collection (true, true);
            var schema = new Secret.Schema ("dev.sinty.BrowserRequestArchive", Secret.SchemaFlags.NONE,
                "scope", Secret.SchemaAttributeType.STRING, "profile", Secret.SchemaAttributeType.STRING, "nonce", Secret.SchemaAttributeType.STRING);
            var attributes = new HashTable<string, string> (str_hash, str_equal);
            attributes["scope"] = scope;
            attributes["profile"] = profile.id;
            attributes["nonce"] = dataset;
            var bytes = encoded ();
            var items = yield collection.search (schema, attributes, Secret.SearchFlags.ALL, null);
            if (items.length () > 1) throw new IOError.INVALID_DATA (_("The saved device request archive is ambiguous"));
            Secret.Item item;
            if (items.length () == 0) item = yield Secret.Item.create (collection, schema, attributes, _("Previous Browser Device Request (%s)").printf (profile.id),
                new Secret.Value ((string) bytes.get_data (), (ssize_t) bytes.get_size (), "text/plain"), Secret.ItemCreateFlags.REPLACE, null);
            else item = items.data;
            var observed = yield item.retrieve_secret (null);
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The pairing account changed while retaining the previous request"));
            if (observed == null || observed.get_content_type () != "text/plain" || new Bytes (observed.get ()).compare (bytes) != 0)
                throw new IOError.FAILED (_("The previous device keys were not retained. Keep the existing request and retry"));
        }

        public static async VaultKeys load (Accounts.Account account, Profile profile, bool unlock = true) throws Error {
            string scope = account_scope (account, profile);
            var collection = yield default_collection (false, unlock);
            if (collection == null) throw new IOError.NOT_FOUND (_("This profile has no saved sync keys"));
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The sync account changed during key unlock"));
            var attributes = new HashTable<string, string> (str_hash, str_equal);
            attributes["scope"] = scope;
            attributes["profile"] = profile.id;
            var items = yield Secret.password_searchv (schema (), attributes, Secret.SearchFlags.ALL, null);
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The sync account changed during key lookup"));
            if (items.length () == 0) throw new IOError.NOT_FOUND (_("This profile has no saved sync keys"));
            if (items.length () != 1) throw new IOError.INVALID_DATA (_("This profile has ambiguous saved sync keys"));
            var item = items.data as Secret.Item;
            if (item == null) throw new IOError.INVALID_DATA (_("The keyring returned an invalid sync key item"));
            if (item.get_locked ()) {
                if (!unlock) throw new IOError.PERMISSION_DENIED (_("The sync keys are locked"));
                var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
                var locked = new GLib.List<GLib.DBusProxy> ();
                locked.append (item);
                GLib.List<GLib.DBusProxy>? unlocked;
                yield service.unlock (locked, null, out unlocked);
                item.refresh ();
                if (unlocked == null || unlocked.length () == 0 || item.get_locked ()) throw new IOError.CANCELLED (_("Sync key unlock was canceled"));
            }
            var value = yield item.retrieve_secret (null);
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The sync account changed during key lookup"));
            if (value == null || value.get_content_type () != "text/plain") throw new IOError.INVALID_DATA (_("The keyring returned no sync keys"));
            return decode (new Bytes (value.get ()), scope);
        }

        public async void save (Accounts.Account account, Profile profile) throws Error {
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The sync keys belong to another profile or account"));
            try {
                var previous = yield load (account, profile);
                if (previous.dataset != dataset || previous.writer != writer || previous.administrator.compare (administrator) != 0)
                    throw new IOError.INVALID_DATA (_("This profile already has another sync dataset"));
                if (VaultCrypto.public_key (previous.signing).compare (VaultCrypto.public_key (signing)) != 0
                    || VaultCrypto.exchange_public (previous.exchange).compare (VaultCrypto.exchange_public (exchange)) != 0)
                    throw new IOError.INVALID_DATA (_("The saved sync device keys cannot be replaced"));
                foreach (var known in previous.roots.entries) add_root (known.key, known.value);
                recovery = recovery ?? previous.recovery;
                if (enrollment == null) enrollment = previous.enrollment;
                else if (previous.enrollment != null && (enrollment.revision < previous.enrollment.revision
                    || (enrollment.revision == previous.enrollment.revision && enrollment.document.compare (previous.enrollment.document) != 0)))
                    throw new IOError.INVALID_DATA (_("The saved device approval cannot be rolled back or replaced"));
            } catch (IOError.NOT_FOUND e) {}
            var collection = yield default_collection (true, true);
            if (account_scope (account, profile) != scope) throw new IOError.PERMISSION_DENIED (_("The sync account changed before saving keys"));
            var attributes = new HashTable<string, string> (str_hash, str_equal);
            attributes["scope"] = scope;
            attributes["profile"] = profile.id;
            var bytes = encoded ();
            var value = new Secret.Value ((string) bytes.get_data (), (ssize_t) bytes.get_size (), "text/plain");
            yield Secret.Item.create (collection, schema (), attributes, _("Browser Sync (%s)").printf (profile.id), value, Secret.ItemCreateFlags.REPLACE, null);
            var observed = yield load (account, profile, false);
            if (observed.encoded ().compare (bytes) != 0) throw new IOError.FAILED (_("The keyring did not retain the saved sync keys"));
        }
    }
}
