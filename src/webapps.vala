using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public class WebAppInfo : Object {
        public string id;
        public string name;
        public string url;
        public string scope;

        public WebAppInfo (string id, string name, string url) {
            this.id = id;
            this.name = name;
            this.url = url;
            this.scope = Address.site_key (url);
        }

        public bool in_scope (string uri) {
            string site = Address.site_key (uri);
            return site == scope || site.has_suffix ("." + scope) || scope.has_suffix ("." + site);
        }

        public static string root_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser", "webapps");
        }

        public string dir () {
            return Path.build_filename (root_dir (), id);
        }

        public string desktop_path () {
            return Path.build_filename (Environment.get_user_data_dir (), "applications", id + ".desktop");
        }

        public static bool valid_id (string id) {
            if (!id.has_prefix (WebApps.PREFIX) || id.length > 200) return false;
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if (!(c.isalnum () || c == '_' || c == '.')) return false;
            }
            return true;
        }

        public static WebAppInfo? load (string id) {
            if (!valid_id (id)) return null;
            var file = new KeyFile ();
            try {
                file.load_from_file (Path.build_filename (root_dir (), id, "app.ini"), KeyFileFlags.NONE);
                var info = new WebAppInfo (id, file.get_string ("Web App", "Name"), file.get_string ("Web App", "Url"));
                if (file.has_key ("Web App", "Scope")) info.scope = file.get_string ("Web App", "Scope");
                return info;
            } catch (Error e) {
                return null;
            }
        }

        public void save (string icon) throws Error {
            DirUtils.create_with_parents (dir (), 0700);
            var file = new KeyFile ();
            file.set_string ("Web App", "Name", name);
            file.set_string ("Web App", "Url", url);
            file.set_string ("Web App", "Scope", scope);
            file.save_to_file (Path.build_filename (dir (), "app.ini"));
            string exe = Environment.find_program_in_path ("singularity-browser") ?? FileUtils.read_link ("/proc/self/exe");
            var desktop = new KeyFile ();
            desktop.set_list_separator (';');
            desktop.set_string ("Desktop Entry", "Type", "Application");
            desktop.set_string ("Desktop Entry", "Name", name);
            desktop.set_string ("Desktop Entry", "Comment", _("Web app for %s").printf (scope));
            desktop.set_string ("Desktop Entry", "Exec", "%s --webapp %s".printf (exec_quote (exe), id));
            desktop.set_string ("Desktop Entry", "Icon", icon);
            desktop.set_string ("Desktop Entry", "StartupWMClass", id);
            desktop.set_string ("Desktop Entry", "Categories", "Network;");
            desktop.set_boolean ("Desktop Entry", "Terminal", false);
            desktop.set_boolean ("Desktop Entry", "StartupNotify", true);
            desktop.set_string ("Desktop Entry", "X-Singularity-WebApp", id);
            DirUtils.create_with_parents (Path.get_dirname (desktop_path ()), 0755);
            desktop.save_to_file (desktop_path ());
        }

        private static string exec_quote (string arg) {
            bool plain = true;
            for (int i = 0; i < arg.length; i++) {
                char c = arg[i];
                if (!(c.isalnum () || c == '/' || c == '.' || c == '-' || c == '_')) plain = false;
            }
            if (plain) return arg;
            return "\"" + arg.replace ("\\", "\\\\").replace ("\"", "\\\"").replace ("`", "\\`").replace ("$", "\\$") + "\"";
        }

        public void uninstall () {
            FileUtils.unlink (desktop_path ());
            FileUtils.unlink (Path.build_filename (dir (), "app.ini"));
            FileUtils.unlink (Path.build_filename (dir (), "icon.png"));
            DirUtils.remove (dir ());
        }
    }

    public class WebApps : Object {
        public const string PREFIX = "dev.sinty.browser.WebApp_";

        public static string make_id (string url) {
            string site = Address.site_key (url);
            var clean = new StringBuilder ();
            for (int i = 0; i < site.length && clean.len < 40; i++) {
                char c = site[i];
                clean.append_c (c.isalnum () ? c.tolower () : '_');
            }
            string hash = Checksum.compute_for_string (ChecksumType.SHA256, url).substring (0, 6);
            return PREFIX + (clean.len > 0 ? clean.str : "app") + "_" + hash;
        }

        public static string? best_icon_url (string html, string base_uri) {
            var doc = Html.Doc.read_memory (html.to_utf8 (), html.length, base_uri, "UTF-8",
                Html.ParserOption.NOERROR | Html.ParserOption.NOWARNING | Html.ParserOption.NONET | Html.ParserOption.RECOVER);
            if (doc == null) return null;
            string? best = null;
            int best_size = 0;
            scan_links (doc->get_root_element (), ref best, ref best_size);
            delete doc;
            if (best == null) return null;
            try {
                return Uri.resolve_relative (base_uri, best, UriFlags.NONE);
            } catch (Error e) {
                return null;
            }
        }

        private static void scan_links (Xml.Node* node, ref string? best, ref int best_size) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (n->name.down () == "link") {
                    string rel = (n->get_prop ("rel") ?? "").down ();
                    string? href = n->get_prop ("href");
                    if (href != null && (rel.contains ("apple-touch-icon") || rel.contains ("icon"))) {
                        int size = rel.contains ("apple-touch-icon") ? 180 : 16;
                        string sizes = n->get_prop ("sizes") ?? "";
                        if (sizes.contains ("x")) size = int.max (size, int.parse (sizes.split ("x")[0]));
                        if (href.down ().has_suffix (".svg")) size = int.max (size, 256);
                        if (size > best_size) {
                            best_size = size;
                            best = href;
                        }
                    }
                }
                if (n->name.down () != "body") scan_links (n->children, ref best, ref best_size);
            }
        }

        public static void install_dialog (BrowserWindow parent, BrowserTab tab) {
            if (!Store.recordable (tab.uri)) return;
            var dialog = new AppDialog (parent.application, true, false);
            dialog.transient_for = parent;
            dialog.set_title (_("Install as Web App"));
            dialog.set_default_size (420, 0);
            var box = new Box (Orientation.VERTICAL, 16);
            box.margin_top = 12;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;
            var icon = new Image ();
            icon.pixel_size = 64;
            icon.halign = Align.CENTER;
            icon.add_css_class ("browser-webapp-icon");
            if (tab.favicon != null) icon.set_from_paintable (tab.favicon);
            else icon.icon_name = "dev.sinty.browser";
            box.append (icon);
            var note = new Label (_("The app opens %s in its own window, with its own dock icon and its own sign-ins.").printf (Address.site_key (tab.uri)));
            note.wrap = true;
            note.max_width_chars = 40;
            note.justify = Justification.CENTER;
            note.add_css_class ("dim-label");
            box.append (note);
            var group = new PreferencesGroup (_("App"));
            var name = new EntryRow (_("Name"));
            string suggested = tab.display_title;
            if (suggested.length > 40) suggested = suggested.substring (0, suggested.index_of_nth_char (40));
            name.text = suggested;
            group.add_row (name);
            box.append (group);
            var buttons = new Box (Orientation.HORIZONTAL, 12);
            buttons.halign = Align.END;
            var cancel = dialog.add_cancel_button ();
            buttons.append (cancel);
            var install = new Button.with_label (_("Install"));
            install.add_css_class ("suggested-action");
            buttons.append (install);
            box.append (buttons);
            dialog.content_box.append (box);

            Gdk.Texture? hires = null;
            fetch_icon.begin (tab, (obj, res) => {
                hires = fetch_icon.end (res);
                if (hires != null) icon.set_from_paintable (hires);
            });

            install.clicked.connect (() => {
                string title = name.text.strip ();
                if (title == "") title = Address.site_key (tab.uri);
                var info = new WebAppInfo (make_id (tab.uri), title, tab.uri);
                try {
                    DirUtils.create_with_parents (info.dir (), 0700);
                    string icon_name = "dev.sinty.browser";
                    var texture = hires ?? tab.favicon;
                    if (texture != null) {
                        string png = Path.build_filename (info.dir (), "icon.png");
                        if (texture.save_to_png (png)) icon_name = png;
                    }
                    info.save (icon_name);
                    var toast = new Toast (_("%s installed").printf (title));
                    toast.button_label = _("Open");
                    toast.button_clicked.connect (() => BrowserApp.launch_webapp (info));
                    parent.add_toast (toast);
                } catch (Error e) {
                    parent.add_toast (new Toast (_("The web app could not be installed: %s").printf (e.message)));
                }
                dialog.close_dialog ();
            });
            dialog.open_dialog ();
        }

        private static async Gdk.Texture? fetch_icon (BrowserTab tab) {
            var view = tab.view;
            if (view == null) return null;
            var resource = view.get_main_resource ();
            if (resource == null) return null;
            try {
                uint8[] data = yield resource.get_data (null);
                var copy = new uint8[data.length + 1];
                Memory.copy (copy, data, data.length);
                string html = ((string) copy).make_valid ();
                string? icon_url = best_icon_url (html, tab.uri);
                if (icon_url == null) return null;
                var session = new Soup.Session ();
                session.timeout = 10;
                var message = new Soup.Message ("GET", icon_url);
                var bytes = yield session.send_and_read_async (message, Priority.DEFAULT, null);
                if (message.status_code != 200) return null;
                var texture = Gdk.Texture.from_bytes (bytes);
                return texture.get_width () >= 48 ? texture : null;
            } catch (Error e) {
                return null;
            }
        }
    }
}
