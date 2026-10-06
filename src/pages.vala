using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public abstract class NativePage : Box {
        public signal void navigate (string uri, bool new_tab);

        protected Services services;

        protected NativePage (Services services) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            this.services = services;
            hexpand = true;
            vexpand = true;
            add_css_class ("browser-native-page");
        }

        public virtual string title { owned get { return ""; } }
        public virtual void refresh () {}
        public virtual void focus_primary () {}

        protected static Widget site_icon (Services services, string url, string title, int size = 16) {
            var image = new Image.from_icon_name ("web-browser-symbolic");
            image.pixel_size = size;
            image.margin_end = size <= 16 ? 12 : 0;
            image.add_css_class ("browser-site-icon");
            var db = services.main_profile.favicons ();
            if (db != null) {
                db.get_favicon.begin (url, null, (obj, res) => {
                    try {
                        var texture = db.get_favicon.end (res);
                        if (texture != null) image.set_from_paintable (texture);
                    } catch (Error e) {
                    }
                });
            }
            return image;
        }

        protected Box column (int maximum = 760) {
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            var box = new Box (Orientation.VERTICAL, 18);
            box.margin_top = 28;
            box.margin_bottom = 36;
            box.margin_start = 24;
            box.margin_end = 24;
            scroll.child = new Clamp (box, maximum);
            append (scroll);
            return box;
        }

        protected static void clear (Box box) {
            Widget? child;
            while ((child = box.get_first_child ()) != null) box.remove (child);
        }
    }

    public class NewTabPage : NativePage {
        private const int TOP_SITE_WIDTH = 112;

        private Entry search;
        private FlowBox sites;
        private Box sites_group;
        private Box banner_slot;
        private bool is_private;

        public override string title { owned get { return is_private ? _("Private Browsing") : _("New Tab"); } }

        public NewTabPage (Services services, bool is_private) {
            base (services);
            this.is_private = is_private;
            add_css_class ("browser-start-page");
            if (is_private) add_css_class ("private");

            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            var outer = new Box (Orientation.VERTICAL, 0);
            outer.valign = Align.CENTER;
            outer.vexpand = true;
            outer.margin_top = 32;
            outer.margin_bottom = 48;
            outer.margin_start = 16;
            outer.margin_end = 16;
            scroll.child = outer;
            append (scroll);

            var body = new Box (Orientation.VERTICAL, 26);
            body.halign = Align.FILL;
            body.hexpand = true;
            var layout = new NarrowColumnLayout (26);
            body.layout_manager = layout;
            outer.append (new Clamp (body, 600));

            var header = new Box (Orientation.VERTICAL, 8);
            header.halign = Align.CENTER;
            var icon = new Image.from_icon_name (is_private ? "dev.sinty.browser-private" : "dev.sinty.browser");
            icon.pixel_size = 72;
            icon.add_css_class ("welcome-page-icon");
            header.append (icon);
            var heading = new Label (is_private ? _("Private Browsing") : _("Where to Next?"));
            heading.add_css_class ("title-1");
            heading.wrap = true;
            heading.justify = Justification.CENTER;
            header.append (heading);
            if (is_private) {
                var note = new Label (_("Pages you open in this window leave no history, cookies or site data once you close it."));
                note.add_css_class ("dim-label");
                note.wrap = true;
                note.justify = Justification.CENTER;
                note.max_width_chars = 48;
                header.append (note);
            }
            body.append (header);

            search = new Entry ();
            search.placeholder_text = _("Search or enter address");
            search.primary_icon_name = "system-search-symbolic";
            search.add_css_class ("browser-start-search");
            search.hexpand = true;
            search.width_chars = 1;
            search.activate.connect (() => {
                string? uri = Address.normalize (search.text, services.engine ());
                if (uri != null) navigate (uri, false);
            });
            body.append (search);

            banner_slot = new Box (Orientation.VERTICAL, 0);
            body.append (banner_slot);

            sites_group = new Box (Orientation.VERTICAL, 10);
            var sites_title = new Label (_("Top Sites"));
            sites_title.add_css_class ("heading");
            sites_title.halign = Align.START;
            sites_title.margin_start = 4;
            sites_group.append (sites_title);
            sites = new FlowBox ();
            sites.selection_mode = SelectionMode.NONE;
            sites.homogeneous = true;
            sites.min_children_per_line = 1;
            sites.max_children_per_line = 4;
            sites.column_spacing = 10;
            sites.row_spacing = 10;
            sites_group.append (sites);
            body.append (sites_group);
            layout.set_secondary (header, 0);
            layout.set_secondary (banner_slot, 0);
            layout.set_secondary (sites_group, 2 * TOP_SITE_WIDTH + 10);

            refresh ();
        }

        public override void focus_primary () {
            search.grab_focus ();
        }

        public override void refresh () {
            clear (banner_slot);
            if (!is_private && !BrowserApp.is_default_browser () && !services.settings.get_boolean ("default-browser-dismissed")) {
                var banner = new Banner (_("Make Browser your default web browser to open links from other apps here."));
                banner.icon_name = "web-browser-symbolic";
                banner.button_label = _("Set as Default");
                banner.secondary_label = _("Not Now");
                banner.button_clicked.connect (() => {
                    BrowserApp.make_default_browser ();
                    refresh ();
                });
                banner.secondary_clicked.connect (() => {
                    services.settings.set_boolean ("default-browser-dismissed", true);
                    refresh ();
                });
                banner_slot.append (banner);
            }

            Widget? child;
            while ((child = sites.get_first_child ()) != null) sites.remove (child);
            var top = services.settings.get_boolean ("show-top-sites") && !is_private ? services.store.top_sites (8) : new HistoryEntry[0];
            sites_group.visible = top.length > 0;
            foreach (var entry in top) sites.append (site_tile (entry));
        }

        private Widget site_tile (HistoryEntry entry) {
            var button = new Button ();
            button.add_css_class ("browser-top-site");
            button.set_size_request (TOP_SITE_WIDTH, -1);
            button.tooltip_text = entry.url;
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 12;
            box.margin_bottom = 10;
            var badge = new Box (Orientation.VERTICAL, 0);
            badge.add_css_class ("browser-top-site-badge");
            badge.halign = Align.CENTER;
            var icon = site_icon (services, entry.url, entry.title, 28);
            icon.halign = Align.CENTER;
            icon.valign = Align.CENTER;
            icon.vexpand = true;
            badge.append (icon);
            box.append (badge);
            var label = new Label (entry.title != "" ? entry.title : Address.display (entry.url));
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 14;
            label.add_css_class ("caption");
            box.append (label);
            button.child = box;
            button.clicked.connect (() => navigate (entry.url, false));
            var middle = new GestureClick ();
            middle.button = 2;
            middle.released.connect (() => navigate (entry.url, true));
            button.add_controller (middle);
            return button;
        }
    }

    public class NarrowColumnLayout : LayoutManager {
        public int spacing { get; construct; }

        private HashTable<Widget, int> secondary = new HashTable<Widget, int> (direct_hash, direct_equal);

        public NarrowColumnLayout (int spacing) {
            Object (spacing: spacing);
        }

        public void set_secondary (Widget child, int threshold) {
            secondary[child] = threshold;
            layout_changed ();
        }

        public bool fits (Widget child, int width) {
            if (width < 0 || !secondary.contains (child)) return true;
            int min, nat;
            child.measure (Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            return width >= int.max (min, secondary[child]);
        }

        protected override SizeRequestMode get_request_mode (Widget widget) {
            return SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        protected override void measure (Widget widget, Orientation orientation, int for_size,
                                          out int minimum, out int natural,
                                          out int minimum_baseline, out int natural_baseline) {
            minimum = natural = 0;
            minimum_baseline = natural_baseline = -1;
            int count = 0;
            for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
                if (!child.should_layout ()) continue;
                int min, nat;
                if (orientation == Orientation.HORIZONTAL) {
                    child.measure (Orientation.HORIZONTAL, -1, out min, out nat, null, null);
                    if (!secondary.contains (child)) minimum = int.max (minimum, min);
                    natural = int.max (natural, nat);
                    continue;
                }
                if (!fits (child, for_size)) continue;
                child.measure (Orientation.VERTICAL, for_size, out min, out nat, null, null);
                minimum += min;
                natural += nat;
                count++;
            }
            if (orientation == Orientation.VERTICAL && count > 1) {
                minimum += spacing * (count - 1);
                natural += spacing * (count - 1);
            }
        }

        protected override void allocate (Widget widget, int width, int height, int baseline) {
            int total_natural = 0;
            int count = 0;
            for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
                if (!child.should_layout () || !fits (child, width)) continue;
                int min, nat;
                child.measure (Orientation.VERTICAL, width, out min, out nat, null, null);
                total_natural += nat;
                count++;
            }
            bool use_natural = total_natural + spacing * int.max (0, count - 1) <= height;
            int y = 0;
            for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
                if (!child.should_layout ()) continue;
                bool shown = fits (child, width);
                child.set_child_visible (shown);
                if (!shown) continue;
                int min, nat;
                child.measure (Orientation.VERTICAL, width, out min, out nat, null, null);
                int h = use_natural ? nat : min;
                child.allocate_size ({ 0, y, width, h }, -1);
                y += h + spacing;
            }
        }
    }

    public class HistoryPage : NativePage {
        private Box list;
        private Singularity.Widgets.SearchEntry search;
        private uint search_source = 0;
        private ulong changed_handler = 0;

        public override string title { owned get { return _("History"); } }

        public HistoryPage (Services services) {
            base (services);
            var box = column ();
            var top = new Box (Orientation.HORIZONTAL, 10);
            var heading = new Label (_("History"));
            heading.add_css_class ("title-1");
            heading.halign = Align.START;
            heading.hexpand = true;
            heading.ellipsize = Pango.EllipsizeMode.END;
            heading.xalign = 0;
            top.append (heading);
            var clear_btn = new Button.with_label (_("Clear History…"));
            clear_btn.add_css_class ("destructive-action");
            clear_btn.valign = Align.CENTER;
            clear_btn.clicked.connect (confirm_clear);
            top.append (clear_btn);
            box.append (top);
            search = new Singularity.Widgets.SearchEntry ();
            search.placeholder_text = _("Search History");
            search.search_changed.connect (() => {
                if (search_source != 0) Source.remove (search_source);
                search_source = Timeout.add (180, () => {
                    search_source = 0;
                    refresh ();
                    return Source.REMOVE;
                });
            });
            box.append (search);
            list = new Box (Orientation.VERTICAL, 6);
            box.append (list);
            changed_handler = services.store.history_changed.connect (refresh);
            refresh ();
        }

        public override void dispose () {
            if (changed_handler != 0) {
                services.store.disconnect (changed_handler);
                changed_handler = 0;
            }
            if (search_source != 0) {
                Source.remove (search_source);
                search_source = 0;
            }
            base.dispose ();
        }

        public override void focus_primary () {
            search.grab_focus ();
        }

        private void confirm_clear () {
            var win = get_root () as Gtk.Window;
            var dialog = new ConfirmDialog (win.application, _("Clear History?"), "dev.sinty.browser",
                _("Every page you visited is removed from History, suggestions and Top Sites. Bookmarks stay."),
                _("Clear History"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = win;
            dialog.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) services.store.clear_history ();
            });
            dialog.open_dialog ();
        }

        public override void refresh () {
            clear (list);
            string q = search.text.strip ();
            var entries = q == "" ? services.store.recent_history (300) : services.store.search_history (q, 300);
            if (entries.length == 0) {
                var status = new StatusPage ();
                status.icon_name = "document-open-recent-symbolic";
                status.title = q == "" ? _("No History") : _("No Results");
                status.description = q == "" ? _("Pages you visit appear here.") : _("No visited page matches your search.");
                list.append (status);
                return;
            }
            PreferencesGroup? group = null;
            string current_day = "";
            var now = new DateTime.now_local ();
            foreach (var entry in entries) {
                var when = new DateTime.from_unix_local (entry.last_visit);
                string day = when.format ("%Y-%m-%d");
                if (day != current_day || group == null) {
                    current_day = day;
                    string label;
                    if (day == now.format ("%Y-%m-%d")) label = _("Today");
                    else if (day == now.add_days (-1).format ("%Y-%m-%d")) label = _("Yesterday");
                    else label = when.format ("%A %e %B %Y").strip ();
                    group = new PreferencesGroup (label);
                    list.append (group);
                }
                var row = new ActionRow (entry.title != "" ? entry.title : Address.display (entry.url), Address.full_display (entry.url));
                row.add_prefix (site_icon (services, entry.url, entry.title));
                var time = new Label (when.format ("%H:%M"));
                time.add_css_class ("dim-label");
                time.add_css_class ("caption");
                row.add_suffix (time);
                var remove_btn = new Button.from_icon_name ("user-trash-symbolic");
                remove_btn.add_css_class ("flat");
                remove_btn.tooltip_text = _("Remove from History");
                string url = entry.url;
                remove_btn.clicked.connect (() => services.store.remove_history (url));
                row.add_suffix (remove_btn);
                row.activated.connect (() => navigate (url, false));
                group.add_row (row);
            }
        }
    }

    public class BookmarksPage : NativePage {
        private Box list;
        private Singularity.Widgets.SearchEntry search;
        private ulong changed_handler = 0;
        private Button import_btn;

        public signal void import_requested (ImportSource source);

        public override string title { owned get { return _("Bookmarks"); } }

        public BookmarksPage (Services services) {
            base (services);
            var box = column ();
            var top = new Box (Orientation.HORIZONTAL, 10);
            var heading = new Label (_("Bookmarks"));
            heading.add_css_class ("title-1");
            heading.halign = Align.START;
            heading.hexpand = true;
            heading.ellipsize = Pango.EllipsizeMode.END;
            heading.xalign = 0;
            top.append (heading);
            import_btn = new Button.with_label (_("Import…"));
            import_btn.valign = Align.CENTER;
            import_btn.clicked.connect (show_import_menu);
            top.append (import_btn);
            var folder_btn = new Button.with_label (_("New Folder"));
            folder_btn.valign = Align.CENTER;
            folder_btn.clicked.connect (() => {
                services.store.add_folder (Store.ROOT, _("New Folder"));
            });
            top.append (folder_btn);
            box.append (top);
            search = new Singularity.Widgets.SearchEntry ();
            search.placeholder_text = _("Search Bookmarks");
            search.search_changed.connect (refresh);
            box.append (search);
            list = new Box (Orientation.VERTICAL, 6);
            box.append (list);
            changed_handler = services.store.bookmarks_changed.connect (refresh);
            refresh ();
        }

        public override void dispose () {
            if (changed_handler != 0) {
                services.store.disconnect (changed_handler);
                changed_handler = 0;
            }
            base.dispose ();
        }

        public override void focus_primary () {
            search.grab_focus ();
        }

        private void show_import_menu () {
            var sources = BookmarkImport.detect ();
            var menu = new Singularity.Widgets.ContextMenu (import_btn);
            if (sources.length == 0) {
                menu.add_item (_("No Other Browsers Found"), "dialog-information-symbolic", () => {});
            }
            foreach (var source in sources) {
                var s = source;
                menu.add_item (_("From %s").printf (s.name), "document-import-symbolic", () => import_requested (s));
            }
            menu.add_separator ();
            menu.add_item (_("From a File…"), "document-open-symbolic", () => pick_file ());
            menu.popup ();
        }

        private void pick_file () {
            var dialog = new FileDialog ();
            dialog.title = _("Import Bookmarks");
            var filter = new FileFilter ();
            filter.name = _("Bookmarks");
            filter.add_pattern ("Bookmarks");
            filter.add_pattern ("*.json");
            filter.add_pattern ("places.sqlite");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            dialog.open.begin ((Gtk.Window) get_root (), null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    string path = file.get_path ();
                    bool firefox = path.has_suffix (".sqlite");
                    import_requested (new ImportSource (Path.get_basename (path), "document-import-symbolic", path, firefox));
                } catch (Error e) {
                }
            });
        }

        public override void refresh () {
            clear (list);
            string q = search.text.strip ();
            if (q != "") {
                var found = services.store.search_bookmarks (q, 200);
                if (found.length == 0) {
                    var status = new StatusPage ();
                    status.icon_name = "user-bookmarks-symbolic";
                    status.title = _("No Results");
                    status.description = _("No bookmark matches your search.");
                    list.append (status);
                    return;
                }
                var group = new PreferencesGroup (_("Results"));
                foreach (var b in found) group.add_row (bookmark_row (b));
                list.append (group);
                return;
            }
            if (services.store.count_bookmarks () == 0 && services.store.children (Store.ROOT).length == 0) {
                var status = new StatusPage ();
                status.icon_name = "user-bookmarks-symbolic";
                status.title = _("No Bookmarks");
                status.description = _("Press Ctrl+D on any page to keep it here, or import the bookmarks of another browser.");
                list.append (status);
                return;
            }
            var loose = new PreferencesGroup (_("Unfiled"));
            bool any_loose = false;
            foreach (var b in services.store.children (Store.ROOT)) {
                if (b.is_folder) continue;
                loose.add_row (bookmark_row (b));
                any_loose = true;
            }
            if (any_loose) list.append (loose);
            foreach (var folder in services.store.children (Store.ROOT))
                if (folder.is_folder) add_folder (folder, folder.title);
        }

        private void add_folder (Bookmark folder, string path) {
            var group = new PreferencesGroup (path);
            var remove_btn = new Button.from_icon_name ("user-trash-symbolic");
            remove_btn.add_css_class ("flat");
            remove_btn.tooltip_text = _("Remove Folder");
            int64 id = folder.id;
            remove_btn.clicked.connect (() => services.store.remove_bookmark (id));
            group.add_header_suffix (remove_btn);
            bool any = false;
            var subfolders = new Gee.ArrayList<Bookmark> ();
            foreach (var b in services.store.children (folder.id)) {
                if (b.is_folder) {
                    subfolders.add (b);
                    continue;
                }
                group.add_row (bookmark_row (b));
                any = true;
            }
            if (!any && subfolders.size == 0) {
                var empty = new ActionRow (_("Empty Folder"), _("Bookmarks you add to this folder appear here."));
                empty.activatable = false;
                group.add_row (empty);
            }
            if (any || subfolders.size == 0) list.append (group);
            foreach (var sub in subfolders) add_folder (sub, "%s / %s".printf (path, sub.title));
        }

        private Widget bookmark_row (Bookmark b) {
            var row = new ActionRow (b.title != "" ? b.title : Address.display (b.url), Address.full_display (b.url));
            row.add_prefix (site_icon (services, b.url, b.title));
            var remove_btn = new Button.from_icon_name ("user-trash-symbolic");
            remove_btn.add_css_class ("flat");
            remove_btn.tooltip_text = _("Remove Bookmark");
            int64 id = b.id;
            string url = b.url;
            remove_btn.clicked.connect (() => services.store.remove_bookmark (id));
            row.add_suffix (remove_btn);
            row.activated.connect (() => navigate (url, false));
            return row;
        }
    }

    public class DownloadsPage : NativePage {
        private Box list;
        private ulong changed_handler = 0;

        public override string title { owned get { return _("Downloads"); } }

        public DownloadsPage (Services services) {
            base (services);
            var box = column ();
            var top = new Box (Orientation.HORIZONTAL, 10);
            var heading = new Label (_("Downloads"));
            heading.add_css_class ("title-1");
            heading.halign = Align.START;
            heading.hexpand = true;
            heading.ellipsize = Pango.EllipsizeMode.END;
            heading.xalign = 0;
            top.append (heading);
            var clear_btn = new Button.with_label (_("Clear Finished"));
            clear_btn.valign = Align.CENTER;
            clear_btn.clicked.connect (() => services.downloads.clear_finished ());
            top.append (clear_btn);
            box.append (top);
            list = new Box (Orientation.VERTICAL, 6);
            box.append (list);
            changed_handler = services.downloads.changed.connect (refresh);
            refresh ();
        }

        public override void dispose () {
            if (changed_handler != 0) {
                services.downloads.disconnect (changed_handler);
                changed_handler = 0;
            }
            base.dispose ();
        }

        private uint pending = 0;

        public override void refresh () {
            if (pending != 0) return;
            pending = Idle.add (() => {
                pending = 0;
                rebuild ();
                return Source.REMOVE;
            });
        }

        private void rebuild () {
            clear (list);
            var items = services.downloads.items;
            if (items.get_n_items () == 0) {
                var status = new StatusPage ();
                status.icon_name = "folder-download-symbolic";
                status.title = _("No Downloads");
                status.description = _("Files you download are saved in your Downloads folder and listed here.");
                list.append (status);
                return;
            }
            var session = new PreferencesGroup (_("This Session"));
            var earlier = new PreferencesGroup (_("Earlier"));
            bool any_session = false;
            bool any_earlier = false;
            for (uint i = 0; i < items.get_n_items (); i++) {
                var item = (DownloadItem) items.get_item (i);
                var row = DownloadRow.build (item, services.downloads);
                if (item.earlier) {
                    earlier.add_row (row);
                    any_earlier = true;
                } else {
                    session.add_row (row);
                    any_session = true;
                }
            }
            if (any_session) list.append (session);
            if (any_earlier) list.append (earlier);
        }
    }

    public class DownloadRow : Object {
        public static ActionRow build (DownloadItem item, Downloads downloads) {
            string subtitle;
            if (item.failed) subtitle = item.cancelled ? _("Cancelled") : _("Failed: %s").printf (item.error);
            else if (item.earlier && item.missing) subtitle = _("Moved or deleted");
            else if (item.finished) subtitle = _("%s, done").printf (Util.format_size (item.received));
            else subtitle = _("%s received").printf (Util.format_size (item.received));
            var row = new ActionRow (item.name != "" ? item.name : _("Preparing download"), subtitle);
            var icon = new Image.from_gicon (ContentType.get_icon (ContentType.guess (item.name, null, null)));
            icon.pixel_size = 32;
            icon.margin_end = 12;
            row.add_prefix (icon);
            if (item.active) {
                var bar = new ProgressBar ();
                bar.fraction = item.progress;
                bar.valign = Align.CENTER;
                bar.set_size_request (90, -1);
                row.add_suffix (bar);
                var cancel = new Button.from_icon_name ("process-stop-symbolic");
                cancel.add_css_class ("flat");
                cancel.tooltip_text = _("Cancel Download");
                cancel.clicked.connect (() => {
                    if (item.download != null) item.download.cancel ();
                });
                row.add_suffix (cancel);
            } else if (item.finished && !(item.earlier && item.missing)) {
                var show = new Button.from_icon_name ("folder-open-symbolic");
                show.add_css_class ("flat");
                show.tooltip_text = _("Show in Files");
                show.clicked.connect (() => Downloads.show_in_folder (item));
                row.add_suffix (show);
                row.activated.connect (() => Downloads.open (item));
            } else {
                var remove = new Button.from_icon_name ("user-trash-symbolic");
                remove.add_css_class ("flat");
                remove.tooltip_text = _("Remove from List");
                remove.clicked.connect (() => downloads.remove (item));
                row.add_suffix (remove);
            }
            return row;
        }
    }

    public class ErrorPage : NativePage {
        public signal void retry ();
        public signal void proceed ();

        public ErrorPage (Services services, string icon, string heading, string body, bool allow_proceed) {
            base (services);
            var status = new StatusPage ();
            status.icon_name = icon;
            status.title = heading;
            status.description = body;
            status.vexpand = true;
            var buttons = new Box (Orientation.HORIZONTAL, 10);
            buttons.halign = Align.CENTER;
            if (allow_proceed) {
                var go = new Button.with_label (_("Visit Anyway"));
                go.add_css_class ("destructive-action");
                go.clicked.connect (() => proceed ());
                buttons.append (go);
                var back = new Button.with_label (_("Go Back"));
                back.add_css_class ("suggested-action");
                back.clicked.connect (() => retry ());
                buttons.append (back);
            } else {
                var again = new Button.with_label (_("Try Again"));
                again.add_css_class ("suggested-action");
                again.clicked.connect (() => retry ());
                buttons.append (again);
            }
            status.child = buttons;
            append (status);
        }
    }
}
