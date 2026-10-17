using Singularity.Apps.Browser;

const string SAMPLE_ID = "fhmbhiijhbomemmnplallbapihljmpaj";

string fixtures;

Bytes sample () {
    try {
        uint8[] data;
        FileUtils.get_data (Path.build_filename (fixtures, "sample.crx"), out data);
        return new Bytes.take ((owned) data);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

string temp_dir () {
    try {
        return DirUtils.make_tmp ("extension-test-XXXXXX");
    } catch (Error e) {
        error ("tmp: %s", e.message);
    }
}

void test_crx () {
    try {
        var crx = Crx.parse (sample ());
        assert (crx.id == SAMPLE_ID);
        assert (crx.archive.get_size () > 0);
        Crx.parse (sample (), SAMPLE_ID);
    } catch (Error e) {
        error ("parse: %s", e.message);
    }
    try {
        Crx.parse (sample (), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert_not_reached ();
    } catch (CrxError.MISMATCH e) {
    } catch (Error e) {
        error ("wrong error: %s", e.message);
    }
    uint8[] tampered = sample ().get_data ();
    tampered[tampered.length - 30] ^= 0x01;
    try {
        Crx.parse (new Bytes (tampered));
        assert_not_reached ();
    } catch (CrxError.UNSIGNED e) {
    } catch (Error e) {
        error ("wrong error: %s", e.message);
    }
    try {
        Crx.parse (new Bytes ("PK\x03\x04 not a crx".data));
        assert_not_reached ();
    } catch (CrxError.INVALID e) {
    } catch (Error e) {
        error ("wrong error: %s", e.message);
    }
    assert (Crx.is_valid_id (SAMPLE_ID));
    assert (!Crx.is_valid_id ("fhmbhiijhbomemmnplallbapihljmpaz"));
    assert (!Crx.is_valid_id ("short"));
}

void test_safe_path () {
    assert (ZipArchive.safe_path ("a/b.js") == "a/b.js");
    assert (ZipArchive.safe_path ("./a//b.js") == "a/b.js");
    assert (ZipArchive.safe_path ("../evil") == null);
    assert (ZipArchive.safe_path ("a/../../evil") == null);
    assert (ZipArchive.safe_path ("/etc/passwd") == null);
    assert (ZipArchive.safe_path ("a\\..\\evil") == null);
    assert (ZipArchive.safe_path ("") == null);
}

void test_install () {
    string root = temp_dir ();
    var manager = new ExtensionManager (root);
    Extension extension;
    try {
        extension = manager.install (sample (), SAMPLE_ID);
    } catch (Error e) {
        error ("install: %s", e.message);
    }
    assert (extension.id == SAMPLE_ID);
    assert (extension.name == "Sample Extension");
    assert (extension.description == "A sample");
    assert (extension.version == "1.2.0");
    assert (extension.manifest_version == 3);
    assert (extension.background_worker == "background.js");
    assert (extension.popup == "popup.html");
    assert (extension.has_permission ("storage"));
    assert (extension.host_permissions.length == 1);
    assert (extension.content_scripts.size == 1);
    assert (extension.content_scripts[0].run_at == "document_end");
    assert (extension.icon_for (32) == "icon48.png");
    assert (extension.icon_for (256) == "icon128.png");
    assert (FileUtils.test (Path.build_filename (root, SAMPLE_ID, "content.js"), FileTest.IS_REGULAR));
    try {
        assert (extension.resolve ("/popup.html") == Path.build_filename (root, SAMPLE_ID, "popup.html"));
        extension.resolve ("../state.json");
        assert_not_reached ();
    } catch (ExtensionError e) {
    }

    assert (manager.is_enabled (SAMPLE_ID));
    manager.set_enabled (SAMPLE_ID, false);
    var reopened = new ExtensionManager (root);
    assert (reopened.get_extension (SAMPLE_ID) != null);
    assert (!reopened.is_enabled (SAMPLE_ID));

    try {
        manager.install (sample (), SAMPLE_ID);
        manager.uninstall (SAMPLE_ID);
    } catch (Error e) {
        error ("reinstall: %s", e.message);
    }
    assert (manager.get_extension (SAMPLE_ID) == null);
    assert (!FileUtils.test (Path.build_filename (root, SAMPLE_ID), FileTest.EXISTS));
    ExtensionManager.remove_tree (root);
}

void test_store_url () {
    assert (ExtensionManager.id_from_store_url ("https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh") == "ddkjiahejlhfcafbddmgiahcphecmpfh");
    assert (ExtensionManager.id_from_store_url ("https://chromewebstore.google.com/detail/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=it") == "ddkjiahejlhfcafbddmgiahcphecmpfh");
    assert (ExtensionManager.id_from_store_url ("https://evil.example/detail/ddkjiahejlhfcafbddmgiahcphecmpfh") == null);
    assert (ExtensionManager.update_url ("ddkjiahejlhfcafbddmgiahcphecmpfh").contains ("id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26uc"));
}

void test_versions () {
    assert (Extension.valid_version ("1.2.3.4"));
    assert (!Extension.valid_version ("1.2.3.4.5"));
    assert (!Extension.valid_version ("1.x"));
    assert (Extension.compare_versions ("1.10", "1.9") > 0);
    assert (Extension.compare_versions ("2", "2.0.0") == 0);
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C");
    Environment.set_variable ("LANGUAGE", "en", true);
    Test.init (ref args);
    fixtures = Environment.get_variable ("BROWSER_FIXTURES") ?? "tests/fixtures";
    Test.add_func ("/extensions/crx", test_crx);
    Test.add_func ("/extensions/safe-path", test_safe_path);
    Test.add_func ("/extensions/install", test_install);
    Test.add_func ("/extensions/store-url", test_store_url);
    Test.add_func ("/extensions/versions", test_versions);
    return Test.run ();
}
