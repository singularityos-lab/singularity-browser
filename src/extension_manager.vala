namespace Singularity.Apps.Browser {

    public class ExtensionManager : Object {
        public const string STORE_HOST = "chromewebstore.google.com";
        private const string UPDATE_URL = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=%s&acceptformat=crx3&x=id%%3D%s%%26uc";
        private const string CHROME_VERSION = "141.0.7390.65";
        private const int64 MAX_PACKAGE = 64 * 1024 * 1024;

        public string root { get; construct; }
        public string user_agent { get; set; default = "Singularity-Browser"; }
        private Gee.TreeMap<string, Extension> installed = new Gee.TreeMap<string, Extension> ();
        private Gee.HashSet<string> disabled = new Gee.HashSet<string> ();
        private Soup.Session? http;

        public signal void changed ();

        public ExtensionManager (string root) {
            Object (root: root);
        }

        construct {
            DirUtils.create_with_parents (root, 0700);
            load_state ();
            reload ();
        }

        public Gee.Collection<Extension> extensions {
            owned get { return installed.values; }
        }

        public Extension? get_extension (string id) {
            return installed[id];
        }

        public bool is_enabled (string id) {
            return installed.has_key (id) && !disabled.contains (id);
        }

        public void set_enabled (string id, bool enabled) {
            if (enabled) disabled.remove (id);
            else disabled.add (id);
            save_state ();
            changed ();
        }

        public static string? id_from_store_url (string uri) {
            try {
                var parsed = Uri.parse (uri, UriFlags.NONE);
                string? host = parsed.get_host ();
                if (host != STORE_HOST && host != "chrome.google.com") return null;
                foreach (string part in parsed.get_path ().split ("/")) {
                    if (Crx.is_valid_id (part)) return part;
                }
            } catch (UriError e) {
            }
            return null;
        }

        public static string update_url (string id) {
            return UPDATE_URL.printf (CHROME_VERSION, id);
        }

        public async Bytes download (string id, Cancellable? cancellable = null) throws Error {
            if (!Crx.is_valid_id (id)) throw new ExtensionError.INVALID ("Invalid extension identifier");
            if (http == null) {
                http = new Soup.Session ();
                http.timeout = 120;
                http.user_agent = user_agent;
            }
            var message = new Soup.Message ("GET", update_url (id));
            var stream = yield http.send_async (message, Priority.DEFAULT, cancellable);
            if (message.status_code == 204 || message.status_code == 404) {
                throw new ExtensionError.NOT_FOUND ("The Chrome Web Store no longer offers this extension");
            }
            if (message.status_code != 200) {
                throw new IOError.FAILED ("The Chrome Web Store answered %u".printf (message.status_code));
            }
            var output = new MemoryOutputStream.resizable ();
            uint8[] buffer = new uint8[65536];
            int64 total = 0;
            ssize_t count;
            while ((count = yield stream.read_async (buffer, Priority.DEFAULT, cancellable)) > 0) {
                total += count;
                if (total > MAX_PACKAGE) throw new ExtensionError.INVALID ("The extension package is too large");
                output.write (buffer[0:count]);
            }
            output.close ();
            return output.steal_as_bytes ();
        }

        public Extension install (Bytes package, string? expected_id = null) throws Error {
            var crx = Crx.parse (package, expected_id);
            string staging = Path.build_filename (root, ".staging-%s-%u".printf (crx.id, Random.next_int ()));
            DirUtils.create_with_parents (staging, 0700);
            try {
                ZipArchive.extract (crx.archive, File.new_for_path (staging));
                var extension = Extension.load (crx.id, staging);
                var current = installed[crx.id];
                if (current != null && Extension.compare_versions (extension.version, current.version) < 0) {
                    throw new ExtensionError.INVALID ("A newer version of %s is already installed".printf (current.name));
                }
                string target = Path.build_filename (root, crx.id);
                string old = Path.build_filename (root, ".old-%s-%u".printf (crx.id, Random.next_int ()));
                if (FileUtils.test (target, FileTest.EXISTS) && FileUtils.rename (target, old) != 0) {
                    throw new IOError.FAILED ("Could not replace the installed version");
                }
                if (FileUtils.rename (staging, target) != 0) {
                    FileUtils.rename (old, target);
                    throw new IOError.FAILED ("Could not install the extension");
                }
                remove_tree (old);
                var loaded = Extension.load (crx.id, target);
                installed[crx.id] = loaded;
                changed ();
                return loaded;
            } finally {
                remove_tree (staging);
            }
        }

        public async Extension install_from_store (string id, Cancellable? cancellable = null) throws Error {
            var package = yield download (id, cancellable);
            return install (package, id);
        }

        public Extension inspect (Bytes package, string? expected_id, out string staging) throws Error {
            var crx = Crx.parse (package, expected_id);
            staging = Path.build_filename (root, ".inspect-%s-%u".printf (crx.id, Random.next_int ()));
            DirUtils.create_with_parents (staging, 0700);
            ZipArchive.extract (crx.archive, File.new_for_path (staging));
            return Extension.load (crx.id, staging);
        }

        public void uninstall (string id) throws Error {
            if (!installed.has_key (id)) throw new ExtensionError.NOT_FOUND ("The extension is not installed");
            installed.unset (id);
            disabled.remove (id);
            save_state ();
            remove_tree (Path.build_filename (root, id));
            changed ();
        }

        public void reload () {
            installed.clear ();
            try {
                var dir = Dir.open (root);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    string full = Path.build_filename (root, name);
                    if (name.has_prefix (".staging-") || name.has_prefix (".old-") || name.has_prefix (".inspect-")) {
                        remove_tree (full);
                        continue;
                    }
                    if (!Crx.is_valid_id (name)) continue;
                    try {
                        installed[name] = Extension.load (name, full);
                    } catch (Error e) {
                        warning ("Extension %s could not be loaded: %s", name, e.message);
                    }
                }
            } catch (FileError e) {
            }
        }

        public static void remove_tree (string path) {
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            if (FileUtils.test (path, FileTest.IS_DIR) && !FileUtils.test (path, FileTest.IS_SYMLINK)) {
                try {
                    var dir = Dir.open (path);
                    string? name;
                    while ((name = dir.read_name ()) != null) remove_tree (Path.build_filename (path, name));
                } catch (FileError e) {
                }
                DirUtils.remove (path);
            } else {
                FileUtils.unlink (path);
            }
        }

        private string state_path () {
            return Path.build_filename (root, "state.json");
        }

        private void load_state () {
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (state_path ());
                var object = parser.get_root ().get_object ();
                foreach (var node in object.get_array_member ("disabled").get_elements ()) disabled.add (node.get_string ());
            } catch (Error e) {
            }
        }

        private void save_state () {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("disabled");
            builder.begin_array ();
            foreach (string id in disabled) builder.add_string_value (id);
            builder.end_array ();
            builder.end_object ();
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            try {
                FileUtils.set_contents (state_path (), generator.to_data (null));
            } catch (FileError e) {
                warning ("Extension state could not be saved: %s", e.message);
            }
        }
    }
}
