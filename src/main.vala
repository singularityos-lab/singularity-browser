namespace Singularity.Apps.Browser.Config {
    public const string VERSION = "0.1.0";
}

namespace Singularity.Apps.Browser {

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-browser", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-browser", "UTF-8");
        Intl.textdomain ("singularity-browser");

        if (args.length >= 5 && args[1] == "--install-webapp") {
            string? ff = args.length >= 6 ? args[5] : null;
            string? icon_hint = args.length >= 7 ? args[6] : null;
            int status = 0;
            var loop = new MainLoop ();
            WebApps.install_headless.begin (args[2], args[3], args[4], ff, icon_hint, (obj, res) => {
                try {
                    WebApps.install_headless.end (res);
                } catch (Error e) {
                    printerr ("%s\n", e.message);
                    status = 1;
                }
                loop.quit ();
            });
            loop.run ();
            return status;
        }
        if (args.length >= 3 && args[1] == "--uninstall-webapp") {
            var info = WebAppInfo.load (args[2]);
            if (info == null) return 1;
            info.uninstall ();
            return 0;
        }
        WebAppInfo? webapp = null;
        for (int i = 1; i < args.length - 1; i++) {
            if (args[i] == "--webapp") {
                webapp = WebAppInfo.load (args[i + 1]);
                if (webapp == null) {
                    printerr ("Unknown web app: %s\n", args[i + 1]);
                    return 1;
                }
                webapp.accept_links ();
            }
        }
        Automation.parse (args);
        if (webapp == null && !Automation.requested) DevTools.prepare ();
        var app = new BrowserApp (webapp);
        if (webapp == null && !Automation.requested) new BrowserSearchProvider (app).export (app);
        return app.run (args);
    }
}
