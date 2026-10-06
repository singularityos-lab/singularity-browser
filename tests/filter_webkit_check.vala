using Singularity.Apps.Browser;

int main (string[] args) {
    string list_path = args.length > 1 ? args[1] : Path.build_filename (Environment.get_variable ("BROWSER_FIXTURES") ?? "tests/fixtures", "filters.txt");
    string text;
    try {
        FileUtils.get_contents (list_path, out text);
    } catch (Error e) {
        printerr ("%s\n", e.message);
        return 1;
    }
    var compiler = new FilterCompiler ();
    compiler.add_list (text);
    string json = compiler.to_json ();
    print ("lines %d, blocking %d, hiding %d, exceptions %d, skipped %d, rules %d, json %d bytes\n",
           compiler.stats.lines, compiler.stats.blocking, compiler.stats.hiding, compiler.stats.exceptions,
           compiler.stats.skipped, compiler.rule_count, json.length);
    string dir;
    try {
        dir = DirUtils.make_tmp ("filter-store-XXXXXX");
    } catch (Error e) {
        printerr ("%s\n", e.message);
        return 1;
    }
    var store = new WebKit.UserContentFilterStore (dir);
    var loop = new MainLoop ();
    int status = 0;
    int64 started = get_monotonic_time ();
    store.save.begin ("check", new Bytes (json.data), null, (obj, res) => {
        try {
            store.save.end (res);
            print ("WebKit compiled the list in %lld ms\n", (get_monotonic_time () - started) / 1000);
        } catch (Error e) {
            printerr ("WebKit rejected the list: %s\n", e.message);
            status = 1;
        }
        store.remove.begin ("check", null, (o, r) => {
            try {
                store.remove.end (r);
            } catch (Error e) {
            }
            loop.quit ();
        });
    });
    loop.run ();
    DirUtils.remove (dir);
    return status;
}
