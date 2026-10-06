namespace Singularity.Apps.Browser {

    public class ImportedBookmark : Object {
        public string title;
        public string url;
        public bool is_folder;
        public Gee.ArrayList<ImportedBookmark> children = new Gee.ArrayList<ImportedBookmark> ();

        public ImportedBookmark.folder (string title) {
            this.title = title;
            this.url = "";
            this.is_folder = true;
        }

        public ImportedBookmark.link (string title, string url) {
            this.title = title;
            this.url = url;
            this.is_folder = false;
        }

        public int count () {
            if (!is_folder) return 1;
            int total = 0;
            foreach (var child in children) total += child.count ();
            return total;
        }
    }

    public class ImportSource : Object {
        public string name;
        public string icon_name;
        public string path;
        public bool firefox;

        public ImportSource (string name, string icon_name, string path, bool firefox) {
            this.name = name;
            this.icon_name = icon_name;
            this.path = path;
            this.firefox = firefox;
        }

        public ImportedBookmark? read () throws Error {
            return firefox ? BookmarkImport.from_firefox (path) : BookmarkImport.from_chromium (path);
        }
    }

    public errordomain ImportError {
        UNREADABLE,
        FORMAT
    }

    public class BookmarkImport : Object {

        public static ImportSource[] detect (string? home = null) {
            string h = home ?? Environment.get_home_dir ();
            ImportSource[] found = {};
            string[,] firefox_roots = {
                { "Firefox", ".mozilla/firefox" },
                { "Firefox", ".var/app/org.mozilla.firefox/.mozilla/firefox" },
                { "Firefox", "snap/firefox/common/.mozilla/firefox" },
                { "LibreWolf", ".librewolf" },
                { "Floorp", ".floorp" },
                { "Zen", ".zen" }
            };
            for (int i = 0; i < firefox_roots.length[0]; i++) {
                string? places = firefox_places (Path.build_filename (h, firefox_roots[i, 1]));
                if (places != null) found += new ImportSource (firefox_roots[i, 0], "firefox", places, true);
            }
            string[,] chromium_roots = {
                { "Chrome", ".config/google-chrome" },
                { "Chromium", ".config/chromium" },
                { "Chromium", ".var/app/org.chromium.Chromium/config/chromium" },
                { "Chrome", ".var/app/com.google.Chrome/config/google-chrome" },
                { "Brave", ".config/BraveSoftware/Brave-Browser" },
                { "Edge", ".config/microsoft-edge" },
                { "Vivaldi", ".config/vivaldi" }
            };
            for (int i = 0; i < chromium_roots.length[0]; i++) {
                string file = Path.build_filename (h, chromium_roots[i, 1], "Default", "Bookmarks");
                if (FileUtils.test (file, FileTest.IS_REGULAR))
                    found += new ImportSource (chromium_roots[i, 0], "google-chrome", file, false);
            }
            return found;
        }

        public static string? firefox_places (string root) {
            string ini = Path.build_filename (root, "profiles.ini");
            var key_file = new KeyFile ();
            try {
                key_file.load_from_file (ini, KeyFileFlags.NONE);
            } catch (Error e) {
                return null;
            }
            string? chosen = null;
            string? fallback = null;
            foreach (string group in key_file.get_groups ()) {
                try {
                    if (group.has_prefix ("Install") && key_file.has_key (group, "Default")) {
                        chosen = key_file.get_string (group, "Default");
                        break;
                    }
                    if (!group.has_prefix ("Profile") || !key_file.has_key (group, "Path")) continue;
                    string path = key_file.get_string (group, "Path");
                    bool relative = !key_file.has_key (group, "IsRelative") || key_file.get_integer (group, "IsRelative") == 1;
                    string full = relative ? Path.build_filename (root, path) : path;
                    if (fallback == null || (key_file.has_key (group, "Default") && key_file.get_integer (group, "Default") == 1))
                        fallback = full;
                } catch (Error e) {
                }
            }
            string? profile = chosen != null ? (Path.is_absolute (chosen) ? chosen : Path.build_filename (root, chosen)) : fallback;
            if (profile == null) return null;
            string places = Path.build_filename (profile, "places.sqlite");
            return FileUtils.test (places, FileTest.IS_REGULAR) ? places : null;
        }

        public static ImportedBookmark from_firefox (string places) throws Error {
            string dir = DirUtils.make_tmp ("browser-import-XXXXXX");
            string copy = Path.build_filename (dir, "places.sqlite");
            try {
                File.new_for_path (places).copy (File.new_for_path (copy), FileCopyFlags.OVERWRITE);
                string wal = places + "-wal";
                if (FileUtils.test (wal, FileTest.IS_REGULAR))
                    File.new_for_path (wal).copy (File.new_for_path (copy + "-wal"), FileCopyFlags.OVERWRITE);
                return read_places (copy);
            } finally {
                FileUtils.unlink (copy + "-wal");
                FileUtils.unlink (copy + "-shm");
                FileUtils.unlink (copy);
                DirUtils.remove (dir);
            }
        }

        private static ImportedBookmark read_places (string path) throws Error {
            Sqlite.Database db;
            if (Sqlite.Database.open_v2 (path, out db, Sqlite.OPEN_READWRITE) != Sqlite.OK)
                throw new ImportError.UNREADABLE (_("The Firefox bookmarks could not be opened."));
            Sqlite.Statement stmt;
            if (db.prepare_v2 ("""SELECT b.id, b.parent, b.type, coalesce(b.title, ''), coalesce(p.url, ''), coalesce(b.guid, '')
                    FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position""", -1, out stmt) != Sqlite.OK)
                throw new ImportError.FORMAT (_("The Firefox bookmarks are in an unknown format."));
            var nodes = new Gee.HashMap<int64?, ImportedBookmark> (
                (v) => (uint) (v ^ (v >> 32)), (a, b) => a == b);
            var parents = new Gee.HashMap<int64?, int64?> ((v) => (uint) (v ^ (v >> 32)), (a, b) => a == b);
            var order = new Gee.ArrayList<int64?> ();
            int64 root_id = -1;
            var names = new Gee.HashMap<string, string> ();
            names["menu________"] = _("Bookmarks Menu");
            names["toolbar_____"] = _("Bookmarks Toolbar");
            names["unfiled_____"] = _("Other Bookmarks");
            names["mobile______"] = _("Mobile Bookmarks");
            while (stmt.step () == Sqlite.ROW) {
                int64 id = stmt.column_int64 (0);
                int type = stmt.column_int (2);
                string title = stmt.column_text (3);
                string url = stmt.column_text (4);
                string guid = stmt.column_text (5);
                if (guid == "root________") {
                    root_id = id;
                    nodes[id] = new ImportedBookmark.folder ("Firefox");
                    continue;
                }
                if (guid == "tags________") continue;
                ImportedBookmark node;
                if (type == 2) {
                    node = new ImportedBookmark.folder (names.has_key (guid) ? names[guid] : title);
                } else if (type == 1 && is_importable (url)) {
                    node = new ImportedBookmark.link (title, url);
                } else {
                    continue;
                }
                nodes[id] = node;
                parents[id] = stmt.column_int64 (1);
                order.add (id);
            }
            if (root_id < 0) throw new ImportError.FORMAT (_("The Firefox bookmarks are in an unknown format."));
            foreach (var id in order) {
                var parent = nodes[parents[id]];
                if (parent != null && parent.is_folder) parent.children.add (nodes[id]);
            }
            return nodes[root_id];
        }

        public static ImportedBookmark from_chromium (string path) throws Error {
            var parser = new Json.Parser ();
            try {
                parser.load_from_file (path);
            } catch (Error e) {
                throw new ImportError.UNREADABLE (_("The bookmarks file could not be read."));
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT || !root.get_object ().has_member ("roots"))
                throw new ImportError.FORMAT (_("The bookmarks file is in an unknown format."));
            var roots = root.get_object ().get_object_member ("roots");
            var result = new ImportedBookmark.folder ("Chromium");
            string[,] known = {
                { "bookmark_bar", _("Bookmarks Bar") },
                { "other", _("Other Bookmarks") },
                { "synced", _("Mobile Bookmarks") }
            };
            for (int i = 0; i < known.length[0]; i++) {
                if (!roots.has_member (known[i, 0])) continue;
                var node = read_chromium (roots.get_object_member (known[i, 0]));
                if (node != null) {
                    node.title = known[i, 1];
                    result.children.add (node);
                }
            }
            return result;
        }

        private static ImportedBookmark? read_chromium (Json.Object obj) {
            string type = obj.has_member ("type") ? obj.get_string_member ("type") : "";
            string name = obj.has_member ("name") ? obj.get_string_member ("name") : "";
            if (type == "url") {
                string url = obj.has_member ("url") ? obj.get_string_member ("url") : "";
                return is_importable (url) ? new ImportedBookmark.link (name, url) : null;
            }
            if (type != "folder") return null;
            var folder = new ImportedBookmark.folder (name);
            if (obj.has_member ("children")) {
                var list = obj.get_array_member ("children");
                for (uint i = 0; i < list.get_length (); i++) {
                    var child = list.get_element (i);
                    if (child.get_node_type () != Json.NodeType.OBJECT) continue;
                    var node = read_chromium (child.get_object ());
                    if (node != null) folder.children.add (node);
                }
            }
            return folder;
        }

        private static bool is_importable (string url) {
            string? scheme = Address.scheme_of (url);
            return scheme == "http" || scheme == "https" || scheme == "file" || scheme == "ftp";
        }
    }
}
