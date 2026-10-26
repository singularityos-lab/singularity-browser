namespace Singularity.Apps.Browser.Config {
    public const string VERSION = "0.1.0";
}

namespace Singularity.Apps.Browser {

    public class BrowserMcp : Object {
        private const string SNAPSHOT = """
const out = [];
const elements = [];
const seen = new Set();
const visible = (el) => {
  const r = el.getBoundingClientRect();
  if (r.width === 0 && r.height === 0) return false;
  const s = getComputedStyle(el);
  return s.visibility !== 'hidden' && s.display !== 'none';
};
const label = (el) => {
  const aria = el.getAttribute('aria-label');
  if (aria) return aria;
  if (el.labels && el.labels.length) return el.labels[0].innerText;
  if (el.placeholder) return el.placeholder;
  if (el.alt) return el.alt;
  if (el.title) return el.title;
  return (el.innerText || el.value || '').replace(/\s+/g, ' ').trim();
};
const role = (el) => {
  const r = el.getAttribute('role');
  if (r) return r;
  const t = el.tagName.toLowerCase();
  if (t === 'a') return 'link';
  if (t === 'input') return el.type === 'checkbox' || el.type === 'radio' ? el.type : 'textbox ' + el.type;
  if (t === 'textarea') return 'textbox';
  if (t === 'select') return 'combobox';
  if (/^h[1-6]$/.test(t)) return 'heading ' + t[1];
  return t;
};
const pick = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=option],[onclick],[contenteditable=""],[contenteditable=true],h1,h2,h3';
for (const el of document.querySelectorAll(pick)) {
  if (seen.has(el) || !visible(el)) continue;
  seen.add(el);
  const name = label(el).slice(0, 120);
  let line = role(el) + (name ? ' "' + name + '"' : '');
  if (el.tagName === 'A') line += ' -> ' + el.getAttribute('href');
  if ('value' in el && el.tagName !== 'BUTTON' && el.value) line += ' value="' + String(el.value).slice(0, 80) + '"';
  if (el.checked) line += ' checked';
  if (el.disabled) line += ' disabled';
  elements.push(el);
  out.push(line);
  if (elements.length >= 400) break;
}
return { title: document.title, url: location.href, lines: out, elements: elements,
         text: (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, 6000) };
""";

        private const string SELECT = """
const [el, values] = arguments;
for (const o of el.options) o.selected = values.includes(o.value) || values.includes(o.text);
el.dispatchEvent(new Event('input', { bubbles: true }));
el.dispatchEvent(new Event('change', { bubbles: true }));
return Array.from(el.selectedOptions).map(o => o.value);
""";

        private WebDriverClient driver;
        private Gee.HashMap<string, string> refs = new Gee.HashMap<string, string> ();

        public BrowserMcp (WebDriverClient driver) {
            this.driver = driver;
        }

        private static Json.Object prop (string type, string description) {
            var p = new Json.Object ();
            p.set_string_member ("type", type);
            p.set_string_member ("description", description);
            return p;
        }

        private static Json.Object tool (string name, string description, Json.Object properties, string[] required) {
            var t = new Json.Object ();
            t.set_string_member ("name", name);
            t.set_string_member ("description", description);
            var schema = new Json.Object ();
            schema.set_string_member ("type", "object");
            schema.set_object_member ("properties", properties);
            var req = new Json.Array ();
            foreach (var r in required) req.add_string_element (r);
            schema.set_array_member ("required", req);
            t.set_object_member ("inputSchema", schema);
            return t;
        }

        private static Json.Object target_props () {
            var p = new Json.Object ();
            p.set_object_member ("ref", prop ("string", "Element reference from browser_snapshot, such as e12"));
            p.set_object_member ("selector", prop ("string", "CSS selector, used when no ref is given"));
            return p;
        }

