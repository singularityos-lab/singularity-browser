namespace Singularity.Apps.Browser {

    public errordomain WebDriverError {
        FAILED
    }

    public class WebDriverClient : Object {
        public const string ELEMENT = "element-6066-11e4-a52e-4f735466cecf";

        public string endpoint { get; private set; }
        public bool hidden { get; set; default = false; }

        private Soup.Session http = new Soup.Session ();
        private Subprocess? driver = null;
        private string? session_id = null;

        public WebDriverClient (string? endpoint) {
            this.endpoint = endpoint ?? "";
            http.timeout = 120;
        }

        public void close () {
            if (session_id != null) {
                try {
                    request ("DELETE", "/session/" + session_id, null);
                } catch (Error e) {
                }
                session_id = null;
            }
            if (driver != null) {
                driver.force_exit ();
                driver = null;
            }
        }

        private static string? driver_path () {
            try {
                string exe = FileUtils.read_link ("/proc/self/exe");
                string sibling = Path.build_filename (Path.get_dirname (exe), "singularity-webdriver");
                if (FileUtils.test (sibling, FileTest.IS_EXECUTABLE)) return sibling;
            } catch (FileError e) {
            }
            return Environment.find_program_in_path ("singularity-webdriver");
        }

        private static uint16 free_port () throws Error {
            var socket = new Socket (SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
            socket.bind (new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0), true);
            var address = (InetSocketAddress) socket.get_local_address ();
            uint16 port = address.get_port ();
            socket.close ();
            return port;
        }

        private void start_driver () throws Error {
            string? path = driver_path ();
            if (path == null) throw new WebDriverError.FAILED ("singularity-webdriver is not installed");
            uint16 port = free_port ();
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            if (hidden) launcher.setenv ("FOTONE_AUTOMATION_HIDDEN", "1", true);
            if (Environment.get_variable ("WAYLAND_DISPLAY") == null) {
                string runtime = Environment.get_user_runtime_dir ();
                if (FileUtils.test (Path.build_filename (runtime, "wayland-0"), FileTest.EXISTS))
                    launcher.setenv ("WAYLAND_DISPLAY", "wayland-0", true);
            }
            driver = launcher.spawnv ({ path, "--port=%u".printf (port) });
            endpoint = "http://127.0.0.1:%u".printf (port);
            for (int i = 0; i < 100; i++) {
                try {
                    var status = request ("GET", "/status", null);
                    if (status != null) return;
                } catch (Error e) {
                }
                Thread.usleep (100000);
            }
            throw new WebDriverError.FAILED ("singularity-webdriver did not start");
        }

        public Json.Node? request (string method, string path, Json.Object? body) throws Error {
            var msg = new Soup.Message (method, endpoint + path);
            if (body != null) {
                var node = new Json.Node (Json.NodeType.OBJECT);
                node.set_object (body);
                msg.set_request_body_from_bytes ("application/json", new Bytes (Json.to_string (node, false).data));
            } else if (method == "POST") {
                msg.set_request_body_from_bytes ("application/json", new Bytes ("{}".data));
            }
            var bytes = http.send_and_read (msg);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                throw new WebDriverError.FAILED ("WebDriver %s %s: HTTP %u".printf (method, path, msg.status_code));
            var value = root.get_object ().get_member ("value");
            if (msg.status_code >= 400) {
                string text = "HTTP %u".printf (msg.status_code);
                if (value != null && value.get_node_type () == Json.NodeType.OBJECT) {
                    var o = value.get_object ();
                    text = o.has_member ("message") && o.get_string_member ("message") != ""
                        ? o.get_string_member ("message")
                        : o.get_string_member_with_default ("error", text);
                }
                throw new WebDriverError.FAILED (text);
            }
            return value;
        }

        public string session () throws Error {
            if (session_id != null) return session_id;
            if (endpoint == "") start_driver ();
            var caps = new Json.Object ();
            var always = new Json.Object ();
            always.set_string_member ("pageLoadStrategy", "normal");
            caps.set_object_member ("alwaysMatch", always);
            var body = new Json.Object ();
            body.set_object_member ("capabilities", caps);
            var value = request ("POST", "/session", body);
            session_id = value.get_object ().get_string_member ("sessionId");
            return session_id;
        }

        public Json.Node? call (string method, string path, Json.Object? body = null) throws Error {
            return request (method, "/session/" + session () + path, body);
        }

        public Json.Node? execute (string script, Json.Array? args = null) throws Error {
            var body = new Json.Object ();
            body.set_string_member ("script", script);
            body.set_array_member ("args", args ?? new Json.Array ());
            return call ("POST", "/execute/sync", body);
        }

        public static Json.Object element_ref (string id) {
            var o = new Json.Object ();
            o.set_string_member (ELEMENT, id);
            return o;
        }

        public string find (string selector) throws Error {
            var body = new Json.Object ();
            body.set_string_member ("using", "css selector");
            body.set_string_member ("value", selector);
            return call ("POST", "/element", body).get_object ().get_string_member (ELEMENT);
        }

        public void actions (Json.Array sources) throws Error {
            var body = new Json.Object ();
            body.set_array_member ("actions", sources);
            call ("POST", "/actions", body);
            call ("DELETE", "/actions");
        }
    }
}
