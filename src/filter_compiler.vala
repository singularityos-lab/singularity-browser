namespace Singularity.Apps.Browser {

    public class FilterStats : Object {
        public int lines;
        public int blocking;
        public int hiding;
        public int exceptions;
        public int skipped;
    }

    public class FilterCompiler : Object {
        public const int MAX_RULES = 150000;
        private const int SELECTORS_PER_RULE = 200;

        private Gee.ArrayList<Json.Node> blocks = new Gee.ArrayList<Json.Node> ();
        private Gee.ArrayList<Json.Node> hides = new Gee.ArrayList<Json.Node> ();
        private Gee.ArrayList<Json.Node> allows = new Gee.ArrayList<Json.Node> ();
        private Gee.ArrayList<string> generic_selectors = new Gee.ArrayList<string> ();
        public FilterStats stats = new FilterStats ();

        public void add_list (string text) {
            foreach (string raw in text.split ("\n")) {
                string line = raw.strip ();
                stats.lines++;
                if (line == "" || line.has_prefix ("!") || line.has_prefix ("[")) continue;
                if (!add_line (line)) stats.skipped++;
            }
        }

        public bool add_line (string line) {
            if (!line.validate () || !is_ascii (line)) return false;
            if (line.contains ("#@#") || line.contains ("#?#") || line.contains ("#$#") || line.contains ("#%#")
                || line.contains ("##+") || line.contains ("##^") || line.contains ("$$"))
                return false;
            int hide = line.index_of ("##");
            if (hide >= 0) return add_hiding (line.substring (0, hide), line.substring (hide + 2));
            return add_network (line);
        }

        private static bool is_ascii (string text) {
            for (int i = 0; i < text.length; i++)
                if ((uchar) text[i] >= 0x80) return false;
            return true;
        }

        private bool add_hiding (string domains, string selector) {
            if (selector == "" || selector.contains (":-abp-") || selector.contains (":has(")
                || selector.contains (":xpath(") || selector.contains (":style(") || selector.contains ("{"))
                return false;
            if (domains == "") {
                generic_selectors.add (selector);
                stats.hiding++;
                return true;
            }
            string[] include = {};
            string[] exclude = {};
            if (!split_domains (domains, ",", out include, out exclude)) return false;
            var trigger = new Json.Object ();
            trigger.set_string_member ("url-filter", ".*");
            if (include.length > 0) trigger.set_array_member ("if-domain", domain_array (include));
            else trigger.set_array_member ("unless-domain", domain_array (exclude));
            var action = new Json.Object ();
            action.set_string_member ("type", "css-display-none");
            action.set_string_member ("selector", selector);
            hides.add (rule (trigger, action));
            stats.hiding++;
            return true;
        }

        private static bool split_domains (string text, string separator, out string[] include, out string[] exclude) {
            string[] yes = {};
            string[] no = {};
            include = {};
            exclude = {};
            foreach (string part in text.split (separator)) {
                string d = part.strip ().down ();
                if (d == "") continue;
                bool negate = d.has_prefix ("~");
                if (negate) d = d.substring (1);
                if (d == "" || d.contains ("*") || d.contains ("/")) return false;
                if (negate) no += d;
                else yes += d;
            }
            include = yes;
            exclude = no;
            if (yes.length > 0 && no.length > 0) return false;
            return yes.length > 0 || no.length > 0;
        }

        private static Json.Array domain_array (string[] domains) {
            var array = new Json.Array ();
            foreach (string d in domains) array.add_string_element ("*" + d);
            return array;
        }

        private static Json.Node rule (Json.Object trigger, Json.Object action) {
            var obj = new Json.Object ();
            obj.set_object_member ("trigger", trigger);
            obj.set_object_member ("action", action);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (obj);
            return node;
        }

        private bool add_network (string line) {
            string pattern = line;
            bool exception = pattern.has_prefix ("@@");
            if (exception) pattern = pattern.substring (2);
            string options = "";
            int dollar = pattern.last_index_of_char ('$');
            if (dollar >= 0 && !(pattern.has_prefix ("/") && pattern.has_suffix ("/"))) {
                options = pattern.substring (dollar + 1);
                pattern = pattern.substring (0, dollar);
            }
            if (pattern.length > 2 && pattern.has_prefix ("/") && pattern.has_suffix ("/")) return false;
            string? filter = to_regex (pattern);
            if (filter == null) return false;

            var trigger = new Json.Object ();
            trigger.set_string_member ("url-filter", filter);
            if (options != "" && !apply_options (options, trigger)) return false;

            var action = new Json.Object ();
            action.set_string_member ("type", exception ? "ignore-previous-rules" : "block");
            if (exception) {
                allows.add (rule (trigger, action));
                stats.exceptions++;
            } else {
                blocks.add (rule (trigger, action));
                stats.blocking++;
            }
            return true;
        }

        public static string? to_regex (string pattern) {
            string p = pattern;
            if (p == "" || p == "*" || p == "|" || p == "||") return null;
            var out_regex = new StringBuilder ();
            bool start_anchor = false;
            bool end_anchor = false;
            if (p.has_prefix ("||")) {
                out_regex.append ("^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?");
                p = p.substring (2);
            } else if (p.has_prefix ("|")) {
                start_anchor = true;
                p = p.substring (1);
            }
            if (p.has_suffix ("|")) {
                end_anchor = true;
                p = p.substring (0, p.length - 1);
            }
            if (p == "") return null;
            if (start_anchor) out_regex.append ("^");
            int literal = 0;
            for (int i = 0; i < p.length; i++) {
                char c = p[i];
                switch (c) {
                    case '*':
                        if (out_regex.len > 0 && out_regex.str.has_suffix (".*")) break;
                        out_regex.append (".*");
                        break;
                    case '^':
                        if (i == p.length - 1) out_regex.append ("[/:?=&]?");
                        else out_regex.append ("[/:?=&]");
                        break;
                    case '|':
                    case '\\':
                    case '(':
                    case ')':
                    case '[':
                    case ']':
                    case '{':
                    case '}':
                        return null;
                    case '.':
                    case '+':
                    case '?':
                    case '$':
                    case '/':
                        out_regex.append_c ('\\');
                        out_regex.append_c (c);
                        literal++;
                        break;
                    default:
                        if (c < 0x20 || c == ' ' || (uchar) c >= 0x7f) return null;
                        out_regex.append_c (c);
                        literal++;
                        break;
                }
            }
            if (literal < 3) return null;
            if (end_anchor) out_regex.append ("$");
            string result = out_regex.str;
            if (result.has_prefix (".*")) result = result.substring (2);
            if (result.has_suffix (".*")) result = result.substring (0, result.length - 2);
            return result;
        }

        private static bool apply_options (string options, Json.Object trigger) {
            string[] types = {};
            string[] negated = {};
            foreach (string raw in options.split (",")) {
                string opt = raw.strip ().down ();
                if (opt == "") continue;
                if (opt == "third-party" || opt == "3p") {
                    trigger.set_array_member ("load-type", string_array ({ "third-party" }));
                    continue;
                }
                if (opt == "~third-party" || opt == "first-party" || opt == "1p") {
                    trigger.set_array_member ("load-type", string_array ({ "first-party" }));
                    continue;
                }
                if (opt == "match-case") {
                    trigger.set_boolean_member ("url-filter-is-case-sensitive", true);
                    continue;
                }
                if (opt == "important" || opt == "all") continue;
                if (opt.has_prefix ("domain=")) {
                    string[] include;
                    string[] exclude;
                    if (!split_domains (opt.substring (7), "|", out include, out exclude)) return false;
                    if (include.length > 0) trigger.set_array_member ("if-domain", domain_array (include));
                    else trigger.set_array_member ("unless-domain", domain_array (exclude));
                    continue;
                }
                bool negate = opt.has_prefix ("~");
                string name = negate ? opt.substring (1) : opt;
                string[]? mapped = map_type (name);
                if (mapped == null) return false;
                foreach (string t in mapped) {
                    if (negate) negated += t;
                    else types += t;
                }
            }
            if (types.length == 0 && negated.length > 0) {
                foreach (string t in all_types ())
                    if (!(t in negated)) types += t;
            }
            if (types.length > 0) trigger.set_array_member ("resource-type", string_array (types));
            return true;
        }

        private static string[] all_types () {
            return { "document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "fetch", "websocket", "other" };
        }

        private static string[]? map_type (string name) {
            switch (name) {
                case "script": return { "script" };
                case "image": return { "image" };
                case "stylesheet": case "css": return { "style-sheet" };
                case "font": return { "font" };
                case "media": return { "media" };
                case "object": return { "media", "other" };
                case "xmlhttprequest": case "xhr": return { "fetch", "raw" };
                case "subdocument": case "frame": return { "document" };
                case "document": case "doc": return { "document" };
                case "ping": case "beacon": return { "ping" };
                case "websocket": return { "websocket" };
                case "popup": return { "popup" };
                case "other": return { "other" };
                default: return null;
            }
        }

        private static Json.Array string_array (string[] values) {
            var array = new Json.Array ();
            foreach (string v in values) array.add_string_element (v);
            return array;
        }

        public int rule_count {
            get {
                return blocks.size + hides.size + allows.size
                    + (generic_selectors.size + SELECTORS_PER_RULE - 1) / SELECTORS_PER_RULE;
            }
        }

        public string to_json () {
            var array = new Json.Array ();
            int budget = MAX_RULES;
            foreach (var node in blocks) {
                if (budget-- <= 0) break;
                array.add_element (node);
            }
            for (int i = 0; i < generic_selectors.size && budget > 0; i += SELECTORS_PER_RULE) {
                var group = new StringBuilder ();
                for (int j = i; j < int.min (i + SELECTORS_PER_RULE, generic_selectors.size); j++) {
                    if (group.len > 0) group.append (", ");
                    group.append (generic_selectors[j]);
                }
                var trigger = new Json.Object ();
                trigger.set_string_member ("url-filter", ".*");
                var action = new Json.Object ();
                action.set_string_member ("type", "css-display-none");
                action.set_string_member ("selector", group.str);
                array.add_element (rule (trigger, action));
                budget--;
            }
            foreach (var node in hides) {
                if (budget-- <= 0) break;
                array.add_element (node);
            }
            foreach (var node in allows) {
                if (budget-- <= 0) break;
                array.add_element (node);
            }
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (array);
            var generator = new Json.Generator ();
            generator.set_root (root);
            return generator.to_data (null);
        }
    }
}
