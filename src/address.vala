namespace Singularity.Apps.Browser {

    public enum AddressKind {
        EMPTY,
        URL,
        SEARCH,
        INTERNAL
    }

    public class SearchEngine : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string query_url { get; construct; }
        public string suggest_url { get; construct; }

        public SearchEngine (string id, string name, string query_url, string suggest_url) {
            Object (id: id, name: name, query_url: query_url, suggest_url: suggest_url);
        }

        public string url_for (string query) {
            return query_url.replace ("%s", Uri.escape_string (query.strip (), null, true));
        }

        public string? suggestions_for (string query) {
            if (suggest_url == "") return null;
            return suggest_url.replace ("%s", Uri.escape_string (query.strip (), null, true));
        }

        public static SearchEngine[] builtin () {
            return {
                new SearchEngine ("duckduckgo", "DuckDuckGo", "https://duckduckgo.com/?q=%s", "https://duckduckgo.com/ac/?q=%s&type=list"),
                new SearchEngine ("startpage", "Startpage", "https://www.startpage.com/do/search?q=%s", ""),
                new SearchEngine ("ecosia", "Ecosia", "https://www.ecosia.org/search?q=%s", "https://ac.ecosia.org/autocomplete?q=%s&type=list"),
                new SearchEngine ("google", "Google", "https://www.google.com/search?q=%s", "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"),
                new SearchEngine ("bing", "Bing", "https://www.bing.com/search?q=%s", "https://api.bing.com/osjson.aspx?query=%s")
            };
        }

        public static SearchEngine lookup (string id, string custom_url = "", string custom_suggest = "") {
            if (id == "custom" && custom_url.contains ("%s"))
                return new SearchEngine ("custom", _("Custom"), custom_url, custom_suggest.contains ("%s") ? custom_suggest : "");
            foreach (var engine in builtin ())
                if (engine.id == id) return engine;
            return builtin ()[0];
        }
    }

    public class Address : Object {
        public const string NEW_TAB = "about:newtab";
        public const string HISTORY = "about:history";
        public const string BOOKMARKS = "about:bookmarks";
        public const string DOWNLOADS = "about:downloads";

        private const string[] KNOWN_SCHEMES = {
            "http", "https", "file", "about", "data", "view-source", "ftp", "blob", "mailto", "webkit-pdfjs-viewer"
        };

        public static AddressKind classify (string input) {
            string text = input.strip ();
            if (text == "") return AddressKind.EMPTY;
            if (text.has_prefix ("?")) return AddressKind.SEARCH;
            string? scheme = scheme_of (text);
            if (scheme != null) {
                if (scheme == "about") return AddressKind.INTERNAL;
                if (scheme in KNOWN_SCHEMES) return AddressKind.URL;
                if (!text.contains (" ") && !is_host_port (text) && AppInfo.get_default_for_uri_scheme (scheme) != null)
                    return AddressKind.URL;
            }
            if (text.has_prefix ("/") || text.has_prefix ("~/")) return AddressKind.URL;
            if (text.contains (" ") || text.contains ("\t")) return AddressKind.SEARCH;
            return looks_like_host (text) ? AddressKind.URL : AddressKind.SEARCH;
        }

        public static string? normalize (string input, SearchEngine engine) {
            string text = input.strip ();
            switch (classify (text)) {
                case AddressKind.EMPTY:
                    return null;
                case AddressKind.SEARCH:
                    return engine.url_for (text.has_prefix ("?") ? text.substring (1) : text);
                case AddressKind.INTERNAL:
                    return text.down ();
                default:
                    break;
            }
            if (text.has_prefix ("~/"))
                return File.new_for_path (Path.build_filename (Environment.get_home_dir (), text.substring (2))).get_uri ();
            if (text.has_prefix ("/"))
                return File.new_for_path (text).get_uri ();
            string? scheme = scheme_of (text);
            if (scheme != null && !is_host_port (text)) return text;
            string host = host_part (text);
            bool plain = host == "localhost" || is_ipv4 (host) || host.has_prefix ("[") || host.has_suffix (".local")
                || host.has_suffix (".test") || host.has_suffix (".localhost");
            return (plain ? "http://" : "https://") + text;
        }

        public static string? scheme_of (string text) {
            int colon = text.index_of_char (':');
            if (colon <= 0) return null;
            string scheme = text.substring (0, colon);
            if (!scheme[0].isalpha ()) return null;
            for (int i = 0; i < scheme.length; i++) {
                char c = scheme[i];
                if (!(c.isalnum () || c == '+' || c == '-' || c == '.')) return null;
            }
            return scheme.down ();
        }

        private static bool is_host_port (string text) {
            int colon = text.index_of_char (':');
            if (colon <= 0) return false;
            string rest = text.substring (colon + 1);
            int end = 0;
            while (end < rest.length && rest[end].isdigit ()) end++;
            if (end == 0 || end > 5) return false;
            return end == rest.length || rest[end] == '/' || rest[end] == '?' || rest[end] == '#';
        }

        private static string host_part (string text) {
            string host = text;
            int cut = -1;
            for (int i = 0; i < host.length; i++) {
                char c = host[i];
                if (c == '/' || c == '?' || c == '#') {
                    cut = i;
                    break;
                }
            }
            if (cut >= 0) host = host.substring (0, cut);
            int at = host.last_index_of_char ('@');
            if (at >= 0) host = host.substring (at + 1);
            if (host.has_prefix ("[")) {
                int close = host.index_of_char (']');
                return close > 0 ? host.substring (0, close + 1) : host;
            }
            int colon = host.last_index_of_char (':');
            if (colon > 0) host = host.substring (0, colon);
            return host.down ();
        }

        private static bool looks_like_host (string text) {
            string host = host_part (text);
            if (host == "localhost") return true;
            if (is_ipv4 (host)) return true;
            if (host.has_prefix ("[") && host.has_suffix ("]")) return true;
            string[] labels = host.split (".");
            if (labels.length < 2) return false;
            foreach (string label in labels) {
                if (label.length == 0 || label.length > 63) return false;
                if (label.has_prefix ("-") || label.has_suffix ("-")) return false;
                for (int i = 0; i < label.length; i++) {
                    char c = label[i];
                    if (!(c.isalnum () || c == '-' || (uchar) c >= 0x80)) return false;
                }
            }
            string tld = labels[labels.length - 1];
            if (tld.length < 2) return false;
            for (int i = 0; i < tld.length; i++)
                if (tld[i].isdigit ()) return false;
            return true;
        }

        public static bool is_ipv4 (string host) {
            string[] parts = host.split (".");
            if (parts.length != 4) return false;
            foreach (string part in parts) {
                if (part.length == 0 || part.length > 3) return false;
                for (int i = 0; i < part.length; i++)
                    if (!part[i].isdigit ()) return false;
                if (int.parse (part) > 255) return false;
            }
            return true;
        }

        public static string? host_of (string? uri) {
            if (uri == null || uri == "") return null;
            try {
                var parsed = Uri.parse (uri, UriFlags.NONE);
                string? host = parsed.get_host ();
                return host != null && host != "" ? host.down () : null;
            } catch (Error e) {
                return null;
            }
        }

        public static string? origin_of (string? uri) {
            if (uri == null) return null;
            try {
                var parsed = Uri.parse (uri, UriFlags.NONE);
                string? host = parsed.get_host ();
                if (host == null || host == "") return null;
                string scheme = parsed.get_scheme ().down ();
                if (host.contains (":")) host = "[" + host + "]";
                int port = parsed.get_port ();
                bool default_port = port < 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80);
                return default_port ? "%s://%s".printf (scheme, host.down ()) : "%s://%s:%d".printf (scheme, host.down (), port);
            } catch (Error e) {
                return null;
            }
        }

        public static string site_key (string? uri) {
            string? host = host_of (uri);
            if (host == null) return "";
            return host.has_prefix ("www.") ? host.substring (4) : host;
        }

        public static bool is_internal (string? uri) {
            return uri == null || uri == "" || uri.has_prefix ("about:");
        }

        public static bool is_secure (string? uri) {
            if (uri == null) return false;
            string? scheme = scheme_of (uri);
            return scheme == "https" || scheme == "file" || scheme == "about" || scheme == "data"
                || (scheme == "http" && (host_of (uri) == "localhost" || host_of (uri) == "127.0.0.1"));
        }

        public static string display (string? uri) {
            if (uri == null || uri == "" || uri == NEW_TAB) return "";
            if (uri == HISTORY) return _("History");
            if (uri == BOOKMARKS) return _("Bookmarks");
            if (uri == DOWNLOADS) return _("Downloads");
            string? scheme = scheme_of (uri);
            if (scheme == "file") {
                try {
                    return Filename.from_uri (uri);
                } catch (Error e) {
                    return uri;
                }
            }
            if (scheme != "http" && scheme != "https") return uri;
            string? host = host_of (uri);
            if (host == null) return uri;
            return host.has_prefix ("www.") ? host.substring (4) : host;
        }

        public static string full_display (string? uri) {
            if (uri == null || Address.is_internal (uri)) return display (uri);
            string text = uri;
            if (text.has_prefix ("https://")) text = text.substring (8);
            if (text.has_prefix ("www.")) text = text.substring (4);
            if (text.has_suffix ("/") && text.index_of_char ('/') == text.length - 1) text = text.substring (0, text.length - 1);
            return Uri.unescape_string (text) ?? text;
        }

        public static string[] parse_suggestions (string json) {
            string[] result = {};
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return result;
                var array = root.get_array ();
                if (array.get_length () >= 2 && array.get_element (1).get_node_type () == Json.NodeType.ARRAY) {
                    var list = array.get_array_element (1);
                    for (uint i = 0; i < list.get_length (); i++) {
                        var item = list.get_element (i);
                        if (item.get_value_type () == typeof (string)) result += item.get_string ();
                    }
                    return result;
                }
                for (uint i = 0; i < array.get_length (); i++) {
                    var item = array.get_element (i);
                    if (item.get_node_type () != Json.NodeType.OBJECT) continue;
                    var obj = item.get_object ();
                    if (obj.has_member ("phrase")) result += obj.get_string_member ("phrase");
                }
            } catch (Error e) {
            }
            return result;
        }
    }
}
