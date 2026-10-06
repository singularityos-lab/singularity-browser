namespace Singularity.Apps.Browser {

    public class VaultBridge : Object {
        public VaultSync sync { get; private set; }
        private Profile profile;
        private Gee.HashMap<string, Json.Object> links = new Gee.HashMap<string, Json.Object> ();
        private Gee.HashMap<string, Json.Object> local = new Gee.HashMap<string, Json.Object> ();

        public VaultBridge (VaultSync sync, Profile profile) throws Error {
            if (profile.ephemeral || profile.id == "private") throw new IOError.PERMISSION_DENIED (_("Private browsing cannot sync"));
            this.sync = sync;
            this.profile = profile;
            profile.store.sync_ready ();
            foreach (var link in profile.store.sync_links (sync.keys.scope)) links[link.get_string_member ("id")] = link;
        }

        private static Json.Node ordered (Json.Node node) {
            if (node.get_node_type () == Json.NodeType.OBJECT) {
                var object = new Json.Object ();
                var keys = new Gee.ArrayList<string> ();
                foreach (string key in node.get_object ().get_members ()) keys.add (key);
                keys.sort ();
                foreach (string key in keys) object.set_member (key, ordered (node.get_object ().get_member (key)));
                var result = new Json.Node (Json.NodeType.OBJECT);
                result.set_object (object);
                return result;
            }
            if (node.get_node_type () == Json.NodeType.ARRAY) {
                var array = new Json.Array ();
                foreach (var value in node.get_array ().get_elements ()) array.add_element (ordered (value));
                var result = new Json.Node (Json.NodeType.ARRAY);
                result.set_array (array);
                return result;
            }
            return node.copy ();
        }

        private string stamp (Json.Object? payload) throws Error {
            if (payload == null) return "deleted";
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (payload);
            var generator = new Json.Generator ();
            generator.set_root (ordered (node));
            var digest = VaultCrypto.authenticate (sync.keys.signing, new Bytes (("Browser local sync state v1\n" + generator.to_data (null)).data));
            if (digest == null) throw new IOError.FAILED (_("The local sync state could not be authenticated"));
            return Base64.encode (digest.get_data ());
        }

        private Json.Object? find (string kind, string key) {
            foreach (var link in links.values)
                if (link.get_string_member ("kind") == kind && link.get_string_member ("key") == key) return link;
            return null;
        }

        private Json.Object reserve (string kind, string key) throws Error {
            var link = find (kind, key);
            if (link != null) return link;
            link = new Json.Object ();
            link.set_string_member ("kind", kind);
            link.set_string_member ("key", key);
            link.set_string_member ("id", Uuid.string_random ());
            link.set_string_member ("stamp", "");
            profile.store.sync_link (sync.keys.scope, kind, key, link.get_string_member ("id"), "");
            links[link.get_string_member ("id")] = link;
            return link;
        }

        private void remember (Json.Object link, Json.Object? payload) throws Error {
            string value = stamp (payload);
            profile.store.sync_link (sync.keys.scope, link.get_string_member ("kind"), link.get_string_member ("key"), link.get_string_member ("id"), value);
            link.set_string_member ("stamp", value);
        }

        private void observe (Json.Object link, Json.Object payload) {
            local[link.get_string_member ("id")] = payload;
        }

        public async void capture (Json.Object session, bool stage = true) throws Error {
            sync.check_scope ();
            local.clear ();
            foreach (var visit in profile.store.sync_history ()) {
                if (!syncable_url (visit.url)) continue;
                var payload = new Json.Object ();
                payload.set_string_member ("url", visit.url);
                payload.set_string_member ("title", visit.title);
                payload.set_int_member ("visits", visit.visits);
                payload.set_int_member ("last_visit", visit.last_visit);
                observe (reserve ("history", visit.url), payload);
            }
            var bookmarks = profile.store.sync_bookmarks ();
            foreach (var bookmark in bookmarks) reserve ("bookmark", bookmark.id.to_string ());
            foreach (var bookmark in bookmarks) {
                if (!bookmark.is_folder && !syncable_url (bookmark.url)) continue;
                var payload = new Json.Object ();
                payload.set_string_member ("title", bookmark.title);
                payload.set_string_member ("url", bookmark.url);
                payload.set_boolean_member ("folder", bookmark.is_folder);
                payload.set_int_member ("position", bookmark.position);
                var parent = bookmark.parent == 0 ? null : find ("bookmark", bookmark.parent.to_string ());
                if (bookmark.parent != 0 && parent == null) throw new IOError.INVALID_DATA (_("A bookmark folder is missing"));
                payload.set_string_member ("parent", parent != null ? parent.get_string_member ("id") : "");
                observe (reserve ("bookmark", bookmark.id.to_string ()), payload);
            }
            var credentials = yield Passwords.all (profile.id);
            sync.check_scope ();
            foreach (var credential in credentials) {
                var identity = new Json.Object ();
                identity.set_string_member ("origin", credential.origin);
                identity.set_string_member ("username", credential.username);
                string key = stamp (identity);
                identity.set_string_member ("password", credential.password);
                observe (reserve ("password", key), identity);
            }
            validate_session (session);
            observe (reserve ("session", sync.keys.writer), session);
            foreach (var link in links.values) {
                string id = link.get_string_member ("id");
                if (link.get_string_member ("kind") == "session" && link.get_string_member ("key") != sync.keys.writer) continue;
                var payload = local[id];
                string value = stamp (payload);
                if (value == link.get_string_member ("stamp")) continue;
                var existing = sync.get_item (id);
                if (existing == null && payload == null) continue;
                if (!stage) throw new IOError.BUSY (_("Browser data changed during sync. Sync again to keep those changes"));
                sync.update (id, link.get_string_member ("kind"), payload);
                remember (link, payload);
            }
        }

        private static bool syncable_url (string url) {
            string? scheme = Address.scheme_of (url);
            return scheme == "http" || scheme == "https";
        }

        private static string text (Json.Object payload, string key) throws Error {
            if (!payload.has_member (key) || payload.get_member (key).get_node_type () != Json.NodeType.VALUE
                || payload.get_member (key).get_value_type () != typeof (string)) throw new IOError.INVALID_DATA (_("The synced browser data contains invalid text"));
            string value = payload.get_string_member (key);
            if (value.length > 1048576) throw new IOError.INVALID_DATA (_("The synced browser text is too large"));
            return value;
        }

        private static int64 integer (Json.Object payload, string key) throws Error {
            if (!payload.has_member (key) || payload.get_member (key).get_node_type () != Json.NodeType.VALUE
                || payload.get_member (key).get_value_type () != typeof (int64)) throw new IOError.INVALID_DATA (_("The synced browser data contains an invalid number"));
            return payload.get_int_member (key);
        }

        private static bool boolean (Json.Object payload, string key) throws Error {
            if (!payload.has_member (key) || payload.get_member (key).get_node_type () != Json.NodeType.VALUE
                || payload.get_member (key).get_value_type () != typeof (bool)) throw new IOError.INVALID_DATA (_("The synced browser data contains an invalid flag"));
            return payload.get_boolean_member (key);
        }

        private static void validate_session (Json.Object payload) throws Error {
            if (integer (payload, "version") != 1 || !payload.has_member ("windows")
                || payload.get_member ("windows").get_node_type () != Json.NodeType.ARRAY)
                throw new IOError.INVALID_DATA (_("The synced session is invalid"));
            var windows = payload.get_array_member ("windows");
            if (windows.get_length () > 100) throw new IOError.INVALID_DATA (_("The synced session has too many windows"));
            foreach (var node in windows.get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("The synced session window is invalid"));
                var window = node.get_object ();
                if (!window.has_member ("tiles") || window.get_member ("tiles").get_node_type () != Json.NodeType.ARRAY)
                    throw new IOError.INVALID_DATA (_("The synced session tiles are invalid"));
                foreach (var tile_node in window.get_array_member ("tiles").get_elements ()) {
                    if (tile_node.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("The synced session tile is invalid"));
                    var tile = tile_node.get_object ();
                    if (!tile.has_member ("tabs") || tile.get_member ("tabs").get_node_type () != Json.NodeType.ARRAY
                        || tile.get_array_member ("tabs").get_length () > 1000) throw new IOError.INVALID_DATA (_("The synced session tabs are invalid"));
                    foreach (var tab_node in tile.get_array_member ("tabs").get_elements ()) {
                        if (tab_node.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("The synced session tab is invalid"));
                        string url = text (tab_node.get_object (), "url");
                        if (url != "" && url != Address.NEW_TAB && !syncable_url (url))
                            throw new IOError.PERMISSION_DENIED (_("Local files and internal pages cannot be synced"));
                    }
                }
            }
        }

        private void validate () throws Error {
            sync.check_scope ();
            var identities = new Gee.HashSet<string> ();
            foreach (var item in sync.items ()) {
                if (item.versions.size != 1) throw new IOError.BUSY (_("Conflicting browser changes need a choice before they can be applied"));
                var version = item.versions[0];
                if (version.deleted) continue;
                var payload = version.payload.get_object ();
                if (item.kind == "history") {
                    if (!syncable_url (text (payload, "url")) || integer (payload, "visits") < 0 || integer (payload, "visits") > int.MAX
                        || integer (payload, "last_visit") < 0) throw new IOError.INVALID_DATA (_("The synced history entry is invalid"));
                    text (payload, "title");
                } else if (item.kind == "bookmark") {
                    bool folder = boolean (payload, "folder");
                    if (!folder && !syncable_url (text (payload, "url"))) throw new IOError.INVALID_DATA (_("The synced bookmark URL is invalid"));
                    text (payload, "title");
                    int64 position = integer (payload, "position");
                    if (position < 0 || position > int.MAX) throw new IOError.INVALID_DATA (_("The synced bookmark order is invalid"));
                    string parent = text (payload, "parent");
                    var seen = new Gee.HashSet<string> ();
                    seen.add (item.id);
                    while (parent != "") {
                        var folder_item = sync.get_item (parent);
                        if (!seen.add (parent) || folder_item == null || folder_item.kind != "bookmark" || folder_item.versions.size != 1
                            || folder_item.versions[0].deleted || !boolean (folder_item.versions[0].payload.get_object (), "folder"))
                            throw new IOError.INVALID_DATA (_("The synced bookmark folders are incomplete or cyclic"));
                        parent = text (folder_item.versions[0].payload.get_object (), "parent");
                    }
                } else if (item.kind == "password") {
                    string origin = text (payload, "origin");
                    if (!Passwords.eligible (origin) || Address.origin_of (origin) != origin) throw new IOError.PERMISSION_DENIED (_("The synced login origin is invalid"));
                    text (payload, "username");
                    text (payload, "password");
                } else if (item.kind == "session") validate_session (payload);
                if (item.kind == "history" || item.kind == "password") {
                    string key;
                    if (item.kind == "history") key = text (payload, "url");
                    else {
                        var identity = new Json.Object ();
                        identity.set_string_member ("origin", text (payload, "origin"));
                        identity.set_string_member ("username", text (payload, "username"));
                        key = stamp (identity);
                    }
                    var known = find (item.kind, key);
                    if (!identities.add (item.kind + "\n" + key) || (known != null && known.get_string_member ("id") != item.id))
                        throw new IOError.BUSY (_("Separate synced items refer to the same local history entry or login. Keep both changes until a choice is made"));
                }
            }
        }

        public async int apply () throws Error {
            validate ();
            int count = 0;
            var pending = new Gee.ArrayList<VaultItem> ();
            foreach (var item in sync.items ()) pending.add (item);
            while (!pending.is_empty) {
                bool progressed = false;
                foreach (var item in pending.to_array ()) {
                    sync.check_scope ();
                    var version = item.versions[0];
                    var payload_node = version.payload;
                    Json.Object? payload = null;
                    if (!version.deleted) payload = payload_node.get_object ();
                    var link = links[item.id];
                    if (version.deleted && link == null) {
                        pending.remove (item);
                        progressed = true;
                        continue;
                    }
                    if (link != null && stamp (payload) == link.get_string_member ("stamp")) {
                        pending.remove (item);
                        progressed = true;
                        continue;
                    }
                    string key = link != null ? link.get_string_member ("key") : "";
                    if (item.kind == "history") {
                        if (payload != null) key = text (payload, "url");
                        if (key != "") profile.store.sync_visit (key, payload != null ? text (payload, "title") : "",
                            payload != null ? (int) integer (payload, "visits") : 0, payload != null ? integer (payload, "last_visit") : 0, payload == null);
                    } else if (item.kind == "bookmark") {
                        int64 id = key != "" ? int64.parse (key) : 0;
                        int64 parent_id = 0;
                        if (payload != null && text (payload, "parent") != "") {
                            var parent = links[text (payload, "parent")];
                            if (parent == null || parent.get_string_member ("stamp") == "") continue;
                            parent_id = int64.parse (parent.get_string_member ("key"));
                        }
                        if (id != 0 || payload != null) id = profile.store.sync_bookmark_link (sync.keys.scope, item.id, stamp (payload), id, parent_id, payload != null && boolean (payload, "folder"),
                            payload != null ? text (payload, "title") : "", payload != null ? text (payload, "url") : "",
                            payload != null ? (int) integer (payload, "position") : 0, payload == null);
                        key = id.to_string ();
                    } else if (item.kind == "password") {
                        Json.Object? login = payload ?? local[item.id];
                        if (login == null && payload == null) {
                            pending.remove (item);
                            progressed = true;
                            continue;
                        }
                        var identity = new Json.Object ();
                        identity.set_string_member ("origin", text (login, "origin"));
                        identity.set_string_member ("username", text (login, "username"));
                        key = stamp (identity);
                        yield Passwords.store_synced (new Credential (text (login, "origin"), text (login, "username"),
                            payload != null ? text (login, "password") : "", profile.id), payload == null);
                        sync.check_scope ();
                    } else if (item.kind == "session") {
                        key = link != null ? key : item.id;
                        if (payload != null) {
                            string dir = Path.build_filename (profile.data_dir, "sync", sync.keys.scope, "sessions");
                            if (DirUtils.create_with_parents (dir, 0700) != 0) throw new IOError.FAILED (_("The synced sessions could not be saved"));
                            var node = new Json.Node (Json.NodeType.OBJECT);
                            node.set_object (payload);
                            var generator = new Json.Generator ();
                            generator.set_root (node);
                            FileUtils.set_contents_full (Path.build_filename (dir, item.id + ".json"), generator.to_data (null), -1,
                                FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
                        }
                    }
                    if (link == null) {
                        link = new Json.Object ();
                        link.set_string_member ("id", item.id);
                        link.set_string_member ("kind", item.kind);
                        link.set_string_member ("key", key);
                        links[item.id] = link;
                    }
                    remember (link, payload);
                    count++;
                    pending.remove (item);
                    progressed = true;
                }
                if (!progressed) throw new IOError.INVALID_DATA (_("The synced bookmarks could not be applied"));
            }
            return count;
        }
    }
}
