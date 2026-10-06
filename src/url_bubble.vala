using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public enum SuggestionKind {
        GO,
        SEARCH,
        TAB,
        BOOKMARK,
        HISTORY,
        REMOTE
    }

    public class Suggestion : Object {
        public SuggestionKind kind;
        public string title;
        public string subtitle;
        public string uri;
        public string icon;
        public string tab_id = "";

        public Suggestion (SuggestionKind kind, string title, string subtitle, string uri, string icon) {
            this.kind = kind;
            this.title = title;
            this.subtitle = subtitle;
            this.uri = uri;
            this.icon = icon;
        }
    }

    public class UrlBubble : Box {
        public Gtk.Text entry { get; private set; }
        public Button security_button { get; private set; }
        public Button reader_button { get; private set; }
        public Button sketch_button { get; private set; }
        public Button bookmark_button { get; private set; }
        public Button zoom_button { get; private set; }
        public Button password_button { get; private set; }

        private Image security_icon;
        private ProgressBar progress_bar;
        private Popover popover;
        private ListBox list;
        private Services services;
        private string current_uri = "";
        private bool editing = false;
        private bool programmatic = false;
        private uint local_source = 0;
        private uint remote_source = 0;
        private Soup.Session? http = null;
        private Cancellable? remote_cancel = null;
        private Gee.ArrayList<Suggestion> items = new Gee.ArrayList<Suggestion> ();
        public bool is_private = false;

        public signal void activated (string uri, TabOpen mode);
        public signal void switch_to_tab (string tab_id);
        public signal void escaped ();
        public delegate Suggestion[] TabMatcher (string query);
        public TabMatcher? tab_matcher;

        public UrlBubble (Services services) {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
            this.services = services;
            add_css_class ("browser-url-bubble");
            hexpand = false;
            overflow = Overflow.HIDDEN;

            var overlay = new Overlay ();
            overlay.hexpand = true;
            var row = new Box (Orientation.HORIZONTAL, 2);
            row.hexpand = true;
            overlay.child = row;
            progress_bar = new ProgressBar ();
            progress_bar.add_css_class ("browser-url-progress");
            progress_bar.valign = Align.END;
            progress_bar.can_target = false;
            progress_bar.visible = false;
            overlay.add_overlay (progress_bar);
            append (overlay);

            security_button = new Button ();
            security_button.add_css_class ("flat");
            security_button.add_css_class ("browser-url-icon");
            security_icon = new Image.from_icon_name ("system-search-symbolic");
            security_button.child = security_icon;
            security_button.tooltip_text = _("Site Settings");
            security_button.valign = Align.CENTER;
            row.append (security_button);

            entry = new Gtk.Text ();
            entry.hexpand = true;
            entry.placeholder_text = _("Search or enter address");
            entry.add_css_class ("browser-url-entry");
            entry.input_purpose = InputPurpose.URL;
            entry.input_hints = InputHints.NO_SPELLCHECK | InputHints.NO_EMOJI;
            entry.xalign = 0.5f;
            entry.truncate_multiline = true;
            entry.width_chars = 10;
            entry.max_width_chars = 64;
            row.append (entry);

            password_button = small_button ("dialog-password-symbolic", _("Fill Saved Password"));
            row.append (password_button);
            zoom_button = new Button.with_label ("100%");
            zoom_button.add_css_class ("flat");
            zoom_button.add_css_class ("browser-url-zoom");
            zoom_button.tooltip_text = _("Reset Zoom");
            zoom_button.visible = false;
            zoom_button.valign = Align.CENTER;
            row.append (zoom_button);
            reader_button = small_button ("browser-reader-symbolic", _("Reader View"));
            row.append (reader_button);
            sketch_button = small_button ("document-edit-symbolic", _("Sketch on This Page"));
            row.append (sketch_button);
            bookmark_button = small_button ("non-starred-symbolic", _("Bookmark This Page"));
            bookmark_button.visible = true;
            row.append (bookmark_button);

            list = new ListBox ();
            list.selection_mode = SelectionMode.SINGLE;
            list.add_css_class ("browser-suggestions");
            list.activate_on_single_click = true;
            list.row_activated.connect ((r) => activate_index (r.get_index (), TabOpen.FOREGROUND));
            popover = new Popover ();
            popover.autohide = false;
            popover.has_arrow = false;
            popover.can_focus = false;
            popover.position = PositionType.BOTTOM;
            popover.add_css_class ("browser-suggestions-popover");
            popover.child = list;
            popover.set_parent (this);

            entry.changed.connect (on_changed);
            entry.activate.connect (() => activate_typed (TabOpen.FOREGROUND));
            var keys = new EventControllerKey ();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect (on_key);
            entry.add_controller (keys);
            var focus = new EventControllerFocus ();
            focus.enter.connect (() => {
                if (editing) return;
                editing = true;
                entry.xalign = 0f;
                string initial = Address.is_internal (current_uri) ? "" : current_uri;
                set_text (initial);
                entry.select_region (0, -1);
                Idle.add (() => {
                    if (entry.text == initial) entry.select_region (0, -1);
                    return Source.REMOVE;
                });
                add_css_class ("editing");
            });
            focus.leave.connect (() => {
                Timeout.add (120, () => {
                    if (!entry.has_focus) end_editing ();
                    return Source.REMOVE;
                });
            });
            entry.add_controller (focus);
        }

        public override void dispose () {
            if (local_source != 0) Source.remove (local_source);
            if (remote_source != 0) Source.remove (remote_source);
            local_source = 0;
            remote_source = 0;
            if (popover != null) {
                popover.unparent ();
                popover = null;
            }
            base.dispose ();
        }

        private Button small_button (string icon, string tooltip) {
            var button = new Button.from_icon_name (icon);
            button.add_css_class ("flat");
            button.add_css_class ("browser-url-icon");
            button.tooltip_text = tooltip;
            button.valign = Align.CENTER;
            button.visible = false;
            return button;
        }

        private void set_text (string text) {
            programmatic = true;
            entry.text = text;
            programmatic = false;
        }

        public void begin_editing (string? initial = null) {
            entry.grab_focus ();
            if (initial != null) {
                set_text (initial);
                entry.set_position (-1);
                on_changed ();
            }
        }

        private void end_editing () {
            if (!editing) return;
            editing = false;
            entry.xalign = 0.5f;
            remove_css_class ("editing");
            hide_suggestions ();
            set_text (Address.display (current_uri));
        }

        public void show_tab (BrowserTab? tab) {
            if (tab == null) return;
            current_uri = tab.uri;
            if (!editing) set_text (Address.display (tab.uri));
            string icon;
            string tip;
            remove_css_class ("insecure");
            switch (tab.security) {
                case SecurityLevel.SECURE:
                    icon = "channel-secure-symbolic";
                    tip = _("Connection Is Secure");
                    break;
                case SecurityLevel.INSECURE:
                    icon = "channel-insecure-symbolic";
                    tip = _("Connection Is Not Secure");
                    add_css_class ("insecure");
                    break;
                case SecurityLevel.BROKEN:
                    icon = "security-low-symbolic";
                    tip = _("Certificate Not Trusted");
                    add_css_class ("insecure");
                    break;
                case SecurityLevel.LOCAL:
                    icon = "computer-symbolic";
                    tip = _("Local Page");
                    break;
                default:
                    icon = tab.is_private ? "browser-private-symbolic" : "system-search-symbolic";
                    tip = tab.is_private ? _("Private Browsing") : _("Search or enter address");
                    break;
            }
            security_icon.icon_name = icon;
            security_button.tooltip_text = tip;
            security_button.sensitive = !Address.is_internal (tab.uri);
            bool loading = tab.loading && tab.materialized && !Address.is_internal (tab.uri);
            progress_bar.visible = loading && tab.progress < 1.0;
            progress_bar.fraction = tab.progress;
            reader_button.visible = tab.reader_available || tab.reader_active;
            sketch_button.visible = !Address.is_internal (tab.uri);
            if (tab.reader_active) reader_button.add_css_class ("active");
            else reader_button.remove_css_class ("active");
            double def = services.settings.get_double ("default-zoom");
            zoom_button.visible = Math.fabs (tab.zoom - def) > 0.001 && !Address.is_internal (tab.uri);
            zoom_button.label = "%d%%".printf ((int) Math.round (tab.zoom * 100));
            bool bookmarkable = Store.recordable (tab.uri);
            bookmark_button.visible = bookmarkable;
            bool starred = bookmarkable && services.store.bookmark_for_url (tab.uri) != null;
            ((Image) bookmark_button.child).icon_name = starred ? "starred-symbolic" : "non-starred-symbolic";
            bookmark_button.tooltip_text = starred ? _("Edit Bookmark") : _("Bookmark This Page");
            if (starred) bookmark_button.add_css_class ("active");
            else bookmark_button.remove_css_class ("active");
        }

        public void set_password_available (bool available) {
            password_button.visible = available;
        }

        private bool on_key (uint keyval, uint keycode, Gdk.ModifierType state) {
            bool alt = (state & Gdk.ModifierType.ALT_MASK) != 0;
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            switch (keyval) {
                case Gdk.Key.Down:
                case Gdk.Key.KP_Down:
                    move_selection (1);
                    return true;
                case Gdk.Key.Up:
                case Gdk.Key.KP_Up:
                    move_selection (-1);
                    return true;
                case Gdk.Key.Tab:
                    if (popover.visible) {
                        move_selection ((state & Gdk.ModifierType.SHIFT_MASK) != 0 ? -1 : 1);
                        return true;
                    }
                    return false;
                case Gdk.Key.Escape:
                    if (popover.visible) {
                        hide_suggestions ();
                        return true;
                    }
                    end_editing ();
                    escaped ();
                    return true;
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                    TabOpen mode = alt ? TabOpen.FOREGROUND : TabOpen.FOREGROUND;
                    if (alt) mode = TabOpen.BACKGROUND;
                    var selected = list.get_selected_row ();
                    if (selected != null && popover.visible) activate_index (selected.get_index (), alt ? TabOpen.BACKGROUND : TabOpen.FOREGROUND);
                    else if (ctrl && !entry.text.contains (".") && !entry.text.contains (" ")) {
                        set_text ("www.%s.com".printf (entry.text.strip ()));
                        activate_typed (mode);
                    } else activate_typed (mode);
                    return true;
                default:
                    return false;
            }
        }

        private void move_selection (int delta) {
            if (!popover.visible || items.size == 0) return;
            var current = list.get_selected_row ();
            int index = current != null ? current.get_index () + delta : (delta > 0 ? 0 : items.size - 1);
            index = index.clamp (0, items.size - 1);
            var row = list.get_row_at_index (index);
            list.select_row (row);
            var item = items[index];
            if (item.kind != SuggestionKind.SEARCH && item.kind != SuggestionKind.REMOTE && item.kind != SuggestionKind.GO) {
                set_text (item.uri);
                entry.set_position (-1);
            }
        }

        private void activate_typed (TabOpen mode) {
            string? uri = Address.normalize (entry.text, services.engine ());
            if (uri == null) return;
            finish (uri, mode);
        }

        private void activate_index (int index, TabOpen mode) {
            if (index < 0 || index >= items.size) return;
            var item = items[index];
            if (item.kind == SuggestionKind.TAB) {
                hide_suggestions ();
                end_editing ();
                switch_to_tab (item.tab_id);
                return;
            }
            finish (item.uri, mode);
        }

        private void finish (string uri, TabOpen mode) {
            hide_suggestions ();
            editing = false;
            entry.xalign = 0.5f;
            remove_css_class ("editing");
            if (mode == TabOpen.FOREGROUND) current_uri = uri;
            set_text (Address.display (current_uri));
            activated (uri, mode);
        }

        private void hide_suggestions () {
            if (local_source != 0) {
                Source.remove (local_source);
                local_source = 0;
            }
            if (remote_source != 0) {
                Source.remove (remote_source);
                remote_source = 0;
            }
            if (popover.visible) popover.popdown ();
            if (remote_cancel != null) remote_cancel.cancel ();
        }

        private void on_changed () {
            if (programmatic || !editing) return;
            if (local_source != 0) Source.remove (local_source);
            local_source = Timeout.add (40, () => {
                local_source = 0;
                if (editing) rebuild (entry.text, new string[0]);
                return Source.REMOVE;
            });
            if (remote_source != 0) Source.remove (remote_source);
            remote_source = 0;
            if (!is_private && services.settings.get_boolean ("search-suggestions")) {
                string query = entry.text;
                remote_source = Timeout.add (220, () => {
                    remote_source = 0;
                    fetch_remote.begin (query);
                    return Source.REMOVE;
                });
            }
        }

        private async void fetch_remote (string query) {
            if (query.strip ().length < 2 || Address.classify (query) != AddressKind.SEARCH) return;
            string? url = services.engine ().suggestions_for (query);
            if (url == null) return;
            if (http == null) {
                http = new Soup.Session ();
                http.timeout = 5;
            }
            if (remote_cancel != null) remote_cancel.cancel ();
            remote_cancel = new Cancellable ();
            try {
                var message = new Soup.Message ("GET", url);
                var bytes = yield http.send_and_read_async (message, Priority.DEFAULT, remote_cancel);
                if (message.status_code != 200 || entry.text != query || !editing) return;
                var found = Address.parse_suggestions (Util.bytes_to_string (bytes));
                rebuild (query, found);
            } catch (Error e) {
            }
        }

        private void rebuild (string text, string[] remote) {
            items.clear ();
            string query = text.strip ();
            Widget? child;
            while ((child = list.get_first_child ()) != null) list.remove (child);
            if (query == "") {
                hide_suggestions ();
                return;
            }
            var engine = services.engine ();
            var seen = new Gee.HashSet<string> ();
            var kind = Address.classify (query);
            string? typed = Address.normalize (query, engine);
            if (kind == AddressKind.URL || kind == AddressKind.INTERNAL) {
                items.add (new Suggestion (SuggestionKind.GO, Address.full_display (typed), _("Open Address"), typed, "go-next-symbolic"));
                seen.add (typed);
                items.add (new Suggestion (SuggestionKind.SEARCH, query, _("Search with %s").printf (engine.name), engine.url_for (query), "system-search-symbolic"));
            } else {
                items.add (new Suggestion (SuggestionKind.SEARCH, query, _("Search with %s").printf (engine.name), typed, "system-search-symbolic"));
            }
            if (tab_matcher != null) {
                int n = 0;
                foreach (var t in tab_matcher (query)) {
                    if (n++ >= 2) break;
                    items.add (t);
                    seen.add (t.uri);
                }
            }
            int bookmarks = 0;
            foreach (var b in services.store.search_bookmarks (query, 4)) {
                if (seen.contains (b.url) || bookmarks >= 3) continue;
                seen.add (b.url);
                items.add (new Suggestion (SuggestionKind.BOOKMARK, b.title != "" ? b.title : Address.display (b.url), Address.full_display (b.url), b.url, "starred-symbolic"));
                bookmarks++;
            }
            int history = 0;
            foreach (var h in services.store.search_history (query, 8)) {
                if (seen.contains (h.url) || history >= 5) continue;
                seen.add (h.url);
                items.add (new Suggestion (SuggestionKind.HISTORY, h.title != "" ? h.title : Address.display (h.url), Address.full_display (h.url), h.url, "document-open-recent-symbolic"));
                history++;
            }
            int n_remote = 0;
            foreach (string r in remote) {
                if (r == query || n_remote >= 4) continue;
                items.add (new Suggestion (SuggestionKind.REMOTE, r, "", engine.url_for (r), "system-search-symbolic"));
                n_remote++;
            }
            foreach (var item in items) list.append (build_row (item));
            list.select_row (list.get_row_at_index (0));
            popover.set_size_request (int.max (get_width (), 320), -1);
            if (!popover.visible) popover.popup ();
        }

        private Widget build_row (Suggestion item) {
            var row = new ListBoxRow ();
            row.add_css_class ("browser-suggestion");
            var box = new Box (Orientation.HORIZONTAL, 10);
            box.margin_start = 8;
            box.margin_end = 8;
            box.margin_top = 5;
            box.margin_bottom = 5;
            var icon = new Image.from_icon_name (item.icon);
            icon.pixel_size = 16;
            icon.add_css_class ("dim-label");
            box.append (icon);
            var labels = new Box (Orientation.VERTICAL, 0);
            labels.hexpand = true;
            var title = new Label (item.title);
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            labels.append (title);
            if (item.subtitle != "") {
                var sub = new Label (item.subtitle);
                sub.xalign = 0;
                sub.ellipsize = Pango.EllipsizeMode.MIDDLE;
                sub.add_css_class ("dim-label");
                sub.add_css_class ("caption");
                labels.append (sub);
            }
            box.append (labels);
            if (item.kind == SuggestionKind.TAB) {
                var hint = new Label (_("Switch to Tab"));
                hint.add_css_class ("dim-label");
                hint.add_css_class ("caption");
                box.append (hint);
            }
            row.child = box;
            return row;
        }
    }

    public class SitePopover : Popover {
        private BrowserTab tab;
        private Profile profile;

        public signal void fill_password ();

        public SitePopover (BrowserTab tab, bool has_password) {
            this.tab = tab;
            this.profile = tab.profile;
            add_css_class ("browser-site-popover");
            has_arrow = false;
            position = PositionType.BOTTOM;
            string site = Address.site_key (tab.uri);

            var box = new Box (Orientation.VERTICAL, 10);
            box.margin_top = 14;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            box.set_size_request (340, -1);

            var head = new Box (Orientation.HORIZONTAL, 12);
            head.margin_start = 4;
            string head_name = "channel-insecure-symbolic";
            if (tab.security == SecurityLevel.SECURE) head_name = "channel-secure-symbolic";
            else if (tab.security == SecurityLevel.LOCAL) head_name = "computer-symbolic";
            else if (tab.security == SecurityLevel.BROKEN) head_name = "security-low-symbolic";
            var head_icon = new Image.from_icon_name (head_name);
            head_icon.pixel_size = 24;
            if (tab.security == SecurityLevel.INSECURE || tab.security == SecurityLevel.BROKEN) head_icon.add_css_class ("warning");
            head.append (head_icon);
            var head_text = new Box (Orientation.VERTICAL, 2);
            var host = new Label (site != "" ? site : Address.display (tab.uri));
            host.add_css_class ("heading");
            host.xalign = 0;
            host.ellipsize = Pango.EllipsizeMode.MIDDLE;
            head_text.append (host);
            string status;
            switch (tab.security) {
                case SecurityLevel.SECURE: status = _("Connection is secure. What you send stays private."); break;
                case SecurityLevel.BROKEN: status = _("This site's certificate is not trusted."); break;
                case SecurityLevel.LOCAL: status = _("This page is on your computer or local network."); break;
                default: status = _("Connection is not secure. Don't enter passwords or card details."); break;
            }
            var status_label = new Label (status);
            status_label.add_css_class ("dim-label");
            status_label.add_css_class ("caption");
            status_label.xalign = 0;
            status_label.wrap = true;
            status_label.max_width_chars = 34;
            head_text.append (status_label);
            head.append (head_text);
            box.append (head);

            var permissions = new PreferencesGroup (_("Permissions"));
            permissions.add_row (permission_row (site, "camera", _("Camera"), "camera-web-symbolic", false));
            permissions.add_row (permission_row (site, "microphone", _("Microphone"), "audio-input-microphone-symbolic", false));
            permissions.add_row (permission_row (site, "location", _("Location"), "find-location-symbolic", false));
            permissions.add_row (permission_row (site, "notifications", _("Notifications"), "preferences-system-notifications-symbolic", false));
            permissions.add_row (autoplay_row (site));
            permissions.add_row (permission_row (site, "popups", _("Pop-up Windows"), "window-new-symbolic", true));
            box.append (permissions);

            var website = new PreferencesGroup (_("This Website"));
            var blocker = new SwitchRow (_("Content Blocker"), _("Block ads and trackers"));
            blocker.active = profile.site_value (site, "blocker") != "off";
            blocker.switch_btn.notify["active"].connect (() => {
                profile.set_site_value (site, "blocker", blocker.active ? null : "off");
                tab.reload ();
            });
            website.add_row (blocker);
            var zoom = new ActionRow (_("Zoom"));
            var minus = new Button.from_icon_name ("zoom-out-symbolic");
            minus.add_css_class ("flat");
            minus.tooltip_text = _("Zoom Out");
            var level = new Label ("%d%%".printf ((int) Math.round (tab.zoom * 100)));
            level.add_css_class ("numeric");
            level.width_chars = 5;
            var plus = new Button.from_icon_name ("zoom-in-symbolic");
            plus.add_css_class ("flat");
            plus.tooltip_text = _("Zoom In");
            minus.clicked.connect (() => {
                tab.zoom_step (-1);
                level.label = "%d%%".printf ((int) Math.round (tab.zoom * 100));
            });
            plus.clicked.connect (() => {
                tab.zoom_step (1);
                level.label = "%d%%".printf ((int) Math.round (tab.zoom * 100));
            });
            zoom.add_suffix (minus);
            zoom.add_suffix (level);
            zoom.add_suffix (plus);
            website.add_row (zoom);
            if (has_password) {
                var fill = new ActionRow (_("Fill Saved Password"), null, "dialog-password-symbolic");
                fill.activated.connect (() => {
                    popdown ();
                    fill_password ();
                });
                website.add_row (fill);
            }
            box.append (website);
            child = box;
        }

        private Widget permission_row (string site, string key, string title, string icon, bool binary) {
            var row = new ActionRow (title, null, icon);
            string[] ids = binary ? new string[] { "allow", "block" } : new string[] { "ask", "allow", "block" };
            string[] labels = binary ? new string[] { _("Allow"), _("Block") } : new string[] { _("Ask"), _("Allow"), _("Block") };
            var dropdown = new DropDown.from_strings (labels);
            dropdown.valign = Align.CENTER;
            string? current = profile.site_value (site, key);
            if (binary && current == null) current = tab.services.settings.get_boolean ("block-popups") ? "block" : "allow";
            for (int i = 0; i < ids.length; i++)
                if (ids[i] == (current ?? "ask")) dropdown.selected = i;
            dropdown.notify["selected"].connect (() => {
                string value = ids[dropdown.selected];
                profile.set_site_value (site, key, value == "ask" ? null : value);
            });
            row.add_suffix (dropdown);
            return row;
        }

        private Widget autoplay_row (string site) {
            var row = new ActionRow (_("Autoplay"), null, "media-playback-start-symbolic");
            string[] ids = { "allow", "allow-without-sound", "block" };
            var dropdown = new DropDown.from_strings ({ _("Allow"), _("Without Sound"), _("Block") });
            dropdown.valign = Align.CENTER;
            string current = profile.site_value (site, "autoplay") ?? tab.services.settings.get_string ("autoplay");
            for (int i = 0; i < ids.length; i++)
                if (ids[i] == current) dropdown.selected = i;
            dropdown.notify["selected"].connect (() => {
                profile.set_site_value (site, "autoplay", ids[dropdown.selected]);
            });
            row.add_suffix (dropdown);
            return row;
        }
    }
}
