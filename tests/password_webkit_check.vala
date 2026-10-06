using Singularity.Apps.Browser;

MainLoop loop;
WebKit.WebView view;
Soup.Server server;
string origin;
string document;
int captured;

async void check (string name, string html, bool expected, string? credential_origin = null) throws Error {
    document = "<!doctype html><html><body>" + html + "<script>document.addEventListener('submit',e=>e.preventDefault());</script></body></html>";
    captured = 0;
    ulong handler = 0;
    handler = view.load_changed.connect ((event) => {
        if (event == WebKit.LoadEvent.FINISHED) {
            view.disconnect (handler);
            Idle.add (() => { check.callback (); return Source.REMOVE; });
        }
    });
    view.load_uri (origin + "/" + name);
    yield;
    Timeout.add (100, () => { check.callback (); return Source.REMOVE; });
    yield;
    var credential = new Credential (credential_origin ?? origin, "alice", "Synthetic-only-password");
    var result = yield view.evaluate_javascript (Passwords.fill_script (credential), -1, Passwords.WORLD, null, null);
    assert (result.to_boolean () == expected);
    var values = yield view.evaluate_javascript ("JSON.stringify(Array.from(document.querySelectorAll('input')).map(i=>[i.id,i.value]))", -1, null, null, null);
    if (expected) {
        assert (values.to_string ().contains ("Synthetic-only-password"));
        assert (values.to_string ().contains ("alice"));
    } else {
        assert (!values.to_string ().contains ("Synthetic-only-password"));
        assert (!values.to_string ().contains ("alice"));
    }
    print ("FILL %s %s\n", name, expected ? "accepted" : "rejected");
}

async void capture (string name, string html, bool expected) throws Error {
    yield check (name, html, false, "https://wrong.example.invalid");
    yield view.evaluate_javascript ("document.querySelector('form').requestSubmit()", -1, null, null, null);
    Timeout.add (150, () => { capture.callback (); return Source.REMOVE; });
    yield;
    assert (captured == (expected ? 1 : 0));
    print ("CAPTURE %s %s\n", name, expected ? "accepted" : "rejected");
}

async void run_checks () {
    try {
        string form = "<form><input id='user'><input id='password' type='password'><button>Sign in</button></form>";
        yield check ("normal", form, true);
        yield check ("port-mismatch", form, false, "http://127.0.0.1:1");
        yield check ("host-mismatch", form, false, "http://localhost:" + Uri.parse (origin, UriFlags.NONE).get_port ().to_string ());
        yield check ("hidden", "<form><input><input type='password' style='display:none'></form>", false);
        yield check ("invisible", "<form><input><input type='password' style='visibility:hidden'></form>", false);
        yield check ("disabled-fieldset", "<form><input><fieldset disabled><input type='password'></fieldset></form>", false);
        yield check ("readonly", "<form><input><input type='password' readonly></form>", false);
        yield check ("inert", "<form inert><input><input type='password'></form>", false);
        yield check ("ambiguous", form + form, false);
        yield check ("cross-origin-action", "<form action='http://127.0.0.1:1/'><input><input type='password'></form>", false);
        yield check ("iframe-only", "<iframe srcdoc=\"<form><input><input type='password'></form>\"></iframe>", false);
        yield check ("hidden-user", "<form><input id='user'><input id='trap' hidden><input type='password'></form>", true);
        var trap = yield view.evaluate_javascript ("document.getElementById('trap').value", -1, null, null, null);
        assert (trap.to_string () == "");
        yield capture ("capture-normal", "<form><input value='bob'><input type='password' value='Synthetic-capture'><button>Sign in</button></form>", true);
        yield capture ("capture-hidden", "<form><input value='bob'><input type='password' hidden value='Synthetic-capture'></form>", false);
        yield capture ("capture-disabled", "<form><input value='bob'><input type='password' disabled value='Synthetic-capture'></form>", false);
        yield capture ("capture-cross-origin", "<form action='http://127.0.0.1:1/'><input value='bob'><input type='password' value='Synthetic-capture'></form>", false);
        print ("PASSWORD WEBKIT CHECKS PASS\n");
    } catch (Error e) {
        error ("Password check: %s", e.message);
    }
    loop.quit ();
}

int main (string[] args) {
    assert (Environment.get_variable ("DISPLAY") == null);
    assert (Environment.get_variable ("GDK_BACKEND") == "wayland");
    assert (Environment.get_variable ("SINGULARITY_SYSTEM_BUS") == Environment.get_variable ("DBUS_SYSTEM_BUS_ADDRESS"));
    Gtk.init ();
    assert (Passwords.eligible ("https://example.invalid"));
    assert (Passwords.eligible ("http://127.0.0.1:8123"));
    assert (Passwords.eligible ("http://[::1]:8123"));
    assert (!Passwords.eligible ("http://example.invalid"));
    assert (!Passwords.eligible ("https://user:pass@example.invalid"));
    assert (!Passwords.eligible ("file:///page.html"));
    assert (Address.origin_of ("https://example.invalid:443/path") == "https://example.invalid");
    assert (Address.origin_of ("http://[::1]:8123/path") == "http://[::1]:8123");
    server = new Soup.Server ("server-header", "SyntheticBrowserCheck");
    server.add_handler (null, (server, message, path, query) => {
        message.set_status (200, null);
        message.set_response ("text/html", Soup.MemoryUse.COPY, document.data);
    });
    try {
        server.listen_local (0, Soup.ServerListenOptions.IPV4_ONLY);
    } catch (Error e) {
        error ("Private server: %s", e.message);
    }
    origin = server.get_uris ().data.to_string ().chomp ();
    if (origin.has_suffix ("/")) origin = origin.substring (0, origin.length - 1);
    var manager = new WebKit.UserContentManager ();
    manager.register_script_message_handler (Passwords.HANDLER, Passwords.WORLD);
    manager.script_message_received[Passwords.HANDLER].connect ((value) => {
        assert (value.object_get_property ("origin").to_string () == origin);
        assert (value.object_get_property ("username").to_string () == "bob");
        assert (value.object_get_property ("password").to_string () == "Synthetic-capture");
        captured++;
    });
    manager.add_script (new WebKit.UserScript.for_world (Passwords.capture_script (), WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserScriptInjectionTime.END, Passwords.WORLD, null, null));
    var settings = new WebKit.Settings ();
    settings.hardware_acceleration_policy = WebKit.HardwareAccelerationPolicy.NEVER;
    view = (WebKit.WebView) Object.new (typeof (WebKit.WebView), "network-session", new WebKit.NetworkSession.ephemeral (), "user-content-manager", manager, "settings", settings);
    var window = new Gtk.Window ();
    window.set_default_size (600, 500);
    window.child = view;
    window.present ();
    loop = new MainLoop ();
    Timeout.add_seconds (60, () => { error ("Password checks timed out"); });
    run_checks.begin ();
    loop.run ();
    window.destroy ();
    server.disconnect ();
    return 0;
}
