using Singularity.Apps.Browser;

string fixtures;

string fixture (string name) {
    return Path.build_filename (fixtures, name);
}

string temp_dir () {
    try {
        return DirUtils.make_tmp ("browser-test-XXXXXX");
    } catch (Error e) {
        error ("tmp: %s", e.message);
    }
}

void remove_tree (string path) {
    var dir = Dir.open (path);
    string? name;
    while ((name = dir.read_name ()) != null) {
        string child = Path.build_filename (path, name);
        if (FileUtils.test (child, FileTest.IS_DIR) && !FileUtils.test (child, FileTest.IS_SYMLINK)) remove_tree (child);
        else FileUtils.unlink (child);
    }
    DirUtils.remove (path);
}

void test_classify () {
    assert (Address.classify ("") == AddressKind.EMPTY);
    assert (Address.classify ("   ") == AddressKind.EMPTY);
    assert (Address.classify ("hello world") == AddressKind.SEARCH);
    assert (Address.classify ("singularity") == AddressKind.SEARCH);
    assert (Address.classify ("example.com") == AddressKind.URL);
    assert (Address.classify ("sub.example.co.uk/path?q=1") == AddressKind.URL);
    assert (Address.classify ("https://example.com") == AddressKind.URL);
    assert (Address.classify ("localhost") == AddressKind.URL);
    assert (Address.classify ("localhost:8080/api") == AddressKind.URL);
    assert (Address.classify ("192.168.1.10") == AddressKind.URL);
    assert (Address.classify ("10.0.0.1:3000") == AddressKind.URL);
    assert (Address.classify ("[::1]:8080") == AddressKind.URL);
    assert (Address.classify ("/tmp/page.html") == AddressKind.URL);
    assert (Address.classify ("~/page.html") == AddressKind.URL);
    assert (Address.classify ("about:history") == AddressKind.INTERNAL);
    assert (Address.classify ("?example.com") == AddressKind.SEARCH);
    assert (Address.classify ("version 1.2") == AddressKind.SEARCH);
    assert (Address.classify ("readme.md") == AddressKind.URL);
    assert (Address.classify ("file.v2") == AddressKind.SEARCH);
    assert (Address.classify ("readme.1") == AddressKind.SEARCH);
    assert (Address.classify ("999.1.1.1") == AddressKind.SEARCH);
    assert (Address.classify ("-bad-.com") == AddressKind.SEARCH);
    assert (Address.classify ("define:singularity") == AddressKind.SEARCH);
}

void test_normalize () {
    var ddg = SearchEngine.lookup ("duckduckgo");
    assert (Address.normalize ("example.com", ddg) == "https://example.com");
    assert (Address.normalize ("  example.com/a b ", ddg) != "https://example.com/a b");
    assert (Address.normalize ("localhost:8000/x", ddg) == "http://localhost:8000/x");
    assert (Address.normalize ("127.0.0.1", ddg) == "http://127.0.0.1");
    assert (Address.normalize ("printer.local", ddg) == "http://printer.local");
    assert (Address.normalize ("app.test:81", ddg) == "http://app.test:81");
    assert (Address.normalize ("http://example.com/x", ddg) == "http://example.com/x");
    assert (Address.normalize ("hello world", ddg) == "https://duckduckgo.com/?q=hello%20world");
    assert (Address.normalize ("?example.com", ddg) == "https://duckduckgo.com/?q=example.com");
    assert (Address.normalize ("c++ & rust", ddg) == "https://duckduckgo.com/?q=c%2B%2B%20%26%20rust");
    assert (Address.normalize ("About:History", ddg) == "about:history");
    assert (Address.normalize ("/tmp/a b.html", ddg) == "file:///tmp/a%20b.html");
    assert (Address.normalize ("", ddg) == null);
    var custom = SearchEngine.lookup ("custom", "http://127.0.0.1:9/search?q=%s", "http://127.0.0.1:9/s?q=%s");
    assert (custom.id == "custom");
    assert (custom.url_for ("a b") == "http://127.0.0.1:9/search?q=a%20b");
    assert (custom.suggestions_for ("x") == "http://127.0.0.1:9/s?q=x");
    assert (SearchEngine.lookup ("custom", "no placeholder").id == "duckduckgo");
    assert (SearchEngine.lookup ("unknown").id == "duckduckgo");
}

