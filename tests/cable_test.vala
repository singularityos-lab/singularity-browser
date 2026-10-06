using Singularity.Apps.Browser;

uint8[] unhex (string s) {
    var out_bytes = new uint8[s.length / 2];
    for (int i = 0; i < out_bytes.length; i++) out_bytes[i] = (uint8) ulong.parse (s.substring (i * 2, 2), 16);
    return out_bytes;
}

string lower_hex (uint8[] data) {
    return Cable.hex (data).down ();
}

void test_digits () {
    uint8[] data = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 255 };
    string d = Cable.digits (data);
    assert (d.length == 17 + 10);
    var back = Cable.from_digits (d);
    assert (back != null && back.length == data.length && Memory.cmp (back, data, data.length) == 0);
    assert (Cable.digits ({ 1 }) == "001");
    assert (Cable.from_digits ("1234") == null);
}

void test_qr () {
    try {
        var key = PasskeyCrypto.generate ();
        uint8[] point = key != null ? PasskeyCrypto.public_point (key).get_data () : new uint8[0];
        uint8[] secret = new uint8[16];
        string url = Cable.qr_url (point, secret, true, 1700000000);
        assert (url.has_prefix ("FIDO:/"));
        var raw = Cable.from_digits (url.substring (6));
        var map = new CborReader (raw).read ();
        assert (map.lookup_int (0).data.length == 33 && map.lookup_int (1).data.length == 16);
        assert (map.lookup_int (2).number == 2 && map.lookup_int (3).number == 1700000000 && map.lookup_int (5).str == "mc");
        assert (Memory.cmp (map.lookup_int (0).data[1:33], point[0:32], 32) == 0);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_advert () {
    try {
        uint8[] secret = PasskeyCrypto.random (16).get_data ();
        uint8[] key = Cable.derive (secret, {}, Cable.EID_KEY, 64);
        uint8[] plain = new uint8[16];
        for (int i = 1; i < 11; i++) plain[i] = (uint8) i;
        plain[11] = 0xab; plain[12] = 0xcd; plain[13] = 0xef;
        plain[14] = 1; plain[15] = 0;
        uint8[] ct = CableCrypto.block_encrypt (new Bytes (key[0:32]), new Bytes (plain)).get_data ();
        uint8[] mac = CableCrypto.hmac (new Bytes (key[32:64]), new Bytes (ct)).get_data ();
        var advert = new ByteArray ();
        advert.append (ct);
        advert.append (mac[0:4]);
        var got = Cable.decrypt_advert (advert.data, key);
        assert (got != null && Memory.cmp (got, plain, 16) == 0);
        string url = Cable.connect_url (got, secret);
        assert (url.has_prefix ("wss://cable.auth.com/cable/connect/ABCDEF/") && url.length == "wss://cable.auth.com/cable/connect/ABCDEF/".length + 32);
        advert.data[17] ^= 1;
        assert (Cable.decrypt_advert (advert.data, key) == null);
        assert (Cable.domain (0) == "cable.ua5v.com" && Cable.domain (2) == null);
        string? hashed = Cable.domain (266);
        assert (hashed != null && hashed.has_prefix ("cable.") && hashed.contains ("."));
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_handshake_with_python () {
    string? responder = Environment.get_variable ("CABLE_RESPONDER");
    if (responder == null) {
        Test.skip ("no responder");
        return;
    }
    try {
        uint8[] identity = PasskeyCrypto.generate ().get_data ();
        uint8[] psk = PasskeyCrypto.random (32).get_data ();
        var hs = new CableHandshake (identity);
        uint8[] first = hs.initial_message (psk);
        assert (first.length == 81);
        var proc = new Subprocess.newv ({ "python3", responder }, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        var input = new DataOutputStream (proc.get_stdin_pipe ());
        var output = new DataInputStream (proc.get_stdout_pipe ());
        var errors = new DataInputStream (proc.get_stderr_pipe ());
        input.put_string (lower_hex (psk) + "\n");
        input.put_string (lower_hex (Cable.x962 (PasskeyCrypto.public_point (new Bytes (identity)).get_data ())) + "\n");
        input.put_string (lower_hex (first) + "\n");
        input.flush ();
        var crypter = hs.process_response (unhex (output.read_line ()));
        uint8[] post = crypter.decrypt (unhex (output.read_line ()));
        var map = new CborReader (post).read ();
        assert (map.kind == CborType.MAP && map.lookup_int (1).data.length == 3);
        var command = Cable.get_assertion_command (new uint8[32], "example.com", new Gee.ArrayList<string> (), true);
        input.put_string (lower_hex (crypter.encrypt (command)) + "\n");
        input.flush ();
        string echoed = errors.read_line ();
        assert (echoed == lower_hex (command));
        var reply = Cable.parse_ctap_response (crypter.decrypt (unhex (output.read_line ())));
        assert (reply.lookup_int (1).str == "demo");
        proc.wait ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/cable/digits", test_digits);
    Test.add_func ("/cable/qr", test_qr);
    Test.add_func ("/cable/advert", test_advert);
    Test.add_func ("/cable/handshake-python", test_handshake_with_python);
    return Test.run ();
}
