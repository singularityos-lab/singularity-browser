namespace Singularity.Apps.Browser {

    public class DnrCompiler : Object {
        public const int MAX_RULES = 150000;
        private Gee.ArrayList<Json.Node> blocks = new Gee.ArrayList<Json.Node> ();
        private Gee.ArrayList<Json.Node> upgrades = new Gee.ArrayList<Json.Node> ();
        private Gee.ArrayList<Json.Node> allows = new Gee.ArrayList<Json.Node> ();
        public int skipped { get; private set; default = 0; }

        public int rule_count {
            get { return blocks.size + upgrades.size + allows.size; }
        }

        public void add_rules (Json.Array rules) {
            foreach (var node in rules.get_elements ()) {
                if (node.get_node_type () != Json.NodeType.OBJECT || !add_rule (node.get_object ())) skipped++;
            }
        }

        private bool add_rule (Json.Object rule) {
            var action = rule.get_object_member ("action");
            var condition = rule.has_member ("condition") ? rule.get_object_member ("condition") : new Json.Object ();
            if (action == null) return false;
            string type = action.get_string_member_with_default ("type", "");
            string webkit_action;
            switch (type) {
                case "block": webkit_action = "block"; break;
                case "allow":
                case "allowAllRequests": webkit_action = "ignore-previous-rules"; break;
                case "upgradeScheme": webkit_action = "make-https"; break;
                default: return false;
            }
            string[]? filters = url_filters (condition);
            if (filters == null) return false;
            string[]? types = resource_types (condition, type == "allowAllRequests");
            if (types == null) return false;
            foreach (string filter in filters) {
                var trigger = new Json.Object ();
                trigger.set_string_member ("url-filter", filter);
                if (condition.get_boolean_member_with_default ("isUrlFilterCaseSensitive", false))
                    trigger.set_boolean_member ("url-filter-is-case-sensitive", true);
                string[] initiators = strings (condition, "initiatorDomains", "domains");
                string[] excluded = strings (condition, "excludedInitiatorDomains", "excludedDomains");
                if (initiators.length > 0) trigger.set_array_member ("if-domain", domains (initiators));
                else if (excluded.length > 0) trigger.set_array_member ("unless-domain", domains (excluded));
                string party = condition.get_string_member_with_default ("domainType", "");
                if (party == "thirdParty") trigger.set_array_member ("load-type", string_array ({ "third-party" }));
                else if (party == "firstParty") trigger.set_array_member ("load-type", string_array ({ "first-party" }));
                trigger.set_array_member ("resource-type", string_array (types));
                var act = new Json.Object ();
                act.set_string_member ("type", webkit_action);
                var obj = new Json.Object ();
                obj.set_object_member ("trigger", trigger);
                obj.set_object_member ("action", act);
                var out_node = new Json.Node (Json.NodeType.OBJECT);
                out_node.set_object (obj);
                if (webkit_action == "block") blocks.add (out_node);
                else if (webkit_action == "make-https") upgrades.add (out_node);
                else allows.add (out_node);
            }
            return true;
        }

        private static string[]? url_filters (Json.Object condition) {
            string[] request_domains = strings (condition, "requestDomains", null);
            bool has_url = condition.has_member ("urlFilter");
            bool has_regex = condition.has_member ("regexFilter");
            if (request_domains.length > 0) {
                if (has_url || has_regex || request_domains.length > 256) return null;
                string[] filters = {};
                foreach (string d in request_domains)
                    filters += "^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?" + Regex.escape_string (d) + "[/:?]";
                return filters;
            }
            string? filter;
            if (has_regex) filter = safe_regex (condition.get_string_member ("regexFilter"));
            else if (!has_url) filter = ".*";
            else filter = FilterCompiler.to_regex (condition.get_string_member ("urlFilter"));
            if (filter == null) return null;
            return { filter };
        }

        public static string? safe_regex (string regex) {
            if (regex.length == 0 || regex.length > 512 || !regex.validate ()) return null;
            for (int i = 0; i < regex.length; i++) {
                char c = regex[i];
                if (c == '|' || c == '{' || c == '}' || c == '(' || c == ')' || (uchar) c >= 0x80) return null;
                if (c == '\\') {
                    if (i + 1 >= regex.length) return null;
                    char n = regex[i + 1];
                    if (n.isalnum ()) return null;
                    i++;
                }
            }
            return regex;
        }

        private static string[] strings (Json.Object o, string key, string? fallback) {
            string[] out_list = {};
            Json.Array? array = null;
            if (o.has_member (key)) array = o.get_array_member (key);
            else if (fallback != null && o.has_member (fallback)) array = o.get_array_member (fallback);
            if (array == null) return out_list;
            foreach (var node in array.get_elements ()) {
                string s = node.get_string ().strip ().down ();
                if (s != "" && s.validate () && !s.contains ("/") && !s.contains ("*")) out_list += s;
            }
            return out_list;
        }

        private static Json.Array domains (string[] list) {
            var array = new Json.Array ();
            foreach (string d in list) array.add_string_element ("*" + d);
            return array;
        }

        private static Json.Array string_array (string[] list) {
            var array = new Json.Array ();
            foreach (string s in list) array.add_string_element (s);
            return array;
        }

        private static string[]? map (string type) {
            switch (type) {
                case "main_frame": case "sub_frame": return { "document" };
                case "stylesheet": return { "style-sheet" };
                case "script": return { "script" };
                case "image": return { "image", "svg-document" };
                case "font": return { "font" };
                case "object": return { "media", "other" };
                case "xmlhttprequest": return { "fetch", "raw" };
                case "ping": case "csp_report": return { "ping" };
                case "media": return { "media" };
                case "websocket": case "webtransport": return { "websocket" };
                case "other": case "webbundle": return { "other" };
            }
            return null;
        }

        private static string[]? resource_types (Json.Object condition, bool frames_only) {
            string[] all = { "document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping", "fetch", "websocket", "other" };
            string[] picked = {};
            if (condition.has_member ("resourceTypes")) {
                foreach (var node in condition.get_array_member ("resourceTypes").get_elements ()) {
                    string[]? m = map (node.get_string ());
                    if (m == null) continue;
                    foreach (string t in m) if (!(t in picked)) picked += t;
                }
                return picked.length > 0 ? picked : null;
            }
            if (frames_only) return { "document" };
            string[] excluded = { "document" };
            if (condition.has_member ("excludedResourceTypes")) {
                excluded = {};
                foreach (var node in condition.get_array_member ("excludedResourceTypes").get_elements ()) {
                    string[]? m = map (node.get_string ());
                    if (m == null) continue;
                    foreach (string t in m) excluded += t;
                }
            }
            foreach (string t in all) if (!(t in excluded)) picked += t;
            return picked.length > 0 ? picked : null;
        }

        public string to_json () {
            var array = new Json.Array ();
            int n = 0;
            foreach (var list in new Gee.ArrayList<Json.Node>[] { blocks, upgrades, allows }) {
                foreach (var node in list) {
                    if (n++ >= MAX_RULES) break;
                    array.add_element (node);
                }
            }
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (array);
            return Json.to_string (root, false);
        }
    }
}
