namespace Singularity.Apps.Browser {

    public class Automation : Object {
        public static bool requested = false;
        public static bool hidden = false;

        private unowned BrowserApp app;
        private BrowserWindow? window = null;

        public static void parse (string[] args) {
            foreach (string a in args) {
                if (a == "--automation") requested = true;
                else if (a == "--automation-hidden") hidden = true;
            }
            string? env = Environment.get_variable ("FOTONE_AUTOMATION_HIDDEN");
            if (env != null && env != "" && env != "0") hidden = true;
            if (hidden) Environment.set_variable ("FOTONE_AUTOMATION_HIDDEN", "1", true);
        }

        public Automation (BrowserApp app, Profile profile) {
            this.app = app;
            profile.context.automation_started.connect (started);
        }

        private void started (WebKit.AutomationSession session) {
            var info = new WebKit.ApplicationInfo ();
            info.set_name ("Singularity Browser");
            string[] parts = Config.VERSION.split (".");
            info.set_version ((uint64) int.parse (parts[0]), parts.length > 1 ? (uint64) int.parse (parts[1]) : 0,
                              parts.length > 2 ? (uint64) int.parse (parts[2]) : 0);
            session.set_application_info (info);
            session.create_web_view.connect (create_view);
        }

        private unowned WebKit.WebView create_view () {
            if (window == null || !window.visible) {
                window = app.create_window (false);
                window.present ();
            }
            var tab = window.add_automation_tab ();
            return tab.view;
        }
    }
}