        private Json.Array tools () {
            var list = new Json.Array ();
            var nav = new Json.Object ();
            nav.set_object_member ("url", prop ("string", "Address to open"));
            list.add_object_element (tool ("browser_navigate", "Open a URL in the current tab and wait for it to load", nav, { "url" }));
            list.add_object_element (tool ("browser_back", "Go back in the current tab", new Json.Object (), {}));
            list.add_object_element (tool ("browser_forward", "Go forward in the current tab", new Json.Object (), {}));
            list.add_object_element (tool ("browser_reload", "Reload the current tab", new Json.Object (), {}));
            list.add_object_element (tool ("browser_snapshot", "Title, address, visible text and the interactive elements of the page, each with a ref for the other tools", new Json.Object (), {}));
            list.add_object_element (tool ("browser_click", "Click an element", target_props (), {}));
            list.add_object_element (tool ("browser_hover", "Move the pointer over an element", target_props (), {}));
            var type = target_props ();
            type.set_object_member ("text", prop ("string", "Text to type"));
            type.set_object_member ("clear", prop ("boolean", "Empty the field first"));
            type.set_object_member ("submit", prop ("boolean", "Press Enter after typing"));
            list.add_object_element (tool ("browser_type", "Type text into an editable element", type, { "text" }));
            var key = new Json.Object ();
            key.set_object_member ("key", prop ("string", "Key name such as Enter, Tab, Escape, ArrowDown, or a single character"));
            list.add_object_element (tool ("browser_press_key", "Press a key on the focused element", key, { "key" }));
            var select = target_props ();
            var values = new Json.Object ();
            values.set_string_member ("type", "array");
            values.set_string_member ("description", "Option values or labels to select");
            var items = new Json.Object ();
            items.set_string_member ("type", "string");
            values.set_object_member ("items", items);
            select.set_object_member ("values", values);
            list.add_object_element (tool ("browser_select_option", "Select options in a list box", select, { "values" }));
            list.add_object_element (tool ("browser_screenshot", "PNG image of the visible part of the page", new Json.Object (), {}));
            var eval = new Json.Object ();
            eval.set_object_member ("function", prop ("string", "JavaScript function to run in the page, for example () => document.title"));
            list.add_object_element (tool ("browser_evaluate", "Run JavaScript in the page and return its JSON result", eval, { "function" }));
            var wait = new Json.Object ();
            wait.set_object_member ("text", prop ("string", "Text to wait for"));
            wait.set_object_member ("selector", prop ("string", "CSS selector to wait for"));
            wait.set_object_member ("seconds", prop ("number", "Longest wait, 10 by default"));
            list.add_object_element (tool ("browser_wait_for", "Wait until text or an element appears, or for a number of seconds", wait, {}));
            var tabs = new Json.Object ();
            tabs.set_object_member ("action", prop ("string", "list, new, select or close"));
            tabs.set_object_member ("index", prop ("integer", "Tab index for select and close"));
            tabs.set_object_member ("url", prop ("string", "Address for a new tab"));
            list.add_object_element (tool ("browser_tabs", "List, open, switch to or close tabs", tabs, { "action" }));
            var size = new Json.Object ();
            size.set_object_member ("width", prop ("integer", "Window width"));
            size.set_object_member ("height", prop ("integer", "Window height"));
            list.add_object_element (tool ("browser_resize", "Resize the browser window", size, { "width", "height" }));
            list.add_object_element (tool ("browser_close", "End the browser session", new Json.Object (), {}));
            return list;
        }

        public Json.Object? handle (string method, Json.Object prm) {
            switch (method) {
                case "initialize":
                    var r = new Json.Object ();
                    r.set_string_member ("protocolVersion", prm.has_member ("protocolVersion") ? prm.get_string_member ("protocolVersion") : "2025-06-18");
                    var caps = new Json.Object ();
                    caps.set_object_member ("tools", new Json.Object ());
                    r.set_object_member ("capabilities", caps);
                    var info = new Json.Object ();
                    info.set_string_member ("name", "singularity-browser");
                    info.set_string_member ("version", Config.VERSION);
                    r.set_object_member ("serverInfo", info);
                    return r;
                case "ping":
                    return new Json.Object ();
                case "tools/list":
                    var r = new Json.Object ();
                    r.set_array_member ("tools", tools ());
                    return r;
                case "tools/call":
                    var args = prm.has_member ("arguments") ? prm.get_object_member ("arguments") : new Json.Object ();
                    try {
                        return call_tool (prm.get_string_member ("name"), args);
                    } catch (Error e) {
                        return text_result (e.message, true);
                    }
                default:
                    return null;
            }
        }

