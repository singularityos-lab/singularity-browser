namespace Singularity.Apps.Browser {

    public class ClosedTab : Object {
        public string url;
        public string title;
        public bool pinned;

        public ClosedTab (string url, string title, bool pinned) {
            this.url = url;
            this.title = title;
            this.pinned = pinned;
        }
    }

    public class Services : Object {
        public GLib.Settings settings { get; construct; }
        public Store store { get; private set; }
        public ContentBlocker blocker { get; private set; }
        public Downloads downloads { get; private set; }
        public Profile main_profile { get; private set; }
        public Gee.ArrayList<ClosedTab> closed = new Gee.ArrayList<ClosedTab> ();

        private Profile? _private_profile = null;
        private int private_users = 0;

        public signal void closed_changed ();

        public Services (GLib.Settings settings, string profile_id = "default") {
            Object (settings: settings);
            string dir = Path.build_filename (Environment.get_user_data_dir (), "singularity", "browser");
            if (profile_id != "default") dir = Path.build_filename (dir, "profiles", profile_id);
            store = new Store (Path.build_filename (dir, "browser.db"));
            blocker = new ContentBlocker (settings);
            downloads = new Downloads (store);
            main_profile = new Profile (profile_id, false, store, settings);
            downloads.watch (main_profile.session);
        }

        public Profile acquire_private () {
            if (_private_profile == null) {
                _private_profile = new Profile ("private", true, store, settings);
                downloads.watch (_private_profile.session, false);
            }
            private_users++;
            return _private_profile;
        }

        public void release_private () {
            if (private_users > 0) private_users--;
            if (private_users == 0) _private_profile = null;
        }

        public SearchEngine engine () {
            return SearchEngine.lookup (settings.get_string ("search-engine"),
                                        settings.get_string ("custom-search-url"),
                                        settings.get_string ("custom-suggest-url"));
        }

        public void remember_closed (string url, string title, bool pinned) {
            if (url == "" || url == Address.NEW_TAB) return;
            closed.insert (0, new ClosedTab (url, title, pinned));
            while (closed.size > 25) closed.remove_at (closed.size - 1);
            closed_changed ();
        }

        public ClosedTab? pop_closed () {
            if (closed.is_empty) return null;
            var tab = closed.remove_at (0);
            closed_changed ();
            return tab;
        }

        public static string accent_hex () {
            string hex = Singularity.Style.StyleManager.get_default ().accent_hex;
            return hex != null && hex != "" ? hex : "#3584e4";
        }
    }
}
