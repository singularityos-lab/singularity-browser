using Singularity.Apps.Browser;

Bytes hex (string value) {
    uint8[] bytes = new uint8[value.length / 2];
    for (int i = 0; i < bytes.length; i++) bytes[i] = (uint8) uint.parse (value.substring (i * 2, 2), 16);
    return new Bytes (bytes);
}

void primitives () {
    assert (VaultCrypto.authenticate (hex ("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), new Bytes ("Hi There".data)).compare (hex ("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")) == 0);
    var key = new Bytes (new uint8[32]);
    var nonce = new Bytes (new uint8[12]);
    var plain = new Bytes (new uint8[16]);
    var aad = new Bytes (new uint8[0]);
    var encrypted = VaultCrypto.seal (key, nonce, aad, plain);
    assert (encrypted != null);
    assert (encrypted.compare (hex ("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")) == 0);
    assert (VaultCrypto.open (key, nonce, aad, encrypted).compare (plain) == 0);
    uint8[] source = new uint8[32];
    for (int i = 0; i < source.length; i++) source[i] = 11;
    var derived = VaultCrypto.derive (new Bytes (source), hex ("000102030405060708090a0b0c"), hex ("f0f1f2f3f4f5f6f7f8f9"));
    assert (derived != null);
    assert (derived.compare (hex ("d4100799f26a09615a72af3e58fa3841a2ff20d5ace3fb392e562e207fe6b718")) == 0);
    assert (VaultCrypto.seal (new Bytes (new uint8[31]), nonce, aad, plain) == null);
    assert (VaultCrypto.seal (key, new Bytes (new uint8[11]), aad, plain) == null);
}

void rejected (Bytes bytes, Bytes root, string dataset, string epoch, string scope, uint64 sequence) {
    try {
        VaultEnvelope.parse (bytes).open (root, dataset, epoch, scope, sequence);
        assert_not_reached ();
    } catch (Error e) {
        assert (e is IOError.INVALID_DATA);
    }
}

void signatures () {
    var key = hex ("302e020100300506032b6570042204209d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    var public_key = hex ("302a300506032b6570032100d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    var message = new Bytes (new uint8[0]);
    var signature = hex ("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
    assert (VaultCrypto.public_key (key).compare (public_key) == 0);
    assert (VaultCrypto.sign (key, message).compare (signature) == 0);
    assert (VaultCrypto.verify (public_key, message, signature));
    assert (!VaultCrypto.verify (public_key, new Bytes ("modified".data), signature));
    var other = VaultCrypto.signing_key ();
    assert (other != null);
    var other_public = VaultCrypto.public_key (other);
    assert (other_public != null);
    assert (!VaultCrypto.verify (other_public, message, signature));
    assert (VaultCrypto.verify (other_public, message, VaultCrypto.sign (other, message)));
    for (int i = 0; i < 64; i++) {
        uint8[] changed = new uint8[64];
        Memory.copy (changed, signature.get_data (), 64);
        changed[i] ^= 1;
        assert (!VaultCrypto.verify (public_key, message, new Bytes (changed)));
    }
    assert (VaultCrypto.public_key (message) == null);
    assert (VaultCrypto.sign (message, message) == null);
    assert (!VaultCrypto.verify (message, message, signature));
    assert (!VaultCrypto.verify (public_key, message, new Bytes.from_bytes (signature, 0, 63)));
}

void key_exchange () {
    var alice = hex ("302e020100300506032b656e0422042077076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    var alice_public = hex ("302a300506032b656e0321008520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    var bob = hex ("302e020100300506032b656e042204205dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    var bob_public = hex ("302a300506032b656e032100de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    var shared = hex ("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
    assert (VaultCrypto.exchange_public (alice).compare (alice_public) == 0);
    assert (VaultCrypto.exchange_public (bob).compare (bob_public) == 0);
    assert (VaultCrypto.exchange (alice, bob_public).compare (shared) == 0);
    assert (VaultCrypto.exchange (bob, alice_public).compare (shared) == 0);
    var generated = VaultCrypto.exchange_key ();
    assert (generated != null);
    var public_key = VaultCrypto.exchange_public (generated);
    assert (public_key != null);
    assert (VaultCrypto.exchange (generated, alice_public).compare (VaultCrypto.exchange (alice, public_key)) == 0);
    var zero = hex ("302a300506032b656e0321000000000000000000000000000000000000000000000000000000000000000000");
    assert (VaultCrypto.exchange (alice, zero) == null);
    var signing = VaultCrypto.signing_key ();
    assert (VaultCrypto.exchange_public (signing) == null);
    assert (VaultCrypto.exchange (signing, alice_public) == null);
    assert (VaultCrypto.exchange (alice, VaultCrypto.public_key (signing)) == null);
    assert (VaultCrypto.sign (alice, shared) == null);
    assert (VaultCrypto.exchange (alice, new Bytes.from_bytes (bob_public, 0, 43)) == null);
}

void envelope () {
    try {
        var root = VaultCrypto.random (32);
        assert (root != null);
        string dataset = Uuid.string_random ();
        string writer = Uuid.string_random ();
        string epoch = Uuid.string_random ();
        string scope = Checksum.compute_for_string (ChecksumType.SHA256, "synthetic provider identity");
        var plain = new Bytes ("Synthetic password, bookmark, history and session payload".data);
        var sealed = VaultEnvelope.seal (root, dataset, writer, epoch, scope, 7, plain);
        assert (sealed.open (root, dataset, epoch, scope, 6).compare (plain) == 0);
        assert (sealed.sequence == 7 && sealed.writer == writer);
        var second = VaultEnvelope.seal (root, dataset, writer, epoch, scope, 7, plain);
        assert (sealed.bytes ().compare (second.bytes ()) != 0);
        rejected (sealed.bytes (), VaultCrypto.random (32), dataset, epoch, scope, 6);
        rejected (sealed.bytes (), root, Uuid.string_random (), epoch, scope, 6);
        rejected (sealed.bytes (), root, dataset, Uuid.string_random (), scope, 6);
        rejected (sealed.bytes (), root, dataset, epoch, Checksum.compute_for_string (ChecksumType.SHA256, "other identity"), 6);
        rejected (sealed.bytes (), root, dataset, epoch, scope, 7);
        rejected (sealed.bytes (), root, dataset, epoch, scope, 8);
        unowned uint8[] data = sealed.bytes ().get_data ();
        for (int i = 0; i < data.length; i++) {
            uint8[] tampered = new uint8[data.length];
            Memory.copy (tampered, data, data.length);
            tampered[i] ^= 1;
            rejected (new Bytes (tampered), root, dataset, epoch, scope, 6);
        }
        for (int i = 0; i < data.length; i++) rejected (new Bytes.from_bytes (sealed.bytes (), 0, i), root, dataset, epoch, scope, 6);
        var extra = new ByteArray ();
        extra.append (data);
        extra.append (new uint8[1]);
        rejected (ByteArray.free_to_bytes ((owned) extra), root, dataset, epoch, scope, 6);
    } catch (Error e) {
        error ("Vault test: %s", e.message);
    }
}

int main (string[] args) {
    assert (Environment.get_variable ("DISPLAY") == null);
    assert (Environment.get_variable ("GDK_BACKEND") == "wayland");
    assert (Environment.get_variable ("SINGULARITY_SYSTEM_BUS") == Environment.get_variable ("DBUS_SYSTEM_BUS_ADDRESS"));
    Gtk.init ();
    if (args.length == 7 && args[1] == "reserve-and-exit") ledger_crash_child (args);
    ledger_test_binary = args[0];
    Test.init (ref args);
    Test.add_func ("/vault/primitives", primitives);
    Test.add_func ("/vault/envelope", envelope);
    Test.add_func ("/vault/signatures", signatures);
    Test.add_func ("/vault/key-exchange", key_exchange);
    Test.add_func ("/vault/ledger", ledger_tests);
    Test.add_func ("/vault/dataset", dataset_tests);
    return Test.run ();
}