        private static Json.Object text_result (string text, bool error = false) {
            var r = new Json.Object ();
            var content = new Json.Array ();
            var c = new Json.Object ();
            c.set_string_member ("type", "text");
            c.set_string_member ("text", text);
            content.add_object_element (c);
            r.set_array_member ("content", content);
            r.set_boolean_member ("isError", error);
            return r;
        }

        private string element (Json.Object args) throws Error {
            string? r = args.has_member ("ref") ? args.get_string_member ("ref") : null;
            if (r != null && r != "") {
                if (!refs.has_key (r)) throw new WebDriverError.FAILED ("Unknown ref %s, take a new browser_snapshot".printf (r));
                return refs[r];
            }
            string? selector = args.has_member ("selector") ? args.get_string_member ("selector") : null;
            if (selector == null || selector == "") throw new WebDriverError.FAILED ("Give a ref or a selector");
            return driver.find (selector);
        }

        private static string key_value (string key) {
            switch (key.down ()) {
                case "enter": case "return": return "";
                case "tab": return "";
                case "escape": case "esc": return "";
                case "backspace": return "";
                case "delete": return "";
                case "space": return " ";
                case "arrowup": case "up": return "";
                case "arrowdown": case "down": return "";
                case "arrowleft": case "left": return "";
                case "arrowright": case "right": return "";
                case "pageup": return "";
                case "pagedown": return "";
                case "home": return "";
                case "end": return "";
                default: return key;
            }
        }

        private void press (string key) throws Error {
            string v = key_value (key);
            var keys = new Json.Array ();
            foreach (string kind in new string[] { "keyDown", "keyUp" }) {
                var a = new Json.Object ();
                a.set_string_member ("type", kind);
                a.set_string_member ("value", v);
                keys.add_object_element (a);
            }
            var source = new Json.Object ();
            source.set_string_member ("type", "key");
            source.set_string_member ("id", "keyboard");
            source.set_array_member ("actions", keys);
            var sources = new Json.Array ();
            sources.add_object_element (source);
            driver.actions (sources);
        }

        private string page_state () throws Error {
            string title = driver.call ("GET", "/title").get_string ();
            string url = driver.call ("GET", "/url").get_string ();
            return "Page: %s\nAddress: %s".printf (title, url);
        }

        private Json.Object snapshot () throws Error {
            var value = driver.execute (SNAPSHOT).get_object ();
            refs.clear ();
            var sb = new StringBuilder ();
            sb.append ("Page: %s\nAddress: %s\n\nElements:\n".printf (value.get_string_member ("title"), value.get_string_member ("url")));
            var lines = value.get_array_member ("lines");
            var elements = value.get_array_member ("elements");
            for (uint i = 0; i < lines.get_length () && i < elements.get_length (); i++) {
                string id = "e%u".printf (i + 1);
                refs[id] = elements.get_object_element (i).get_string_member (WebDriverClient.ELEMENT);
                sb.append ("[%s] %s\n".printf (id, lines.get_string_element (i)));
            }
            sb.append ("\nText:\n");
            sb.append (value.get_string_member ("text"));
            return text_result (sb.str);
        }

