namespace Singularity.Apps.Browser.Util {

    public string bytes_to_string (Bytes bytes) {
        unowned uint8[] data = bytes.get_data ();
        var copy = new uint8[data.length + 1];
        Memory.copy (copy, data, data.length);
        copy[data.length] = 0;
        return (string) copy;
    }

    public string escape_html (string text) {
        return Markup.escape_text (text);
    }

    public string unique_path (string dir, string name) {
        string clean = name.replace ("/", "_").strip ();
        if (clean == "" || clean == "." || clean == "..") clean = "download";
        string path = Path.build_filename (dir, clean);
        if (!FileUtils.test (path, FileTest.EXISTS)) return path;
        string stem = clean;
        string ext = "";
        int dot = clean.last_index_of_char ('.');
        if (dot > 0) {
            stem = clean.substring (0, dot);
            ext = clean.substring (dot);
            if (stem.has_suffix (".tar")) {
                ext = ".tar" + ext;
                stem = stem.substring (0, stem.length - 4);
            }
        }
        for (int i = 2; i < 10000; i++) {
            path = Path.build_filename (dir, "%s (%d)%s".printf (stem, i, ext));
            if (!FileUtils.test (path, FileTest.EXISTS)) return path;
        }
        return Path.build_filename (dir, "%s-%s%s".printf (stem, Uuid.string_random ().substring (0, 8), ext));
    }

    public string downloads_dir () {
        string? dir = Environment.get_user_special_dir (UserDirectory.DOWNLOAD);
        if (dir == null || dir == Environment.get_home_dir ())
            dir = Path.build_filename (Environment.get_home_dir (), "Downloads");
        DirUtils.create_with_parents (dir, 0755);
        return dir;
    }

    public string format_size (int64 bytes) {
        return GLib.format_size ((uint64) int64.max (0, bytes));
    }

    public Gdk.RGBA rgba (string spec) {
        var color = Gdk.RGBA ();
        color.parse (spec);
        return color;
    }
}
