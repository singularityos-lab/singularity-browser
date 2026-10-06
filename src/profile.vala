namespace Singularity.Apps.Browser {

    public class Profile : Object {
        public string id { get; construct; }
        public bool ephemeral { get; construct; }
        public WebKit.NetworkSession session { get; private set; }
        public WebKit.WebContext context { get; private set; }
        public WebKit.Settings web_settings { get; private set; }
        public Store store { get; construct; }
        public string data_dir { get; private set; }

        private HashTable<string, string> overlay = new HashTable<string, string> (str_hash, str_equal);

        public signal void site_changed (string site, string key);

        public Profile (string id, bool ephemeral, Store store, GLib.Settings settings) {
            Object (id: id, ephemeral: ephemeral, store: store);
            string base_dir = Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser");
            string cache_dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity", "browser");
            if (id != "default") {
                base_dir = Path.build_filename (base_dir, "profiles", id);
                cache_dir = Path.build_filename (cache_dir, "profiles", id);
            }
            data_dir = base_dir;
            if (ephemeral) {
                session = new WebKit.NetworkSession.ephemeral ();
            } else {
                DirUtils.create_with_parents (base_dir, 0700);
                DirUtils.create_with_parents (cache_dir, 0700);
                session = new WebKit.NetworkSession (Path.build_filename (base_dir, "website-data"),
                                                     Path.build_filename (cache_dir, "website-data"));
                session.set_persistent_credential_storage_enabled (false);
                var cookies = session.get_cookie_manager ();
                cookies.set_persistent_storage (Path.build_filename (base_dir, "cookies.sqlite"), WebKit.CookiePersistentStorage.SQLITE);
            }
            session.get_cookie_manager ().set_accept_policy (WebKit.CookieAcceptPolicy.NO_THIRD_PARTY);
            session.get_website_data_manager ().set_favicons_enabled (true);
            session.set_itp_enabled (true);

            context = new WebKit.WebContext ();
            context.set_cache_model (WebKit.CacheModel.WEB_BROWSER);
            context.set_spell_checking_enabled (true);
            context.initialize_notification_permissions.connect (() => {
                var allowed = new List<WebKit.SecurityOrigin> ();
                var denied = new List<WebKit.SecurityOrigin> ();
                foreach (string site in store.sites_with ("notifications", "allow"))
                    allowed.append (new WebKit.SecurityOrigin.for_uri ("https://" + site));
                foreach (string site in store.sites_with ("notifications", "block"))
                    denied.append (new WebKit.SecurityOrigin.for_uri ("https://" + site));
                context.init_notification_permissions (allowed, denied);
            });

            web_settings = new WebKit.Settings ();
            web_settings.enable_media_stream = true;
            web_settings.enable_webrtc = true;
            web_settings.enable_back_forward_navigation_gestures = true;
            web_settings.enable_smooth_scrolling = true;
            web_settings.javascript_can_open_windows_automatically = true;
            web_settings.enable_encrypted_media = true;
            web_settings.enable_webaudio = true;
            web_settings.set_user_agent_with_application_details ("Singularity", Config.VERSION);
            settings.bind ("developer-tools", web_settings, "enable-developer-extras", SettingsBindFlags.GET);
        }

        public string? site_value (string site, string key) {
            if (site == "") return null;
            string? local = overlay[site + "\n" + key];
            if (local != null) return local;
            return store.get_site (site, key);
        }

        public void set_site_value (string site, string key, string? value) {
            if (site == "") return;
            if (ephemeral) {
                if (value == null) overlay.remove (site + "\n" + key);
                else overlay[site + "\n" + key] = value;
            } else {
                store.set_site (site, key, value);
            }
            site_changed (site, key);
        }

        public void record_visit (string url, string title) {
            if (!ephemeral) store.add_visit (url, title);
        }

        public void record_title (string url, string title) {
            if (!ephemeral) store.set_title (url, title);
        }

        public WebKit.FaviconDatabase? favicons () {
            return session.get_website_data_manager ().get_favicon_database ();
        }
    }
}
