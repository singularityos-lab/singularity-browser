namespace Singularity.Apps.Browser {

    public class VaultChange : Object {
        public string writer { get; construct; }
        public int64 clock { get; construct; }
        public bool deleted { get; construct; }
        public Gee.Map<string, int64?> context { get; private set; }
        public Json.Node payload {
            owned get {
                try { return copy_payload (value); }
                catch (Error e) { assert_not_reached (); }
            }
        }
        private Json.Node value;

        internal VaultChange (string writer, int64 clock, bool deleted, Json.Node value, Gee.Map<string, int64?> context) throws Error {
            Object (writer: writer, clock: clock, deleted: deleted);
            this.value = copy_payload (value);
            var copy = new Gee.HashMap<string, int64?> ();
            copy.set_all (context);
            this.context = copy.read_only_view;
        }

        private static Json.Node copy_payload (Json.Node source, int depth = 0) throws Error {
            if (depth > 128) throw new IOError.INVALID_DATA (_("The browser dataset payload is nested too deeply"));
            var node = source.copy ();
            if (source.get_node_type () == Json.NodeType.OBJECT) {
                var object = new Json.Object ();
                foreach (string member in source.get_object ().get_members ())
                    object.set_member (member, copy_payload (source.get_object ().get_member (member), depth + 1));
                node.set_object (object);
            } else if (source.get_node_type () == Json.NodeType.ARRAY) {
                var array = new Json.Array ();
                foreach (var member in source.get_array ().get_elements ()) array.add_element (copy_payload (member, depth + 1));
                node.set_array (array);
            }
            return node;
        }

        internal bool same (VaultChange other) {
            if (deleted != other.deleted || !value.equal (other.value) || context.size != other.context.size) return false;
            foreach (var entry in context.entries) if (!other.context.has_key (entry.key) || other.context[entry.key] != entry.value) return false;
            return true;
        }
    }

    public class VaultItem : Object {
        public string id { get; construct; }
        public string kind { get; construct; }
        public Gee.List<VaultChange> versions { owned get { return changes.read_only_view; } }
        private Gee.ArrayList<VaultChange> changes = new Gee.ArrayList<VaultChange> ();

        internal VaultItem (string id, string kind) {
            Object (id: id, kind: kind);
        }

        internal void add (VaultChange change) throws Error {
            foreach (var known in changes) {
                if (known.writer == change.writer && known.clock == change.clock) {
                    if (!known.same (change)) throw new IOError.INVALID_DATA (_("A dataset change has conflicting contents"));
                    return;
                }
            }
            changes.add (change);
        }

        internal void reduce () {
            var retained = new Gee.ArrayList<VaultChange> ();
            foreach (var change in changes) {
                bool covered = false;
                foreach (var other in changes) {
                    if (other == change) continue;
                    int64? clock = other.context[change.writer];
                    if (clock != null && clock >= change.clock) { covered = true; break; }
                }
                if (!covered) retained.add (change);
            }
            retained.sort ((a, b) => a.writer == b.writer ? (a.clock < b.clock ? -1 : a.clock > b.clock ? 1 : 0) : strcmp (a.writer, b.writer));
            changes = retained;
        }
    }

    public class VaultDataset : Object {
        public string writer { get; construct; }
        public int64 clock { get; private set; }
        private Gee.HashMap<string, VaultItem> records = new Gee.HashMap<string, VaultItem> ();

        public VaultDataset (string writer) throws Error {
            if (!VaultRoster.valid_id (writer)) throw new IOError.INVALID_ARGUMENT (_("Invalid dataset writer"));
            Object (writer: writer);
        }

        public VaultItem? get_item (string id) {
            return records[id];
        }

        public VaultItem[] items () {
            var ids = new Gee.ArrayList<string> ();
            ids.add_all (records.keys);
            ids.sort ();
            VaultItem[] result = {};
            foreach (string id in ids) result += records[id];
            return result;
        }

        private static bool known_kind (string kind) {
            return kind == "history" || kind == "bookmark" || kind == "password" || kind == "session";
        }

        public string create (string kind, Json.Object payload) throws Error {
            string id = Uuid.string_random ();
            update (id, kind, payload);
            return id;
        }

        public void update (string id, string kind, Json.Object? payload) throws Error {
            if (!VaultRoster.valid_id (id) || !known_kind (kind)) throw new IOError.INVALID_ARGUMENT (_("Invalid browser dataset item"));
            var item = records[id];
            if (item != null && item.kind != kind) throw new IOError.INVALID_ARGUMENT (_("The browser dataset item type cannot change"));
            if (clock == int64.MAX) throw new IOError.NO_SPACE (_("The dataset change clock is exhausted"));
            var context = new Gee.HashMap<string, int64?> ();
            if (item != null) {
                foreach (var change in item.versions) {
                    foreach (var entry in change.context.entries) {
                        int64? previous = context[entry.key];
                        if (previous == null || previous < entry.value) context[entry.key] = entry.value;
                    }
                    int64? previous = context[change.writer];
                    if (previous == null || previous < change.clock) context[change.writer] = change.clock;
                }
            }
            var value = new Json.Node (payload == null ? Json.NodeType.NULL : Json.NodeType.OBJECT);
            if (payload != null) value.set_object (payload);
            var changed = new VaultItem (id, kind);
            changed.add (new VaultChange (writer, clock + 1, payload == null, value, context));
            clock++;
            records[id] = changed;
        }

        private static string text (Json.Object object, string key) throws Error {
            if (!object.has_member (key) || object.get_member (key).get_node_type () != Json.NodeType.VALUE
                || object.get_member (key).get_value ().type () != typeof (string)) throw new IOError.INVALID_DATA (_("Invalid browser dataset text"));
            return object.get_string_member (key);
        }

        private static int64 integer (Json.Object object, string key) throws Error {
            if (!object.has_member (key) || object.get_member (key).get_node_type () != Json.NodeType.VALUE
                || object.get_member (key).get_value ().type () != typeof (int64)) throw new IOError.INVALID_DATA (_("Invalid browser dataset counter"));
            return object.get_int_member (key);
        }

        public void merge (Bytes snapshot) throws Error {
            if (snapshot.get_size () == 0 || snapshot.get_size () > VaultEnvelope.MAX_SIZE - VaultEnvelope.HEADER_SIZE - 16)
                throw new IOError.INVALID_DATA (_("Invalid browser dataset size"));
            unowned uint8[] raw = snapshot.get_data ();
            foreach (uint8 c in raw) if (c == 0) throw new IOError.INVALID_DATA (_("Invalid browser dataset encoding"));
            var parser = new Json.Parser ();
            try { parser.load_from_data ((string) raw, raw.length); }
            catch (Error e) { throw new IOError.INVALID_DATA (_("The browser dataset could not be parsed")); }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid browser dataset"));
            var object = root.get_object ();
            if (integer (object, "format") != 1 || !object.has_member ("items") || object.get_member ("items").get_node_type () != Json.NodeType.ARRAY)
                throw new IOError.INVALID_DATA (_("Invalid browser dataset version"));
            var merged = new Gee.HashMap<string, VaultItem> ();
            foreach (var item in records.values) {
                var copy = new VaultItem (item.id, item.kind);
                foreach (var change in item.versions) copy.add (change);
                merged[item.id] = copy;
            }
            int64 next_clock = clock;
            var ids = new Gee.HashSet<string> ();
            var dots = new Gee.HashMap<string, string> ();
            foreach (var member in object.get_array_member ("items").get_elements ()) {
                if (member.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid browser dataset item"));
                var source = member.get_object ();
                string id = text (source, "id");
                string kind = text (source, "kind");
                if (!VaultRoster.valid_id (id) || !known_kind (kind) || !ids.add (id)) throw new IOError.INVALID_DATA (_("Invalid or repeated browser dataset item"));
                if (!source.has_member ("versions") || source.get_member ("versions").get_node_type () != Json.NodeType.ARRAY)
                    throw new IOError.INVALID_DATA (_("The browser dataset item has no change history"));
                var versions = source.get_array_member ("versions");
                if (versions.get_length () == 0 || versions.get_length () > 256) throw new IOError.INVALID_DATA (_("Invalid browser dataset conflict count"));
                var item = merged[id];
                if (item == null) { item = new VaultItem (id, kind); merged[id] = item; }
                else if (item.kind != kind) throw new IOError.INVALID_DATA (_("Conflicting browser dataset item types"));
                foreach (var version in versions.get_elements ()) {
                    if (version.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("Invalid browser dataset change"));
                    var change = version.get_object ();
                    string author = text (change, "writer");
                    int64 counter = integer (change, "clock");
                    string dot = author + "." + counter.to_string ();
                    if (!VaultRoster.valid_id (author) || counter <= 0 || dots.has_key (dot)) throw new IOError.INVALID_DATA (_("Invalid or repeated dataset change identity"));
                    dots[dot] = id;
                    if (!change.has_member ("deleted") || change.get_member ("deleted").get_node_type () != Json.NodeType.VALUE
                        || change.get_member ("deleted").get_value ().type () != typeof (bool)) throw new IOError.INVALID_DATA (_("Invalid browser dataset deletion"));
                    bool deleted = change.get_boolean_member ("deleted");
                    if (!change.has_member ("payload") || change.get_member ("payload").get_node_type () != (deleted ? Json.NodeType.NULL : Json.NodeType.OBJECT))
                        throw new IOError.INVALID_DATA (_("Invalid browser dataset payload"));
                    if (!change.has_member ("context") || change.get_member ("context").get_node_type () != Json.NodeType.OBJECT)
                        throw new IOError.INVALID_DATA (_("Invalid browser dataset change context"));
                    var context = new Gee.HashMap<string, int64?> ();
                    var source_context = change.get_object_member ("context");
                    if (source_context.get_size () > 256) throw new IOError.INVALID_DATA (_("Invalid browser dataset device count"));
                    foreach (string device in source_context.get_members ()) {
                        int64 previous = integer (source_context, device);
                        if (!VaultRoster.valid_id (device) || previous <= 0 || previous >= counter) throw new IOError.INVALID_DATA (_("Invalid browser dataset causal clock"));
                        context[device] = previous;
                    }
                    item.add (new VaultChange (author, counter, deleted, change.get_member ("payload"), context));
                    next_clock = int64.max (next_clock, counter);
                }
            }
            dots.clear ();
            foreach (var item in merged.values) {
                foreach (var change in item.versions) {
                    string dot = change.writer + "." + change.clock.to_string ();
                    if (dots.has_key (dot) && dots[dot] != item.id) throw new IOError.INVALID_DATA (_("A dataset change was reused for another item"));
                    dots[dot] = item.id;
                }
                item.reduce ();
                if (item.versions.size == 0 || item.versions.size > 256) throw new IOError.INVALID_DATA (_("Invalid merged browser dataset changes"));
            }
            records = merged;
            clock = next_clock;
        }

        public Bytes snapshot () throws Error {
            var array = new Json.Array ();
            foreach (var item in items ()) {
                var object = new Json.Object ();
                object.set_string_member ("id", item.id);
                object.set_string_member ("kind", item.kind);
                var changes = new Json.Array ();
                foreach (var version in item.versions) {
                    var change = new Json.Object ();
                    change.set_string_member ("writer", version.writer);
                    change.set_int_member ("clock", version.clock);
                    change.set_boolean_member ("deleted", version.deleted);
                    change.set_member ("payload", version.payload);
                    var context = new Json.Object ();
                    var devices = new Gee.ArrayList<string> ();
                    devices.add_all (version.context.keys);
                    devices.sort ();
                    foreach (string device in devices) context.set_int_member (device, version.context[device]);
                    change.set_object_member ("context", context);
                    changes.add_object_element (change);
                }
                object.set_array_member ("versions", changes);
                array.add_object_element (object);
            }
            var root = new Json.Object ();
            root.set_int_member ("format", 1);
            root.set_array_member ("items", array);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (root);
            var generator = new Json.Generator ();
            generator.set_root (node);
            var result = new Bytes (generator.to_data (null).data);
            if (result.get_size () > VaultEnvelope.MAX_SIZE - VaultEnvelope.HEADER_SIZE - 16)
                throw new IOError.NO_SPACE (_("The browser dataset is too large for one encrypted snapshot"));
            return result;
        }
    }
}
