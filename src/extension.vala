namespace Singularity.Apps.Browser {

    public errordomain ExtensionError {
        INVALID,
        UNSUPPORTED,
        NOT_FOUND
    }

    public class ContentScript : Object {
        public string[] matches = {};
        public string[] exclude_matches = {};
        public string[] js = {};
        public string[] css = {};
        public string run_at = "document_idle";
        public bool all_frames = false;
    }

    public class Extension : Object {
        public string id { get; construct; }
        public string path { get; construct; }
        public string name { get; private set; default = ""; }
        public string description { get; private set; default = ""; }
        public string version { get; private set; default = ""; }
        public int manifest_version { get; private set; default = 3; }
        public string? background_worker { get; private set; }
        public string[] background_scripts = {};
        public string? popup { get; private set; }
        public string? options_page { get; private set; }
        public string? action_title { get; private set; }
        public string[] permissions = {};
        public string[] host_permissions = {};
        public Gee.ArrayList<ContentScript> content_scripts = new Gee.ArrayList<ContentScript> ();
        public Gee.TreeMap<int, string> icons = new Gee.TreeMap<int, string> ();
        public Json.Object manifest { get; private set; }

        private Json.Object? messages;
        private Json.Object? fallback_messages;

        public Extension (string id, string path) {
            Object (id: id, path: path);
        }

        public static Extension load (string id, string path) throws Error {
            var extension = new Extension (id, path);
            extension.read_manifest ();
            return extension;
        }

        public string resolve (string relative) throws ExtensionError {
            string? clean = ZipArchive.safe_path (relative.has_prefix ("/") ? relative.substring (1) : relative);
            if (clean == null) throw new ExtensionError.INVALID ("Invalid extension path %s".printf (relative));
            return Path.build_filename (path, clean);
        }

        public bool has_permission (string permission) {
            foreach (string p in permissions) {
                if (p == permission) return true;
            }
            return false;
        }

        public string? icon_for (int size) {
            string? best = null;
            foreach (var entry in icons.entries) {
                best = entry.value;
                if (entry.key >= size) break;
            }
            return best;
        }

        public string localize (string text) {
            if (!text.has_prefix ("__MSG_") || !text.has_suffix ("__")) return text;
            string key = text.substring (6, text.length - 8).down ();
            foreach (var table in new Json.Object?[] { messages, fallback_messages }) {
                if (table == null) continue;
                foreach (string member in table.get_members ()) {
                    if (member.down () != key) continue;
                    var entry = table.get_object_member (member);
                    if (entry != null && entry.has_member ("message")) return entry.get_string_member ("message");
                }
            }
            return text;
        }

        private void read_manifest () throws Error {
            var parser = new Json.Parser ();
            parser.load_from_file (Path.build_filename (path, "manifest.json"));
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                throw new ExtensionError.INVALID ("The extension manifest is not an object");
            }
            manifest = root.get_object ();
            manifest_version = (int) manifest.get_int_member_with_default ("manifest_version", 0);
            if (manifest_version != 2 && manifest_version != 3) {
                throw new ExtensionError.UNSUPPORTED ("Manifest version %d is not supported".printf (manifest_version));
            }
            version = manifest.get_string_member_with_default ("version", "");
            if (!valid_version (version)) throw new ExtensionError.INVALID ("The extension version is invalid");

            string? locale = manifest.has_member ("default_locale") ? manifest.get_string_member ("default_locale") : null;
            if (locale != null) {
                fallback_messages = read_messages (locale);
                foreach (string language in Intl.get_language_names ()) {
                    string candidate = language.split (".")[0];
                    messages = read_messages (candidate);
                    if (messages != null) break;
                }
            }
            name = localize (manifest.get_string_member_with_default ("name", ""));
            if (name.strip () == "") throw new ExtensionError.INVALID ("The extension has no name");
            description = localize (manifest.get_string_member_with_default ("description", ""));

            permissions = strings (manifest, "permissions");
            host_permissions = strings (manifest, "host_permissions");
            if (manifest_version == 2) {
                string[] hosts = {};
                string[] plain = {};
                foreach (string p in permissions) {
                    if (p.contains ("://") || p == "<all_urls>") hosts += p;
                    else plain += p;
                }
                permissions = plain;
                host_permissions = hosts;
            }

            if (manifest.has_member ("background")) {
                var background = manifest.get_object_member ("background");
                if (background != null) {
                    if (background.has_member ("service_worker")) background_worker = background.get_string_member ("service_worker");
                    background_scripts = strings (background, "scripts");
                }
            }

            string action_key = manifest_version == 3 ? "action" : (manifest.has_member ("browser_action") ? "browser_action" : "page_action");
            if (manifest.has_member (action_key)) {
                var action = manifest.get_object_member (action_key);
                if (action != null) {
                    if (action.has_member ("default_popup")) popup = action.get_string_member ("default_popup");
                    if (action.has_member ("default_title")) action_title = localize (action.get_string_member ("default_title"));
                    read_icons (action, "default_icon");
                }
            }
            if (manifest.has_member ("options_ui")) {
                var options = manifest.get_object_member ("options_ui");
                if (options != null && options.has_member ("page")) options_page = options.get_string_member ("page");
            } else if (manifest.has_member ("options_page")) {
                options_page = manifest.get_string_member ("options_page");
            }
            read_icons (manifest, "icons");

            if (manifest.has_member ("content_scripts")) {
                foreach (var node in manifest.get_array_member ("content_scripts").get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var entry = node.get_object ();
                    var script = new ContentScript ();
                    script.matches = strings (entry, "matches");
                    script.exclude_matches = strings (entry, "exclude_matches");
                    script.js = strings (entry, "js");
                    script.css = strings (entry, "css");
                    script.run_at = entry.get_string_member_with_default ("run_at", "document_idle");
                    script.all_frames = entry.get_boolean_member_with_default ("all_frames", false);
                    if (script.matches.length > 0 && (script.js.length > 0 || script.css.length > 0)) content_scripts.add (script);
                }
            }
        }

        private void read_icons (Json.Object owner, string member) {
            if (!owner.has_member (member)) return;
            var node = owner.get_member (member);
            if (node.get_node_type () == Json.NodeType.VALUE) {
                icons[128] = node.get_string ();
                return;
            }
            if (node.get_node_type () != Json.NodeType.OBJECT) return;
            var table = node.get_object ();
            foreach (string size in table.get_members ()) {
                int value = int.parse (size);
                if (value > 0) icons[value] = table.get_string_member (size);
            }
        }

        private Json.Object? read_messages (string locale) {
            if (ZipArchive.safe_path (locale) == null || locale.contains ("/")) return null;
            string file = Path.build_filename (path, "_locales", locale, "messages.json");
            if (!FileUtils.test (file, FileTest.IS_REGULAR)) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (file);
                var root = parser.get_root ();
                return root != null && root.get_node_type () == Json.NodeType.OBJECT ? root.get_object () : null;
            } catch (Error e) {
                return null;
            }
        }

        public static bool valid_version (string version) {
            string[] parts = version.split (".");
            if (parts.length < 1 || parts.length > 4) return false;
            foreach (string part in parts) {
                if (part == "" || part.length > 5) return false;
                for (int i = 0; i < part.length; i++) {
                    if (!part[i].isdigit ()) return false;
                }
            }
            return true;
        }

        public static int compare_versions (string a, string b) {
            string[] left = a.split (".");
            string[] right = b.split (".");
            for (int i = 0; i < int.max (left.length, right.length); i++) {
                int l = i < left.length ? int.parse (left[i]) : 0;
                int r = i < right.length ? int.parse (right[i]) : 0;
                if (l != r) return l < r ? -1 : 1;
            }
            return 0;
        }

        private static string[] strings (Json.Object owner, string member) {
            string[] result = {};
            if (!owner.has_member (member)) return result;
            var node = owner.get_member (member);
            if (node.get_node_type () != Json.NodeType.ARRAY) return result;
            foreach (var element in node.get_array ().get_elements ()) {
                if (element.get_value_type () == typeof (string)) result += element.get_string ();
            }
            return result;
        }
    }
}
