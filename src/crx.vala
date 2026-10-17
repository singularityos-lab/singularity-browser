namespace Singularity.Apps.Browser {

    public errordomain CrxError {
        INVALID,
        UNSIGNED,
        MISMATCH
    }

    public class Crx : Object {
        private const uint32 MAX_HEADER = 1 << 20;
        private const string SIGNED_PREFIX = "CRX3 SignedData";

        public string id { get; private set; default = ""; }
        public Bytes archive { get; private set; }

        private class Proof {
            public Bytes key;
            public Bytes signature;
            public bool ecdsa;
        }

        private struct Field {
            public uint number;
            public uint wire;
            public uint64 value;
            public size_t offset;
            public size_t length;
        }

        public static Crx parse (Bytes package, string? expected_id = null) throws CrxError {
            unowned uint8[] data = package.get_data ();
            if (data.length < 12 || data[0] != 'C' || data[1] != 'r' || data[2] != '2' || data[3] != '4') {
                throw new CrxError.INVALID ("This is not an extension package");
            }
            if (read_u32 (data, 4) != 3) throw new CrxError.INVALID ("Only CRX3 packages are supported");
            uint32 header_size = read_u32 (data, 8);
            if (header_size > MAX_HEADER || 12 + (size_t) header_size > data.length) {
                throw new CrxError.INVALID ("The package header is damaged");
            }
            var header = package.slice (12, 12 + header_size);
            var archive = package.slice (12 + header_size, data.length);

            var proofs = new GenericArray<Proof> ();
            Bytes? signed_data = null;
            foreach (var field in fields (header)) {
                if (field.wire != 2) continue;
                var value = header.slice (field.offset, field.offset + field.length);
                if (field.number == 2 || field.number == 3) {
                    var proof = parse_proof (value);
                    proof.ecdsa = field.number == 3;
                    proofs.add (proof);
                } else if (field.number == 10000) {
                    signed_data = value;
                }
            }
            if (signed_data == null) throw new CrxError.UNSIGNED ("The package carries no signed header");

            Bytes? crx_id = null;
            foreach (var field in fields (signed_data)) {
                if (field.number == 1 && field.wire == 2) crx_id = signed_data.slice (field.offset, field.offset + field.length);
            }
            if (crx_id == null || crx_id.get_size () != 16) throw new CrxError.UNSIGNED ("The package has no identifier");

            var message = new ByteArray ();
            message.append (SIGNED_PREFIX.data);
            message.append ({ 0 });
            uint8[] length = new uint8[4];
            write_u32 (length, (uint32) signed_data.get_size ());
            message.append (length);
            message.append (signed_data.get_data ());
            message.append (archive.get_data ());
            var signed = ByteArray.free_to_bytes ((owned) message);

            string id = id_for_bytes (crx_id);
            bool verified = false;
            foreach (var proof in proofs.data) {
                if (id_for_key (proof.key) != id) continue;
                if (!ExtensionCrypto.verify (proof.key, signed, proof.signature, proof.ecdsa)) {
                    throw new CrxError.UNSIGNED ("The package signature does not match its contents");
                }
                verified = true;
            }
            if (!verified) throw new CrxError.UNSIGNED ("The package is not signed by its own key");
            if (expected_id != null && expected_id != id) {
                throw new CrxError.MISMATCH ("The package belongs to a different extension");
            }
            var crx = new Crx ();
            crx.id = id;
            crx.archive = archive;
            return crx;
        }

        public static string id_for_key (Bytes key) {
            var checksum = new Checksum (ChecksumType.SHA256);
            checksum.update (key.get_data (), key.get_size ());
            uint8[] digest = new uint8[32];
            size_t size = digest.length;
            checksum.get_digest (digest, ref size);
            return id_for_bytes (new Bytes (digest[0:16]));
        }

        public static bool is_valid_id (string id) {
            if (id.length != 32) return false;
            for (int i = 0; i < id.length; i++) {
                if (id[i] < 'a' || id[i] > 'p') return false;
            }
            return true;
        }

        private static string id_for_bytes (Bytes bytes) {
            var builder = new StringBuilder ();
            foreach (uint8 b in bytes.get_data ()) {
                builder.append_c ((char) ('a' + (b >> 4)));
                builder.append_c ((char) ('a' + (b & 0xf)));
            }
            return builder.str;
        }

        private static Proof parse_proof (Bytes value) throws CrxError {
            var proof = new Proof ();
            foreach (var field in fields (value)) {
                if (field.wire != 2) continue;
                var slice = value.slice (field.offset, field.offset + field.length);
                if (field.number == 1) proof.key = slice;
                else if (field.number == 2) proof.signature = slice;
            }
            if (proof.key == null || proof.signature == null) throw new CrxError.INVALID ("A package signature is incomplete");
            return proof;
        }

        private static Field[] fields (Bytes message) throws CrxError {
            unowned uint8[] data = message.get_data ();
            Field[] result = {};
            size_t position = 0;
            while (position < data.length) {
                uint64 tag = read_varint (data, ref position);
                var field = Field ();
                field.number = (uint) (tag >> 3);
                field.wire = (uint) (tag & 7);
                switch (field.wire) {
                    case 0:
                        field.value = read_varint (data, ref position);
                        break;
                    case 1:
                        if (data.length - position < 8) throw new CrxError.INVALID ("The package header is truncated");
                        position += 8;
                        break;
                    case 2:
                        uint64 length = read_varint (data, ref position);
                        if (length > data.length - position) throw new CrxError.INVALID ("The package header is truncated");
                        field.offset = position;
                        field.length = (size_t) length;
                        position += (size_t) length;
                        break;
                    case 5:
                        if (data.length - position < 4) throw new CrxError.INVALID ("The package header is truncated");
                        position += 4;
                        break;
                    default:
                        throw new CrxError.INVALID ("The package header is damaged");
                }
                result += field;
            }
            return result;
        }

        private static uint64 read_varint (uint8[] data, ref size_t position) throws CrxError {
            uint64 value = 0;
            for (int shift = 0; shift < 64; shift += 7) {
                if (position >= data.length) throw new CrxError.INVALID ("The package header is truncated");
                uint8 b = data[position++];
                value |= ((uint64) (b & 0x7f)) << shift;
                if ((b & 0x80) == 0) return value;
            }
            throw new CrxError.INVALID ("The package header is damaged");
        }

        private static uint32 read_u32 (uint8[] data, size_t offset) {
            return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | ((uint32) data[offset + 3] << 24);
        }

        private static void write_u32 (uint8[] data, uint32 value) {
            data[0] = (uint8) value;
            data[1] = (uint8) (value >> 8);
            data[2] = (uint8) (value >> 16);
            data[3] = (uint8) (value >> 24);
        }
    }
}
