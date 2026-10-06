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

        WebAppInfo? webapp = null;
        for (int i = 1; i < args.length - 1; i++) {
            if (args[i] == "--webapp") {
                webapp = WebAppInfo.load (args[i + 1]);
                if (webapp == null) {
                    printerr ("Unknown web app: %s\n", args[i + 1]);
                    return 1;
                }
            }
        }
        var app = new BrowserApp (webapp);
        if (webapp == null) new BrowserSearchProvider (app).export (app);
        return app.run (args);
    }
}
