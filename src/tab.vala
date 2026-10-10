using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public enum SecurityLevel {
        INTERNAL,
        SECURE,
        INSECURE,
        BROKEN,
        LOCAL
    }

    public class BrowserTab : Box {
        public string tab_id { get; construct; }
        public Services services { get; construct; }
        public Profile profile { get; construct; }
        public string uri { get; private set; default = ""; }
        public string title { get; private set; default = ""; }
        public Gdk.Texture? favicon { get; private set; default = null; }
        public bool loading { get; private set; default = false; }
        public double progress { get; private set; default = 0; }
        public bool can_go_back { get; private set; default = false; }
        public bool can_go_forward { get; private set; default = false; }
        public bool pinned { get; set; default = false; }
        public string group_id { get; set; default = ""; }
        public bool reader_available { get; private set; default = false; }
        public bool reader_active { get; private set; default = false; }
        public bool playing_audio { get; private set; default = false; }
        public bool muted { get; private set; default = false; }
        public double zoom { get; private set; default = 1.0; }
        public SecurityLevel security { get; private set; default = SecurityLevel.INTERNAL; }
        public bool is_private { get { return profile.ephemeral; } }
        public uint password_revision { get; private set; default = 0; }

        public WebKit.WebView? view { get; private set; default = null; }
        private WebKit.WebView? related;
        private WebKit.UserContentManager? content_manager;
        private WebKit.WebView? reader_view;
        private NativePage? native_page;
        private Stack stack;
        private Box prompts;
        private Revealer find_revealer;
        private Singularity.Widgets.SearchEntry find_entry;
        private Label find_count;
        private string pending_uri = "";
        private string native_back = "";
        private bool committed_any = false;
        private string password_site = "";
        private uint password_capture_revision = 0;
        private string pending_title = "";
        private string last_site = "";
        private bool blocker_off = false;
        private GLib.TlsCertificate? failed_certificate = null;
        private string failed_host = "";
        private Gee.HashMap<string, Banner> active_prompts = new Gee.HashMap<string, Banner> ();
        private ReaderArticle? article = null;
        private uint reader_probe = 0;
        private PageSketch? sketch;
        private bool capturing_sketch = false;

        public signal void open_requested (string uri, TabOpen mode);
        public signal Widget? popup_requested (WebKit.WebView related_view);
        public signal void close_requested ();
        public signal void fullscreen_changed (bool fullscreen);
        public signal void import_requested (ImportSource source);
        public signal void focus_address ();
        public signal void state_changed ();
        public signal void download_only ();

        public BrowserTab (Services services, Profile profile, string? uri = null, WebKit.WebView? related = null) {
            Object (tab_id: Uuid.string_random (), services: services, profile: profile,
                    orientation: Orientation.VERTICAL, spacing: 0);
            this.related = related;
            hexpand = true;
            vexpand = true;
            add_css_class ("browser-tab");

            prompts = new Box (Orientation.VERTICAL, 6);
            prompts.add_css_class ("browser-prompts");
            prompts.visible = false;
            append (prompts);

            stack = new Stack ();
            stack.hexpand = true;
            stack.vexpand = true;
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.transition_duration = Singularity.Motion.reduced () ? 0 : Singularity.Motion.Duration.SMALL.ms ();
            append (stack);

            find_revealer = new Revealer ();
            find_revealer.transition_type = RevealerTransitionType.SLIDE_UP;
            find_revealer.transition_duration = Singularity.Motion.reduced () ? 0 : Singularity.Motion.Duration.MEDIUM.ms ();
            find_revealer.child = build_find_bar ();
            find_revealer.visible = false;
            find_revealer.notify["child-revealed"].connect (() => {
                if (!find_revealer.reveal_child && !find_revealer.child_revealed) find_revealer.visible = false;
            });
            append (find_revealer);

            profile.site_changed.connect (on_site_changed);
            services.blocker.changed.connect (apply_blocker);

            if (related != null) {
                ensure_view ();
            } else if (uri != null && uri != "") {
                pending_uri = uri;
            } else {
                pending_uri = Address.NEW_TAB;
            }
        }

        public override void dispose () {
            if (reader_probe != 0) {
                Source.remove (reader_probe);
                reader_probe = 0;
            }
            if (profile != null) profile.site_changed.disconnect (on_site_changed);
            if (services != null) services.blocker.changed.disconnect (apply_blocker);
            if (view != null) view.try_close ();
            base.dispose ();
        }

        public void restore (string uri, string title) {
            pending_uri = uri;
            pending_title = title;
            this.uri = uri;
            this.title = title;
        }

        public bool materialized {
            get { return pending_uri == ""; }
        }

        public void materialize () {
            if (pending_uri == "") return;
            string target = pending_uri;
            pending_uri = "";
            load (target);
        }

        public string display_title {
            owned get {
                if (title != "") return title;
                if (native_page != null && native_page.title != "") return native_page.title;
                if (uri == "" || uri == Address.NEW_TAB) return is_private ? _("Private Tab") : _("New Tab");
                return Address.display (uri);
            }
        }

        public bool is_new_tab {
            get { return uri == "" || uri == Address.NEW_TAB; }
        }

        private void ensure_view () {
            if (view != null) return;
            content_manager = new WebKit.UserContentManager ();
            if (!profile.ephemeral) {
                content_manager.register_script_message_handler_with_reply (WebAuthnScript.HANDLER, null);
                content_manager.script_message_with_reply_received[WebAuthnScript.HANDLER].connect (on_webauthn_message);
                content_manager.add_script (new WebKit.UserScript (WebAuthnScript.source (),
                    WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserScriptInjectionTime.START, null, null));
            }
            if (services.settings.get_boolean ("save-passwords") && !profile.ephemeral) {
                content_manager.register_script_message_handler (Passwords.HANDLER, Passwords.WORLD);
                content_manager.script_message_received[Passwords.HANDLER].connect (on_password_message);
                content_manager.add_script (new WebKit.UserScript.for_world (Passwords.capture_script (),
                    WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserScriptInjectionTime.END,
                    Passwords.WORLD, null, null));
            }
            if (related != null) {
                view = (WebKit.WebView) Object.new (typeof (WebKit.WebView),
                    "related-view", related,
                    "user-content-manager", content_manager,
                    "settings", profile.web_settings);
            } else {
                view = (WebKit.WebView) Object.new (typeof (WebKit.WebView),
                    "network-session", profile.session,
                    "web-context", profile.context,
                    "user-content-manager", content_manager,
                    "settings", profile.web_settings,
                    "website-policies", policies_for (""));
            }
            view.hexpand = true;
            view.vexpand = true;
            apply_blocker ();

            view.notify["uri"].connect (() => {
                string? u = view.get_uri ();
                if (u != null && !reader_active) {
                    uri = u;
                    if (password_site != "" && Address.origin_of (u) != password_site) {
                        password_capture_revision++;
                        password_site = "";
                        dismiss_prompt ("password");
                    }
                    update_security ();
                    state_changed ();
                }
            });
            view.notify["title"].connect (() => {
                string? t = view.get_title ();
                if (reader_active) return;
                title = t ?? "";
                if (title != "" && uri != "") profile.record_title (uri, title);
                state_changed ();
            });
            view.notify["favicon"].connect (() => {
                favicon = view.get_favicon ();
                state_changed ();
            });
            view.notify["estimated-load-progress"].connect (() => {
                progress = view.estimated_load_progress;
                state_changed ();
            });
            view.notify["is-loading"].connect (() => {
                loading = view.is_loading;
                state_changed ();
            });
            view.notify["is-playing-audio"].connect (() => {
                playing_audio = view.is_playing_audio;
                state_changed ();
            });
            view.notify["is-muted"].connect (() => {
                muted = view.is_muted;
                state_changed ();
            });
            view.load_changed.connect (on_load_changed);
            view.load_failed.connect (on_load_failed);
            view.load_failed_with_tls_errors.connect (on_tls_error);
            view.decide_policy.connect (on_decide_policy);
            view.create.connect (on_create);
            view.permission_request.connect (on_permission_request);
            view.enter_fullscreen.connect (() => {
                fullscreen_changed (true);
                return false;
            });
            view.leave_fullscreen.connect (() => {
                fullscreen_changed (false);
                return false;
            });
            view.context_menu.connect (on_context_menu);
            view.close.connect (() => close_requested ());
            view.mouse_target_changed.connect ((hit, modifiers) => {
                view.tooltip_text = hit.context_is_link () ? hit.get_link_uri () : null;
            });
            view.get_back_forward_list ().changed.connect (() => {
                can_go_back = view.can_go_back () || native_back != "";
                can_go_forward = view.can_go_forward ();
                state_changed ();
            });
            stack.add_named (view, "web");
        }

        private WebKit.WebsitePolicies policies_for (string site) {
            string? value = site != "" ? profile.site_value (site, "autoplay") : null;
            string policy = value ?? services.settings.get_string ("autoplay");
            WebKit.AutoplayPolicy autoplay = WebKit.AutoplayPolicy.ALLOW_WITHOUT_SOUND;
            if (policy == "allow") autoplay = WebKit.AutoplayPolicy.ALLOW;
            else if (policy == "block") autoplay = WebKit.AutoplayPolicy.DENY;
            return (WebKit.WebsitePolicies) Object.new (typeof (WebKit.WebsitePolicies), "autoplay", autoplay);
        }

        public void load (string target) {
            pending_uri = "";
            failed_certificate = null;
            set_reader (false);
            if (target == Address.NEW_TAB || target == Address.HISTORY || target == Address.BOOKMARKS || target == Address.DOWNLOADS) {
                show_native (target);
                return;
            }
            ensure_view ();
            if (native_page != null && !(native_page is ErrorPage)) native_back = uri;
            else if (view.get_uri () != null) native_back = "";
            clear_native ();
            stack.visible_child_name = "web";
            uri = target;
            password_capture_revision++;
            password_site = "";
            dismiss_prompt ("password");
            update_security ();
            view.load_uri (target);
            state_changed ();
        }

        private void show_native (string target) {
            clear_native ();
            NativePage page;
            if (target == Address.HISTORY) page = new HistoryPage (services);
            else if (target == Address.BOOKMARKS) {
                var bookmarks = new BookmarksPage (services);
                bookmarks.import_requested.connect ((s) => import_requested (s));
                page = bookmarks;
            } else if (target == Address.DOWNLOADS) page = new DownloadsPage (services);
            else page = new NewTabPage (services, profile.ephemeral);
            page.navigate.connect ((u, new_tab) => {
                if (new_tab) open_requested (u, TabOpen.BACKGROUND);
                else load (u);
            });
            native_page = page;
            stack.add_named (page, "native");
            stack.visible_child_name = "native";
            uri = target;
            title = "";
            favicon = null;
            loading = false;
            progress = 0;
            security = SecurityLevel.INTERNAL;
            can_go_back = view != null && view.can_go_back ();
            can_go_forward = view != null && view.can_go_forward ();
            reader_available = false;
            state_changed ();
            if (target == Address.NEW_TAB) Idle.add (() => {
                if (native_page == page && page.get_mapped ()) page.focus_primary ();
                return Source.REMOVE;
            });
        }

        private void clear_native () {
            if (native_page == null) return;
            stack.remove (native_page);
            native_page = null;
        }

        private void show_error (string icon, string heading, string body, bool tls) {
            clear_native ();
            var page = new ErrorPage (services, icon, heading, body, tls);
            page.retry.connect (() => {
                if (tls) {
                    if (view != null && view.can_go_back ()) view.go_back ();
                    else load (Address.NEW_TAB);
                } else {
                    reload ();
                }
            });
            page.proceed.connect (() => {
                if (failed_certificate != null && failed_host != "") {
                    profile.session.allow_tls_certificate_for_host (failed_certificate, failed_host);
                    failed_certificate = null;
                    reload ();
                }
            });
            native_page = page;
            stack.add_named (page, "native");
            stack.visible_child_name = "native";
            state_changed ();
        }

        public void refresh_native () {
            if (native_page != null) native_page.refresh ();
        }

        public void focus_page () {
            if (native_page != null && native_page.get_visible ()) native_page.focus_primary ();
            else if (view != null) view.grab_focus ();
        }

        public void go_back () {
            if (view == null) return;
            if (native_page != null && view.get_uri () != null && view.get_uri () != "" && !is_new_tab) {
                clear_native ();
                stack.visible_child_name = "web";
                uri = view.get_uri ();
                title = view.get_title () ?? "";
                update_security ();
                state_changed ();
                return;
            }
            if (!view.can_go_back () && native_back != "") {
                string target = native_back;
                native_back = "";
                show_native (target);
                return;
            }
            view.go_back ();
        }

        public void go_forward () {
            if (view != null) view.go_forward ();
        }

        public void reload (bool bypass_cache = false) {
            if (native_page != null && view != null && view.get_uri () != null && !(native_page is ErrorPage)) {
                native_page.refresh ();
                return;
            }
            if (view == null) return;
            clear_native ();
            stack.visible_child_name = "web";
            if (bypass_cache) view.reload_bypass_cache ();
            else view.reload ();
        }

        public void stop () {
            if (view != null) view.stop_loading ();
        }

        public void toggle_mute () {
            if (view != null) view.is_muted = !view.is_muted;
        }

        private void on_load_changed (WebKit.LoadEvent event) {
            switch (event) {
                case WebKit.LoadEvent.STARTED:
                    password_revision++;
                    clear_native ();
                    stack.visible_child_name = "web";
                    reader_available = false;
                    article = null;
                    string site = Address.site_key (view.get_uri ());
                    if (site != last_site) {
                        last_site = site;
                        apply_blocker ();
                    }
                    break;
                case WebKit.LoadEvent.COMMITTED:
                    committed_any = true;
                    string site = Address.site_key (view.get_uri ());
                    string? z = profile.site_value (site, "zoom");
                    zoom = z != null ? double.parse (z).clamp (0.3, 5.0) : services.settings.get_double ("default-zoom");
                    view.zoom_level = zoom;
                    update_security ();
                    foreach (string key in active_prompts.keys.to_array ()) {
                        if (key == "password" && Address.origin_of (view.get_uri ()) == password_site) continue;
                        dismiss_prompt (key);
                    }
                    break;
                case WebKit.LoadEvent.FINISHED:
                    string? u = view.get_uri ();
                    if (u != null) profile.record_visit (u, view.get_title () ?? "");
                    schedule_reader_probe ();
                    auto_fill.begin (password_revision);
                    break;
                default:
                    break;
            }
            state_changed ();
        }

        private bool on_load_failed (WebKit.LoadEvent event, string failing_uri, Error error) {
            if (error.matches (WebKit.NetworkError.quark (), WebKit.NetworkError.CANCELLED)) return true;
            if (error.matches (WebKit.PolicyError.quark (), WebKit.PolicyError.FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE)) return true;
            uri = failing_uri;
            string host = Address.display (failing_uri);
            string body;
            if (error.matches (WebKit.PolicyError.quark (), WebKit.PolicyError.CANNOT_SHOW_URI)) {
                body = _("There is no app to open this address.");
            } else if (error.matches (WebKit.NetworkError.quark (), WebKit.NetworkError.UNKNOWN_PROTOCOL)) {
                body = _("This kind of address is not supported.");
            } else {
                body = _("%s could not be reached. Check the address and your connection, then try again.").printf (host != "" ? host : failing_uri);
            }
            show_error ("network-offline-symbolic", _("Can't Open This Page"), body, false);
            return true;
        }

        private bool on_tls_error (string failing_uri, GLib.TlsCertificate certificate, GLib.TlsCertificateFlags errors) {
            failed_certificate = certificate;
            failed_host = Address.host_of (failing_uri) ?? "";
            uri = failing_uri;
            security = SecurityLevel.BROKEN;
            show_error ("security-low-symbolic", _("This Connection Is Not Private"),
                _("%s presented a certificate that can't be trusted. Someone could be pretending to be this site to steal what you send it.").printf (Address.display (failing_uri)),
                true);
            return true;
        }

        private bool on_decide_policy (WebKit.PolicyDecision decision, WebKit.PolicyDecisionType type) {
            if (type == WebKit.PolicyDecisionType.RESPONSE) {
                var response = (WebKit.ResponsePolicyDecision) decision;
                if (!response.is_mime_type_supported () && response.is_main_frame_main_resource ()) {
                    decision.download ();
                    if (!committed_any) Idle.add (() => {
                        download_only ();
                        return Source.REMOVE;
                    });
                    return true;
                }
                return false;
            }
            var nav = ((WebKit.NavigationPolicyDecision) decision).get_navigation_action ();
            string target = nav.get_request ().get_uri ();
            if (type == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) {
                if (nav.is_user_gesture () || site_allows_popups ()) {
                    bool background = (nav.get_modifiers () & Gdk.ModifierType.CONTROL_MASK) != 0 || nav.get_mouse_button () == 2;
                    open_requested (target, background ? TabOpen.BACKGROUND : TabOpen.FOREGROUND);
                } else {
                    popup_blocked (target);
                }
                decision.ignore ();
                return true;
            }
            if (nav.get_navigation_type () == WebKit.NavigationType.LINK_CLICKED) {
                uint mods = nav.get_modifiers ();
                if (nav.get_mouse_button () == 2 || (mods & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    open_requested (target, (mods & Gdk.ModifierType.SHIFT_MASK) != 0 ? TabOpen.FOREGROUND : TabOpen.BACKGROUND);
                    decision.ignore ();
                    return true;
                }
            }
            if (nav.get_frame_name () == null && Singularity.Parental.WebFilter.get_default ().blocks (target)) {
                decision.ignore ();
                uri = target;
                show_error ("action-unavailable-symbolic", _("This Site Is Blocked"),
                    _("%s is blocked by parental controls on this account.").printf (Address.display (target)), false);
                return true;
            }
            if (nav.get_frame_name () == null && !nav.is_redirect ()) {
                string site = Address.site_key (target);
                if (site != "" && site != last_site) {
                    last_site = site;
                    apply_blocker ();
                }
                decision.use_with_policies (policies_for (site));
                return true;
            }
            return false;
        }

        private bool site_allows_popups () {
            string site = Address.site_key (uri);
            string? value = profile.site_value (site, "popups");
            if (value != null) return value == "allow";
            return !services.settings.get_boolean ("block-popups");
        }

        private Gtk.Widget on_create (WebKit.NavigationAction nav) {
            string target = nav.get_request ().get_uri () ?? "";
            if (!nav.is_user_gesture () && !site_allows_popups ()) {
                popup_blocked (target);
                return null;
            }
            return popup_requested (view);
        }

        private void popup_blocked (string target) {
            string site = Address.site_key (uri);
            var banner = show_prompt ("popup", "window-new-symbolic",
                _("%s tried to open a pop-up window.").printf (site != "" ? site : _("This page")),
                _("Always Allow"), _("Open It"));
            banner.button_clicked.connect (() => {
                profile.set_site_value (site, "popups", "allow");
                dismiss_prompt ("popup");
                if (target != "" && target != "about:blank") open_requested (target, TabOpen.FOREGROUND);
            });
            banner.secondary_clicked.connect (() => {
                dismiss_prompt ("popup");
                if (target != "" && target != "about:blank") open_requested (target, TabOpen.FOREGROUND);
            });
        }

        private bool on_permission_request (WebKit.PermissionRequest request) {
            string site = Address.site_key (uri);
            string key;
            string message;
            string icon;
            if (request is WebKit.UserMediaPermissionRequest) {
                var media = (WebKit.UserMediaPermissionRequest) request;
                if (media.is_for_video_device && media.is_for_audio_device) {
                    key = "camera+microphone";
                    message = _("%s wants to use your camera and microphone.");
                    icon = "camera-web-symbolic";
                } else if (media.is_for_video_device) {
                    key = "camera";
                    message = _("%s wants to use your camera.");
                    icon = "camera-web-symbolic";
                } else {
                    key = "microphone";
                    message = _("%s wants to use your microphone.");
                    icon = "audio-input-microphone-symbolic";
                }
            } else if (request is WebKit.GeolocationPermissionRequest) {
                key = "location";
                message = _("%s wants to know your location.");
                icon = "find-location-symbolic";
            } else if (request is WebKit.NotificationPermissionRequest) {
                key = "notifications";
                message = _("%s wants to show notifications.");
                icon = "preferences-system-notifications-symbolic";
            } else {
                request.deny ();
                return true;
            }
            string? stored = stored_permission (site, key);
            if (stored == "allow") {
                request.allow ();
                return true;
            }
            if (stored == "block" || site == "") {
                request.deny ();
                return true;
            }
            var banner = show_prompt ("permission-" + key, icon, message.printf (site), _("Allow"), _("Block"));
            banner.add_css_class ("browser-permission-prompt");
            banner.button_clicked.connect (() => {
                store_permission (site, key, "allow");
                request.allow ();
                dismiss_prompt ("permission-" + key);
            });
            banner.secondary_clicked.connect (() => {
                store_permission (site, key, "block");
                request.deny ();
                dismiss_prompt ("permission-" + key);
            });
            return true;
        }

        private string? stored_permission (string site, string key) {
            if (key == "camera+microphone") {
                string? cam = profile.site_value (site, "camera");
                string? mic = profile.site_value (site, "microphone");
                if (cam == "block" || mic == "block") return "block";
                if (cam == "allow" && mic == "allow") return "allow";
                return null;
            }
            return profile.site_value (site, key);
        }

        private void store_permission (string site, string key, string value) {
            if (key == "camera+microphone") {
                profile.set_site_value (site, "camera", value);
                profile.set_site_value (site, "microphone", value);
            } else {
                profile.set_site_value (site, key, value);
            }
        }

        private Banner show_prompt (string id, string icon, string text, string? primary, string? secondary) {
            dismiss_prompt (id);
            var banner = new Banner (text);
            banner.icon_name = icon;
            banner.button_label = primary;
            banner.secondary_label = secondary;
            banner.add_css_class ("browser-prompt");
            active_prompts[id] = banner;
            prompts.append (banner);
            prompts.visible = true;
            return banner;
        }

        private void dismiss_prompt (string id) {
            if (!active_prompts.has_key (id)) return;
            var banner = active_prompts[id];
            active_prompts.unset (id);
            if (banner.get_parent () == prompts) prompts.remove (banner);
            prompts.visible = prompts.get_first_child () != null;
        }

        public bool has_prompt (string id) {
            return active_prompts.has_key (id);
        }

        private bool on_context_menu (WebKit.ContextMenu menu, WebKit.HitTestResult hit) {
            var win = get_root () as Gtk.ApplicationWindow;
            if (win == null) return false;
            if (hit.context_is_link ()) {
                string link = hit.get_link_uri ();
                var tab_action = win.lookup_action ("open-link-tab");
                var tile_action = win.lookup_action ("open-link-tile");
                var private_action = ((Gtk.Application) win.application).lookup_action ("open-private");
                int index = 0;
                if (tab_action != null)
                    menu.insert (new WebKit.ContextMenuItem.from_gaction (tab_action, _("Open Link in New Tab"), new Variant.string (link)), index++);
                if (tile_action != null)
                    menu.insert (new WebKit.ContextMenuItem.from_gaction (tile_action, _("Open Link in New Tile"), new Variant.string (link)), index++);
                if (private_action != null && !profile.ephemeral)
                    menu.insert (new WebKit.ContextMenuItem.from_gaction (private_action, _("Open Link in Private Window"), new Variant.string (link)), index++);
                foreach (var item in menu.get_items ().copy ()) {
                    var stock = item.get_stock_action ();
                    if (stock == WebKit.ContextMenuAction.OPEN_LINK_IN_NEW_WINDOW) menu.remove (item);
                }
            }
            if (hit.context_is_selection () && !profile.ephemeral && Singularity.Notes.NotePicker.available ()) {
                if (quote_action == null) {
                    quote_action = new SimpleAction ("quote-to-note", VariantType.STRING);
                    quote_action.activate.connect ((a, p) => quote_to_note.begin (p.get_string ()));
                }
                var notes = new WebKit.ContextMenu ();
                notes.append (new WebKit.ContextMenuItem.from_gaction (quote_action, _("New Note"), new Variant.string ("")));
                var recent = Singularity.Notes.NotePicker.cached_recent ();
                Singularity.Notes.NotePicker.refresh_recent ();
                if (!recent.is_empty) notes.append (new WebKit.ContextMenuItem.separator ());
                foreach (var n in recent) {
                    notes.append (new WebKit.ContextMenuItem.from_gaction (quote_action, n.title != "" ? n.title : _("Untitled Note"), new Variant.string (n.id)));
                }
                menu.append (new WebKit.ContextMenuItem.separator ());
                menu.append (new WebKit.ContextMenuItem.with_submenu (_("Add to a Note"), notes));
            }
            return false;
        }

        private SimpleAction? quote_action = null;

        private async void quote_to_note (string note_id) {
            string text = "";
            try {
                var result = yield view.evaluate_javascript ("window.getSelection().toString()", -1, null, null, null);
                if (result.is_string ()) text = result.to_string ().strip ();
            } catch (Error e) {
                warning ("Quote to note: %s", e.message);
            }
            if (text == "") return;
            var quoted = new StringBuilder ();
            foreach (string line in text.split ("\n")) quoted.append ("> %s\n".printf (line.strip ()));
            string page_title = title != "" ? title : uri;
            quoted.append ("\n[%s](%s)\n".printf (page_title.replace ("]", ""), uri));
            var window = get_root () as Singularity.Widgets.Window;
            try {
                var note = yield Singularity.Notes.NotePicker.add (note_id != "" ? note_id : null, page_title, quoted.str);
                if (window != null) window.add_toast (Singularity.Notes.NotePicker.toast (note, _("Quote")));
            } catch (Error e) {
                if (window != null) window.add_toast (new Singularity.Widgets.Toast (e.message));
            }
        }

        private bool on_webauthn_message (JSC.Value value, WebKit.ScriptMessageReply reply) {
            var window = get_root () as Gtk.Window;
            string? origin = Address.origin_of (uri);
            if (window == null || window.application == null || origin == null || !value.is_string ()) {
                reply.return_value (new JSC.Value.string (value.get_context (), WebAuthnPrompt.error_reply ("NotAllowedError", _("Passkeys are not available here"))));
                return true;
            }
            var prompt = new WebAuthnPrompt (window.application, window, profile.ephemeral ? "private" : profile.id);
            prompt.handle.begin (value.to_string (), origin, (o, r) => {
                string answer = prompt.handle.end (r);
                reply.return_value (new JSC.Value.string (value.get_context (), answer));
            });
            return true;
        }

        private void on_password_message (JSC.Value value) {
            if (profile.ephemeral || !value.is_object ()) return;
            if (value.object_has_property ("pick")) {
                show_choices (value);
                return;
            }
            if (!services.settings.get_boolean ("save-passwords")) return;
            foreach (string key in new string[] { "origin", "username", "password" }) {
                if (!value.object_get_property (key).is_string ()) return;
            }
            string origin = value.object_get_property ("origin").to_string ();
            string username = value.object_get_property ("username").to_string ();
            string password = value.object_get_property ("password").to_string ();
            if (password == "" || origin != Address.origin_of (uri) || !Passwords.eligible (uri)) return;
            string site = Address.site_key (uri);
            if (profile.site_value (site, "passwords") == "never") return;
            password_site = origin;
            uint revision = ++password_capture_revision;
            Passwords.lookup.begin (origin, profile.id, false, (obj, res) => {
                var found = Passwords.lookup.end (res);
                if (profile.ephemeral || revision != password_capture_revision || origin != Address.origin_of (uri)
                    || !services.settings.get_boolean ("save-passwords")) return;
                foreach (var c in found)
                    if (c.username == username && c.password == password) return;
                var banner = show_prompt ("password", "dialog-password-symbolic",
                    username != "" ? _("Save the password for %s on %s?").printf (username, site) : _("Save the password for %s?").printf (site),
                    _("Save"), _("Never for This Site"));
                var credential = new Credential (origin, username, password, profile.id);
                banner.button_clicked.connect (() => {
                    dismiss_prompt ("password");
                    if (profile.ephemeral || revision != password_capture_revision || origin != Address.origin_of (uri)
                        || !services.settings.get_boolean ("save-passwords")) return;
                    Passwords.save.begin (credential, (o, result) => {
                        if (!Passwords.save.end (result)) {
                            show_prompt ("password-error", "dialog-password-symbolic", _("The password could not be saved in the keyring"), null, null);
                        }
                        state_changed ();
                    });
                });
                banner.secondary_clicked.connect (() => {
                    dismiss_prompt ("password");
                    profile.set_site_value (site, "passwords", "never");
                });
            });
        }

        private Credential[] password_choices = {};
        private Singularity.Widgets.ContextMenu? choice_menu = null;
        private int64 choice_closed_at = 0;

        private async bool offer_choices () {
            try {
                var result = yield view.evaluate_javascript (Passwords.pick_script (), -1, Passwords.WORLD, null, null);
                return result.to_boolean ();
            } catch (Error e) {
                return false;
            }
        }

        private void show_choices (JSC.Value value) {
            if (password_choices.length < 2 || view == null) return;
            if (choice_menu != null || get_monotonic_time () - choice_closed_at < 1000000) return;
            double zoom = view.zoom_level;
            Gdk.Rectangle rect = {
                (int) (value.object_get_property ("x").to_double () * zoom),
                (int) (value.object_get_property ("y").to_double () * zoom),
                int.max (1, (int) (value.object_get_property ("width").to_double () * zoom)),
                int.max (1, (int) (value.object_get_property ("height").to_double () * zoom))
            };
            var menu = new Singularity.Widgets.ContextMenu (view);
            uint revision = password_revision;
            foreach (var credential in password_choices) {
                var chosen = credential;
                menu.add_item (chosen.username != "" ? chosen.username : _("No username"), "dialog-password-symbolic", () => {
                    fill_password.begin (chosen, revision);
                });
            }
            menu.set_pointing_to (rect);
            menu.position = Gtk.PositionType.BOTTOM;
            menu.autohide = true;
            menu.closed.connect (() => {
                choice_closed_at = get_monotonic_time ();
                Idle.add (() => {
                    if (choice_menu == menu) choice_menu = null;
                    menu.unparent ();
                    return Source.REMOVE;
                });
            });
            choice_menu = menu;
            menu.popup ();
        }

        private async void auto_fill (uint revision) {
            if (profile.ephemeral || view == null || !Passwords.eligible (uri)) return;
            string? origin = Address.origin_of (uri);
            if (origin == null) return;
            var found = yield Passwords.lookup (origin, profile.id, false);
            password_choices = found.length > 1 ? found : new Credential[0];
            if (found.length == 0) return;
            for (int attempt = 0; attempt < 4; attempt++) {
                if (revision != password_revision || origin != Address.origin_of (uri)) return;
                if (found.length == 1 && (yield fill_password (found[0], revision))) return;
                if (found.length > 1 && (yield offer_choices ())) return;
                Timeout.add (700, () => {
                    auto_fill.callback ();
                    return Source.REMOVE;
                });
                yield;
            }
        }

        public async bool fill_password (Credential? chosen = null, uint revision = uint.MAX) {
            if (profile.ephemeral || view == null || !Passwords.eligible (uri)) return false;
            string? origin = Address.origin_of (uri);
            if (origin == null) return false;
            if (revision == uint.MAX) revision = password_revision;
            if (chosen == null) {
                var found = yield Passwords.lookup (origin, profile.id, true);
                if (found.length != 1) return false;
                chosen = found[0];
            }
            if (revision != password_revision || origin != Address.origin_of (uri)
                || chosen.origin != origin || chosen.profile != profile.id || profile.ephemeral) return false;
            try {
                var result = yield view.evaluate_javascript (Passwords.fill_script (chosen), -1, Passwords.WORLD, null, null);
                return result.to_boolean ();
            } catch (Error e) {
                warning ("Password fill: %s", e.message);
                return false;
            }
        }

        private void on_site_changed (string site, string key) {
            if (site != Address.site_key (uri)) return;
            if (key == "blocker") apply_blocker ();
            else if (key == "zoom" && view != null) {
                string? z = profile.site_value (site, "zoom");
                zoom = z != null ? double.parse (z) : services.settings.get_double ("default-zoom");
                view.zoom_level = zoom;
                state_changed ();
            }
        }

        public bool blocker_disabled_here {
            get { return blocker_off; }
        }

        private void apply_blocker () {
            if (content_manager == null) return;
            string site = last_site != "" ? last_site : Address.site_key (uri);
            blocker_off = profile.site_value (site, "blocker") == "off";
            services.blocker.apply (content_manager, blocker_off);
        }

        private void update_security () {
            if (Address.is_internal (uri)) {
                security = SecurityLevel.INTERNAL;
                return;
            }
            string? scheme = Address.scheme_of (uri);
            if (scheme == "file") {
                security = SecurityLevel.LOCAL;
                return;
            }
            if (scheme != "https") {
                security = Address.is_secure (uri) ? SecurityLevel.LOCAL : SecurityLevel.INSECURE;
                return;
            }
            if (view != null) {
                unowned GLib.TlsCertificate cert;
                GLib.TlsCertificateFlags errors;
                if (view.get_tls_info (out cert, out errors) && errors != 0) {
                    security = SecurityLevel.BROKEN;
                    return;
                }
            }
            security = SecurityLevel.SECURE;
        }

        public void apply_zoom (double level) {
            if (view == null) return;
            zoom = level.clamp (0.3, 5.0);
            view.zoom_level = zoom;
            string site = Address.site_key (uri);
            double def = services.settings.get_double ("default-zoom");
            profile.set_site_value (site, "zoom", Math.fabs (zoom - def) < 0.001 ? null : "%.2f".printf (zoom));
            state_changed ();
        }

        public void zoom_step (int direction) {
            double[] levels = { 0.3, 0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0 };
            if (direction == 0) {
                apply_zoom (services.settings.get_double ("default-zoom"));
                return;
            }
            double current = zoom;
            if (direction > 0) {
                foreach (double l in levels) if (l > current + 0.001) { apply_zoom (l); return; }
            } else {
                for (int i = levels.length - 1; i >= 0; i--) if (levels[i] < current - 0.001) { apply_zoom (levels[i]); return; }
            }
        }

        private Widget build_find_bar () {
            var bar = new Box (Orientation.HORIZONTAL, 6);
            bar.add_css_class ("browser-find-bar");
            find_entry = new Singularity.Widgets.SearchEntry ();
            find_entry.placeholder_text = _("Find in Page");
            find_entry.hexpand = true;
            find_entry.search_changed.connect (() => run_find (true));
            find_entry.entry.activate.connect (() => find_next ());
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape) {
                    close_find ();
                    return true;
                }
                if (keyval == Gdk.Key.Return && (state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                    find_previous ();
                    return true;
                }
                return false;
            });
            find_entry.entry.add_controller (keys);
            bar.append (find_entry);
            find_count = new Label ("");
            find_count.add_css_class ("dim-label");
            find_count.add_css_class ("numeric");
            find_count.ellipsize = Pango.EllipsizeMode.END;
            find_count.visible = false;
            find_count.notify["label"].connect (() => find_count.visible = find_count.label != "");
            bar.append (find_count);
            var prev = new Button.from_icon_name ("go-up-symbolic");
            prev.tooltip_text = _("Previous Match");
            prev.add_css_class ("flat");
            prev.clicked.connect (find_previous);
            bar.append (prev);
            var next = new Button.from_icon_name ("go-down-symbolic");
            next.tooltip_text = _("Next Match");
            next.add_css_class ("flat");
            next.clicked.connect (find_next);
            bar.append (next);
            var done = new Button.with_label (_("Done"));
            done.clicked.connect (close_find);
            bar.append (done);
            return bar;
        }

        private WebKit.WebView? find_target () {
            return reader_active ? reader_view : view;
        }

        public void open_find () {
            var target = find_target ();
            if (target == null || native_page != null) return;
            find_revealer.visible = true;
            find_revealer.reveal_child = true;
            find_entry.grab_focus ();
            if (find_entry.text != "") run_find (true);
        }

        public bool find_open {
            get { return find_revealer.reveal_child; }
        }

        public void close_find () {
            find_revealer.reveal_child = false;
            var target = find_target ();
            if (target != null) {
                target.get_find_controller ().search_finish ();
                target.grab_focus ();
            }
            find_count.label = "";
        }

        private bool find_connected = false;

        private void run_find (bool reset) {
            var target = find_target ();
            if (target == null) return;
            var controller = target.get_find_controller ();
            if (!find_connected) {
                find_connected = true;
                controller.counted_matches.connect ((count) => {
                    find_count.label = count > 0 ? ngettext ("%u match", "%u matches", count).printf (count) : _("No matches");
                });
                controller.failed_to_find_text.connect (() => {
                    find_count.label = _("No matches");
                    find_entry.add_css_class ("error");
                });
                controller.found_text.connect ((count) => find_entry.remove_css_class ("error"));
            }
            string text = find_entry.text;
            if (text == "") {
                controller.search_finish ();
                find_count.label = "";
                find_entry.remove_css_class ("error");
                return;
            }
            uint32 options = WebKit.FindOptions.CASE_INSENSITIVE | WebKit.FindOptions.WRAP_AROUND;
            controller.count_matches (text, options, 1000);
            controller.search (text, options, 1000);
        }

        public void find_next () {
            var target = find_target ();
            if (target == null) return;
            if (!find_open) {
                open_find ();
                return;
            }
            target.get_find_controller ().search_next ();
        }

        public void find_previous () {
            var target = find_target ();
            if (target != null && find_open) target.get_find_controller ().search_previous ();
        }

        public void find_text (string text) {
            open_find ();
            find_entry.text = text;
            run_find (true);
        }

        private void schedule_reader_probe () {
            if (reader_probe != 0) Source.remove (reader_probe);
            reader_probe = Timeout.add (400, () => {
                reader_probe = 0;
                probe_reader.begin ();
                return Source.REMOVE;
            });
        }

        private async void probe_reader () {
            if (view == null) return;
            string? current = view.get_uri ();
            string? scheme = current != null ? Address.scheme_of (current) : null;
            if (scheme != "http" && scheme != "https" && scheme != "file") return;
            var resource = view.get_main_resource ();
            if (resource == null) return;
            var response = resource.get_response ();
            if (response != null && response.mime_type != null && response.mime_type != "text/html" && response.mime_type != "application/xhtml+xml") return;
            try {
                uint8[] data = yield resource.get_data (null);
                if (view.get_uri () != current) return;
                var copy = new uint8[data.length + 1];
                Memory.copy (copy, data, data.length);
                string html = (string) copy;
                if (!html.validate ()) html = html.make_valid ();
                article = Reader.extract (html, current);
                reader_available = article != null;
                state_changed ();
            } catch (Error e) {
                debug ("Reader probe: %s", e.message);
            }
        }

        public void toggle_reader () {
            set_reader (!reader_active);
        }

        public async void toggle_sketch () {
            if (sketch != null) {
                stack.visible_child = stack.visible_child == sketch ? (reader_active ? (Widget) reader_view : (Widget) view) : sketch;
                return;
            }
            var target = printable_view ();
            if (target == null || capturing_sketch || loading || Address.is_internal (uri)) return;
            capturing_sketch = true;
            string captured_uri = uri;
            try {
                double offset = 0;
                try {
                    var position = yield target.evaluate_javascript ("window.scrollY * window.devicePixelRatio", -1, null, null, null);
                    if (position.is_number ()) offset = position.to_double ();
                } catch (Error e) {
                }
                Gdk.Texture snapshot;
                try {
                    snapshot = yield target.get_snapshot (WebKit.SnapshotRegion.FULL_DOCUMENT, WebKit.SnapshotOptions.NONE, null);
                } catch (Error e) {
                    warning ("Full page sketch: %s", e.message);
                    snapshot = yield target.get_snapshot (WebKit.SnapshotRegion.VISIBLE, WebKit.SnapshotOptions.NONE, null);
                    offset = 0;
                }
                if (uri != captured_uri || loading) return;
                sketch = new PageSketch (snapshot, captured_uri, offset);
                sketch.closed.connect (() => stack.visible_child_name = reader_active ? "reader" : "web");
                stack.add_named (sketch, "sketch");
                stack.visible_child = sketch;
            } catch (Error e) {
                warning ("Page sketch: %s", e.message);
            } finally {
                capturing_sketch = false;
            }
        }

        public void set_reader (bool on) {
            if (on == reader_active) return;
            if (on) {
                if (article == null) return;
                if (reader_view == null) {
                    var settings = new WebKit.Settings ();
                    settings.enable_javascript = false;
                    settings.enable_developer_extras = profile.web_settings.enable_developer_extras;
                    reader_view = (WebKit.WebView) Object.new (typeof (WebKit.WebView),
                        "network-session", profile.session,
                        "web-context", profile.context,
                        "settings", settings);
                    reader_view.hexpand = true;
                    reader_view.vexpand = true;
                    reader_view.decide_policy.connect ((decision, type) => {
                        if (type != WebKit.PolicyDecisionType.NAVIGATION_ACTION && type != WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) return false;
                        var nav = ((WebKit.NavigationPolicyDecision) decision).get_navigation_action ();
                        if (nav.get_navigation_type () == WebKit.NavigationType.LINK_CLICKED || type == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) {
                            string target = nav.get_request ().get_uri ();
                            decision.ignore ();
                            set_reader (false);
                            load (target);
                            return true;
                        }
                        return false;
                    });
                    stack.add_named (reader_view, "reader");
                }
                reader_view.zoom_level = zoom;
                reader_view.load_html (Reader.render (article, Services.accent_hex ()), view.get_uri ());
                reader_active = true;
                stack.visible_child_name = "reader";
            } else {
                reader_active = false;
                if (native_page == null && view != null) stack.visible_child_name = "web";
            }
            if (find_open) close_find ();
            state_changed ();
        }

        public WebKit.WebView? printable_view () {
            if (native_page != null) return null;
            return reader_active ? reader_view : view;
        }

        public void show_inspector () {
            var target = printable_view ();
            if (target == null) return;
            profile.web_settings.enable_developer_extras = true;
            if (reader_view != null) reader_view.get_settings ().enable_developer_extras = true;
            target.get_inspector ().show ();
        }

        public string? session_uri () {
            if (pending_uri != "") return pending_uri;
            if (native_page is ErrorPage || reader_active) return uri;
            return uri;
        }
    }

    public enum TabOpen {
        FOREGROUND,
        BACKGROUND,
        TILE,
        WINDOW
    }
}