void test_uri_helpers () {
    assert (Address.origin_of ("https://Example.com:443/a?b") == "https://example.com");
    assert (Address.origin_of ("http://localhost:8080/x") == "http://localhost:8080");
    assert (Address.origin_of ("about:blank") == null);
    assert (Address.site_key ("https://www.example.com/") == "example.com");
    assert (Address.site_key ("https://docs.example.com/") == "docs.example.com");
    assert (Address.display ("https://www.example.com/deep/path") == "example.com");
    assert (Address.display ("about:newtab") == "");
    assert (Address.full_display ("https://www.example.com/") == "example.com");
    assert (Address.full_display ("https://example.com/a%20b") == "example.com/a b");
    assert (Address.is_secure ("https://x.org"));
    assert (Address.is_secure ("http://localhost:1/"));
    assert (!Address.is_secure ("http://x.org"));
    assert (Address.is_ipv4 ("1.2.3.4"));
    assert (!Address.is_ipv4 ("1.2.3.256"));
    var s = Address.parse_suggestions ("[\"q\",[\"alpha\",\"beta\"]]");
    assert (s.length == 2 && s[0] == "alpha" && s[1] == "beta");
    var p = Address.parse_suggestions ("[{\"phrase\":\"gamma\"},{\"phrase\":\"delta\"}]");
    assert (p.length == 2 && p[1] == "delta");
    assert (Address.parse_suggestions ("not json").length == 0);
}

void test_store_downloads () {
    string dir = temp_dir ();
    string path = Path.build_filename (dir, "d.db");
    var store = new Store (path);
    int64 first = store.add_download ("a.pdf", "/downloads/a.pdf", "https://example.com/a.pdf", 1200, "done");
    int64 second = store.add_download ("b.zip", "/downloads/b.zip", "https://example.com/b.zip", 0, "failed", "Network error");
    store.add_download ("c.iso", "/downloads/c.iso", "", 0, "cancelled");
    assert (first > 0 && second > first);
    var reopened = new Store (path);
    var saved = reopened.downloads ();
    assert (saved.length == 3);
    assert (saved[0].name == "c.iso" && saved[0].state == "cancelled");
    assert (saved[1].error == "Network error" && saved[1].source == "https://example.com/b.zip");
    assert (saved[2].id == first && saved[2].size == 1200 && saved[2].destination == "/downloads/a.pdf");
    assert (saved[2].finished > 0);
    reopened.remove_download (second);
    assert (new Store (path).downloads ().length == 2);
    for (int i = 0; i < Store.DOWNLOADS_KEPT + 5; i++)
        reopened.add_download ("f%d".printf (i), "/downloads/f%d".printf (i), "", 1, "done");
    var trimmed = reopened.downloads ();
    assert (trimmed.length == Store.DOWNLOADS_KEPT);
    assert (trimmed[0].name == "f%d".printf (Store.DOWNLOADS_KEPT + 4));
    var memory = new Store (null);
    assert (memory.downloads ().length == 0);
    remove_tree (dir);
}

