namespace Singularity.Apps.Browser {

    public class VaultRoster : Object {
        public string dataset { get; private set; }
        public string epoch { get; private set; }
        public string scope { get; private set; }
        public string root_commitment { get; private set; }
        public int64 revision { get; private set; }
        public Gee.Map<string, Bytes> devices { get; private set; }
        public Gee.Set<string> retired_epochs { get; private set; }
        public Bytes document { get; private set; }
        public Bytes signature { get; private set; }

        public static bool valid_id (string id) {
            return Uuid.string_is_valid (id) && id == id.down ();
        }

        public static bool valid_scope (string scope) {
            if (scope.length != 64) return false;
            foreach (uint8 c in scope.data) {
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            }
            return true;
        }

        public static bool valid_public_key (Bytes key) {
            uint8[] prefix = { 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
            return key.get_size () == 44 && new Bytes.from_bytes (key, 0, 12).compare (new Bytes (prefix)) == 0;
        }

        private static string text (Json.Object object, string member) throws Error {
            if (!object.has_member (member)) throw new IOError.INVALID_DATA (_("Incomplete device roster"));
            var node = object.get_member (member);
            if (node.get_node_type () != Json.NodeType.VALUE || node.get_value ().type () != typeof (string))
                throw new IOError.INVALID_DATA (_("Invalid device roster field"));
            return node.get_string ();
        }

        public static string commitment (string dataset, string scope, Bytes root) throws Error {
            if (!valid_id (dataset) || !valid_scope (scope) || root.get_size () != 32)
                throw new IOError.INVALID_ARGUMENT (_("Invalid encryption root"));
            var derived = VaultCrypto.derive (root, new Bytes (dataset.data), new Bytes (("browser-roster-root\n" + scope).data));
            if (derived == null) throw new IOError.FAILED (_("The encryption root could not be bound to the device roster"));
            return Checksum.compute_for_bytes (ChecksumType.SHA256, derived);
        }

        public static VaultRoster issue (Bytes administrator, string dataset, string epoch, string scope, int64 revision, Gee.Map<string, Bytes> devices, Bytes root, Gee.Set<string>? retired_epochs = null) throws Error {
            if (!valid_id (dataset) || !valid_id (epoch) || !valid_scope (scope) || revision <= 0 || devices.size == 0 || devices.size > 256)
                throw new IOError.INVALID_ARGUMENT (_("Invalid device roster"));
            var object = new Json.Object ();
            object.set_int_member ("format", 2);
            object.set_string_member ("dataset", dataset);
            object.set_string_member ("epoch", epoch);
            object.set_string_member ("scope", scope);
            object.set_string_member ("root", commitment (dataset, scope, root));
            object.set_int_member ("revision", revision);
            var retired = new Json.Array ();
            if (retired_epochs != null) {
                var retired_ids = new Gee.ArrayList<string> ();
                retired_ids.add_all (retired_epochs);
                retired_ids.sort ();
                foreach (string id in retired_ids) retired.add_string_element (id);
            }
            object.set_array_member ("retired", retired);
            var array = new Json.Array ();
            var ids = new Gee.ArrayList<string> ();
            ids.add_all (devices.keys);
            ids.sort ();
            foreach (string id in ids) {
                var key = devices[id];
                if (!valid_id (id) || !valid_public_key (key)) throw new IOError.INVALID_ARGUMENT (_("Invalid enrolled device"));
                var device = new Json.Object ();
                device.set_string_member ("id", id);
                device.set_string_member ("key", Base64.encode (key.get_data ()));
                array.add_object_element (device);
            }
            object.set_array_member ("devices", array);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (object);
            var generator = new Json.Generator ();
            generator.set_root (node);
            var bytes = new Bytes (generator.to_data (null).data);
            var signature = VaultCrypto.sign (administrator, bytes);
            var public_key = VaultCrypto.public_key (administrator);
            if (signature == null || public_key == null) throw new IOError.FAILED (_("The device roster could not be signed"));
            return parse (bytes, signature, public_key);
        }

        public static VaultRoster parse (Bytes document, Bytes signature, Bytes administrator) throws Error {
            if (document.get_size () == 0 || document.get_size () > 65536 || !valid_public_key (administrator)
                || !VaultCrypto.verify (administrator, document, signature))
                throw new IOError.INVALID_DATA (_("The device roster could not be authenticated"));
            unowned uint8[] raw = document.get_data ();
            foreach (uint8 c in raw) if (c == 0) throw new IOError.INVALID_DATA (_("Invalid device roster encoding"));
            var parser = new Json.Parser ();
            parser.load_from_data ((string) raw, raw.length);
            var node = parser.get_root ();
            if (node == null || node.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid device roster"));
            var object = node.get_object ();
            foreach (string member in new string[] { "format", "revision" }) {
                if (!object.has_member (member) || object.get_member (member).get_node_type () != Json.NodeType.VALUE
                    || object.get_member (member).get_value ().type () != typeof (int64))
                    throw new IOError.INVALID_DATA (_("Invalid device roster version"));
            }
            var roster = new VaultRoster ();
            roster.dataset = text (object, "dataset");
            roster.epoch = text (object, "epoch");
            roster.scope = text (object, "scope");
            roster.root_commitment = text (object, "root");
            roster.revision = object.get_int_member ("revision");
            if (object.get_int_member ("format") != 2 || roster.revision <= 0 || !valid_id (roster.dataset)
                || !valid_id (roster.epoch) || !valid_scope (roster.scope) || !valid_scope (roster.root_commitment))
                throw new IOError.INVALID_DATA (_("Invalid device roster identity"));
            if (!object.has_member ("retired") || object.get_member ("retired").get_node_type () != Json.NodeType.ARRAY)
                throw new IOError.INVALID_DATA (_("The device roster has no encryption epoch policy"));
            var retired = object.get_array_member ("retired");
            if (retired.get_length () > 1024) throw new IOError.INVALID_DATA (_("The encryption epoch policy is too large"));
            roster.retired_epochs = new Gee.HashSet<string> ();
            foreach (var member in retired.get_elements ()) {
                if (member.get_node_type () != Json.NodeType.VALUE || member.get_value ().type () != typeof (string))
                    throw new IOError.INVALID_DATA (_("Invalid retired encryption epoch"));
                string id = member.get_string ();
                if (!valid_id (id) || id == roster.epoch || !roster.retired_epochs.add (id))
                    throw new IOError.INVALID_DATA (_("Invalid or repeated retired encryption epoch"));
            }
            roster.retired_epochs = roster.retired_epochs.read_only_view;
            if (!object.has_member ("devices") || object.get_member ("devices").get_node_type () != Json.NodeType.ARRAY)
                throw new IOError.INVALID_DATA (_("The roster has no enrolled devices"));
            var array = object.get_array_member ("devices");
            if (array.get_length () == 0 || array.get_length () > 256) throw new IOError.INVALID_DATA (_("Invalid enrolled device count"));
            roster.devices = new Gee.HashMap<string, Bytes> ();
            foreach (var member in array.get_elements ()) {
                if (member.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid enrolled device"));
                var device = member.get_object ();
                string id = text (device, "id");
                string encoded = text (device, "key");
                var key = new Bytes (Base64.decode (encoded));
                if (!valid_id (id) || !valid_public_key (key) || Base64.encode (key.get_data ()) != encoded || roster.devices.has_key (id))
                    throw new IOError.INVALID_DATA (_("Invalid or repeated enrolled device"));
                roster.devices[id] = key;
            }
            roster.document = document;
            roster.signature = signature;
            roster.devices = roster.devices.read_only_view;
            return roster;
        }
    }
}
