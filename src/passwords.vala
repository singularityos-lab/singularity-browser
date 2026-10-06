namespace Singularity.Apps.Browser {

    public class Credential : Object {
        public string origin;
        public string username;
        public string password;
        public string profile;

        public Credential (string origin, string username, string password, string profile = "default") {
            this.origin = origin;
            this.username = username;
            this.password = password;
            this.profile = profile;
        }
    }

    public class PasswordImport : Object {
        public static Gee.List<Gee.List<string>> rows (string text) {
            var result = new Gee.ArrayList<Gee.List<string>> ();
            var row = new Gee.ArrayList<string> ();
            var field = new StringBuilder ();
            bool quoted = false;
            bool any = false;
            int i = text.has_prefix ("\xef\xbb\xbf") ? 3 : 0;
            for (; i < text.length; i++) {
                char c = text[i];
                if (quoted) {
                    if (c == '"' && i + 1 < text.length && text[i + 1] == '"') {
                        field.append_c ('"');
                        i++;
                    } else if (c == '"') {
                        quoted = false;
                    } else {
                        field.append_c (c);
                    }
                } else if (c == '"') {
                    quoted = true;
                    any = true;
                } else if (c == ',') {
                    row.add (field.str);
                    field.truncate ();
                    any = true;
                } else if (c == '\n' || c == '\r') {
                    if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
                    if (any || field.len > 0) {
                        row.add (field.str);
                        result.add (row);
                    }
                    row = new Gee.ArrayList<string> ();
                    field.truncate ();
                    any = false;
                } else {
                    field.append_c (c);
                    any = true;
                }
            }
            if (any || field.len > 0) {
                row.add (field.str);
                result.add (row);
            }
            return result;
        }

        private static int column (Gee.List<string> header, string[] names) {
            for (int i = 0; i < header.size; i++) {
                string h = header[i].strip ().down ();
                foreach (string n in names) if (h == n) return i;
            }
            return -1;
        }

        public static Credential[] parse (string text, string profile, out int skipped) throws Error {
            skipped = 0;
            Credential[] result = {};
            var table = rows (text);
            if (table.size == 0) return result;
            var header = table[0];
            int url = column (header, { "url", "login_uri", "website", "origin", "hostname", "web site" });
            int user = column (header, { "username", "login_username", "user", "login", "email", "user name" });
            int pass = column (header, { "password", "login_password" });
            if (url < 0 || pass < 0) throw new IOError.INVALID_DATA (_("This file does not look like a password export: it needs a URL and a password column"));
            var seen = new Gee.HashSet<string> ();
            for (int r = 1; r < table.size; r++) {
                var row = table[r];
                string address = url < row.size ? row[url].strip () : "";
                string password = pass < row.size ? row[pass] : "";
                string username = user >= 0 && user < row.size ? row[user].strip () : "";
                string? origin = Address.origin_of (address);
                if (password == "" || origin == null || !Passwords.eligible (origin)) {
                    skipped++;
                    continue;
                }
                if (!seen.add (origin + "\n" + username)) {
                    skipped++;
                    continue;
                }
                result += new Credential (origin, username, password, profile);
            }
            return result;
        }
    }

    public class Passwords : Object {
        public const string WORLD = "singularity-passwords";
        public const string HANDLER = "singularityPasswords";

        private static Secret.Schema? _schema = null;

        public static Secret.Schema schema () {
            if (_schema == null) {
                _schema = new Secret.Schema ("dev.sinty.Password", Secret.SchemaFlags.NONE,
                    "url", Secret.SchemaAttributeType.STRING,
                    "username", Secret.SchemaAttributeType.STRING,
                    "profile", Secret.SchemaAttributeType.STRING);
            }
            return _schema;
        }

        public static bool eligible (string? uri) {
            if (uri == null) return false;
            try {
                var parsed = Uri.parse (uri, UriFlags.NONE);
                if (parsed.get_host () == null || parsed.get_userinfo () != null) return false;
            } catch (Error e) {
                return false;
            }
            string? scheme = Address.scheme_of (uri);
            if (scheme == "https") return true;
            string? host = Address.host_of (uri);
            return scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1");
        }

        private static async Secret.Collection? default_collection (Secret.Service service) throws Error {
            var collection = yield Secret.Collection.for_alias (service, "default", Secret.CollectionFlags.NONE, null);
            if (collection == null) collection = yield Secret.Collection.create (service, _("Browser Passwords"), "default", Secret.CollectionCreateFlags.NONE, null);
            if (yield collection_locked (collection)) {
                var locked = new GLib.List<GLib.DBusProxy> ();
                locked.append (collection);
                GLib.List<GLib.DBusProxy>? unlocked;
                yield service.unlock (locked, null, out unlocked);
                collection.refresh ();
                if (unlocked == null || unlocked.length () == 0 || (yield collection_locked (collection))) return null;
            }
            return collection;
        }

        private static async bool collection_locked (Secret.Collection collection) throws Error {
            var response = yield collection.call ("org.freedesktop.DBus.Properties.Get",
                new Variant ("(ss)", "org.freedesktop.Secret.Collection", "Locked"), DBusCallFlags.NONE, -1, null);
            if (!response.is_of_type (new VariantType ("(v)"))) throw new IOError.INVALID_DATA (_("The password collection returned invalid lock state"));
            var value = response.get_child_value (0).get_variant ();
            if (!value.is_of_type (VariantType.BOOLEAN)) throw new IOError.INVALID_DATA (_("The password collection returned invalid lock state"));
            return value.get_boolean ();
        }

        public static async Credential[] lookup (string origin, string profile = "default", bool unlock = false) {
            Credential[] result = {};
            if (!eligible (origin) || profile == "" || profile == "private") return result;
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            try {
                if (unlock) {
                    var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
                    var collection = yield default_collection (service);
                    if (collection == null) return result;
                }
                var items = yield Secret.password_searchv (schema (), attrs, Secret.SearchFlags.ALL, null);
                foreach (var item in items) {
                    HashTable<string, string> attributes = item.get_attributes ();
                    if (!attributes.contains ("url") || Address.origin_of (attributes["url"]) != origin) continue;
                    string stored_profile = attributes.contains ("profile") ? attributes["profile"] : "default";
                    if (stored_profile != profile) continue;
                    var proxy = item as Secret.Item;
                    if (proxy != null && proxy.get_locked ()) {
                        if (!unlock) continue;
                        var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
                        var locked = new GLib.List<GLib.DBusProxy> ();
                        locked.append (proxy);
                        GLib.List<GLib.DBusProxy>? unlocked;
                        yield service.unlock (locked, null, out unlocked);
                    }
                    var value = yield item.retrieve_secret (null);
                    if (value == null) continue;
                    string? text = value.get_text ();
                    if (text == null) continue;
                    string username = attributes.contains ("username") ? attributes["username"] : "";
                    result += new Credential (origin, username, text, profile);
                }
            } catch (Error e) {
                debug ("Password lookup: %s", e.message);
            }
            return result;
        }

        public static async Credential[] all (string profile, bool unlock = true) throws Error {
            if (profile == "" || profile == "private") throw new IOError.PERMISSION_DENIED (_("Private browsing cannot export passwords"));
            var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
            var collection = yield Secret.Collection.for_alias (service, "default", Secret.CollectionFlags.NONE, null);
            if (collection == null) throw new IOError.NOT_FOUND (_("The password collection is unavailable"));
            if (yield collection_locked (collection)) {
                if (!unlock) throw new IOError.PERMISSION_DENIED (_("The saved passwords are locked"));
                collection = yield default_collection (service);
                if (collection == null || (yield collection_locked (collection))) throw new IOError.CANCELLED (_("Password unlock was canceled"));
            }
            var attributes = new HashTable<string, string> (str_hash, str_equal);
            var items = yield collection.search (schema (), attributes, Secret.SearchFlags.ALL, null);
            if (yield collection_locked (collection)) throw new IOError.PERMISSION_DENIED (_("The saved passwords were locked during export"));
            Credential[] result = {};
            var identities = new Gee.HashSet<string> ();
            foreach (var item in items) {
                var fields = item.get_attributes ();
                string stored_profile = fields.contains ("profile") ? fields["profile"] : "default";
                if (stored_profile != profile) continue;
                string origin = Address.origin_of (fields["url"] ?? "") ?? "";
                string username = fields["username"] ?? "";
                if (!eligible (origin)) continue;
                var identity = new Json.Builder ();
                identity.begin_array ();
                identity.add_string_value (origin);
                identity.add_string_value (username);
                identity.end_array ();
                var generator = new Json.Generator ();
                generator.set_root (identity.get_root ());
                if (!identities.add (generator.to_data (null))) throw new IOError.INVALID_DATA (_("The saved passwords contain an ambiguous login"));
                if (item.get_locked ()) throw new IOError.PERMISSION_DENIED (_("A saved password is locked"));
                var value = yield item.retrieve_secret (null);
                if (value == null || value.get_text () == null) throw new IOError.INVALID_DATA (_("A saved password could not be read"));
                result += new Credential (origin, username, value.get_text (), profile);
            }
            if (yield collection_locked (collection)) throw new IOError.PERMISSION_DENIED (_("The saved passwords were locked during export"));
            return result;
        }

        public static async void store_synced (Credential credential, bool deleted = false) throws Error {
            if (!eligible (credential.origin) || Address.origin_of (credential.origin) != credential.origin
                || credential.profile == "" || credential.profile == "private")
                throw new IOError.PERMISSION_DENIED (_("This login cannot be synced"));
            var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
            var collection = yield default_collection (service);
            if (collection == null) throw new IOError.CANCELLED (_("Password unlock was canceled"));
            yield all (credential.profile, false);
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            attrs["url"] = credential.origin;
            attrs["username"] = credential.username;
            var items = yield collection.search (schema (), attrs, Secret.SearchFlags.ALL, null);
            bool replaced = false;
            foreach (var item in items) {
                var fields = item.get_attributes ();
                if ((fields["profile"] ?? "default") != credential.profile) continue;
                if (replaced) throw new IOError.INVALID_DATA (_("The saved login is ambiguous"));
                if (deleted) {
                    if (!yield item.delete (null)) throw new IOError.FAILED (_("The saved login could not be removed"));
                } else {
                    yield item.set_secret (new Secret.Value (credential.password, -1, "text/plain"), null);
                }
                replaced = true;
            }
            if (!deleted && !replaced) {
                attrs["profile"] = credential.profile;
                yield Secret.Item.create (collection, schema (), attrs, Address.display (credential.origin),
                    new Secret.Value (credential.password, -1, "text/plain"), Secret.ItemCreateFlags.REPLACE, null);
            }
            var saved = yield all (credential.profile, false);
            foreach (var value in saved) {
                if (value.origin != credential.origin || value.username != credential.username) continue;
                if (deleted || value.password != credential.password) throw new IOError.FAILED (_("The saved login did not match the synced data"));
                return;
            }
            if (!deleted) throw new IOError.FAILED (_("The synced login was not saved"));
        }

        public static async bool save (Credential credential) {
            if (!eligible (credential.origin) || credential.profile == "" || credential.profile == "private") return false;
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            attrs["url"] = credential.origin;
            attrs["username"] = credential.username;
            attrs["profile"] = credential.profile;
            string host = Address.display (credential.origin);
            string label = credential.username != "" ? "%s (%s)".printf (host, credential.username) : host;
            try {
                var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
                var collection = yield default_collection (service);
                if (collection == null) return false;
                var value = new Secret.Value (credential.password, -1, "text/plain");
                yield Secret.Item.create (collection, schema (), attrs, label, value, Secret.ItemCreateFlags.REPLACE, null);
                return true;
            } catch (Error e) {
                warning ("Password could not be saved: %s", e.message);
                return false;
            }
        }

        public static string capture_script () {
            return """(() => {
  if (window.top !== window) return;
  const usable = (i) => !i.matches(':disabled') && !i.readOnly &&
    !i.closest('[hidden],[inert],[aria-hidden="true"]') &&
    i.getBoundingClientRect().width > 0 && i.getBoundingClientRect().height > 0 &&
    getComputedStyle(i).visibility === 'visible';
  const send = (form) => {
    if (!form || !form.querySelectorAll) return;
    if (new URL(form.action || location.href, location.href).origin !== location.origin) return;
    const inputs = Array.from(form.querySelectorAll('input'));
    const pw = inputs.find((i) => (i.type || '').toLowerCase() === 'password' && i.value && usable(i));
    if (!pw) return;
    let user = '';
    for (let i = inputs.indexOf(pw) - 1; i >= 0; i--) {
      const t = (inputs[i].type || 'text').toLowerCase();
      if ((t === 'text' || t === 'email' || t === 'tel') && inputs[i].value && usable(inputs[i])) { user = inputs[i].value; break; }
    }
    window.webkit.messageHandlers.""" + HANDLER + """.postMessage({ origin: location.origin, username: user, password: pw.value });
  };
  document.addEventListener('submit', (e) => send(e.target), true);
})();""";
        }

        public static string pick_script () {
            return """(() => {
  if (window.top !== window) return false;
  const usable = (i) => !i.matches(':disabled') && !i.readOnly &&
    !i.closest('[hidden],[inert],[aria-hidden="true"]') &&
    i.getBoundingClientRect().width > 0 && i.getBoundingClientRect().height > 0 &&
    getComputedStyle(i).visibility === 'visible';
  const fields = () => {
    const inputs = Array.from(document.querySelectorAll('input'));
    const pw = inputs.filter((i) => (i.type || '').toLowerCase() === 'password' && usable(i));
    if (pw.length === 0) return [];
    const found = [pw[0]];
    for (let i = inputs.indexOf(pw[0]) - 1; i >= 0; i--) {
      const t = (inputs[i].type || 'text').toLowerCase();
      if ((t === 'text' || t === 'email' || t === 'tel') && usable(inputs[i])) { found.push(inputs[i]); break; }
    }
    return found;
  };
  const send = (el) => {
    const r = el.getBoundingClientRect();
    window.webkit.messageHandlers.""" + HANDLER + """.postMessage({ pick: true, x: r.left, y: r.top, width: r.width, height: r.height });
  };
  const found = fields();
  if (found.length === 0) return false;
  for (const el of found) {
    if (el.dataset.singularityPick) continue;
    el.dataset.singularityPick = '1';
    el.addEventListener('focus', () => send(el));
    el.addEventListener('click', () => send(el));
  }
  if (found.includes(document.activeElement)) send(document.activeElement);
  return true;
})();""";
        }

        public static string fill_script (Credential credential) {
            var builder = new Json.Builder ();
            builder.begin_array ();
            builder.add_string_value (credential.origin);
            builder.add_string_value (credential.username);
            builder.add_string_value (credential.password);
            builder.end_array ();
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            return """((args) => {
  const [origin, user, pass] = args;
  if (window.top !== window || location.origin !== origin) return false;
  const usable = (i) => !i.matches(':disabled') && !i.readOnly &&
    !i.closest('[hidden],[inert],[aria-hidden="true"]') &&
    i.getBoundingClientRect().width > 0 && i.getBoundingClientRect().height > 0 &&
    getComputedStyle(i).visibility === 'visible';
  const inputs = Array.from(document.querySelectorAll('input'));
  const fields = inputs.filter((i) => (i.type || '').toLowerCase() === 'password' && usable(i));
  const current = fields.filter((i) => i.autocomplete === 'current-password');
  const candidates = current.length ? current : fields;
  if (candidates.length !== 1) return false;
  const pw = candidates[0];
  if (!pw) return false;
  if (pw.form && new URL(pw.form.action || location.href, location.href).origin !== origin) return false;
  const set = (el, v) => {
    const proto = Object.getPrototypeOf(el);
    const desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) desc.set.call(el, v); else el.value = v;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  if (user) {
    for (let i = inputs.indexOf(pw) - 1; i >= 0; i--) {
      const t = (inputs[i].type || 'text').toLowerCase();
      if ((t === 'text' || t === 'email' || t === 'tel') && usable(inputs[i]) && inputs[i].form === pw.form) { set(inputs[i], user); break; }
    }
  }
  set(pw, pass);
  return true;
})(""" + generator.to_data (null) + ");";
        }
    }
}