void test_store () {
    string dir = temp_dir ();
    var store = new Store (Path.build_filename (dir, "b.db"));
    store.add_visit ("https://example.com/a", "Example A");
    store.add_visit ("https://example.com/a", "");
    store.add_visit ("https://www.example.com/b", "Example B");
    store.add_visit ("https://other.org/", "Other");
    store.add_visit ("about:newtab", "ignored");
    store.add_visit ("javascript:alert(1)", "ignored");
    var found = store.search_history ("example", 10);
    assert (found.length == 2);
    assert (found[0].title == "Example A" && found[0].visits == 2);
    assert (store.search_history ("100%", 10).length == 0);
    assert (store.search_history ("oth", 10)[0].url == "https://other.org/");
    var top = store.top_sites (8);
    assert (top.length == 2);
    assert (top[0].url == "https://example.com/a");
    store.set_title ("https://other.org/", "Other Site");
    assert (store.search_history ("Other Site", 1).length == 1);
    store.remove_history ("https://other.org/");
    assert (store.recent_history (10).length == 2);

    int64 folder = store.add_folder (Store.ROOT, "Work");
    int64 sub = store.add_folder (folder, "Deep");
    int64 b1 = store.add_bookmark (folder, "Docs", "https://docs.example.com/");
    store.add_bookmark (sub, "Deeper", "https://deep.example.com/");
    store.add_bookmark (Store.ROOT, "Home", "https://home.example.com/");
    assert (store.children (folder).length == 2);
    assert (store.count_bookmarks () == 3);
    assert (store.bookmark_for_url ("https://docs.example.com/").id == b1);
    assert (store.search_bookmarks ("deep", 5).length == 1);
    assert (store.folders ().length == 2);
    store.update_bookmark (b1, "Documentation", "https://docs.example.com/", Store.ROOT);
    assert (store.bookmark (b1).parent == Store.ROOT);
    store.remove_bookmark (folder);
    assert (store.count_bookmarks () == 2);
    assert (store.folders ().length == 0);

    store.set_site ("example.com", "camera", "allow");
    store.set_site ("example.com", "zoom", "1.25");
    store.set_site ("other.org", "camera", "block");
    assert (store.get_site ("example.com", "camera") == "allow");
    assert (store.sites_with ("camera", "block")[0] == "other.org");
    store.set_site ("example.com", "camera", null);
    assert (store.get_site ("example.com", "camera") == null);
    assert (store.get_site ("", "camera") == null);
    store.clear_history ();
    assert (store.recent_history (10).length == 0);
    store = null;
    remove_tree (dir);
}

void make_places (string path) {
    Sqlite.Database db;
    Sqlite.Database.open_v2 (path, out db, Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE);
    string sql = """
CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT);
CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
INSERT INTO moz_places VALUES (1, 'https://www.mozilla.org/'), (2, 'https://example.com/fx'), (3, 'place:sort=8'), (4, 'https://tagged.example/');
INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________');
INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'menu', 'menu________');
INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____');
INSERT INTO moz_bookmarks VALUES (4, 2, NULL, 1, 2, 'tags', 'tags________');
INSERT INTO moz_bookmarks VALUES (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____');
INSERT INTO moz_bookmarks VALUES (6, 1, 1, 3, 0, 'Mozilla', 'aaaaaaaaaaaa');
INSERT INTO moz_bookmarks VALUES (7, 2, NULL, 3, 1, 'Projects', 'bbbbbbbbbbbb');
INSERT INTO moz_bookmarks VALUES (8, 1, 2, 7, 0, 'Example FX', 'cccccccccccc');
INSERT INTO moz_bookmarks VALUES (9, 1, 3, 2, 0, 'Smart Folder', 'dddddddddddd');
INSERT INTO moz_bookmarks VALUES (10, 1, 4, 4, 0, 'Tag entry', 'eeeeeeeeeeee');
""";
    string errmsg;
    if (db.exec (sql, null, out errmsg) != Sqlite.OK) error ("places: %s", errmsg);
}

