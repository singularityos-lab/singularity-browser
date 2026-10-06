namespace Singularity.Apps.Browser {

    public class ContentBlocker : Object {
        private GLib.Settings settings;
        private WebKit.UserContentFilterStore filter_store;
        private string lists_dir;
        private Gee.HashMap<string, WebKit.UserContentFilter> filters = new Gee.HashMap<string, WebKit.UserContentFilter> ();
        private Soup.Session http;
        private bool refreshing = false;

        public bool enabled { get { return settings.get_boolean ("content-blocker"); } }
        public int rule_total { get; private set; default = 0; }
        public string status { get; private set; default = ""; }

        public signal void changed ();

        public ContentBlocker (GLib.Settings settings) {
            this.settings = settings;
            string data = Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser");
            lists_dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity", "browser", "filter-lists");
            DirUtils.create_with_parents (lists_dir, 0700);
            string store_dir = Path.build_filename (data, "content-filters");
            DirUtils.create_with_parents (store_dir, 0700);
            filter_store = new WebKit.UserContentFilterStore (store_dir);
            http = new Soup.Session ();
            http.timeout = 60;
            http.user_agent = "Singularity-Browser/" + Config.VERSION;
            settings.changed["content-blocker"].connect (() => changed ());
            settings.changed["filter-lists"].connect (() => refresh.begin (true));
        }

        public static string identifier_for (string url) {
            return "list-" + Checksum.compute_for_string (ChecksumType.SHA256, url).substring (0, 16);
        }

        public void apply (WebKit.UserContentManager manager, bool allowed_on_site) {
            manager.remove_all_filters ();
            if (!enabled || allowed_on_site) return;
            foreach (var filter in filters.values) manager.add_filter (filter);
        }

        public async void start () {
            foreach (string url in settings.get_strv ("filter-lists")) {
                string id = identifier_for (url);
                try {
                    var filter = yield filter_store.load (id, null);
                    filters[id] = filter;
                } catch (Error e) {
                }
            }
            if (!filters.is_empty) changed ();
            int days = settings.get_int ("filter-update-days");
            bool stale = false;
            foreach (string url in settings.get_strv ("filter-lists")) {
                if (!filters.has_key (identifier_for (url))) {
                    stale = true;
                    break;
                }
                var info = File.new_for_path (list_path (url));
                try {
                    var fi = info.query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    var age = new DateTime.now_utc ().difference (fi.get_modification_date_time ());
                    if (age > days * TimeSpan.DAY) stale = true;
                } catch (Error e) {
                    stale = true;
                }
            }
            if (stale) yield refresh (false);
        }

        private string list_path (string url) {
            return Path.build_filename (lists_dir, identifier_for (url) + ".txt");
        }

        public async void refresh (bool force) {
            if (refreshing) return;
            refreshing = true;
            status = _("Updating filter lists");
            string[] urls = settings.get_strv ("filter-lists");
            var wanted = new Gee.HashSet<string> ();
            int total = 0;
            foreach (string url in urls) {
                string id = identifier_for (url);
                wanted.add (id);
                string? text = yield download (url);
                if (text == null) {
                    if (!filters.has_key (id)) {
                        try {
                            FileUtils.get_contents (list_path (url), out text);
                        } catch (Error e) {
                            continue;
                        }
                    } else {
                        continue;
                    }
                }
                var compiler = new FilterCompiler ();
                compiler.add_list (text);
                string json = compiler.to_json ();
                try {
                    var filter = yield filter_store.save (id, new Bytes (json.data), null);
                    filters[id] = filter;
                    total += compiler.rule_count;
                    debug ("Filter list %s: %d rules, %d skipped", url, compiler.rule_count, compiler.stats.skipped);
                } catch (Error e) {
                    warning ("Filter list %s could not be compiled: %s", url, e.message);
                }
            }
            foreach (var id in filters.keys.to_array ()) {
                if (!wanted.contains (id)) {
                    filters.unset (id);
                    try {
                        yield filter_store.remove (id, null);
                    } catch (Error e) {
                    }
                }
            }
            if (total > 0) rule_total = total;
            status = "";
            refreshing = false;
            changed ();
        }

        private async string? download (string url) {
            try {
                string text;
                if (url.has_prefix ("file://")) {
                    uint8[] data;
                    yield File.new_for_uri (url).load_contents_async (null, out data, null);
                    text = (string) data;
                } else {
                    var message = new Soup.Message ("GET", url);
                    var bytes = yield http.send_and_read_async (message, Priority.LOW, null);
                    if (message.status_code != 200) return null;
                    text = Util.bytes_to_string (bytes);
                }
                if (!text.validate ()) return null;
                FileUtils.set_contents (list_path (url), text);
                return text;
            } catch (Error e) {
                warning ("Filter list %s could not be downloaded: %s", url, e.message);
                return null;
            }
        }
    }
}
