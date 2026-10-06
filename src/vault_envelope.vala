namespace Singularity.Apps.Browser {

    public class VaultEnvelope : Object {
        public const int HEADER_SIZE = 196;
        public const int MAX_SIZE = 32 * 1024 * 1024;
        public string dataset { get; private set; }
        public string writer { get; private set; }
        public string epoch { get; private set; }
        public string scope { get; private set; }
        public uint64 sequence { get; private set; }
        private Bytes envelope;

        private static bool valid_id (string id) {
            return Uuid.string_is_valid (id) && id == id.down ();
        }

        private static bool valid_scope (string scope) {
            if (scope.length != 64) return false;
            foreach (uint8 c in scope.data) {
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            }
            return true;
        }

        private static Bytes record_key (Bytes root, string dataset, string writer, string epoch, string scope, uint64 sequence) throws Error {
            var key = VaultCrypto.derive (root, new Bytes ((dataset + "\n" + epoch).data),
                new Bytes (("Singularity Browser snapshot v1\n" + scope + "\n" + writer + "\n" + sequence.to_string ()).data));
            if (key == null) throw new IOError.FAILED (_("The encryption key could not be derived"));
            return key;
        }

        public static VaultEnvelope seal (Bytes root, string dataset, string writer, string epoch, string scope, uint64 sequence, Bytes plain) throws Error {
            if (!valid_id (dataset) || !valid_id (writer) || !valid_id (epoch) || !valid_scope (scope) || sequence == 0 || plain.get_size () > MAX_SIZE - HEADER_SIZE - 16)
                throw new IOError.INVALID_ARGUMENT (_("Invalid encrypted snapshot metadata"));
            var nonce = VaultCrypto.random (12);
            if (nonce == null) throw new IOError.FAILED (_("A secure nonce could not be generated"));
            var header = new ByteArray ();
            header.append ("SBV1".data);
            header.append (dataset.data);
            header.append (writer.data);
            header.append (epoch.data);
            header.append (scope.data);
            for (int shift = 56; shift >= 0; shift -= 8) {
                uint8[] octet = { (uint8) (sequence >> shift) };
                header.append (octet);
            }
            header.append (nonce.get_data ());
            assert (header.len == HEADER_SIZE);
            var authenticated = ByteArray.free_to_bytes ((owned) header);
            var key = record_key (root, dataset, writer, epoch, scope, sequence);
            var cipher = VaultCrypto.seal (key, nonce, authenticated, plain);
            if (cipher == null) throw new IOError.FAILED (_("The snapshot could not be encrypted"));
            var result = new ByteArray ();
            result.append (authenticated.get_data ());
            result.append (cipher.get_data ());
            return parse (ByteArray.free_to_bytes ((owned) result));
        }

        private static string text_at (uint8[] data, int offset, int length) {
            uint8[] text = new uint8[length + 1];
            Memory.copy (text, &data[offset], length);
            return ((string) text).dup ();
        }

        public static VaultEnvelope parse (Bytes bytes) throws Error {
            if (bytes.get_size () < HEADER_SIZE + 16 || bytes.get_size () > MAX_SIZE)
                throw new IOError.INVALID_DATA (_("Invalid encrypted snapshot size"));
            unowned uint8[] data = bytes.get_data ();
            if (text_at (data, 0, 4) != "SBV1") throw new IOError.INVALID_DATA (_("Unsupported encrypted snapshot version"));
            var result = new VaultEnvelope ();
            result.dataset = text_at (data, 4, 36);
            result.writer = text_at (data, 40, 36);
            result.epoch = text_at (data, 76, 36);
            result.scope = text_at (data, 112, 64);
            if (!valid_id (result.dataset) || !valid_id (result.writer) || !valid_id (result.epoch) || !valid_scope (result.scope))
                throw new IOError.INVALID_DATA (_("Invalid encrypted snapshot identity"));
            result.sequence = 0;
            for (int i = 176; i < 184; i++) result.sequence = (result.sequence << 8) | data[i];
            if (result.sequence == 0) throw new IOError.INVALID_DATA (_("Invalid encrypted snapshot sequence"));
            result.envelope = bytes;
            return result;
        }

        public Bytes open (Bytes root, string expected_dataset, string expected_epoch, string expected_scope, uint64 last_sequence) throws Error {
            if (dataset != expected_dataset || epoch != expected_epoch || scope != expected_scope || sequence <= last_sequence)
                throw new IOError.INVALID_DATA (_("The snapshot belongs to another dataset or has already been received"));
            var key = record_key (root, dataset, writer, epoch, scope, sequence);
            var plain = VaultCrypto.open (key, new Bytes.from_bytes (envelope, 184, 12), new Bytes.from_bytes (envelope, 0, HEADER_SIZE),
                new Bytes.from_bytes (envelope, HEADER_SIZE, envelope.get_size () - HEADER_SIZE));
            if (plain == null) throw new IOError.INVALID_DATA (_("The encrypted snapshot could not be authenticated"));
            return plain;
        }

        public Bytes bytes () {
            return envelope;
        }
    }
}
