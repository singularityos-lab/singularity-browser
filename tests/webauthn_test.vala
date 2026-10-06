using Singularity.Apps.Browser;

Json.Object options (string json) {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (json);
    } catch (Error e) {
        error ("%s", e.message);
    }
    return parser.get_root ().get_object ();
}

Json.Object response_of (string json) {
    return options (json).get_object_member ("response");
}

void test_rp_rules () {
    assert (WebAuthnCore.rp_matches ("https://github.com", "github.com"));
    assert (WebAuthnCore.rp_matches ("https://accounts.google.com", "google.com"));
    assert (!WebAuthnCore.rp_matches ("https://github.com", "evil.com"));
    assert (!WebAuthnCore.rp_matches ("https://notgithub.com", "github.com"));
    assert (!WebAuthnCore.rp_matches ("https://a.com", "com"));
    assert (WebAuthnCore.origin_allowed ("https://github.com"));
    assert (WebAuthnCore.origin_allowed ("http://localhost:8080"));
    assert (!WebAuthnCore.origin_allowed ("http://github.com"));
}

void test_register_and_sign () {
    try {
        var create = options ("{\"rp\":{\"id\":\"example.test\",\"name\":\"Example\"},\"user\":{\"id\":\"dXNlci0x\",\"name\":\"ann\",\"displayName\":\"Ann\"},\"challenge\":\"Y2hhbGxlbmdl\",\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7}]}");
        assert (WebAuthnCore.supports_es256 (create));
        string rp = WebAuthnCore.rp_id_for_create (create, "https://login.example.test");
        assert (rp == "example.test");
        var passkey = WebAuthnCore.new_passkey (create, rp, "default");
        assert (passkey.user_name == "ann" && passkey.credential_id.length == 32);
        var reg = response_of (WebAuthnCore.registration (passkey, "Y2hhbGxlbmdl", "https://login.example.test", true));
        string client = (string) Base64Url.decode (reg.get_string_member ("clientDataJSON"));
        var cd = options (client);
        assert (cd.get_string_member ("type") == "webauthn.create" && cd.get_string_member ("challenge") == "Y2hhbGxlbmdl" && cd.get_string_member ("origin") == "https://login.example.test");
        var att = new CborReader (Base64Url.decode (reg.get_string_member ("attestationObject"))).read ();
        assert (att.lookup ("fmt").str == "none");
        uint8[] auth = att.lookup ("authData").data;
        assert (Memory.cmp (auth, WebAuthnCore.digest ("example.test".data), 32) == 0);
        assert ((auth[32] & WebAuthnCore.FLAG_AT) != 0 && (auth[32] & WebAuthnCore.FLAG_UV) != 0 && (auth[32] & WebAuthnCore.FLAG_UP) != 0);
        int id_len = (auth[53] << 8) | auth[54];
        assert (id_len == 32 && Memory.cmp (auth[55:87], passkey.credential_id, 32) == 0);
        var cose = new CborReader (auth[87:auth.length]).read ();
        assert (cose.lookup_int (1).number == 2 && cose.lookup_int (3).number == -7 && cose.lookup_int (-1).number == 1);
        var point = new ByteArray ();
        point.append (cose.lookup_int (-2).data);
        point.append (cose.lookup_int (-3).data);
        assert (point.len == 64);
        var parsed = WebAuthnCore.point_from_auth_data (auth);
        assert (Memory.cmp (parsed, point.data, 64) == 0);
        var der = PasskeyCrypto.public_der (new Bytes (passkey.private_key)).get_data ();
        var spki = WebAuthnCore.spki_from_point (parsed);
        assert (spki.length == der.length && Memory.cmp (spki, der, der.length) == 0);
        assert (Base64Url.encode (der) == reg.get_string_member ("publicKey"));
        var packed = WebAuthnCore.pack_ids (new Gee.ArrayList<string>.wrap ({ Base64Url.encode (passkey.credential_id), "AQID" }));
        assert (packed.get_size () == 2 + 32 + 2 + 3);

        var assertion = response_of (WebAuthnCore.assertion (passkey, "bG9naW4", "https://login.example.test", true));
        uint8[] a_auth = Base64Url.decode (assertion.get_string_member ("authenticatorData"));
        assert (a_auth.length == 37 && (a_auth[32] & WebAuthnCore.FLAG_AT) == 0);
        string a_client = (string) Base64Url.decode (assertion.get_string_member ("clientDataJSON"));
        assert (options (a_client).get_string_member ("type") == "webauthn.get");
        uint8[] sig = Base64Url.decode (assertion.get_string_member ("signature"));
        var signed = WebAuthnCore.signed_payload (a_auth, a_client);
        assert (PasskeyCrypto.verify (new Bytes (point.data), new Bytes (signed), new Bytes (sig)));
        signed[0] ^= 1;
        assert (!PasskeyCrypto.verify (new Bytes (point.data), new Bytes (signed), new Bytes (sig)));
        assert (Base64Url.encode (Base64Url.decode (assertion.get_string_member ("userHandle"))) == "dXNlci0x");
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_rejects_other_algorithms () {
    var create = options ("{\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-257}]}");
    assert (!WebAuthnCore.supports_es256 (create));
}

void test_cbor_round_trip () {
    try {
        var bytes = new CborWriter ().map (2).integer (-300).text ("x").text ("k").array (2).integer (70000).boolean (true).finish ();
        var v = new CborReader (bytes).read ();
        assert (v.lookup_int (-300).str == "x");
        var arr = v.lookup ("k");
        assert (arr.items.size == 2 && arr.items[0].number == 70000 && arr.items[1].number == 21);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/webauthn/rp-rules", test_rp_rules);
    Test.add_func ("/webauthn/register-and-sign", test_register_and_sign);
    Test.add_func ("/webauthn/algorithms", test_rejects_other_algorithms);
    Test.add_func ("/webauthn/cbor", test_cbor_round_trip);
    return Test.run ();
}
