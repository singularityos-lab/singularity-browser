namespace Singularity.Apps.Browser {

    public errordomain WebAuthnError {
        NOT_ALLOWED,
        INVALID_STATE,
        SECURITY,
        NOT_SUPPORTED,
        UNKNOWN
    }

    public class Base64Url : Object {
        public static string encode (uint8[] data) {
            return Base64.encode (data).replace ("+", "-").replace ("/", "_").replace ("=", "");
        }

        public static uint8[] decode (string text) throws WebAuthnError {
            string s = text.strip ().replace ("-", "+").replace ("_", "/");
            while (s.length % 4 != 0) s += "=";
            foreach (char c in s.to_utf8 ()) {
                if (!(c.isalnum () || c == '+' || c == '/' || c == '=')) throw new WebAuthnError.UNKNOWN ("invalid base64url");
            }
            return Base64.decode (s);
        }
    }

    public class CborWriter : Object {
        private ByteArray buffer = new ByteArray ();

        private void head (uint8 major, uint64 value) {
            uint8 m = major << 5;
            if (value < 24) {
                buffer.append ({ m | (uint8) value });
            } else if (value <= 0xff) {
                buffer.append ({ m | 24, (uint8) value });
            } else if (value <= 0xffff) {
                buffer.append ({ m | 25, (uint8) (value >> 8), (uint8) value });
            } else if (value <= 0xffffffff) {
                buffer.append ({ m | 26, (uint8) (value >> 24), (uint8) (value >> 16), (uint8) (value >> 8), (uint8) value });
            } else {
                buffer.append ({ m | 27 });
                for (int i = 7; i >= 0; i--) buffer.append ({ (uint8) (value >> (i * 8)) });
            }
        }

        public CborWriter integer (int64 value) {
            if (value >= 0) head (0, (uint64) value);
            else head (1, (uint64) (-1 - value));
            return this;
        }

        public CborWriter bytes (uint8[] value) {
            head (2, value.length);
            buffer.append (value);
            return this;
        }

        public CborWriter text (string value) {
            head (3, value.length);
            buffer.append (value.data);
            return this;
        }

        public CborWriter array (uint count) {
            head (4, count);
            return this;
        }

        public CborWriter map (uint count) {
            head (5, count);
            return this;
        }

        public CborWriter boolean (bool value) {
            buffer.append ({ value ? (uint8) 0xf5 : (uint8) 0xf4 });
            return this;
        }

        public CborWriter raw (uint8[] encoded) {
            buffer.append (encoded);
            return this;
        }

        public uint8[] finish () {
            return buffer.data;
        }
    }

    public enum CborType { UNSIGNED, NEGATIVE, BYTES, TEXT, ARRAY, MAP, SIMPLE }

    public class CborValue : Object {
        public CborType kind;
        public int64 number;
        public uint8[] data;
        public string str;
        public Gee.ArrayList<CborValue> items = new Gee.ArrayList<CborValue> ();
        public Gee.ArrayList<CborValue> keys = new Gee.ArrayList<CborValue> ();

        public CborValue? lookup_int (int64 key) {
            for (int i = 0; i < keys.size; i++) {
                var k = keys[i];
                if ((k.kind == CborType.UNSIGNED || k.kind == CborType.NEGATIVE) && k.number == key) return items[i];
            }
            return null;
        }

        public CborValue? lookup (string key) {
            for (int i = 0; i < keys.size; i++) {
                if (keys[i].kind == CborType.TEXT && keys[i].str == key) return items[i];
            }
            return null;
        }
    }

    public class CborReader : Object {
        private uint8[] data;
        private int pos = 0;

        public CborReader (uint8[] data) {
            this.data = data;
        }

        public int offset { get { return pos; } }

        private uint8 next () throws WebAuthnError {
            if (pos >= data.length) throw new WebAuthnError.UNKNOWN ("truncated CBOR");
            return data[pos++];
        }

        private uint64 argument (uint8 info) throws WebAuthnError {
            if (info < 24) return info;
            int count = info == 24 ? 1 : info == 25 ? 2 : info == 26 ? 4 : info == 27 ? 8 : -1;
            if (count < 0) throw new WebAuthnError.UNKNOWN ("unsupported CBOR length");
            uint64 value = 0;
            for (int i = 0; i < count; i++) value = (value << 8) | next ();
            return value;
        }

        public CborValue read (int depth = 0) throws WebAuthnError {
            if (depth > 16) throw new WebAuthnError.UNKNOWN ("CBOR nested too deep");
            uint8 first = next ();
            uint8 major = first >> 5;
            uint8 info = first & 0x1f;
            var value = new CborValue ();
            if (major == 7) {
                value.kind = CborType.SIMPLE;
                value.number = info;
                if (info == 24) value.number = next ();
                return value;
            }
            uint64 arg = argument (info);
            switch (major) {
                case 0:
                    value.kind = CborType.UNSIGNED;
                    value.number = (int64) arg;
                    break;
                case 1:
                    value.kind = CborType.NEGATIVE;
                    value.number = -1 - (int64) arg;
                    break;
                case 2:
                case 3:
                    if (arg > data.length - pos) throw new WebAuthnError.UNKNOWN ("truncated CBOR");
                    value.data = data[pos:pos + (int) arg];
                    pos += (int) arg;
                    if (major == 3) {
                        value.kind = CborType.TEXT;
                        var sb = new StringBuilder ();
                        sb.append_len ((string) value.data, value.data.length);
                        value.str = sb.str;
                    } else {
                        value.kind = CborType.BYTES;
                    }
                    break;
                case 4:
                    value.kind = CborType.ARRAY;
                    for (uint64 i = 0; i < arg; i++) value.items.add (read (depth + 1));
                    break;
                case 5:
                    value.kind = CborType.MAP;
                    for (uint64 i = 0; i < arg; i++) {
                        value.keys.add (read (depth + 1));
                        value.items.add (read (depth + 1));
                    }
                    break;
                default:
                    throw new WebAuthnError.UNKNOWN ("unsupported CBOR type");
            }
            return value;
        }
    }

    public class Passkey : Object {
        public uint8[] credential_id;
        public string rp_id = "";
        public uint8[] user_handle;
        public string user_name = "";
        public string display_name = "";
        public uint8[] private_key;
        public string profile = "default";

        public string label {
            owned get { return display_name != "" && display_name != user_name ? "%s (%s)".printf (display_name, user_name) : user_name; }
        }
    }

    public class WebAuthnCore : Object {
        public const uint8 FLAG_UP = 0x01;
        public const uint8 FLAG_UV = 0x04;
        public const uint8 FLAG_AT = 0x40;
        public const int64 ES256 = -7;

        public static bool rp_matches (string origin, string rp_id) {
            if (rp_id == "" || rp_id.has_prefix (".") || rp_id.has_suffix (".")) return false;
            string? host = Address.host_of (origin);
            if (host == null) return false;
            host = host.down ();
            string rp = rp_id.down ();
            if (host == rp) return true;
            return rp.contains (".") && host.has_suffix ("." + rp);
        }

        public static bool origin_allowed (string origin) {
            string? scheme = Address.scheme_of (origin);
            string? host = Address.host_of (origin);
            if (scheme == "https") return true;
            return scheme == "http" && (host == "localhost" || (host != null && host.has_suffix (".localhost")));
        }

        public static string client_data (string type, string challenge, string origin) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("type");
            builder.add_string_value (type);
            builder.set_member_name ("challenge");
            builder.add_string_value (challenge);
            builder.set_member_name ("origin");
            builder.add_string_value (origin);
            builder.set_member_name ("crossOrigin");
            builder.add_boolean_value (false);
            builder.end_object ();
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            return generator.to_data (null);
        }

        public static uint8[] cose_key (uint8[] point) {
            return new CborWriter ().map (5)
                .integer (1).integer (2)
                .integer (3).integer (ES256)
                .integer (-1).integer (1)
                .integer (-2).bytes (point[0:32])
                .integer (-3).bytes (point[32:64])
                .finish ();
        }

        public static uint8[] digest (uint8[] data) {
            return PasskeyCrypto.digest (new Bytes (data)).get_data ();
        }

        public static uint8[] auth_data (string rp_id, uint8 flags, uint32 counter, uint8[]? credential_id = null, uint8[]? cose = null) {
            var buf = new ByteArray ();
            buf.append (digest (rp_id.data));
            buf.append ({ flags, (uint8) (counter >> 24), (uint8) (counter >> 16), (uint8) (counter >> 8), (uint8) counter });
            if (credential_id != null && cose != null) {
                buf.append (new uint8[16]);
                buf.append ({ (uint8) (credential_id.length >> 8), (uint8) credential_id.length });
                buf.append (credential_id);
                buf.append (cose);
            }
            return buf.data;
        }

        public static uint8[] attestation_object (uint8[] auth) {
            return new CborWriter ().map (3)
                .text ("fmt").text ("none")
                .text ("attStmt").map (0)
                .text ("authData").bytes (auth)
                .finish ();
        }

        public static uint8[] signed_payload (uint8[] auth, string client_json) {
            var buf = new ByteArray ();
            buf.append (auth);
            buf.append (digest (client_json.data));
            return buf.data;
        }

        public static string member_string (Json.Object o, string name) {
            return o.has_member (name) && o.get_member (name).get_value_type () == typeof (string) ? o.get_string_member (name) : "";
        }

        public static Gee.List<string> credential_ids (Json.Object options, string member) {
            var ids = new Gee.ArrayList<string> ();
            if (!options.has_member (member)) return ids;
            var node = options.get_member (member);
            if (node.get_node_type () != Json.NodeType.ARRAY) return ids;
            node.get_array ().foreach_element ((a, i, n) => {
                if (n.get_node_type () == Json.NodeType.OBJECT) {
                    string id = member_string (n.get_object (), "id");
                    if (id != "") ids.add (id);
                }
            });
            return ids;
        }

        public static bool supports_es256 (Json.Object options) {
            if (!options.has_member ("pubKeyCredParams")) return true;
            bool found = false;
            options.get_array_member ("pubKeyCredParams").foreach_element ((a, i, n) => {
                if (n.get_node_type () == Json.NodeType.OBJECT && n.get_object ().has_member ("alg")
                    && n.get_object ().get_int_member ("alg") == ES256) found = true;
            });
            return found;
        }

        public static string rp_id_for_create (Json.Object options, string origin) {
            if (options.has_member ("rp") && options.get_member ("rp").get_node_type () == Json.NodeType.OBJECT) {
                string id = member_string (options.get_object_member ("rp"), "id");
                if (id != "") return id;
            }
            return Address.host_of (origin) ?? "";
        }

        public static string rp_id_for_get (Json.Object options, string origin) {
            string id = member_string (options, "rpId");
            return id != "" ? id : Address.host_of (origin) ?? "";
        }

        public static Passkey new_passkey (Json.Object options, string rp_id, string profile) throws WebAuthnError {
            if (!options.has_member ("user") || options.get_member ("user").get_node_type () != Json.NodeType.OBJECT)
                throw new WebAuthnError.UNKNOWN ("The site did not name the account");
            var user = options.get_object_member ("user");
            var key = PasskeyCrypto.generate ();
            var id = PasskeyCrypto.random (32);
            if (key == null || id == null) throw new WebAuthnError.UNKNOWN ("Could not create the key");
            var passkey = new Passkey ();
            passkey.credential_id = id.get_data ();
            passkey.rp_id = rp_id;
            passkey.user_handle = Base64Url.decode (member_string (user, "id"));
            passkey.user_name = member_string (user, "name");
            passkey.display_name = member_string (user, "displayName");
            passkey.private_key = key.get_data ();
            passkey.profile = profile;
            if (passkey.user_handle.length == 0 || passkey.user_handle.length > 64) throw new WebAuthnError.UNKNOWN ("The site sent an invalid account id");
            return passkey;
        }

        private static Json.Builder response_start (uint8[] id, string attachment) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id");
            b.add_string_value (Base64Url.encode (id));
            b.set_member_name ("type");
            b.add_string_value ("public-key");
            b.set_member_name ("authenticatorAttachment");
            b.add_string_value (attachment);
            return b;
        }

        private static string finish (Json.Builder b) {
            b.end_object ();
            var g = new Json.Generator ();
            g.set_root (b.get_root ());
            return g.to_data (null);
        }

        public static uint8[] spki_from_point (uint8[] point) {
            uint8[] prefix = { 0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04 };
            var buf = new ByteArray ();
            buf.append (prefix);
            buf.append (point);
            return buf.data;
        }

        public static uint8[] credential_id_from_auth_data (uint8[] auth) throws WebAuthnError {
            if (auth.length < 55 || (auth[32] & FLAG_AT) == 0) throw new WebAuthnError.UNKNOWN ("The authenticator returned no key");
            int id_len = (auth[53] << 8) | auth[54];
            if (55 + id_len > auth.length) throw new WebAuthnError.UNKNOWN ("The authenticator returned a broken key");
            return auth[55:55 + id_len];
        }

        public static uint8[] point_from_auth_data (uint8[] auth) throws WebAuthnError {
            if (auth.length < 55 || (auth[32] & FLAG_AT) == 0) throw new WebAuthnError.UNKNOWN ("The authenticator returned no key");
            int id_len = (auth[53] << 8) | auth[54];
            if (55 + id_len >= auth.length) throw new WebAuthnError.UNKNOWN ("The authenticator returned a broken key");
            var cose = new CborReader (auth[55 + id_len:auth.length]).read ();
            var alg = cose.lookup_int (3);
            var x = cose.lookup_int (-2);
            var y = cose.lookup_int (-3);
            if (alg == null || alg.number != ES256 || x == null || y == null || x.data.length != 32 || y.data.length != 32)
                throw new WebAuthnError.NOT_SUPPORTED ("The authenticator made an unsupported key");
            var point = new ByteArray ();
            point.append (x.data);
            point.append (y.data);
            return point.data;
        }

        public static GLib.Bytes pack_ids (Gee.List<string> ids) {
            var buf = new ByteArray ();
            foreach (string id in ids) {
                try {
                    uint8[] raw = Base64Url.decode (id);
                    if (raw.length == 0 || raw.length > 1023) continue;
                    buf.append ({ (uint8) (raw.length >> 8), (uint8) raw.length });
                    buf.append (raw);
                } catch (WebAuthnError e) {
                }
            }
            return new GLib.Bytes (buf.data);
        }

        public static string registration_response (uint8[] id, string client, uint8[] auth, string attachment, string[] transports, bool resident) throws WebAuthnError {
            var point = point_from_auth_data (auth);
            var b = response_start (id, attachment);
            b.set_member_name ("response");
            b.begin_object ();
            b.set_member_name ("clientDataJSON");
            b.add_string_value (Base64Url.encode (client.data));
            b.set_member_name ("attestationObject");
            b.add_string_value (Base64Url.encode (attestation_object (auth)));
            b.set_member_name ("authenticatorData");
            b.add_string_value (Base64Url.encode (auth));
            b.set_member_name ("publicKey");
            b.add_string_value (Base64Url.encode (spki_from_point (point)));
            b.set_member_name ("publicKeyAlgorithm");
            b.add_int_value (ES256);
            b.set_member_name ("transports");
            b.begin_array ();
            foreach (string t in transports) b.add_string_value (t);
            b.end_array ();
            b.end_object ();
            b.set_member_name ("clientExtensionResults");
            b.begin_object ();
            b.set_member_name ("credProps");
            b.begin_object ();
            b.set_member_name ("rk");
            b.add_boolean_value (resident);
            b.end_object ();
            b.end_object ();
            return finish (b);
        }

        public static string assertion_response (uint8[] id, string client, uint8[] auth, uint8[] signature, uint8[]? user_handle, string attachment) {
            var b = response_start (id, attachment);
            b.set_member_name ("response");
            b.begin_object ();
            b.set_member_name ("clientDataJSON");
            b.add_string_value (Base64Url.encode (client.data));
            b.set_member_name ("authenticatorData");
            b.add_string_value (Base64Url.encode (auth));
            b.set_member_name ("signature");
            b.add_string_value (Base64Url.encode (signature));
            if (user_handle != null && user_handle.length > 0) {
                b.set_member_name ("userHandle");
                b.add_string_value (Base64Url.encode (user_handle));
            }
            b.end_object ();
            b.set_member_name ("clientExtensionResults");
            b.begin_object ();
            b.end_object ();
            return finish (b);
        }

        public static string registration (Passkey passkey, string challenge, string origin, bool verified) throws WebAuthnError {
            var point = PasskeyCrypto.public_point (new Bytes (passkey.private_key));
            if (point == null) throw new WebAuthnError.UNKNOWN ("Could not read the key");
            uint8 flags = FLAG_UP | FLAG_AT | (verified ? FLAG_UV : 0);
            var auth = auth_data (passkey.rp_id, flags, 0, passkey.credential_id, cose_key (point.get_data ()));
            string client = client_data ("webauthn.create", challenge, origin);
            return registration_response (passkey.credential_id, client, auth, "platform", { "internal", "hybrid" }, true);
        }

        public static string assertion (Passkey passkey, string challenge, string origin, bool verified) throws WebAuthnError {
            uint8 flags = FLAG_UP | (verified ? FLAG_UV : 0);
            var auth = auth_data (passkey.rp_id, flags, 0);
            string client = client_data ("webauthn.get", challenge, origin);
            var signature = PasskeyCrypto.sign (new Bytes (passkey.private_key), new Bytes (signed_payload (auth, client)));
            if (signature == null) throw new WebAuthnError.UNKNOWN ("Could not sign");
            return assertion_response (passkey.credential_id, client, auth, signature.get_data (), passkey.user_handle, "platform");
        }
    }

    public class PasskeyStore : Object {
        private static Secret.Schema? _schema = null;

        public static Secret.Schema schema () {
            if (_schema == null) {
                _schema = new Secret.Schema ("dev.sinty.Passkey", Secret.SchemaFlags.NONE,
                    "rp", Secret.SchemaAttributeType.STRING,
                    "credential", Secret.SchemaAttributeType.STRING,
                    "username", Secret.SchemaAttributeType.STRING,
                    "profile", Secret.SchemaAttributeType.STRING);
            }
            return _schema;
        }

        public static async void save (Passkey passkey) throws Error {
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            attrs["rp"] = passkey.rp_id;
            attrs["credential"] = Base64Url.encode (passkey.credential_id);
            attrs["username"] = passkey.user_name;
            attrs["profile"] = passkey.profile;
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("user");
            b.add_string_value (Base64Url.encode (passkey.user_handle));
            b.set_member_name ("name");
            b.add_string_value (passkey.user_name);
            b.set_member_name ("display");
            b.add_string_value (passkey.display_name);
            b.set_member_name ("key");
            b.add_string_value (Base64Url.encode (passkey.private_key));
            b.end_object ();
            var g = new Json.Generator ();
            g.set_root (b.get_root ());
            string label = _("Passkey for %s (%s)").printf (passkey.rp_id, passkey.user_name);
            yield Secret.password_storev (schema (), attrs, Secret.COLLECTION_DEFAULT, label, g.to_data (null), null);
        }

        public static async Gee.List<Passkey> find (string rp_id, string profile, Gee.List<string>? allowed = null) throws Error {
            var result = new Gee.ArrayList<Passkey> ();
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            attrs["rp"] = rp_id;
            var items = yield Secret.password_searchv (schema (), attrs, Secret.SearchFlags.ALL | Secret.SearchFlags.UNLOCK, null);
            foreach (var item in items) {
                var fields = item.get_attributes ();
                if ((fields["profile"] ?? "default") != profile) continue;
                string credential = fields["credential"] ?? "";
                if (allowed != null && allowed.size > 0 && !(credential in allowed)) continue;
                var value = yield item.retrieve_secret (null);
                if (value == null || value.get_text () == null) continue;
                try {
                    var parser = new Json.Parser ();
                    parser.load_from_data (value.get_text ());
                    var o = parser.get_root ().get_object ();
                    var passkey = new Passkey ();
                    passkey.credential_id = Base64Url.decode (credential);
                    passkey.rp_id = rp_id;
                    passkey.user_handle = Base64Url.decode (o.get_string_member ("user"));
                    passkey.user_name = o.get_string_member ("name");
                    passkey.display_name = o.get_string_member ("display");
                    passkey.private_key = Base64Url.decode (o.get_string_member ("key"));
                    passkey.profile = profile;
                    result.add (passkey);
                } catch (Error e) {
                    warning ("Skipping an unreadable passkey: %s", e.message);
                }
            }
            return result;
        }

        public static async bool exists (string rp_id, string profile, Gee.List<string> ids) throws Error {
            if (ids.size == 0) return false;
            var attrs = new HashTable<string, string> (str_hash, str_equal);
            attrs["rp"] = rp_id;
            var items = yield Secret.password_searchv (schema (), attrs, Secret.SearchFlags.ALL, null);
            foreach (var item in items) {
                var fields = item.get_attributes ();
                if ((fields["profile"] ?? "default") == profile && (fields["credential"] ?? "") in ids) return true;
            }
            return false;
        }
    }

    public class WebAuthnScript : Object {
        public const string HANDLER = "singularityWebAuthn";

        public static string source () {
            return """(() => {
  if (window.top !== window || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.""" + HANDLER + """) return;
  const bridge = window.webkit.messageHandlers.""" + HANDLER + """;
  const toB64 = (buf) => {
    const bytes = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
    let s = '';
    for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  const fromB64 = (s) => {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  };
  const isBuf = (v) => v instanceof ArrayBuffer || ArrayBuffer.isView(v);
  const plain = (v) => {
    if (isBuf(v)) return toB64(v);
    if (Array.isArray(v)) return v.map(plain);
    if (v && typeof v === 'object') {
      const o = {};
      for (const k of Object.keys(v)) if (v[k] !== undefined) o[k] = plain(v[k]);
      return o;
    }
    return v;
  };
  class AuthenticatorResponse {
    constructor(r) { this.clientDataJSON = fromB64(r.clientDataJSON); }
  }
  class AuthenticatorAttestationResponse extends AuthenticatorResponse {
    constructor(r) {
      super(r);
      this.attestationObject = fromB64(r.attestationObject);
      this._r = r;
    }
    getTransports() { return this._r.transports.slice(); }
    getAuthenticatorData() { return fromB64(this._r.authenticatorData); }
    getPublicKey() { return fromB64(this._r.publicKey); }
    getPublicKeyAlgorithm() { return this._r.publicKeyAlgorithm; }
    toJSON() { return { clientDataJSON: this._r.clientDataJSON, attestationObject: this._r.attestationObject, authenticatorData: this._r.authenticatorData, publicKey: this._r.publicKey, publicKeyAlgorithm: this._r.publicKeyAlgorithm, transports: this._r.transports }; }
  }
  class AuthenticatorAssertionResponse extends AuthenticatorResponse {
    constructor(r) {
      super(r);
      this.authenticatorData = fromB64(r.authenticatorData);
      this.signature = fromB64(r.signature);
      this.userHandle = r.userHandle ? fromB64(r.userHandle) : null;
      this._r = r;
    }
    toJSON() { return { clientDataJSON: this._r.clientDataJSON, authenticatorData: this._r.authenticatorData, signature: this._r.signature, userHandle: this._r.userHandle }; }
  }
  class PublicKeyCredential {
    constructor(r, created) {
      this.id = r.id;
      this.rawId = fromB64(r.id);
      this.type = 'public-key';
      this.authenticatorAttachment = r.authenticatorAttachment;
      this.response = created ? new AuthenticatorAttestationResponse(r.response) : new AuthenticatorAssertionResponse(r.response);
      this._ext = r.clientExtensionResults || {};
    }
    getClientExtensionResults() { return this._ext; }
    toJSON() { return { id: this.id, rawId: this.id, type: this.type, authenticatorAttachment: this.authenticatorAttachment, response: this.response.toJSON(), clientExtensionResults: this._ext }; }
    static isUserVerifyingPlatformAuthenticatorAvailable() { return Promise.resolve(true); }
    static isConditionalMediationAvailable() { return Promise.resolve(false); }
    static getClientCapabilities() { return Promise.resolve({ conditionalCreate: false, conditionalGet: false, hybridTransport: true, passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true, relatedOrigins: false, signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false }); }
    static parseCreationOptionsFromJSON(o) {
      const c = Object.assign({}, o, { challenge: fromB64(o.challenge), user: Object.assign({}, o.user, { id: fromB64(o.user.id) }) });
      if (o.excludeCredentials) c.excludeCredentials = o.excludeCredentials.map((x) => Object.assign({}, x, { id: fromB64(x.id) }));
      return c;
    }
    static parseRequestOptionsFromJSON(o) {
      const c = Object.assign({}, o, { challenge: fromB64(o.challenge) });
      if (o.allowCredentials) c.allowCredentials = o.allowCredentials.map((x) => Object.assign({}, x, { id: fromB64(x.id) }));
      return c;
    }
  }
  const call = async (kind, options) => {
    const signal = options.signal;
    if (signal && signal.aborted) throw new DOMException('The operation was aborted.', 'AbortError');
    const request = JSON.stringify({ kind, origin: location.origin, publicKey: plain(options.publicKey), mediation: options.mediation || '' });
    const reply = JSON.parse(await bridge.postMessage(request));
    if (reply.error) throw new DOMException(reply.message || 'The operation either timed out or was not allowed.', reply.error);
    return new PublicKeyCredential(reply.credential, kind === 'create');
  };
  const credentials = navigator.credentials;
  const originalCreate = credentials && credentials.create ? credentials.create.bind(credentials) : null;
  const originalGet = credentials && credentials.get ? credentials.get.bind(credentials) : null;
  const api = {
    create(options) {
      if (options && options.publicKey) return call('create', options);
      return originalCreate ? originalCreate(options) : Promise.reject(new DOMException('Not supported', 'NotSupportedError'));
    },
    get(options) {
      if (options && options.publicKey) {
        if (options.mediation === 'conditional') return new Promise(() => {});
        return call('get', options);
      }
      return originalGet ? originalGet(options) : Promise.reject(new DOMException('Not supported', 'NotSupportedError'));
    },
    store(c) { return credentials && credentials.store ? credentials.store(c) : Promise.resolve(c); },
    preventSilentAccess() { return Promise.resolve(); }
  };
  try {
    Object.defineProperty(navigator, 'credentials', { value: api, configurable: true });
  } catch (e) {}
  for (const [name, cls] of [['PublicKeyCredential', PublicKeyCredential], ['AuthenticatorResponse', AuthenticatorResponse], ['AuthenticatorAttestationResponse', AuthenticatorAttestationResponse], ['AuthenticatorAssertionResponse', AuthenticatorAssertionResponse]]) {
    try { Object.defineProperty(window, name, { value: cls, configurable: true, writable: true }); } catch (e) {}
  }
})();""";
        }
    }
}