void test_import_firefox () {
    string dir = temp_dir ();
    string root = Path.build_filename (dir, ".mozilla", "firefox");
    string profile = Path.build_filename (root, "abcd.default-release");
    DirUtils.create_with_parents (profile, 0700);
    make_places (Path.build_filename (profile, "places.sqlite"));
    try {
        FileUtils.set_contents (Path.build_filename (root, "profiles.ini"),
            "[Profile0]\nName=default-release\nIsRelative=1\nPath=abcd.default-release\nDefault=1\n\n[General]\nStartWithLastProfile=1\n");
    } catch (Error e) {
        error ("%s", e.message);
    }
    var sources = BookmarkImport.detect (dir);
    assert (sources.length == 1);
    assert (sources[0].firefox && sources[0].name == "Firefox");
    ImportedBookmark tree;
    try {
        tree = sources[0].read ();
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert (tree.count () == 2);
    var toolbar = tree.children[1];
    assert (toolbar.is_folder && toolbar.children.size == 2);
    assert (toolbar.children[0].url == "https://www.mozilla.org/");
    assert (toolbar.children[1].title == "Projects" && toolbar.children[1].children[0].url == "https://example.com/fx");
    var store = new Store (null);
    int64 folder = store.add_folder (Store.ROOT, "Imported");
    assert (store.import_tree (tree, folder) == 2);
    assert (store.bookmark_for_url ("https://example.com/fx") != null);
    assert (store.bookmark_for_url ("https://tagged.example/") == null);
    remove_tree (dir);
}

void test_import_chromium () {
    ImportedBookmark tree;
    try {
        tree = BookmarkImport.from_chromium (fixture ("chrome-Bookmarks"));
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert (tree.count () == 3);
    assert (tree.children.size == 3);
    var bar = tree.children[0];
    assert (bar.children[0].title == "Singularity");
    assert (bar.children[1].is_folder && bar.children[1].children.size == 1);
    var store = new Store (null);
    assert (store.import_tree (tree, Store.ROOT) == 3);
    assert (store.folders ().length == 3);
    bool failed = false;
    try {
        BookmarkImport.from_chromium (fixture ("article.html"));
    } catch (Error e) {
        failed = true;
    }
    assert (failed);
}

void test_filter_regex () {
    assert (FilterCompiler.to_regex ("||ads.example.com^") == "^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?ads\\.example\\.com[/:?=&]?");
    assert (FilterCompiler.to_regex ("/banner/*/img^") == "\\/banner\\/.*\\/img[/:?=&]?");
    assert (FilterCompiler.to_regex ("|https://track.") == "^https:\\/\\/track\\.");
    assert (FilterCompiler.to_regex ("swf|") == "swf$");
    assert (FilterCompiler.to_regex ("*tracker.js*") == "tracker\\.js");
    assert (FilterCompiler.to_regex ("ab") == null);
    assert (FilterCompiler.to_regex ("a(b)c") == null);
    assert (FilterCompiler.to_regex ("") == null);
}

Json.Array compile (string list, out FilterCompiler compiler) {
    compiler = new FilterCompiler ();
    compiler.add_list (list);
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (compiler.to_json ());
    } catch (Error e) {
        error ("%s", e.message);
    }
    return parser.get_root ().get_array ();
}

void test_filter_compile () {
    FilterCompiler c;
    var rules = compile ("""[Adblock Plus 2.0]
! comment
||ads.example.com^$third-party
/tracker/pixel.gif$image
@@||ads.example.com/allowed^
##.ad-banner
##div[id^="sponsor"]
example.com,~shop.example.com##.promo
news.example##.popup-overlay
example.org#@#.ad
||evil.example^$csp=script-src 'none'
/regex[0-9]+/
||media.example^$~script,~image
||x.example^$domain=a.example|b.example
||y.example^$domain=a.example|~b.example
""", out c);
    assert (c.stats.blocking == 4);
    assert (c.stats.exceptions == 1);
    assert (c.stats.hiding == 3);
    assert (c.stats.skipped == 5);
    assert (rules.get_length () == 7);
    var first = rules.get_object_element (0);
    assert (first.get_object_member ("action").get_string_member ("type") == "block");
    assert (first.get_object_member ("trigger").get_array_member ("load-type").get_string_element (0) == "third-party");
    var pixel = rules.get_object_element (1).get_object_member ("trigger");
    assert (pixel.get_array_member ("resource-type").get_string_element (0) == "image");
    var media = rules.get_object_element (2).get_object_member ("trigger");
    var types = media.get_array_member ("resource-type");
    for (uint i = 0; i < types.get_length (); i++) {
        assert (types.get_string_element (i) != "script");
        assert (types.get_string_element (i) != "image");
    }
    var scoped = rules.get_object_element (3).get_object_member ("trigger");
    assert (scoped.get_array_member ("if-domain").get_string_element (1) == "*b.example");
    var generic = rules.get_object_element (4).get_object_member ("action");
    assert (generic.get_string_member ("type") == "css-display-none");
    assert (generic.get_string_member ("selector") == ".ad-banner, div[id^=\"sponsor\"]");
    var news = rules.get_object_element (5).get_object_member ("trigger");
    assert (news.get_array_member ("if-domain").get_string_element (0) == "*news.example");
    var last = rules.get_object_element (rules.get_length () - 1).get_object_member ("action");
    assert (last.get_string_member ("type") == "ignore-previous-rules");
    assert (c.rule_count == 7);
}

void test_reader () {
    string html;
    try {
        FileUtils.get_contents (fixture ("article.html"), out html);
    } catch (Error e) {
        error ("%s", e.message);
    }
    var article = Reader.extract (html, "https://journal.example/2026/tiles");
    assert (article != null);
    assert (article.title == "Tiles and Tabs");
    assert (article.byline == "Ada Example");
    assert (article.site == "Example Journal");
    assert (article.content.contains ("Tiling changes that"));
    assert (article.content.contains ("<blockquote>"));
    assert (article.content.contains ("src=\"https://journal.example/images/tiles.png\""));
    assert (!article.content.contains ("newsletter"));
    assert (!article.content.contains ("All rights reserved"));
    assert (!article.content.contains ("tracking"));
    assert (!article.content.contains ("<h1>"));
    string page = Reader.render (article, "#3584e4");
    assert (page.contains ("Content-Security-Policy"));
    assert (page.contains ("<h1>Tiles and Tabs</h1>"));
    try {
        FileUtils.get_contents (fixture ("short.html"), out html);
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert (Reader.extract (html, "https://login.example/") == null);
    assert (Reader.extract ("", "https://x/") == null);
}

void test_unique_path () {
    string dir = temp_dir ();
    string a = Util.unique_path (dir, "file.tar.gz");
    assert (Path.get_basename (a) == "file.tar.gz");
    try {
        FileUtils.set_contents (a, "x");
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert (Path.get_basename (Util.unique_path (dir, "file.tar.gz")) == "file (2).tar.gz");
    assert (Path.get_basename (Util.unique_path (dir, "../evil")) == ".._evil");
    assert (Path.get_basename (Util.unique_path (dir, "")) == "download");
    remove_tree (dir);
}

int main (string[] args) {
    Test.init (ref args);
    fixtures = Environment.get_variable ("BROWSER_FIXTURES") ?? "tests/fixtures";
    Test.add_func ("/address/classify", test_classify);
    Test.add_func ("/address/normalize", test_normalize);
    Test.add_func ("/address/helpers", test_uri_helpers);
    Test.add_func ("/store/history-bookmarks-sites", test_store);
    Test.add_func ("/store/unique-path", test_unique_path);
    Test.add_func ("/store/downloads", test_store_downloads);
    Test.add_func ("/import/firefox", test_import_firefox);
    Test.add_func ("/import/chromium", test_import_chromium);
    Test.add_func ("/filters/regex", test_filter_regex);
    Test.add_func ("/filters/compile", test_filter_compile);
    Test.add_func ("/reader/extract", test_reader);
    return Test.run ();
}
