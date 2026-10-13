namespace Singularity.Apps.Browser {

    public class DevTools : Object {
        public const string SCHEME = "singularity-devtools";
        public const string SETTINGS_KEY = "advanced-developer-tools";

        public static string? server { get; private set; default = null; }

        private static WebKit.WebContext? shared_context = null;

        public static void prepare () {
            var source = SettingsSchemaSource.get_default ();
            var schema = source != null ? source.lookup (BrowserApp.APP_ID, true) : null;
            if (schema == null || !schema.has_key (SETTINGS_KEY)) return;
            if (!new GLib.Settings (BrowserApp.APP_ID).get_boolean (SETTINGS_KEY)) return;
            uint16 port = free_port ();
            if (port == 0) return;
            server = "127.0.0.1:%u".printf (port);
            Environment.set_variable ("WEBKIT_INSPECTOR_HTTP_SERVER", server, true);
        }

        private static uint16 free_port () {
            try {
                var socket = new Socket (SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
                socket.bind (new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0), true);
                var address = (InetSocketAddress) socket.get_local_address ();
                uint16 port = address.get_port ();
                socket.close ();
                return port;
            } catch (Error e) {
                warning ("Developer tools: no free port: %s", e.message);
                return 0;
            }
        }

        public static string? frontend_dir () {
            string? dir = Environment.get_variable ("SINGULARITY_DEVTOOLS_FRONTEND");
            if (dir == null) {
                try {
                    string exe = FileUtils.read_link ("/proc/self/exe");
                    dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "singularity-browser", "devtools");
                } catch (Error e) {
                    return null;
                }
            }
            return FileUtils.test (Path.build_filename (dir, "devtools_app.html"), FileTest.EXISTS) ? dir : null;
        }

        public static bool available {
            get { return server != null && frontend_dir () != null; }
        }

        public static WebKit.WebContext context () {
            if (shared_context != null) return shared_context;
            shared_context = new WebKit.WebContext ();
            shared_context.register_uri_scheme (SCHEME, serve);
            var security = shared_context.get_security_manager ();
            security.register_uri_scheme_as_secure (SCHEME);
            security.register_uri_scheme_as_cors_enabled (SCHEME);
            return shared_context;
        }

        private static void serve (WebKit.URISchemeRequest request) {
            string? root = frontend_dir ();
            string path = request.get_path ();
            if (root == null || path == null || path == "" || path.contains ("..")) {
                request.finish_error (new IOError.NOT_FOUND ("Not found"));
                return;
            }
            var file = File.new_for_path (Path.build_filename (root, path));
            try {
                var stream = file.read ();
                var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                request.finish (stream, info.get_size (), mime_for (path));
            } catch (Error e) {
                request.finish_error (e);
            }
        }

        private static string mime_for (string path) {
            if (path.has_suffix (".js") || path.has_suffix (".mjs")) return "text/javascript";
            if (path.has_suffix (".html")) return "text/html";
            if (path.has_suffix (".css")) return "text/css";
            if (path.has_suffix (".json") || path.has_suffix (".map")) return "application/json";
            if (path.has_suffix (".svg")) return "image/svg+xml";
            if (path.has_suffix (".png")) return "image/png";
            if (path.has_suffix (".avif")) return "image/avif";
            if (path.has_suffix (".woff2")) return "font/woff2";
            if (path.has_suffix (".wasm")) return "application/wasm";
            return "application/octet-stream";
        }

        public static async string[] targets (string uri) {
            string[] matching = {};
            string[] all = {};
            if (server == null) return all;
            try {
                var session = new Soup.Session ();
                var message = new Soup.Message ("GET", "http://%s/".printf (server));
                var bytes = yield session.send_and_read_async (message, Priority.DEFAULT, null);
                string html = (string) bytes.get_data ();
                var rows = new Regex ("targeturl\">([^<]*)</div>.*?(/socket/[0-9]+/[0-9]+/WebPage)");
                MatchInfo match;
                if (rows.match (html, 0, out match)) {
                    do {
                        string path = match.fetch (2);
                        all += path;
                        if (match.fetch (1) == uri) matching += path;
                    } while (match.next ());
                }
            } catch (Error e) {
                warning ("Developer tools: cannot list targets: %s", e.message);
            }
            return matching.length > 0 ? matching : all;
        }
    }

    public class DevToolsPanel : Gtk.Box {
        public signal void dock_requested (bool docked);
        public signal void close_requested ();
        public signal void open_uri (string uri);
        public signal void page_bounds_changed (int x, int y, int width, int height);

        public WebKit.WebView frontend { get; private set; }
        public bool docked { get; set; default = true; }

        private bool loaded = false;
        private double pending_x = -1;
        private double pending_y = -1;
        private bool pending_pick = false;

        construct {
            orientation = Gtk.Orientation.VERTICAL;
            add_css_class ("devtools-panel");
            var content = new WebKit.UserContentManager ();
            foreach (string name in new string[] { "host.js", "compatibility", "translator.js" }) {
                string? source = script (name);
                if (source == null) continue;
                content.add_script (new WebKit.UserScript (source, WebKit.UserContentInjectedFrames.TOP_FRAME,
                    WebKit.UserScriptInjectionTime.START, { DevTools.SCHEME + "://*/*" }, null));
            }
            content.register_script_message_handler ("singularityDevtools", null);
            content.script_message_received["singularityDevtools"].connect (on_message);
            frontend = (WebKit.WebView) Object.new (typeof (WebKit.WebView),
                "web-context", DevTools.context (),
                "user-content-manager", content);
            frontend.get_settings ().enable_developer_extras = false;
            frontend.hexpand = true;
            frontend.vexpand = true;
            frontend.load_changed.connect ((event) => {
                if (event != WebKit.LoadEvent.FINISHED) return;
                loaded = true;
                if (pending_pick) inspect_at (pending_x, pending_y);
            });
            append (frontend);
        }

        private static string? script (string name) {
            if (name == "compatibility") {
                string? root = DevTools.frontend_dir ();
                if (root == null) return null;
                try {
                    string text;
                    FileUtils.get_contents (Path.build_filename (root, "devtools_compatibility.js"), out text);
                    return text;
                } catch (Error e) {
                    warning ("Developer tools: %s", e.message);
                    return null;
                }
            }
            try {
                var bytes = resources_lookup_data ("/dev/sinty/browser/devtools/" + name, ResourceLookupFlags.NONE);
                return (string) bytes.get_data ();
            } catch (Error e) {
                warning ("Developer tools: %s", e.message);
                return null;
            }
        }

        public async void attach (WebKit.WebView inspected) {
            string marker = Uuid.string_random ();
            try {
                yield inspected.evaluate_javascript ("window.__singularityDevtools = '%s'".printf (marker), -1, null, null, null);
            } catch (Error e) {
            }
            string[] paths = yield DevTools.targets (inspected.uri ?? "");
            for (int attempt = 0; paths.length == 0 && attempt < 20; attempt++) {
                Timeout.add (250, attach.callback);
                yield;
                paths = yield DevTools.targets (inspected.uri ?? "");
            }
            var list = new Json.Builder ();
            list.begin_array ();
            foreach (string path in paths) list.add_string_value (path);
            list.end_array ();
            var generator = new Json.Generator ();
            generator.root = list.get_root ();
            string uri = "%s://frontend/devtools_app.html?can_dock=true&dockSide=right&server=%s&targets=%s&marker=%s%s".printf (
                DevTools.SCHEME,
                Uri.escape_string (DevTools.server, null, false),
                Uri.escape_string (generator.to_data (null), null, false),
                marker,
                Environment.get_variable ("SINGULARITY_DEVTOOLS_DEBUG") != null ? "&debug=1" : "");
            loaded = false;
            frontend.load_uri (uri);
        }

        public void inspect_at (double x, double y) {
            pending_x = x;
            pending_y = y;
            if (!loaded) {
                pending_pick = true;
                return;
            }
            pending_pick = false;
            frontend.evaluate_javascript.begin ("SingularityCDP.inspectAt(%d, %d)".printf ((int) x, (int) y), -1, null, null, null);
        }

        private void on_message (JSC.Value value) {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (value.to_string ());
            } catch (Error e) {
                return;
            }
            var root = parser.get_root ().get_object ();
            string method = root.get_string_member ("method");
            var args = root.get_array_member ("args");
            switch (method) {
                case "copyText":
                    if (args.get_length () > 0) get_clipboard ().set_text (args.get_string_element (0));
                    break;
                case "openInNewTab":
                    if (args.get_length () > 0) open_uri (args.get_string_element (0));
                    break;
                case "save":
                    if (args.get_length () > 1) save.begin (args.get_string_element (0), args.get_string_element (1));
                    break;
                case "closeWindow":
                    close_requested ();
                    break;
                case "setIsDocked":
                    if (args.get_length () > 0) dock_requested (args.get_boolean_element (0));
                    break;
                case "setInspectedPageBounds":
                    if (args.get_length () > 0) {
                        var bounds = args.get_object_element (0);
                        page_bounds_changed ((int) bounds.get_int_member ("x"), (int) bounds.get_int_member ("y"),
                            (int) bounds.get_int_member ("width"), (int) bounds.get_int_member ("height"));
                    }
                    break;
                case "log":
                    if (args.get_length () > 0) message ("devtools: %s", args.get_string_element (0));
                    break;
                case "bringToFront":
                    var window = get_root () as Gtk.Window;
                    if (window != null) window.present ();
                    break;
                default:
                    break;
            }
        }

        private async void save (string url, string content) {
            var dialog = new Gtk.FileDialog ();
            string name = Path.get_basename (url);
            dialog.initial_name = name != "" && name != "/" ? name : "devtools.txt";
            try {
                var file = yield dialog.save (get_root () as Gtk.Window, null);
                if (file != null) yield file.replace_contents_async (content.data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
            }
        }
    }
}
