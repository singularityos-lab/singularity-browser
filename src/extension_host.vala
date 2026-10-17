namespace Singularity.Apps.Browser {

    public class ExtensionHost : Object {
        public const string SCHEME = "chrome-extension";
        private const string BACKGROUND_PAGE = "/_sinty_/background.html";

        public ExtensionManager manager { get; construct; }
        public Profile profile { get; construct; }
        public BrowserTab? active_tab { get; set; }

        private string data_root;
        private Gee.HashMap<string, WebKit.WebView> backgrounds = new Gee.HashMap<string, WebKit.WebView> ();
        private Gee.HashMap<string, WebKit.WebView> offscreens = new Gee.HashMap<string, WebKit.WebView> ();
        private Gee.HashMap<string, Json.Object> storage = new Gee.HashMap<string, Json.Object> ();
        private Gee.HashMap<string, string> badges = new Gee.HashMap<string, string> ();
        private Gee.HashMap<string, uint> alarms = new Gee.HashMap<string, uint> ();
        private Gee.HashMap<string, Json.Object> alarm_info = new Gee.HashMap<string, Json.Object> ();
        private Gee.HashMap<int, unowned BrowserTab> tabs = new Gee.HashMap<int, unowned BrowserTab> ();
        private Gee.HashMap<unowned BrowserTab, int> tab_ids = new Gee.HashMap<unowned BrowserTab, int> ();
        private int next_tab_id = 1;
        private Gee.HashSet<string> ready = new Gee.HashSet<string> ();
        private Gee.HashMap<string, Gee.ArrayList<Waiter>> waiting = new Gee.HashMap<string, Gee.ArrayList<Waiter>> ();

        private class Waiter {
            public SourceFunc resume;
        }

        public signal void open_url (string url);
        public signal void action_changed (string id);
        public signal void tabs_need_refresh ();

        public ExtensionHost (ExtensionManager manager, Profile profile) {
            Object (manager: manager, profile: profile);
        }

        construct {
            data_root = Path.build_filename (profile.data_dir, "extension-data");
            DirUtils.create_with_parents (data_root, 0700);
            profile.context.register_uri_scheme (SCHEME, handle_scheme);
            var security = profile.context.get_security_manager ();
            security.register_uri_scheme_as_secure (SCHEME);
            security.register_uri_scheme_as_cors_enabled (SCHEME);
            manager.changed.connect (() => {
                sync_backgrounds ();
                tabs_need_refresh ();
            });
            Idle.add (() => {
                sync_backgrounds ();
                return Source.REMOVE;
            });
        }

        public string? badge_for (string id) {
            return badges[id];
        }

        public string page_url (Extension extension, string path) {
            string clean = path.has_prefix ("/") ? path.substring (1) : path;
            return "%s://%s/%s".printf (SCHEME, extension.id, clean);
        }

        public static string[] allow_list (string[] patterns) {
            string[] result = {};
            foreach (string pattern in patterns) {
                if (pattern == "<all_urls>" || pattern == "*://*/*") {
                    result += "http://*/*";
                    result += "https://*/*";
                } else if (pattern.has_prefix ("*://")) {
                    result += "http" + pattern.substring (1);
                    result += "https" + pattern.substring (1);
                } else if (pattern.has_prefix ("http://") || pattern.has_prefix ("https://") || pattern.has_prefix ("file://")) {
                    result += pattern;
                }
            }
            return result;
        }

        public void attach (BrowserTab tab, WebKit.UserContentManager content) {
            if (!tab_ids.has_key (tab)) {
                int tab_id = next_tab_id++;
                tabs[tab_id] = tab;
                tab_ids[tab] = tab_id;
                tab.weak_ref ((obj) => {
                    foreach (var entry in tab_ids.entries) {
                        if ((Object) entry.key == obj) {
                            int gone = entry.value;
                            tab_ids.unset (entry.key);
                            tabs.unset (gone);
                            broadcast ("tabRemoved", "{\"tabId\":%d}".printf (gone));
                            break;
                        }
                    }
                });
            }
            foreach (var extension in manager.extensions) {
                if (!manager.is_enabled (extension.id)) continue;
                string handler = ExtensionScript.handler_for (extension.id);
                string world = ExtensionScript.world_for (extension.id);
                string messages = messages_json (extension);
                content.register_script_message_handler_with_reply (handler, world);
                content.register_script_message_handler_with_reply (handler, null);
                content.script_message_with_reply_received[handler].connect ((value, reply) => {
                    handle_message.begin (extension, tab, null, value, reply);
                    return true;
                });
                string[] own_pages = { "%s://%s/*".printf (SCHEME, extension.id) };
                content.add_script (new WebKit.UserScript (ExtensionScript.source (extension, ExtensionContext.PAGE, messages),
                    WebKit.UserContentInjectedFrames.ALL_FRAMES, WebKit.UserScriptInjectionTime.START, own_pages, null));

                string[] all_matches = {};
                foreach (var script in extension.content_scripts) {
                    foreach (string m in allow_list (script.matches)) all_matches += m;
                }
                if (all_matches.length == 0) continue;
                content.add_script (new WebKit.UserScript.for_world (ExtensionScript.source (extension, ExtensionContext.CONTENT, messages),
                    WebKit.UserContentInjectedFrames.ALL_FRAMES, WebKit.UserScriptInjectionTime.START, world, all_matches, null));
                foreach (var script in extension.content_scripts) {
                    string[] allow = allow_list (script.matches);
                    string[] block = allow_list (script.exclude_matches);
                    var frames = script.all_frames ? WebKit.UserContentInjectedFrames.ALL_FRAMES : WebKit.UserContentInjectedFrames.TOP_FRAME;
                    var css = new StringBuilder ();
                    foreach (string file in script.css) css.append (read_text (extension, file) ?? "").append_c ('\n');
                    if (css.len > 0) {
                        content.add_style_sheet (new WebKit.UserStyleSheet.for_world (css.str, frames, WebKit.UserStyleLevel.USER,
                            world, allow, block.length > 0 ? block : null));
                    }
                    var js = new StringBuilder ();
                    foreach (string file in script.js) {
                        string? text = read_text (extension, file);
                        if (text != null) js.append ("try {\n").append (text).append ("\n} catch (e) { console.error(e); }\n");
                    }
                    if (js.len > 0) {
                        var time = script.run_at == "document_start" ? WebKit.UserScriptInjectionTime.START : WebKit.UserScriptInjectionTime.END;
                        content.add_script (new WebKit.UserScript.for_world (js.str, frames, time, world, allow, block.length > 0 ? block : null));
                    }
                }
            }
        }

        public void tab_updated (BrowserTab tab) {
            if (!tab_ids.has_key (tab)) return;
            int tab_id = tab_ids[tab];
            broadcast ("tabUpdated", "{\"tabId\":%d,\"changes\":%s,\"tab\":%s}".printf (tab_id,
                "{\"status\":\"complete\",\"url\":%s}".printf (Json.to_string (string_node (tab.uri), false)),
                Json.to_string (tab_node (tab_id, tab), false)));
        }

        public void tab_activated (BrowserTab tab) {
            active_tab = tab;
            if (!tab_ids.has_key (tab)) return;
            broadcast ("tabActivated", "{\"tabId\":%d,\"windowId\":1}".printf (tab_ids[tab]));
        }

        public WebKit.WebView create_page_view (Extension extension) {
            var content = new WebKit.UserContentManager ();
            string handler = ExtensionScript.handler_for (extension.id);
            content.register_script_message_handler_with_reply (handler, null);
            content.script_message_with_reply_received[handler].connect ((value, reply) => {
                handle_message.begin (extension, null, null, value, reply);
                return true;
            });
            string[] own_pages = { "%s://%s/*".printf (SCHEME, extension.id) };
            content.add_script (new WebKit.UserScript (ExtensionScript.source (extension, ExtensionContext.PAGE, messages_json (extension)),
                WebKit.UserContentInjectedFrames.ALL_FRAMES, WebKit.UserScriptInjectionTime.START, own_pages, null));
            return (WebKit.WebView) Object.new (typeof (WebKit.WebView),
                "network-session", profile.session,
                "web-context", profile.context,
                "user-content-manager", content,
                "settings", profile.web_settings);
        }

        public void action_clicked (Extension extension) {
            var tab = active_tab;
            string data = tab != null && tab_ids.has_key (tab) ? Json.to_string (tab_node (tab_ids[tab], tab), false) : "null";
            dispatch_background.begin (extension.id, "action", data, null);
        }

        private void sync_backgrounds () {
            foreach (var id in backgrounds.keys.to_array ()) {
                if (!manager.is_enabled (id)) {
                    backgrounds[id].try_close ();
                    backgrounds.unset (id);
                    ready.remove (id);
                    release (id);
                }
            }
            foreach (var extension in manager.extensions) {
                if (!manager.is_enabled (extension.id) || backgrounds.has_key (extension.id)) continue;
                if (extension.background_worker == null && extension.background_scripts.length == 0) continue;
                var view = create_background_view (extension);
                backgrounds[extension.id] = view;
                string marker = Path.build_filename (data_root, extension.id, "installed-version");
                string? previous = null;
                try {
                    FileUtils.get_contents (marker, out previous);
                } catch (FileError e) {
                }
                ulong handler = 0;
                handler = view.load_changed.connect ((event) => {
                    if (event != WebKit.LoadEvent.FINISHED) return;
                    view.disconnect (handler);
                    ready.add (extension.id);
                    release (extension.id);
                    if (previous == null || previous.strip () != extension.version) {
                        string reason = previous == null ? "install" : "update";
                        dispatch_background.begin (extension.id, "installed", "{\"reason\":\"%s\",\"previousVersion\":%s}".printf (reason,
                            previous == null ? "null" : Json.to_string (string_node (previous.strip ()), false)), null);
                        DirUtils.create_with_parents (Path.get_dirname (marker), 0700);
                        try {
                            FileUtils.set_contents (marker, extension.version);
                        } catch (FileError e) {
                        }
                    } else {
                        dispatch_background.begin (extension.id, "startup", "null", null);
                    }
                });
                view.load_uri (page_url (extension, BACKGROUND_PAGE));
            }
        }

        private WebKit.WebView create_background_view (Extension extension) {
            var content = new WebKit.UserContentManager ();
            string handler = ExtensionScript.handler_for (extension.id);
            content.register_script_message_handler_with_reply (handler, null);
            content.script_message_with_reply_received[handler].connect ((value, reply) => {
                handle_message.begin (extension, null, "background", value, reply);
                return true;
            });
            string[] own_pages = { "%s://%s/*".printf (SCHEME, extension.id) };
            content.add_script (new WebKit.UserScript (ExtensionScript.source (extension, ExtensionContext.BACKGROUND, messages_json (extension)),
                WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserScriptInjectionTime.START, own_pages, null));
            return (WebKit.WebView) Object.new (typeof (WebKit.WebView),
                "network-session", profile.session,
                "web-context", profile.context,
                "user-content-manager", content,
                "settings", profile.web_settings);
        }

        private string background_page (Extension extension) {
            var html = new StringBuilder ("<!doctype html><meta charset=\"utf-8\"><script>self.importScripts = (...urls) => { for (const url of urls) { const r = new XMLHttpRequest(); r.open(\"GET\", new URL(url, location.href).href, false); r.send(); (0, eval)(r.responseText); } }; self.registration = { scope: location.origin + \"/\", showNotification: () => Promise.resolve() }; self.clients = { matchAll: () => Promise.resolve([]), claim: () => Promise.resolve() }; self.skipWaiting = () => Promise.resolve();</script>\n");
            if (extension.background_worker != null) {
                bool module = false;
                var background = extension.manifest.get_object_member ("background");
                if (background != null && background.get_string_member_with_default ("type", "") == "module") module = true;
                html.append ("<script%s src=\"/%s\"></script>\n".printf (module ? " type=\"module\"" : "",
                    Markup.escape_text (strip_slash (extension.background_worker))));
            }
            foreach (string script in extension.background_scripts) {
                html.append ("<script src=\"/%s\"></script>\n".printf (Markup.escape_text (strip_slash (script))));
            }
            return html.str;
        }

        private void handle_scheme (WebKit.URISchemeRequest request) {
            string id;
            string path;
            try {
                var uri = Uri.parse (request.get_uri (), UriFlags.NONE);
                id = uri.get_host () ?? "";
                path = Uri.unescape_string (uri.get_path ()) ?? "/";
            } catch (UriError e) {
                request.finish_error (new IOError.INVALID_ARGUMENT ("Invalid extension address"));
                return;
            }
            var extension = manager.get_extension (id);
            if (extension == null || !manager.is_enabled (id)) {
                request.finish_error (new IOError.NOT_FOUND ("The extension is not available"));
                return;
            }
            Bytes bytes;
            string mime;
            if (path == BACKGROUND_PAGE) {
                bytes = new Bytes (background_page (extension).data);
                mime = "text/html";
            } else {
                try {
                    string file = extension.resolve (path == "/" || path == "" ? "index.html" : path);
                    uint8[] data;
                    FileUtils.get_data (file, out data);
                    bytes = new Bytes.take ((owned) data);
                    mime = mime_for (file);
                } catch (Error e) {
                    request.finish_error (new IOError.NOT_FOUND ("%s was not found in the extension".printf (path)));
                    return;
                }
            }
            var response = new WebKit.URISchemeResponse (new MemoryInputStream.from_bytes (bytes), (int64) bytes.get_size ());
            response.set_content_type (mime);
            request.finish_with_response (response);
        }

        public static string mime_for (string file) {
            string lower = file.down ();
            if (lower.has_suffix (".js") || lower.has_suffix (".mjs")) return "text/javascript";
            if (lower.has_suffix (".css")) return "text/css";
            if (lower.has_suffix (".html") || lower.has_suffix (".htm")) return "text/html";
            if (lower.has_suffix (".json")) return "application/json";
            if (lower.has_suffix (".svg")) return "image/svg+xml";
            if (lower.has_suffix (".wasm")) return "application/wasm";
            bool uncertain;
            string? type = ContentType.guess (file, null, out uncertain);
            string? mime = type != null ? ContentType.get_mime_type (type) : null;
            return mime ?? "application/octet-stream";
        }

        private async void handle_message (Extension extension, BrowserTab? tab, string? origin, JSC.Value value, WebKit.ScriptMessageReply reply) {
            string kind = origin ?? (tab != null ? "content" : "page");
            Json.Object request;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (value.to_string ());
                request = parser.get_root ().get_object ();
            } catch (Error e) {
                reply.return_error_message ("Malformed extension request");
                return;
            }
            string op = request.get_string_member_with_default ("op", "");
            var args = request.has_member ("args") ? request.get_member ("args") : new Json.Node (Json.NodeType.NULL);
            var argo = args.get_node_type () == Json.NodeType.OBJECT ? args.get_object () : new Json.Object ();
            try {
                string? result = yield dispatch (extension, tab, kind, op, args, argo);
                reply.return_value (new JSC.Value.string (value.get_context (), result ?? ""));
            } catch (Error e) {
                reply.return_error_message (e.message);
            }
        }

        private async string? dispatch (Extension extension, BrowserTab? tab, string kind, string op, Json.Node args, Json.Object argo) throws Error {
            switch (op) {
                case "storage.get":
                    return storage_get (extension, argo.get_string_member_with_default ("area", "local"), argo.get_member ("keys"));
                case "storage.set":
                    storage_set (extension, argo.get_string_member_with_default ("area", "local"), argo.get_object_member ("items"));
                    return null;
                case "storage.remove":
                    storage_remove (extension, argo.get_string_member_with_default ("area", "local"), argo.get_member ("keys"));
                    return null;
                case "storage.clear":
                    storage_clear (extension, argo.get_string_member_with_default ("area", "local"));
                    return null;
                case "storage.bytes":
                    return Json.to_string (int_node (Json.to_string (object_node (storage_for (extension, argo.get_string_member_with_default ("area", "local"))), false).length), false);
                case "runtime.sendMessage":
                    string message = node_json (argo.get_member ("message"));
                    string sender = sender_json (extension, tab, kind);
                    if (kind == "background") return null;
                    return yield dispatch_background (extension.id, "message", message, sender);
                case "runtime.openOptionsPage":
                    if (extension.options_page != null) open_url (page_url (extension, extension.options_page));
                    return null;
                case "runtime.reload":
                    if (backgrounds.has_key (extension.id)) backgrounds[extension.id].reload ();
                    return null;
                case "tabs.query":
                    return Json.to_string (query_tabs (argo), false);
                case "tabs.current":
                    if (tab != null && tab_ids.has_key (tab)) return Json.to_string (tab_node (tab_ids[tab], tab), false);
                    return null;
                case "tabs.get":
                    int get_id = (int) argo.get_int_member_with_default ("tabId", -1);
                    if (!tabs.has_key (get_id)) throw new IOError.NOT_FOUND ("No tab with id: %d".printf (get_id));
                    return Json.to_string (tab_node (get_id, tabs[get_id]), false);
                case "tabs.create":
                    string url = argo.get_string_member_with_default ("url", Address.NEW_TAB);
                    open_url (url.has_prefix ("/") || !url.contains (":") ? page_url (extension, url) : url);
                    return null;
                case "tabs.update":
                    var target = tab_from (argo.get_member ("tabId"));
                    var props = argo.get_object_member ("props");
                    if (target != null && props != null && props.has_member ("url")) {
                        string next = props.get_string_member ("url");
                        target.load (next.has_prefix ("/") ? page_url (extension, next) : next);
                    }
                    return target != null && tab_ids.has_key (target) ? Json.to_string (tab_node (tab_ids[target], target), false) : null;
                case "tabs.reload":
                    var reload_target = tab_from (argo.get_member ("tabId"));
                    if (reload_target != null) reload_target.reload ();
                    return null;
                case "tabs.remove":
                    foreach (var node in argo.get_array_member ("tabIds").get_elements ()) {
                        int remove_id = (int) node.get_int ();
                        if (tabs.has_key (remove_id)) tabs[remove_id].close_requested ();
                    }
                    return null;
                case "tabs.sendMessage":
                    var receiver = tab_from (argo.get_member ("tabId"));
                    if (receiver == null || receiver.view == null) throw new IOError.NOT_FOUND ("Could not establish connection. Receiving end does not exist.");
                    return yield call_view (receiver.view, ExtensionScript.world_for (extension.id), "message",
                        node_json (argo.get_member ("message")), sender_json (extension, null, kind));
                case "scripting.executeScript":
                    return yield execute_script (extension, argo);
                case "scripting.insertCSS":
                    var css_target = tab_from (argo.get_member ("tabId"));
                    if (css_target != null && css_target.view != null) {
                        var css = new StringBuilder ();
                        if (argo.has_member ("css") && argo.get_member ("css").get_node_type () == Json.NodeType.VALUE) css.append (argo.get_string_member ("css"));
                        if (argo.has_member ("files") && argo.get_member ("files").get_node_type () == Json.NodeType.ARRAY) {
                            foreach (var node in argo.get_array_member ("files").get_elements ()) css.append (read_text (extension, node.get_string ()) ?? "");
                        }
                        string inject = "(() => { const s = document.createElement('style'); s.textContent = %s; (document.head || document.documentElement).appendChild(s); })()".printf (
                            Json.to_string (string_node (css.str), false));
                        yield css_target.view.evaluate_javascript (inject, -1, ExtensionScript.world_for (extension.id), null, null);
                    }
                    return null;
                case "alarms.create":
                    create_alarm (extension, argo.get_string_member_with_default ("name", ""), argo.get_object_member ("info") ?? new Json.Object ());
                    return null;
                case "alarms.get":
                    string alarm_key = extension.id + "\n" + argo.get_string_member_with_default ("name", "");
                    return alarm_info.has_key (alarm_key) ? Json.to_string (object_node (alarm_info[alarm_key]), false) : null;
                case "alarms.getAll":
                    var all = new Json.Array ();
                    foreach (var entry in alarm_info.entries) {
                        if (entry.key.has_prefix (extension.id + "\n")) all.add_object_element (entry.value);
                    }
                    var all_node = new Json.Node (Json.NodeType.ARRAY);
                    all_node.set_array (all);
                    return Json.to_string (all_node, false);
                case "alarms.clear":
                    return clear_alarm (extension.id + "\n" + argo.get_string_member_with_default ("name", "")) ? "true" : "false";
                case "alarms.clearAll":
                    foreach (var key in alarms.keys.to_array ()) {
                        if (key.has_prefix (extension.id + "\n")) clear_alarm (key);
                    }
                    return "true";
                case "action.setBadgeText":
                    badges[extension.id] = argo.get_string_member_with_default ("text", "");
                    action_changed (extension.id);
                    return null;
                case "action.getBadgeText":
                    return Json.to_string (string_node (badges[extension.id] ?? ""), false);
                case "action.getTitle":
                    return Json.to_string (string_node (extension.action_title ?? extension.name), false);
                case "action.getPopup":
                    return Json.to_string (string_node (extension.popup != null ? page_url (extension, extension.popup) : ""), false);
                case "action.setTitle":
                case "action.setPopup":
                case "action.openPopup":
                case "contextMenus.create":
                case "contextMenus.update":
                case "contextMenus.remove":
                case "contextMenus.removeAll":
                case "notifications.clear":
                    return null;
                case "notifications.create":
                    var options = argo.get_object_member ("options") ?? new Json.Object ();
                    var notification = new Notification (options.get_string_member_with_default ("title", extension.name));
                    notification.set_body (options.get_string_member_with_default ("message", ""));
                    string nid = argo.get_string_member_with_default ("id", "");
                    if (nid == "") nid = "%u".printf (Random.next_int ());
                    var app = GLib.Application.get_default ();
                    if (app != null) app.send_notification ("extension-%s-%s".printf (extension.id, nid), notification);
                    return Json.to_string (string_node (nid), false);
                case "permissions.contains":
                    bool granted = true;
                    if (argo.has_member ("permissions")) {
                        foreach (var node in argo.get_array_member ("permissions").get_elements ()) {
                            if (!extension.has_permission (node.get_string ())) granted = false;
                        }
                    }
                    return granted ? "true" : "false";
                case "permissions.getAll":
                    var perms = new Json.Builder ();
                    perms.begin_object ();
                    perms.set_member_name ("permissions");
                    perms.begin_array ();
                    foreach (string p in extension.permissions) perms.add_string_value (p);
                    perms.end_array ();
                    perms.set_member_name ("origins");
                    perms.begin_array ();
                    foreach (string p in extension.host_permissions) perms.add_string_value (p);
                    perms.end_array ();
                    perms.end_object ();
                    return Json.to_string (perms.get_root (), false);
                case "dnr.enabled":
                case "dnr.dynamic":
                    return "[]";
                case "dnr.updateRulesets":
                case "dnr.updateDynamic":
                    return null;
                case "offscreen.create":
                    string offscreen_url = argo.get_string_member_with_default ("url", "");
                    if (offscreens.has_key (extension.id)) throw new IOError.EXISTS ("Only a single offscreen document may be created.");
                    var offscreen = create_page_view (extension);
                    offscreens[extension.id] = offscreen;
                    offscreen.load_uri (page_url (extension, offscreen_url));
                    return null;
                case "offscreen.close":
                    if (offscreens.has_key (extension.id)) {
                        offscreens[extension.id].try_close ();
                        offscreens.unset (extension.id);
                    }
                    return null;
                case "offscreen.has":
                    return offscreens.has_key (extension.id) ? "true" : "false";
                default:
                    throw new IOError.NOT_SUPPORTED ("%s is not supported by this browser yet".printf (op));
            }
        }

        private void release (string id) {
            var list = waiting[id];
            if (list == null) return;
            waiting.unset (id);
            foreach (var waiter in list) Idle.add ((owned) waiter.resume);
        }

        public async string? dispatch_background (string id, string type, string payload, string? sender) {
            if (!backgrounds.has_key (id)) sync_backgrounds ();
            if (!backgrounds.has_key (id)) return null;
            if (!ready.contains (id)) {
                var waiter = new Waiter ();
                waiter.resume = dispatch_background.callback;
                if (!waiting.has_key (id)) waiting[id] = new Gee.ArrayList<Waiter> ();
                waiting[id].add (waiter);
                yield;
                if (!ready.contains (id) || !backgrounds.has_key (id)) return null;
            }
            try {
                return yield call_view (backgrounds[id], null, type, payload, sender ?? "{}");
            } catch (Error e) {
                debug ("Extension %s background did not answer: %s", id, e.message);
                return null;
            }
        }

        private async string? call_view (WebKit.WebView view, string? world, string type, string payload, string sender) throws Error {
            var builder = new VariantBuilder (new VariantType ("a{sv}"));
            builder.add ("{sv}", "type", new Variant.string (type));
            builder.add ("{sv}", "payload", new Variant.string (payload));
            builder.add ("{sv}", "sender", new Variant.string (sender));
            var result = yield view.call_async_javascript_function (
                "if (!globalThis.__sintyExtension) return null; return await globalThis.__sintyExtension.dispatch(type, payload, sender);",
                -1, builder.end (), world, null, null);
            if (result.is_null () || result.is_undefined ()) return null;
            return result.to_string ();
        }

        private void broadcast (string type, string payload) {
            foreach (var id in backgrounds.keys) dispatch_background.begin (id, type, payload, null);
        }

        private async string? execute_script (Extension extension, Json.Object argo) throws Error {
            var target = tab_from (argo.get_member ("tabId"));
            if (target == null || target.view == null) throw new IOError.NOT_FOUND ("No tab to run the script in");
            string world = ExtensionScript.world_for (extension.id);
            var results = new Json.Array ();
            if (argo.has_member ("func") && argo.get_member ("func").get_node_type () == Json.NodeType.VALUE) {
                string call_args = node_json (argo.get_member ("args"));
                string body = "return JSON.stringify(await (%s)(...%s) ?? null);".printf (argo.get_string_member ("func"), call_args == "null" ? "[]" : call_args);
                var value = yield target.view.call_async_javascript_function (body, -1, null, world, null, null);
                var entry = new Json.Object ();
                entry.set_int_member ("frameId", 0);
                var parser = new Json.Parser ();
                parser.load_from_data (value.is_string () ? value.to_string () : "null");
                entry.set_member ("result", parser.get_root ());
                results.add_object_element (entry);
            } else if (argo.has_member ("files") && argo.get_member ("files").get_node_type () == Json.NodeType.ARRAY) {
                foreach (var node in argo.get_array_member ("files").get_elements ()) {
                    string? text = read_text (extension, node.get_string ());
                    if (text == null) throw new IOError.NOT_FOUND ("Could not load file: %s".printf (node.get_string ()));
                    yield target.view.evaluate_javascript (text, -1, world, page_url (extension, node.get_string ()), null);
                }
                var entry = new Json.Object ();
                entry.set_int_member ("frameId", 0);
                entry.set_null_member ("result");
                results.add_object_element (entry);
            }
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (results);
            return Json.to_string (root, false);
        }

        private void create_alarm (Extension extension, string name, Json.Object info) {
            string key = extension.id + "\n" + name;
            clear_alarm (key);
            double delay = info.has_member ("delayInMinutes") ? info.get_double_member ("delayInMinutes") : 0;
            double period = info.has_member ("periodInMinutes") ? info.get_double_member ("periodInMinutes") : 0;
            if (delay <= 0 && info.has_member ("when")) delay = (info.get_double_member ("when") - get_real_time () / 1000.0) / 60000.0;
            if (delay <= 0) delay = period > 0 ? period : 0.5;
            uint first = (uint) Math.fmax (500, delay * 60000);
            var alarm = new Json.Object ();
            alarm.set_string_member ("name", name);
            alarm.set_double_member ("scheduledTime", get_real_time () / 1000.0 + first);
            if (period > 0) alarm.set_double_member ("periodInMinutes", period);
            alarm_info[key] = alarm;
            alarms[key] = Timeout.add (first, () => {
                dispatch_background.begin (extension.id, "alarm", Json.to_string (object_node (alarm), false), null);
                if (period <= 0) {
                    alarms.unset (key);
                    alarm_info.unset (key);
                    return Source.REMOVE;
                }
                uint every = (uint) Math.fmax (30000, period * 60000);
                alarm.set_double_member ("scheduledTime", get_real_time () / 1000.0 + every);
                alarms[key] = Timeout.add (every, () => {
                    alarm.set_double_member ("scheduledTime", get_real_time () / 1000.0 + every);
                    dispatch_background.begin (extension.id, "alarm", Json.to_string (object_node (alarm), false), null);
                    return Source.CONTINUE;
                });
                return Source.REMOVE;
            });
        }

        private bool clear_alarm (string key) {
            if (!alarms.has_key (key)) return false;
            Source.remove (alarms[key]);
            alarms.unset (key);
            alarm_info.unset (key);
            return true;
        }

        private Json.Object storage_for (Extension extension, string area) {
            string key = extension.id + "/" + area;
            if (storage.has_key (key)) return storage[key];
            var data = new Json.Object ();
            if (area != "session") {
                try {
                    var parser = new Json.Parser ();
                    parser.load_from_file (storage_path (extension, area));
                    var root = parser.get_root ();
                    if (root != null && root.get_node_type () == Json.NodeType.OBJECT) data = root.get_object ();
                } catch (Error e) {
                }
            }
            storage[key] = data;
            return data;
        }

        private string storage_path (Extension extension, string area) {
            return Path.build_filename (data_root, extension.id, "storage-%s.json".printf (area == "sync" ? "sync" : "local"));
        }

        private void persist (Extension extension, string area, Json.Object data, Json.Object changes) {
            if (area != "session") {
                string path = storage_path (extension, area);
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                try {
                    FileUtils.set_contents (path, Json.to_string (object_node (data), false));
                } catch (FileError e) {
                    warning ("Extension storage could not be saved: %s", e.message);
                }
            }
            if (changes.get_size () == 0) return;
            var payload = new Json.Object ();
            payload.set_object_member ("changes", changes);
            payload.set_string_member ("area", area);
            string text = Json.to_string (object_node (payload), false);
            dispatch_background.begin (extension.id, "storage", text, null);
            foreach (var tab in tab_ids.keys) {
                if (tab.view != null) call_view.begin (tab.view, ExtensionScript.world_for (extension.id), "storage", text, "{}");
            }
        }

        private string storage_get (Extension extension, string area, Json.Node? keys) {
            var data = storage_for (extension, area);
            var result = new Json.Object ();
            if (keys == null || keys.get_node_type () == Json.NodeType.NULL) {
                foreach (string member in data.get_members ()) result.set_member (member, data.get_member (member).copy ());
            } else if (keys.get_node_type () == Json.NodeType.VALUE) {
                string key = keys.get_string ();
                if (data.has_member (key)) result.set_member (key, data.get_member (key).copy ());
            } else if (keys.get_node_type () == Json.NodeType.ARRAY) {
                foreach (var node in keys.get_array ().get_elements ()) {
                    string key = node.get_string ();
                    if (data.has_member (key)) result.set_member (key, data.get_member (key).copy ());
                }
            } else {
                var defaults = keys.get_object ();
                foreach (string member in defaults.get_members ()) {
                    result.set_member (member, (data.has_member (member) ? data.get_member (member) : defaults.get_member (member)).copy ());
                }
            }
            return Json.to_string (object_node (result), false);
        }

        private void storage_set (Extension extension, string area, Json.Object? items) {
            if (items == null) return;
            var data = storage_for (extension, area);
            var changes = new Json.Object ();
            foreach (string member in items.get_members ()) {
                var change = new Json.Object ();
                if (data.has_member (member)) change.set_member ("oldValue", data.get_member (member).copy ());
                change.set_member ("newValue", items.get_member (member).copy ());
                changes.set_object_member (member, change);
                data.set_member (member, items.get_member (member).copy ());
            }
            persist (extension, area, data, changes);
        }

        private void storage_remove (Extension extension, string area, Json.Node? keys) {
            var data = storage_for (extension, area);
            var changes = new Json.Object ();
            string[] names = {};
            if (keys != null && keys.get_node_type () == Json.NodeType.VALUE) names += keys.get_string ();
            else if (keys != null && keys.get_node_type () == Json.NodeType.ARRAY) {
                foreach (var node in keys.get_array ().get_elements ()) names += node.get_string ();
            }
            foreach (string name in names) {
                if (!data.has_member (name)) continue;
                var change = new Json.Object ();
                change.set_member ("oldValue", data.get_member (name).copy ());
                changes.set_object_member (name, change);
                data.remove_member (name);
            }
            persist (extension, area, data, changes);
        }

        private void storage_clear (Extension extension, string area) {
            var data = storage_for (extension, area);
            var changes = new Json.Object ();
            foreach (string member in data.get_members ()) {
                var change = new Json.Object ();
                change.set_member ("oldValue", data.get_member (member).copy ());
                changes.set_object_member (member, change);
            }
            foreach (string member in data.get_members ()) data.remove_member (member);
            persist (extension, area, data, changes);
        }

        private Json.Node query_tabs (Json.Object query) {
            var array = new Json.Array ();
            bool want_active = query.has_member ("active") && query.get_boolean_member ("active");
            bool only_current = (query.has_member ("currentWindow") && query.get_boolean_member ("currentWindow"))
                || (query.has_member ("lastFocusedWindow") && query.get_boolean_member ("lastFocusedWindow"));
            foreach (var entry in tabs.entries) {
                var tab = entry.value;
                if (want_active && tab != active_tab) continue;
                if (query.has_member ("url")) {
                    var url_node = query.get_member ("url");
                    string[] patterns = {};
                    if (url_node.get_node_type () == Json.NodeType.VALUE) patterns += url_node.get_string ();
                    else if (url_node.get_node_type () == Json.NodeType.ARRAY) {
                        foreach (var node in url_node.get_array ().get_elements ()) patterns += node.get_string ();
                    }
                    bool matched = false;
                    foreach (string pattern in patterns) {
                        if (url_matches (pattern, tab.uri)) matched = true;
                    }
                    if (!matched) continue;
                }
                array.add_object_element (tab_node (entry.key, tab).get_object ());
            }
            if (only_current && array.get_length () == 0 && active_tab != null && want_active && tab_ids.has_key (active_tab)) {
                array.add_object_element (tab_node (tab_ids[active_tab], active_tab).get_object ());
            }
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.set_array (array);
            return node;
        }

        public static bool url_matches (string pattern, string url) {
            if (pattern == "<all_urls>") return url.has_prefix ("http://") || url.has_prefix ("https://") || url.has_prefix ("file://");
            var regex = new StringBuilder ("^");
            for (int i = 0; i < pattern.length; i++) {
                char c = pattern[i];
                if (c == '*') regex.append (".*");
                else regex.append (Regex.escape_string (c.to_string ()));
            }
            regex.append ("$");
            try {
                return new Regex (regex.str).match (url);
            } catch (RegexError e) {
                return false;
            }
        }

        private BrowserTab? tab_from (Json.Node? node) {
            if (node == null || node.get_node_type () != Json.NodeType.VALUE) return active_tab;
            int id = (int) node.get_int ();
            return tabs.has_key (id) ? tabs[id] : null;
        }

        private Json.Node tab_node (int id, BrowserTab tab) {
            var object = new Json.Object ();
            object.set_int_member ("id", id);
            object.set_int_member ("index", id);
            object.set_int_member ("windowId", 1);
            object.set_boolean_member ("active", tab == active_tab);
            object.set_boolean_member ("highlighted", tab == active_tab);
            object.set_boolean_member ("incognito", false);
            object.set_boolean_member ("pinned", false);
            object.set_boolean_member ("discarded", false);
            object.set_string_member ("status", "complete");
            object.set_string_member ("url", tab.uri);
            object.set_string_member ("title", tab.display_title);
            return object_node (object);
        }

        private string sender_json (Extension extension, BrowserTab? tab, string kind) {
            var sender = new Json.Object ();
            sender.set_string_member ("id", extension.id);
            if (tab != null && tab_ids.has_key (tab)) {
                sender.set_object_member ("tab", tab_node (tab_ids[tab], tab).get_object ());
                sender.set_string_member ("url", tab.uri);
                sender.set_string_member ("origin", Address.origin_of (tab.uri));
                sender.set_int_member ("frameId", 0);
            } else {
                sender.set_string_member ("url", page_url (extension, kind == "background" ? BACKGROUND_PAGE : "/"));
                sender.set_string_member ("origin", "%s://%s".printf (SCHEME, extension.id));
            }
            return Json.to_string (object_node (sender), false);
        }

        private string messages_json (Extension extension) {
            var table = new Json.Object ();
            foreach (string locale in new string[] { extension.manifest.get_string_member_with_default ("default_locale", ""), Intl.get_language_names ()[0].split (".")[0] }) {
                if (locale == "" || ZipArchive.safe_path (locale) == null || locale.contains ("/")) continue;
                try {
                    var parser = new Json.Parser ();
                    parser.load_from_file (Path.build_filename (extension.path, "_locales", locale, "messages.json"));
                    var root = parser.get_root ().get_object ();
                    foreach (string member in root.get_members ()) {
                        var entry = root.get_object_member (member);
                        if (entry != null && entry.has_member ("message")) table.set_string_member (member.down (), entry.get_string_member ("message"));
                    }
                } catch (Error e) {
                }
            }
            return Json.to_string (object_node (table), false);
        }

        private string? read_text (Extension extension, string relative) {
            try {
                string text;
                FileUtils.get_contents (extension.resolve (relative), out text);
                return text;
            } catch (Error e) {
                return null;
            }
        }

        private static string strip_slash (string path) {
            return path.has_prefix ("/") ? path.substring (1) : path;
        }

        private static string node_json (Json.Node? node) {
            return node == null ? "null" : Json.to_string (node, false);
        }

        private static Json.Node object_node (Json.Object object) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (object);
            return node;
        }

        private static Json.Node string_node (string value) {
            var node = new Json.Node (Json.NodeType.VALUE);
            node.set_string (value);
            return node;
        }

        private static Json.Node int_node (int64 value) {
            var node = new Json.Node (Json.NodeType.VALUE);
            node.set_int (value);
            return node;
        }
    }
}