        private Json.Object call_tool (string name, Json.Object args) throws Error {
            switch (name) {
                case "browser_navigate":
                    var body = new Json.Object ();
                    body.set_string_member ("url", args.get_string_member ("url"));
                    driver.call ("POST", "/url", body);
                    refs.clear ();
                    return text_result (page_state ());
                case "browser_back":
                    driver.call ("POST", "/back");
                    return text_result (page_state ());
                case "browser_forward":
                    driver.call ("POST", "/forward");
                    return text_result (page_state ());
                case "browser_reload":
                    driver.call ("POST", "/refresh");
                    return text_result (page_state ());
                case "browser_snapshot":
                    return snapshot ();
                case "browser_click":
                    driver.call ("POST", "/element/%s/click".printf (element (args)));
                    return text_result ("Clicked\n" + page_state ());
                case "browser_hover":
                    var move = new Json.Object ();
                    move.set_string_member ("type", "pointerMove");
                    move.set_int_member ("duration", 0);
                    move.set_object_member ("origin", WebDriverClient.element_ref (element (args)));
                    move.set_int_member ("x", 0);
                    move.set_int_member ("y", 0);
                    var moves = new Json.Array ();
                    moves.add_object_element (move);
                    var pointer = new Json.Object ();
                    pointer.set_string_member ("type", "pointer");
                    pointer.set_string_member ("id", "mouse");
                    pointer.set_array_member ("actions", moves);
                    var sources = new Json.Array ();
                    sources.add_object_element (pointer);
                    driver.actions (sources);
                    return text_result ("Hovered");
                case "browser_type":
                    string target = element (args);
                    if (args.has_member ("clear") && args.get_boolean_member ("clear"))
                        driver.call ("POST", "/element/%s/clear".printf (target));
                    var text = new Json.Object ();
                    string typed = args.get_string_member ("text");
                    if (args.has_member ("submit") && args.get_boolean_member ("submit")) typed += "";
                    text.set_string_member ("text", typed);
                    driver.call ("POST", "/element/%s/value".printf (target), text);
                    return text_result ("Typed\n" + page_state ());
                case "browser_press_key":
                    press (args.get_string_member ("key"));
                    return text_result ("Pressed " + args.get_string_member ("key"));
                case "browser_select_option":
                    var sargs = new Json.Array ();
                    sargs.add_object_element (WebDriverClient.element_ref (element (args)));
                    sargs.add_array_element (args.get_array_member ("values"));
                    var chosen = driver.execute (SELECT, sargs);
                    return text_result ("Selected " + Json.to_string (chosen, false));
                case "browser_screenshot":
                    string png = driver.call ("GET", "/screenshot").get_string ();
                    var r = new Json.Object ();
                    var content = new Json.Array ();
                    var image = new Json.Object ();
                    image.set_string_member ("type", "image");
                    image.set_string_member ("data", png);
                    image.set_string_member ("mimeType", "image/png");
                    content.add_object_element (image);
                    r.set_array_member ("content", content);
                    return r;
                case "browser_evaluate":
                    var result = driver.execute ("return await (" + args.get_string_member ("function") + ")();");
                    return text_result (result != null ? Json.to_string (result, true) : "undefined");
                case "browser_wait_for":
                    return wait_for (args);
                case "browser_tabs":
                    return tabs (args);
                case "browser_resize":
                    var rect = new Json.Object ();
                    rect.set_int_member ("width", args.get_int_member ("width"));
                    rect.set_int_member ("height", args.get_int_member ("height"));
                    driver.call ("POST", "/window/rect", rect);
                    return text_result ("Resized");
                case "browser_close":
                    driver.close ();
                    refs.clear ();
                    return text_result ("Closed");
                default:
                    return text_result ("Unknown tool " + name, true);
            }
        }

        private Json.Object wait_for (Json.Object args) throws Error {
            double seconds = args.has_member ("seconds") ? args.get_double_member ("seconds") : 10;
            string? text = args.has_member ("text") ? args.get_string_member ("text") : null;
            string? selector = args.has_member ("selector") ? args.get_string_member ("selector") : null;
            int64 deadline = get_monotonic_time () + (int64) (seconds * 1000000);
            if (text == null && selector == null) {
                Thread.usleep ((ulong) (seconds * 1000000));
                return text_result ("Waited %g seconds".printf (seconds));
            }
            var cargs = new Json.Array ();
            cargs.add_string_element (text ?? "");
            cargs.add_string_element (selector ?? "");
            const string CHECK = "const [t, s] = arguments; return (!t || (document.body && document.body.innerText.includes(t))) && (!s || !!document.querySelector(s));";
            while (get_monotonic_time () < deadline) {
                var found = driver.execute (CHECK, cargs);
                if (found != null && found.get_boolean ()) return text_result ("Found\n" + page_state ());
                Thread.usleep (250000);
            }
            return text_result ("Not found within %g seconds".printf (seconds), true);
        }

