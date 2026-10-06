using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public class BrowserApp : Singularity.Application {
        public const string APP_ID = "dev.sinty.browser";

        public GLib.Settings settings { get; private set; }
        public Services? services { get; private set; default = null; }
        public WebAppInfo? webapp { get; construct; }

        private Singularity.DockMenu? dock_menu = null;
        private uint dock_source = 0;
        private uint save_source = 0;
        private Store? readonly_store = null;
        private GLib.Menu? closed_section = null;
        private bool started = false;

        public BrowserApp (WebAppInfo? webapp) {
            Object (application_id: webapp != null ? webapp.id : APP_ID,
                    flags: ApplicationFlags.HANDLES_OPEN | ApplicationFlags.HANDLES_COMMAND_LINE,
                    webapp: webapp);
            Environment.set_prgname (webapp != null ? webapp.id : APP_ID);
            Environment.set_application_name (webapp != null ? webapp.name : _("Browser"));
            about_name = _("Browser");
            about_icon = APP_ID;
            about_version = Config.VERSION;
            about_description = _("Browse the web with tiles, tabs and bubbles that never cover the page.");
            about_website = "https://github.com/singularityos-lab/singularity-desktop";
            about_license = _("GNU General Public License, version 3 only");
        }

        public Store read_store () {
            if (readonly_store == null) {
                string path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser", "browser.db");
                readonly_store = new Store (FileUtils.test (path, FileTest.EXISTS) ? path : null, FileUtils.test (path, FileTest.EXISTS));
            }
            return readonly_store;
        }

        private GLib.Settings load_settings () {
            var source = SettingsSchemaSource.get_default ();
            if (source == null || source.lookup (APP_ID, true) == null) {
                try {
                    string exe = FileUtils.read_link ("/proc/self/exe");
                    string dir = Path.build_filename (Path.get_dirname (exe), "data");
                    if (FileUtils.test (Path.build_filename (dir, "gschemas.compiled"), FileTest.EXISTS)) {
                        var compiled = new SettingsSchemaSource.from_directory (dir, source, true);
                        var schema = compiled.lookup (APP_ID, true);
                        if (schema != null) return new GLib.Settings.full (schema, null, null);
                    }
                } catch (Error e) {
                    warning ("Browser settings: %s", e.message);
                }
            }
            return new GLib.Settings (APP_ID);
        }

        protected override void startup () {
            base.startup ();
            settings = load_settings ();
            var provider = new CssProvider ();
            provider.load_from_resource ("/dev/sinty/browser/browser.css");
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/dev/sinty/browser/icons");

            services = new Services (settings, webapp != null ? "webapp-" + webapp.id.substring (WebApps.PREFIX.length) : "default");
            services.blocker.start.begin ();
            services.closed_changed.connect (queue_save);
            build_menu ();
            install_actions ();
            if (webapp == null) {
                services.store.history_changed.connect (queue_dock);
                queue_dock ();
            }
            started = true;
        }

        protected override void shutdown () {
            if (save_source != 0) {
                Source.remove (save_source);
                save_source = 0;
            }
            if (webapp == null) save_session ();
            base.shutdown ();
        }

        protected override void activate () {
            var windows = browser_windows ();
            if (!windows.is_empty) {
                windows[0].present ();
                return;
            }
            if (webapp != null) {
                var win = new BrowserWindow (this, services, false, webapp);
                win.add_tab (webapp.url);
                win.present ();
                return;
            }
            bool restored = false;
            if (settings.get_boolean ("restore-session")) restored = restore_session ();
            if (!restored) {
                var win = create_window (false);
                win.start_blank ();
                win.present ();
            }
        }

        protected override void open (File[] files, string hint) {
            foreach (var file in files) open_uri_from_outside (file.get_uri ());
        }

        protected override int command_line (ApplicationCommandLine cmdline) {
            string[] args = cmdline.get_arguments ();
            bool private_window = false;
            bool new_window = false;
            string[] uris = {};
            for (int i = 1; i < args.length; i++) {
                string a = args[i];
                if (a == "--private" || a == "--private-window") private_window = true;
                else if (a == "--new-window") new_window = true;
                else if (a == "--webapp") i++;
                else if (a == "--gapplication-service") continue;
                else if (a.has_prefix ("-")) continue;
                else {
                    string? scheme = Address.scheme_of (a);
                    if (scheme == null || scheme.length == 1) uris += cmdline.create_file_for_arg (a).get_uri ();
                    else uris += a;
                }
            }
            if (private_window || new_window) {
                var win = create_window (private_window);
                if (uris.length == 0) win.start_blank ();
                foreach (string u in uris) win.add_tab (u);
                win.present ();
                return 0;
            }
            if (browser_windows ().is_empty) {
                if (uris.length > 0 && webapp == null) {
                    if (!settings.get_boolean ("restore-session") || !restore_session ()) {
                        var win = create_window (false);
                        foreach (string uri in uris) win.add_tab (uri);
                        win.present ();
                        return 0;
                    }
                } else if (uris.length == 0) {
                    activate ();
                    return 0;
                } else activate ();
            }
            foreach (string u in uris) open_uri_from_outside (u);
            if (uris.length == 0) activate ();
            return 0;
        }

        public Gee.List<BrowserWindow> browser_windows () {
            var list = new Gee.ArrayList<BrowserWindow> ();
            foreach (var w in get_windows ())
                if (w is BrowserWindow) list.add ((BrowserWindow) w);
            return list;
        }

        private BrowserWindow? main_window () {
            var active = get_active_window () as BrowserWindow;
            if (active != null && !active.is_private) return active;
            foreach (var w in browser_windows ()) if (!w.is_private) return w;
            return null;
        }

        public BrowserWindow create_window (bool is_private) {
            var win = new BrowserWindow (this, services, is_private, webapp);
            win.session_changed.connect (queue_save);
            return win;
        }

        public BrowserWindow new_window (string? uri, bool is_private) {
            var win = create_window (is_private);
            if (uri != null) win.add_tab (uri);
            else win.start_blank ();
            win.present ();
            return win;
        }

        public BrowserWindow window_with_tab (BrowserTab? tab, bool is_private) {
            var win = create_window (is_private);
            if (tab != null) win.adopt_tab (tab, null, Singularity.TileZone.CENTER);
            win.present ();
            return win;
        }

        public void move_tab_between_windows (string tab_id, BrowserWindow target, BrowserTile tile, Singularity.TileZone zone) {
            foreach (var win in browser_windows ()) {
                if (win == target || win.is_private != target.is_private) continue;
                var tab = win.take_tab (tab_id);
                if (tab != null) {
                    target.adopt_tab (tab, tile, zone);
                    return;
                }
            }
        }

        public void open_uri_from_outside (string uri) {
            if (webapp != null) {
                var win = browser_windows ().is_empty ? null : browser_windows ()[0];
                if (win == null) {
                    activate ();
                    win = browser_windows ()[0];
                }
                if (webapp.in_scope (uri)) win.open (uri, TabOpen.FOREGROUND);
                else open_in_main_browser (uri);
                win.present ();
                return;
            }
            var win = main_window ();
            if (win == null) {
                win = create_window (false);
                win.add_tab (uri);
                win.present ();
                return;
            }
            var current = win.current_tab ();
            if (current != null && current.is_new_tab) current.load (uri);
            else win.add_tab (uri);
            win.present ();
        }

        public void open_in_main_browser (string uri) {
            try {
                string exe = FileUtils.read_link ("/proc/self/exe");
                Process.spawn_async (null, { exe, uri }, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL, null, null);
            } catch (Error e) {
                warning ("Could not open %s: %s", uri, e.message);
            }
        }

        public static void launch_webapp (WebAppInfo info) {
            try {
                string exe = FileUtils.read_link ("/proc/self/exe");
                Process.spawn_async (null, { exe, "--webapp", info.id }, null, SpawnFlags.STDOUT_TO_DEV_NULL, null, null);
            } catch (Error e) {
                warning ("Could not start %s: %s", info.name, e.message);
            }
        }

        public void print_tab (BrowserWindow win, BrowserTab tab) {
            var view = tab.printable_view ();
            if (view == null) return;
            PagePrinter.print_with_dialog.begin (win, view, tab.display_title);
        }

        private void pick_password_file (BrowserWindow win) {
            var dialog = new FileDialog ();
            dialog.title = _("Import Passwords");
            var filter = new FileFilter ();
            filter.name = _("Password Exports (CSV)");
            filter.add_suffix ("csv");
            filter.add_mime_type ("text/csv");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            dialog.open.begin (win, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null) import_passwords.begin (win, file);
                } catch (Error e) {
                }
            });
        }

        private async void import_passwords (BrowserWindow win, File file) {
            try {
                uint8[] data;
                yield file.load_contents_async (null, out data, null);
                var text = new StringBuilder ();
                text.append_len ((string) data, data.length);
                int skipped;
                var credentials = PasswordImport.parse (text.str, win.profile.id, out skipped);
                int saved = 0;
                foreach (var credential in credentials) {
                    if (yield Passwords.save (credential)) saved++;
                    else skipped++;
                }
                string message = ngettext ("%d password imported", "%d passwords imported", saved).printf (saved);
                if (skipped > 0) message += ", " + ngettext ("%d skipped", "%d skipped", skipped).printf (skipped);
                win.add_toast (new Toast (message));
            } catch (Error e) {
                win.add_toast (new Toast (e.message));
            }
        }

        public void import_bookmarks (BrowserWindow win, ImportSource source) {
            try {
                var tree = source.read ();
                int64 folder = services.store.add_folder (Store.ROOT, _("Imported from %s").printf (source.name));
                int count = services.store.import_tree (tree, folder);
                win.add_toast (new Toast (ngettext ("%d bookmark imported", "%d bookmarks imported", count).printf (count)));
            } catch (Error e) {
                win.add_toast (new Toast (e.message));
            }
        }

        public static bool is_default_browser () {
            var info = AppInfo.get_default_for_uri_scheme ("https");
            return info != null && info.get_id () == APP_ID + ".desktop";
        }

        public static void make_default_browser () {
            var info = new GLib.DesktopAppInfo (APP_ID + ".desktop");
            if (info == null) return;
            foreach (string type in new string[] { "x-scheme-handler/http", "x-scheme-handler/https", "text/html", "application/xhtml+xml" }) {
                try {
                    info.set_as_default_for_type (type);
                } catch (Error e) {
                    warning ("Default browser for %s: %s", type, e.message);
                }
            }
        }

        private Json.Object sync_session () throws Error {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("version");
            builder.add_int_value (1);
            builder.set_member_name ("windows");
            builder.begin_array ();
            foreach (var win in browser_windows ()) {
                if (!win.is_private && win.webapp == null) win.write_session (builder);
            }
            builder.end_array ();
            builder.end_object ();
            var object = builder.get_root ().get_object ();
            foreach (var window in object.get_array_member ("windows").get_elements ()) {
                foreach (var tile in window.get_object ().get_array_member ("tiles").get_elements ()) {
                    foreach (var tab in tile.get_object ().get_array_member ("tabs").get_elements ()) {
                        string url = tab.get_object ().get_string_member ("url");
                        if (Address.scheme_of (url) != "http" && Address.scheme_of (url) != "https")
                            tab.get_object ().set_string_member ("url", Address.NEW_TAB);
                    }
                }
            }
            return object;
        }

        private bool syncing = false;
        private VaultSync? synced_data = null;

        private async void open_synced_tabs (BrowserWindow win) {
            if (win.is_private || win.webapp != null) return;
            var sync = synced_data;
            if (sync == null) {
                win.add_toast (new Toast (_("Sync this profile first to find tabs from other devices")));
                return;
            }
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            foreach (var item in sync.items ()) {
                if (item.kind != "session" || item.versions.size != 1 || item.versions[0].deleted
                    || item.versions[0].writer == sync.keys.writer) continue;
                options.add (new Singularity.Core.AppSettingOption () { id = item.id, label = _("Device %s").printf (item.versions[0].writer.substring (0, 8)) });
            }
            if (options.is_empty) {
                win.add_toast (new Toast (_("No tabs from another enrolled device are available")));
                return;
            }
            var dialog = new ConfirmDialog (this, _("Open Synced Tabs"), "tab-new-symbolic",
                _("Open this device's saved web tabs in new windows. Local files and private tabs are excluded."),
                _("Open"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = win;
            dialog.modal = true;
            var group = new PreferencesGroup ();
            var row = new SelectionRow.with_options (_("Device"), options, options[0].id);
            group.add_row (row);
            dialog.custom_area.append (group);
            string selected = "";
            dialog.response.connect ((response) => {
                if (response == ConfirmDialog.Response.PRIMARY) selected = row.current_value;
                Idle.add (() => { open_synced_tabs.callback (); return Source.REMOVE; });
            });
            dialog.present ();
            yield;
            if (selected == "" || win.is_private) return;
            var item = sync.get_item (selected);
            if (item == null || item.versions.size != 1 || item.versions[0].deleted) return;
            var node = item.versions[0].payload;
            foreach (var window in node.get_object ().get_array_member ("windows").get_elements ()) {
                BrowserWindow? opened = null;
                foreach (var tile in window.get_object ().get_array_member ("tiles").get_elements ()) {
                    foreach (var tab in tile.get_object ().get_array_member ("tabs").get_elements ()) {
                        string url = tab.get_object ().get_string_member ("url");
                        if (Address.scheme_of (url) != "http" && Address.scheme_of (url) != "https") continue;
                        if (opened == null) opened = new_window (url, false);
                        else opened.add_tab (url);
                    }
                }
            }
        }


        private async void sync_code (BrowserWindow win, string title, string description, string code, string? fingerprint = null) throws Error {
            var dialog = new ConfirmDialog (this, title, "folder-remote-symbolic", description, _("Continue"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = win;
            dialog.modal = true;
            var view = new TextView ();
            view.editable = false;
            view.cursor_visible = false;
            view.monospace = true;
            view.wrap_mode = WrapMode.CHAR;
            view.buffer.text = code;
            var scroll = new ScrolledWindow ();
            scroll.min_content_height = 100;
            scroll.max_content_height = 160;
            scroll.min_content_width = 280;
            scroll.set_child (view);
            dialog.custom_area.append (scroll);
            if (fingerprint != null) {
                var label = new Label (_("Fingerprint: %s").printf (fingerprint));
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.CHAR;
                label.selectable = true;
                label.max_width_chars = 40;
                dialog.custom_area.append (label);
            }
            var copy = new Button.with_label (_("Copy Code"));
            copy.clicked.connect (() => win.get_clipboard ().set_text (code));
            dialog.custom_area.append (copy);
            bool accepted = false;
            dialog.response.connect ((response) => {
                accepted = response == ConfirmDialog.Response.PRIMARY;
                Idle.add (() => { sync_code.callback (); return Source.REMOVE; });
            });
            dialog.present ();
            yield;
            if (!accepted) throw new IOError.CANCELLED (_("Device setup canceled"));
        }

        private async string[] sync_input (BrowserWindow win, string title, string description, string first, string? second = null, bool secret = false) throws Error {
            var dialog = new ConfirmDialog (this, title, "folder-remote-symbolic", description, _("Continue"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = win;
            dialog.modal = true;
            var group = new PreferencesGroup ();
            EntryRow input = secret ? new PasswordRow (first) : new EntryRow (first);
            group.add_row (input);
            var trust = new EntryRow (second ?? "");
            if (second != null) group.add_row (trust);
            dialog.custom_area.append (group);
            string[] result = {};
            dialog.response.connect ((response) => {
                if (response == ConfirmDialog.Response.PRIMARY) result = { input.text.strip (), trust.text.strip () };
                Idle.add (() => { sync_input.callback (); return Source.REMOVE; });
            });
            dialog.present ();
            input.grab_focus ();
            yield;
            if (result.length == 0) throw new IOError.CANCELLED (_("Device setup canceled"));
            return result;
        }

        private async VaultSync setup_sync (BrowserWindow win, Accounts.Account account, Cancellable cancel) throws Error {
            services.main_profile.store.sync_ready ();
            var setup = new VaultEnrollment (account, services.main_profile);
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            options.add (new Singularity.Core.AppSettingOption () { id = "new", label = _("Create a New Dataset") });
            options.add (new Singularity.Core.AppSettingOption () { id = "pair", label = _("Pair with an Existing Device") });
            options.add (new Singularity.Core.AppSettingOption () { id = "recover", label = _("Use a Recovery Key") });
            var dialog = new ConfirmDialog (this, _("Set Up Browser Sync"), "folder-remote-symbolic",
                _("This profile has no authorized sync keys. Pair with your administrator device or use your saved recovery key to reopen existing data. Creating a new dataset keeps it separate."),
                _("Continue"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = win;
            dialog.modal = true;
            var group = new PreferencesGroup ();
            var row = new SelectionRow.with_options (_("Setup"), options, "pair");
            group.add_row (row);
            dialog.custom_area.append (group);
            string selected = "";
            dialog.response.connect ((response) => {
                if (response == ConfirmDialog.Response.PRIMARY) selected = row.current_value;
                Idle.add (() => { setup_sync.callback (); return Source.REMOVE; });
            });
            dialog.present ();
            yield;
            cancel.set_error_if_cancelled ();
            if (selected == "") throw new IOError.CANCELLED (_("Device setup canceled"));
            if (selected == "recover") {
                var entered = yield sync_input (win, _("Recover Browser Data"),
                    _("Use the independent recovery key you saved outside your account. Recovery creates a new device identity and rotates the encryption root before confirming success."), _("Recovery Key"), null, true);
                return yield setup.recover (entered[0], cancel);
            }
            if (selected == "pair") {
                string request;
                try { request = yield setup.request (false, cancel); }
                catch (IOError.TIMED_OUT e) {
                    var expired = new ConfirmDialog (this, _("Device Request Expired"), "folder-remote-symbolic",
                        _("Create a new request and compare its new fingerprint with your trusted device. Existing Browser data and the previous request keys are retained. An older approval cannot authorize this new request."),
                        _("Create New Request"), ConfirmDialog.ActionStyle.SUGGESTED);
                    expired.transient_for = win;
                    expired.modal = true;
                    bool renew = false;
                    expired.response.connect ((response) => {
                        renew = response == ConfirmDialog.Response.PRIMARY;
                        Idle.add (() => { setup_sync.callback (); return Source.REMOVE; });
                    });
                    expired.present ();
                    yield;
                    cancel.set_error_if_cancelled ();
                    if (!renew) throw new IOError.CANCELLED (_("Device request renewal canceled"));
                    request = yield setup.request (true, cancel);
                }
                yield sync_code (win, _("Request Device Approval"),
                    _("Copy this request to your trusted administrator device using File > Sync Devices. Compare this fingerprint on both devices before approval. The request expires after one hour and can be used once."),
                    request, setup.request_fingerprint (request));
                cancel.set_error_if_cancelled ();
                var entered = yield sync_input (win, _("Accept Device Approval"),
                    _("Paste the encrypted approval and the administrator fingerprint shown on your trusted device. Verify the fingerprint independently before accepting. The account cannot supply this trust for you."),
                    _("Approval Code"), _("Administrator Fingerprint"));
                return yield setup.accept (entered[0], entered[1], cancel);
            }
            if (selected != "new") throw new IOError.INVALID_ARGUMENT (_("Unknown Browser setup choice"));
            var drive = yield Accounts.CloudDrive.for_app_data (account, cancel);
            if (drive == null) throw new IOError.NOT_SUPPORTED (_("This account has no Browser app-data storage"));
            yield drive.list (drive.root_id, cancel);
            var sync = yield VaultSync.open (account, services.main_profile, true, true);
            var bridge = new VaultBridge (sync, services.main_profile);
            yield bridge.capture (sync_session ());
            yield sync.sync (cancel);
            string recovery = yield setup.recovery_code (sync, cancel);
            yield sync_code (win, _("Keep Your Recovery Key"),
                _("Store this key somewhere separate from this account and device. Anyone with it can recover your encrypted Browser data and approve devices. It is required if every enrolled device is lost."), recovery);
            return sync;
        }

        private async void sync_device_state (BrowserWindow win, VaultSync sync) throws Error {
            var roster = sync.ledger.roster ();
            var dialog = new ConfirmDialog (this, _("Enrolled Browser Devices"), "folder-remote-symbolic",
                _("These signing identities belong to the current authenticated roster. This device is %s. Roster revision: %s. Account access alone cannot authorize another device.")
                    .printf (sync.keys.authority == null ? _("a paired device") : _("an administrator"), roster.revision.to_string ()),
                _("Done"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = win;
            dialog.modal = true;
            var group = new PreferencesGroup ();
            var devices = new Gee.ArrayList<string> ();
            devices.add_all (roster.devices.keys);
            devices.sort ((a, b) => strcmp (a, b));
            foreach (string device in devices) {
                var row = new ActionRow (device == sync.keys.writer ? _("This Device") : _("Enrolled Device"));
                row.subtitle = device + "\n" + VaultEnrollment.fingerprint (roster.devices[device]);
                group.add_row (row);
            }
            var scroll = new ScrolledWindow ();
            scroll.min_content_width = 280;
            scroll.max_content_height = 240;
            scroll.propagate_natural_height = true;
            scroll.set_child (group);
            dialog.custom_area.append (scroll);
            var administrator = new Label (_("Administrator fingerprint: %s").printf (VaultEnrollment.fingerprint (sync.keys.administrator)));
            administrator.wrap = true;
            administrator.wrap_mode = Pango.WrapMode.CHAR;
            administrator.max_width_chars = 40;
            administrator.selectable = true;
            dialog.custom_area.append (administrator);
            dialog.response.connect ((response) => { Idle.add (() => { sync_device_state.callback (); return Source.REMOVE; }); });
            dialog.present ();
            yield;
        }

        private async void sync_devices (BrowserWindow win) {
            if (syncing || win.is_private || win.webapp != null) return;
            syncing = true;
            hold ();
            var cancel = new Cancellable ();
            ulong closed = win.close_request.connect (() => { cancel.cancel (); return false; });
            try {
                var manager = Accounts.Manager.get_default ();
                yield manager.load ();
                var options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
                foreach (var account in manager.get_accounts_for (Accounts.Capability.FILES)) {
                    if (account.healthy && (account.provider == "google" || account.provider == "microsoft" || account.provider == "nextcloud"))
                        options.add (new Singularity.Core.AppSettingOption () { id = account.id, label = account.display_name });
                }
                if (options.is_empty) throw new IOError.NOT_FOUND (_("Add an enabled sync account in Online Accounts first"));
                var dialog = new ConfirmDialog (this, _("Sync Devices"), "folder-remote-symbolic",
                    _("Inspect your enrolled devices, use an administrator to approve another device, or obtain your independent recovery key. Existing devices receive fresh roots only while they remain in the signed roster."),
                    _("Continue"), ConfirmDialog.ActionStyle.SUGGESTED);
                dialog.transient_for = win;
                dialog.modal = true;
                var group = new PreferencesGroup ();
                var account_row = new SelectionRow.with_options (_("Online Account"), options, options[0].id);
                group.add_row (account_row);
                var actions = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
                actions.add (new Singularity.Core.AppSettingOption () { id = "devices", label = _("Show Enrolled Devices") });
                actions.add (new Singularity.Core.AppSettingOption () { id = "approve", label = _("Approve a Device") });
                actions.add (new Singularity.Core.AppSettingOption () { id = "previous", label = _("Retrieve a Previous Approval") });
                actions.add (new Singularity.Core.AppSettingOption () { id = "recovery", label = _("Show Recovery Key") });
                var action_row = new SelectionRow.with_options (_("Action"), actions, "devices");
                group.add_row (action_row);
                dialog.custom_area.append (group);
                string account_id = "";
                string action = "";
                dialog.response.connect ((response) => {
                    if (response == ConfirmDialog.Response.PRIMARY) { account_id = account_row.current_value; action = action_row.current_value; }
                    Idle.add (() => { sync_devices.callback (); return Source.REMOVE; });
                });
                dialog.present ();
                yield;
                cancel.set_error_if_cancelled ();
                if (account_id == "") return;
                var account = manager.get_account (account_id);
                if (account == null) throw new IOError.NOT_FOUND (_("The sync account was removed"));
                var sync = yield VaultSync.open (account, services.main_profile);
                var setup = new VaultEnrollment (account, services.main_profile);
                yield setup.refresh (sync, cancel);
                var bridge = new VaultBridge (sync, services.main_profile);
                yield bridge.capture (sync_session ());
                yield sync.sync (cancel);
                if (action == "devices") {
                    yield sync_device_state (win, sync);
                } else if (action == "recovery") {
                    string recovery = yield setup.recovery_code (sync, cancel);
                    yield sync_code (win, _("Keep Your Recovery Key"), _("Keep this capability outside your account. Anyone with it can recover your Browser data and approve devices."), recovery);
                } else if (action == "approve" || action == "previous") {
                    var input = yield sync_input (win, action == "previous" ? _("Retrieve a Previous Approval") : _("Approve a Device"),
                        action == "previous" ? _("Use the original request and compare its fingerprint on the requesting device. The existing approval can be copied again only while its signed roster is current and its request has not expired.")
                            : _("Read the request fingerprint on the new device and compare it independently before authorizing. Approval rotates the root and publishes a complete snapshot for enrolled devices."),
                        _("Device Request"), _("Request Fingerprint"));
                    string approval = action == "previous" ? yield setup.previous_approval (sync, input[0], input[1], cancel)
                        : yield setup.approve (sync, input[0], input[1], cancel);
                    yield sync_code (win, _("Encrypted Device Approval"), _("Return this encrypted approval to the requesting device. Verify this administrator fingerprint there before accepting."), approval, VaultEnrollment.fingerprint (sync.keys.administrator));
                } else throw new IOError.INVALID_ARGUMENT (_("Unknown device setup action"));
                synced_data = sync;
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                if (!cancel.is_cancelled ()) {
                    var failed = new ConfirmDialog (this, _("Device Setup Needs Attention"), "dialog-warning-symbolic", e.message, _("Close"), ConfirmDialog.ActionStyle.SUGGESTED);
                    failed.transient_for = win;
                    failed.present ();
                }
            } finally { win.disconnect (closed); syncing = false; release (); }
        }

        private async void sync_browser (BrowserWindow win) {
            if (syncing || win.is_private || win.webapp != null) return;
            syncing = true;
            hold ();
            var cancel = new Cancellable ();
            ulong closed = win.close_request.connect (() => { cancel.cancel (); return false; });
            try {
                var manager = Accounts.Manager.get_default ();
                yield manager.load ();
                if (!manager.available) throw new IOError.NOT_CONNECTED (_("Online Accounts is unavailable"));
                var options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
                foreach (var account in manager.get_accounts_for (Accounts.Capability.FILES)) {
                    if (!account.healthy || (account.provider != "google" && account.provider != "microsoft" && account.provider != "nextcloud")) continue;
                    options.add (new Singularity.Core.AppSettingOption () { id = account.id, label = account.display_name });
                }
                if (options.is_empty) throw new IOError.NOT_FOUND (_("Add an enabled Google, Microsoft or Nextcloud account in Online Accounts first"));
                var dialog = new ConfirmDialog (this, _("Sync Browser Data"), "folder-remote-symbolic",
                    _("Encrypt this profile's history, bookmarks, saved logins and open tabs before sending them to your account. Keep this device's keyring to reopen the data."),
                    _("Sync"), ConfirmDialog.ActionStyle.SUGGESTED);
                dialog.transient_for = win;
                dialog.modal = true;
                var group = new PreferencesGroup ();
                var row = new SelectionRow.with_options (_("Online Account"), options, options[0].id);
                group.add_row (row);
                dialog.custom_area.append (group);
                string selected = "";
                dialog.response.connect ((response) => {
                    if (response == ConfirmDialog.Response.PRIMARY) selected = row.current_value;
                    Idle.add (() => { sync_browser.callback (); return Source.REMOVE; });
                });
                dialog.present ();
                yield;
                cancel.set_error_if_cancelled ();
                if (selected == "") return;
                var account = manager.get_account (selected);
                if (account == null) throw new IOError.NOT_FOUND (_("The account was removed"));
                win.add_toast (new Toast (_("Syncing encrypted browser data")));
                VaultSync sync;
                try { sync = yield VaultSync.open (account, services.main_profile, false, true); }
                catch (IOError.NOT_FOUND e) { sync = yield setup_sync (win, account, cancel); }
                yield new VaultEnrollment (account, services.main_profile).refresh (sync, cancel);
                var bridge = new VaultBridge (sync, services.main_profile);
                yield bridge.capture (sync_session ());
                yield sync.sync (cancel);
                cancel.set_error_if_cancelled ();
                yield bridge.capture (sync_session (), false);
                int changed = yield bridge.apply ();
                synced_data = sync;
                cancel.set_error_if_cancelled ();
                var done = new ConfirmDialog (this, _("Browser Data Synced"), "folder-remote-symbolic",
                    _("Encrypted changes were acknowledged by your account. %d received changes were applied. Other devices require enrollment before they can decrypt this dataset.").printf (changed),
                    _("Done"), ConfirmDialog.ActionStyle.SUGGESTED);
                done.transient_for = win;
                done.present ();
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                if (!cancel.is_cancelled ()) {
                    string detail = e.message;
                    if (e is Accounts.AccountsError.AUTH_FAILED || e is Accounts.AccountsError.NEEDS_REAUTH)
                        detail = _("Sign in again in Online Accounts to approve Browser app-data access. Your local data and pending encrypted changes were kept.");
                    var failure = new ConfirmDialog (this, _("Browser Sync Needs Attention"), "dialog-warning-symbolic",
                        detail, _("Close"), ConfirmDialog.ActionStyle.SUGGESTED);
                    failure.transient_for = win;
                    failure.present ();
                }
            } finally {
                win.disconnect (closed);
                syncing = false;
                release ();
            }
        }

        private string session_path () {
            return Path.build_filename (Environment.get_user_state_dir (), "singularity", "browser", "session.json");
        }

        private void queue_save () {
            if (webapp != null || save_source != 0) return;
            save_source = Timeout.add (400, () => {
                save_source = 0;
                save_session ();
                return Source.REMOVE;
            });
        }

        public void save_session () {
            if (!started || webapp != null) return;
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("version");
            builder.add_int_value (1);
            builder.set_member_name ("windows");
            builder.begin_array ();
            foreach (var win in browser_windows ()) {
                if (win.is_private || win.webapp != null) continue;
                win.write_session (builder);
            }
            builder.end_array ();
            builder.set_member_name ("closed");
            builder.begin_array ();
            foreach (var c in services.closed) {
                builder.begin_object ();
                builder.set_member_name ("url");
                builder.add_string_value (c.url);
                builder.set_member_name ("title");
                builder.add_string_value (c.title);
                builder.set_member_name ("pinned");
                builder.add_boolean_value (c.pinned);
                builder.end_object ();
            }
            builder.end_array ();
            builder.end_object ();
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            string path = session_path ();
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            try {
                FileUtils.set_contents_full (path, generator.to_data (null), -1,
                    FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.ONLY_EXISTING, 0600);
            } catch (Error e) {
                warning ("Session could not be saved: %s", e.message);
            }
        }

        private bool restore_session () {
            var parser = new Json.Parser ();
            try {
                parser.load_from_file (session_path ());
            } catch (Error e) {
                return false;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return false;
            var obj = root.get_object ();
            if (obj.has_member ("closed")) {
                var closed = obj.get_array_member ("closed");
                for (uint i = 0; i < closed.get_length (); i++) {
                    var c = closed.get_object_element (i);
                    if (c == null) continue;
                    services.closed.add (new ClosedTab (c.get_string_member_with_default ("url", ""),
                        c.get_string_member_with_default ("title", ""), c.get_boolean_member_with_default ("pinned", false)));
                }
                services.closed_changed ();
            }
            if (!obj.has_member ("windows")) return false;
            var windows = obj.get_array_member ("windows");
            bool any = false;
            for (uint i = 0; i < windows.get_length (); i++) {
                var w = windows.get_object_element (i);
                if (w == null) continue;
                var win = create_window (false);
                if (win.restore_session (w)) {
                    win.present ();
                    any = true;
                } else {
                    win.destroy ();
                }
            }
            return any;
        }

        private void queue_dock () {
            if (dock_source != 0) return;
            dock_source = Timeout.add (1500, () => {
                dock_source = 0;
                update_dock ();
                return Source.REMOVE;
            });
        }

        private void update_dock () {
            if (dock_menu == null) {
                dock_menu = new Singularity.DockMenu (APP_ID);
                dock_menu.activated.connect ((id) => {
                    if (id.has_prefix ("open:")) open_uri_from_outside (id.substring (5));
                });
            }
            dock_menu.clear ();
            int shown = 0;
            var seen = new Gee.HashSet<string> ();
            foreach (var entry in services.store.recent_history (40)) {
                string site = Address.site_key (entry.url);
                if (site == "" || seen.contains (site)) continue;
                seen.add (site);
                dock_menu.add_item ("open:" + entry.url, entry.title != "" ? entry.title : site, "web-browser-symbolic");
                if (++shown >= 6) break;
            }
            if (shown == 0) dock_menu.unpublish ();
            else dock_menu.publish ();
        }

        private void add_app_action (string name, owned Singularity.Widgets.Window.BubbleAction callback) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => callback ());
            add_action (action);
        }

        private void install_actions () {
            add_app_action ("new-window", () => new_window (null, false));
            add_app_action ("new-private-window", () => new_window (null, true));
            add_app_action ("quit", () => {
                save_session ();
                var windows = new Gee.ArrayList<Gtk.Window> ();
                foreach (var w in get_windows ()) windows.add (w);
                foreach (var w in windows) w.close ();
            });
            add_app_action ("settings", () => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings (APP_ID);
                } catch (Error e) {
                    warning ("Browser: settings unavailable: %s", e.message);
                }
            });
            add_app_action ("open-synced-tabs", () => {
                var win = get_active_window () as BrowserWindow;
                if (win != null) open_synced_tabs.begin (win);
            });
            add_app_action ("sync-devices", () => {
                var win = get_active_window () as BrowserWindow;
                if (win != null) sync_devices.begin (win);
            });
            add_app_action ("sync-browser", () => {
                var win = get_active_window () as BrowserWindow;
                if (win != null) sync_browser.begin (win);
            });
            add_app_action ("import-bookmarks", () => {
                var win = main_window ();
                if (win != null) win.open_library (Address.BOOKMARKS);
            });
            add_app_action ("import-passwords", () => {
                var win = get_active_window () as BrowserWindow ?? main_window ();
                if (win != null) pick_password_file (win);
            });
            add_app_action ("remove-webapp", () => {
                if (webapp == null) return;
                webapp.uninstall ();
                quit ();
            });
            var open_private = new SimpleAction ("open-private", VariantType.STRING);
            open_private.activate.connect ((p) => new_window (p.get_string (), true));
            add_action (open_private);
            var print_pdf = new SimpleAction ("print-to-pdf", VariantType.STRING);
            print_pdf.activate.connect ((p) => {
                var win = get_active_window () as BrowserWindow ?? main_window ();
                var tab = win != null ? win.current_tab () : null;
                var view = tab != null ? tab.printable_view () : null;
                if (view == null) return;
                string target = p.get_string ();
                hold ();
                PagePrinter.to_pdf.begin (view, target, null, (obj, res) => {
                    bool ok = PagePrinter.to_pdf.end (res);
                    if (win != null) win.add_toast (new Toast (ok ? _("Saved as PDF") : _("The page could not be saved as PDF")));
                    release ();
                });
            });
            add_action (print_pdf);
            var update_filters = new SimpleAction ("update-filters", null);
            update_filters.activate.connect (() => services.blocker.refresh.begin (true));
            add_action (update_filters);

            string[,] accels = {
                { "win.new-tab", "<Control>t" },
                { "win.close-tab", "<Control>w|<Control>F4" },
                { "win.reopen-tab", "<Control><Shift>t" },
                { "app.new-window", "<Control>n" },
                { "app.new-private-window", "<Control><Shift>p" },
                { "win.close", "<Control><Shift>w" },
                { "app.quit", "<Control>q" },
                { "win.reload", "<Control>r|F5" },
                { "win.reload-hard", "<Control><Shift>r|<Shift>F5" },
                { "win.back", "<Alt>Left|<Alt>KP_Left|Back" },
                { "win.forward", "<Alt>Right|<Alt>KP_Right|Forward" },
                { "win.focus-address", "<Control>l|<Alt>d|F6" },
                { "win.search-web", "<Control>k|<Control>e" },
                { "win.find", "<Control>f" },
                { "win.find-next", "<Control>g|F3" },
                { "win.find-previous", "<Control><Shift>g|<Shift>F3" },
                { "win.zoom-in", "<Control>plus|<Control>equal|<Control>KP_Add" },
                { "win.zoom-out", "<Control>minus|<Control>KP_Subtract" },
                { "win.zoom-reset", "<Control>0|<Control>KP_0" },
                { "win.bookmark", "<Control>d" },
                { "win.show-bookmarks", "<Control><Shift>o" },
                { "win.show-history", "<Control>h" },
                { "win.show-downloads", "<Control><Shift>y" },
                { "win.reader", "<Control><Alt>r" },
                { "win.reading-mode", "<Control><Shift>F11" },
                { "win.fullscreen", "F11" },
                { "win.print", "<Control>p" },
                { "win.sketch", "<Control><Alt>d" },
                { "win.devtools", "<Control><Shift>i|F12" },
                { "win.search-tabs", "<Control><Shift>a" },
                { "win.new-tile", "<Control><Shift>n" },
                { "win.split-right", "<Control><Alt>backslash" },
                { "win.split-down", "<Control><Alt>minus" },
                { "win.close-tile", "<Control><Alt>w" },
                { "win.detach-tile", "<Control><Shift>d" },
                { "win.focus-left", "<Control><Alt>Left" },
                { "win.focus-right", "<Control><Alt>Right" },
                { "win.focus-up", "<Control><Alt>Up" },
                { "win.focus-down", "<Control><Alt>Down" },
                { "win.move-left", "<Control><Alt><Shift>Left" },
                { "win.move-right", "<Control><Alt><Shift>Right" },
                { "win.move-up", "<Control><Alt><Shift>Up" },
                { "win.move-down", "<Control><Alt><Shift>Down" },
                { "win.mute-tab", "<Control>m" },
                { "win.fill-password", "<Control><Shift>l" },
                { "app.settings", "<Control>comma" }
            };
            for (int i = 0; i < accels.length[0]; i++)
                set_accels_for_action (accels[i, 0], accels[i, 1].split ("|"));
            for (int n = 1; n <= 9; n++)
                set_accels_for_action ("win.select-tab(%d)".printf (n), { "<Control>%d".printf (n), "<Alt>%d".printf (n) });
        }

        private void sync_closed_menu () {
            if (closed_section == null) return;
            closed_section.remove_all ();
            if (services.closed.is_empty) return;
            var recent = new GLib.Menu ();
            int shown = 0;
            foreach (var item in services.closed) {
                var entry = new GLib.MenuItem (item.title != "" ? item.title : Address.display (item.url), null);
                entry.set_action_and_target_value ("win.reopen-closed", new Variant.int32 (shown));
                recent.append_item (entry);
                if (++shown >= 10) break;
            }
            closed_section.append_submenu (_("Recently Closed"), recent);
        }

        private void build_menu () {
            var menu = new GLib.Menu ();

            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            if (webapp == null) {
                f1.append (_("New Tab"), "win.new-tab");
                f1.append (_("New Window"), "app.new-window");
                f1.append (_("New Private Window"), "app.new-private-window");
            }
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Print…"), "win.print");
            f2.append (_("Share…"), "win.share");
            if (webapp == null) f2.append (_("Install as Web App…"), "win.install-webapp");
            if (webapp == null) {
                f2.append (_("Import Passwords…"), "app.import-passwords");
                f2.append (_("Sync Browser Data"), "app.sync-browser");
                f2.append (_("Sync Devices"), "app.sync-devices");
                f2.append (_("Open Synced Tabs"), "app.open-synced-tabs");
            }
            file.append_section (null, f2);
            var f3 = new GLib.Menu ();
            if (webapp == null) {
                f3.append (_("Close Tab"), "win.close-tab");
                f3.append (_("Close Window"), "win.close");
            } else {
                f3.append (_("Remove Web App"), "app.remove-webapp");
            }
            f3.append (_("Quit"), "app.quit");
            file.append_section (null, f3);
            menu.append_submenu (_("File"), file);

            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Find in Page…"), "win.find");
            e1.append (_("Find Next"), "win.find-next");
            e1.append (_("Find Previous"), "win.find-previous");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Fill Saved Password"), "win.fill-password");
            e2.append (_("Settings"), "app.settings");
            edit.append_section (null, e2);
            menu.append_submenu (_("Edit"), edit);

            var view = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Reload"), "win.reload");
            v1.append (_("Reader View"), "win.reader");
            v1.append (_("Sketch on This Page"), "win.sketch");
            v1.append (_("Reading Mode"), "win.reading-mode");
            v1.append (_("Full Screen"), "win.fullscreen");
            view.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Zoom In"), "win.zoom-in");
            v2.append (_("Zoom Out"), "win.zoom-out");
            v2.append (_("Actual Size"), "win.zoom-reset");
            view.append_section (null, v2);
            if (webapp == null) {
                var v3 = new GLib.Menu ();
                v3.append (_("Vertical Tabs"), "win.vertical-tabs");
                view.append_section (null, v3);
            }
            var v4 = new GLib.Menu ();
            v4.append (_("Developer Tools"), "win.devtools");
            view.append_section (null, v4);
            menu.append_submenu (_("View"), view);

            var history = new GLib.Menu ();
            var h1 = new GLib.Menu ();
            h1.append (_("Back"), "win.back");
            h1.append (_("Forward"), "win.forward");
            history.append_section (null, h1);
            if (webapp == null) {
                var h2 = new GLib.Menu ();
                h2.append (_("Show History"), "win.show-history");
                h2.append (_("Reopen Closed Tab"), "win.reopen-tab");
                history.append_section (null, h2);
                closed_section = new GLib.Menu ();
                history.append_section (null, closed_section);
                services.closed_changed.connect (sync_closed_menu);
                sync_closed_menu ();
            }
            menu.append_submenu (_("History"), history);

            if (webapp == null) {
                var bookmarks = new GLib.Menu ();
                bookmarks.append (_("Bookmark This Page…"), "win.bookmark");
                bookmarks.append (_("Show Bookmarks"), "win.show-bookmarks");
                bookmarks.append (_("Import Bookmarks…"), "app.import-bookmarks");
                menu.append_submenu (_("Bookmarks"), bookmarks);

                var tabs = new GLib.Menu ();
                var t1 = new GLib.Menu ();
                t1.append (_("Search Tabs…"), "win.search-tabs");
                t1.append (_("Pin Tab"), "win.pin-tab");
                t1.append (_("Add Tab to New Group"), "win.group-tab");
                t1.append (_("Mute Tab"), "win.mute-tab");
                tabs.append_section (null, t1);
                var t2 = new GLib.Menu ();
                t2.append (_("New Tile"), "win.new-tile");
                t2.append (_("Split Right"), "win.split-right");
                t2.append (_("Split Down"), "win.split-down");
                t2.append (_("Move Tile to New Window"), "win.detach-tile");
                t2.append (_("Close Tile"), "win.close-tile");
                tabs.append_section (null, t2);
                var t3 = new GLib.Menu ();
                t3.append (_("Show Downloads"), "win.show-downloads");
                tabs.append_section (null, t3);
                menu.append_submenu (_("Window"), tabs);
            }
            set_menubar (menu);
        }
    }
}