        private Json.Object tabs (Json.Object args) throws Error {
            string action = args.get_string_member ("action");
            var handles = driver.call ("GET", "/window/handles").get_array ();
            int index = args.has_member ("index") ? (int) args.get_int_member ("index") : -1;
            switch (action) {
                case "new":
                    var kind = new Json.Object ();
                    kind.set_string_member ("type", "tab");
                    string handle = driver.call ("POST", "/window/new", kind).get_object ().get_string_member ("handle");
                    var sw = new Json.Object ();
                    sw.set_string_member ("handle", handle);
                    driver.call ("POST", "/window", sw);
                    if (args.has_member ("url")) {
                        var body = new Json.Object ();
                        body.set_string_member ("url", args.get_string_member ("url"));
                        driver.call ("POST", "/url", body);
                    }
                    refs.clear ();
                    return text_result ("Opened tab %u\n".printf (handles.get_length ()) + page_state ());
                case "select":
                case "close":
                    if (index < 0 || index >= handles.get_length ()) throw new WebDriverError.FAILED ("No tab %d".printf (index));
                    var sw = new Json.Object ();
                    sw.set_string_member ("handle", handles.get_string_element (index));
                    driver.call ("POST", "/window", sw);
                    refs.clear ();
                    if (action == "select") return text_result (page_state ());
                    var left = driver.call ("DELETE", "/window").get_array ();
                    if (left.get_length () > 0) {
                        var next = new Json.Object ();
                        next.set_string_member ("handle", left.get_string_element (0));
                        driver.call ("POST", "/window", next);
                    }
                    return text_result ("Closed tab %d".printf (index));
                default:
                    string current = driver.call ("GET", "/window").get_string ();
                    var sb = new StringBuilder ();
                    for (uint i = 0; i < handles.get_length (); i++) {
                        string h = handles.get_string_element (i);
                        sb.append ("%u%s\n".printf (i, h == current ? " (current)" : ""));
                    }
                    return text_result (sb.str);
            }
        }

        public static int main (string[] args) {
            string? endpoint = null;
            bool hidden = false;
            for (int i = 1; i < args.length; i++) {
                if (args[i] == "--webdriver" && i + 1 < args.length) endpoint = args[++i];
                else if (args[i].has_prefix ("--webdriver=")) endpoint = args[i].substring (12);
                else if (args[i] == "--undetectable") hidden = true;
            }
            var driver = new WebDriverClient (endpoint);
            driver.hidden = hidden;
            var server = new BrowserMcp (driver);
            var input = new DataInputStream (new UnixInputStream (0, false));
            var output = new UnixOutputStream (1, false);
            try {
                string? line;
                while ((line = input.read_line (null)) != null) {
                    if (line.strip () == "") continue;
                    var parser = new Json.Parser ();
                    try {
                        parser.load_from_data (line);
                    } catch (Error e) {
                        continue;
                    }
                    var root = parser.get_root ();
                    if (root == null || root.get_node_type () != Json.NodeType.OBJECT) continue;
                    var msg = root.get_object ();
                    if (!msg.has_member ("id") || !msg.has_member ("method")) continue;
                    var reply = new Json.Object ();
                    reply.set_string_member ("jsonrpc", "2.0");
                    reply.set_member ("id", msg.get_member ("id").copy ());
                    var prm = msg.has_member ("params") ? msg.get_object_member ("params") : new Json.Object ();
                    var result = server.handle (msg.get_string_member ("method"), prm);
                    if (result != null) {
                        reply.set_object_member ("result", result);
                    } else {
                        var err = new Json.Object ();
                        err.set_int_member ("code", -32601);
                        err.set_string_member ("message", "method not found");
                        reply.set_object_member ("error", err);
                    }
                    var node = new Json.Node (Json.NodeType.OBJECT);
                    node.set_object (reply);
                    output.write_all ((Json.to_string (node, false) + "\n").data, null);
                }
            } catch (Error e) {
                printerr ("singularity-browser-mcp: %s\n", e.message);
            }
            driver.close ();
            return 0;
        }
    }
}
