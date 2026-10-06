namespace Singularity.Apps.Browser {

    public errordomain CableError {
        BLUETOOTH,
        TUNNEL,
        HANDSHAKE,
        PROTOCOL,
        AUTHENTICATOR,
        CANCELLED
    }

    public class Cable : Object {
        public const uint32 EID_KEY = 1;
        public const uint32 TUNNEL_ID = 2;
        public const uint32 PSK = 3;
        public const string FIDO_UUID = "0000fff9-0000-1000-8000-00805f9b34fb";
        public const string GOOGLE_UUID = "0000fde2-0000-1000-8000-00805f9b34fb";
        public const uint8 MSG_SHUTDOWN = 0;
        public const uint8 MSG_CTAP = 1;
        public const uint8 CTAP_MAKE_CREDENTIAL = 0x01;
        public const uint8 CTAP_GET_ASSERTION = 0x02;

        private const string[] ASSIGNED_DOMAINS = { "cable.ua5v.com", "cable.auth.com" };
        private const int[] WIDTHS = { 0, 3, 5, 8, 10, 13, 15, 17 };

        public static uint8[] bytes_of (GLib.Bytes? b) throws CableError {
            if (b == null) throw new CableError.PROTOCOL ("cryptographic operation failed");
            return b.get_data ();
        }

        public static uint8[] derive (uint8[] secret, uint8[] salt, uint32 type, uint length) throws CableError {
            uint8[] info = { (uint8) type, (uint8) (type >> 8), (uint8) (type >> 16), (uint8) (type >> 24) };
            return bytes_of (CableCrypto.hkdf (new GLib.Bytes (secret), new GLib.Bytes (salt), new GLib.Bytes (info), length));
        }

        public static string digits (uint8[] data) {
            var sb = new StringBuilder ();
            for (int at = 0; at < data.length; at += 7) {
                int n = int.min (7, data.length - at);
                uint64 v = 0;
                for (int i = n - 1; i >= 0; i--) v = (v << 8) | data[at + i];
                string s = v.to_string ();
                for (int pad = s.length; pad < WIDTHS[n]; pad++) sb.append_c ('0');
                sb.append (s);
            }
            return sb.str;
        }

        public static uint8[]? from_digits (string text) {
            var out_bytes = new ByteArray ();
            int at = 0;
            while (at < text.length) {
                int remaining = text.length - at;
                int width = remaining >= 17 ? 17 : remaining;
                int count = -1;
                for (int i = 1; i < WIDTHS.length; i++) if (WIDTHS[i] == width) count = i;
                if (count < 0) return null;
                uint64 v = 0;
                for (int i = at; i < at + width; i++) {
                    char c = text[i];
                    if (c < '0' || c > '9') return null;
                    if (v > (uint64.MAX - (c - '0')) / 10) return null;
                    v = v * 10 + (c - '0');
                }
                if (count < 8 && (v >> (count * 8)) != 0) return null;
                for (int i = 0; i < count; i++) out_bytes.append ({ (uint8) (v >> (i * 8)) });
                at += width;
            }
            return out_bytes.data;
        }

        public static uint8[] compress (uint8[] point) {
            var buf = new ByteArray ();
            buf.append ({ (point[63] & 1) == 1 ? (uint8) 3 : (uint8) 2 });
            buf.append (point[0:32]);
            return buf.data;
        }

        public static uint8[] x962 (uint8[] point) {
            var buf = new ByteArray ();
            buf.append ({ 4 });
            buf.append (point);
            return buf.data;
        }

        public static string qr_url (uint8[] identity_point, uint8[] secret, bool create, int64 now) {
            var cbor = new CborWriter ().map (6)
                .integer (0).bytes (compress (identity_point))
                .integer (1).bytes (secret)
                .integer (2).integer (ASSIGNED_DOMAINS.length)
                .integer (3).integer (now)
                .integer (4).boolean (false)
                .integer (5).text (create ? "mc" : "ga")
                .finish ();
            return "FIDO:/" + digits (cbor);
        }

        public static string? domain (uint16 id) {
            if (id < 256) return id < ASSIGNED_DOMAINS.length ? ASSIGNED_DOMAINS[id] : null;
            var templ = new uint8[31];
            uint8[] prefix = "caBLEv2 tunnel server domain".data;
            for (int i = 0; i < prefix.length; i++) templ[i] = prefix[i];
            templ[28] = (uint8) id;
            templ[29] = (uint8) (id >> 8);
            uint8[] digest = WebAuthnCore.digest (templ);
            uint64 result = 0;
            for (int i = 7; i >= 0; i--) result = (result << 8) | digest[i];
            string chars = "abcdefghijklmnopqrstuvwxyz234567";
            string[] tlds = { "com", "org", "net", "info" };
            int tld = (int) (result & 3);
            result >>= 2;
            var sb = new StringBuilder ("cable.");
            while (result != 0) {
                sb.append_c (chars[(int) (result & 31)]);
                result >>= 5;
            }
            sb.append_c ('.');
            sb.append (tlds[tld]);
            return sb.str;
        }

        public static uint8[]? decrypt_advert (uint8[] advert, uint8[] eid_key) {
            if (advert.length != 20 || eid_key.length != 64) return null;
            try {
                uint8[] mac = bytes_of (CableCrypto.hmac (new GLib.Bytes (eid_key[32:64]), new GLib.Bytes (advert[0:16])));
                int diff = 0;
                for (int i = 0; i < 4; i++) diff |= mac[i] ^ advert[16 + i];
                if (diff != 0) return null;
                uint8[] plain = bytes_of (CableCrypto.block_decrypt (new GLib.Bytes (eid_key[0:32]), new GLib.Bytes (advert[0:16])));
                if (plain[0] != 0) return null;
                if (domain (domain_id (plain)) == null) return null;
                return plain;
            } catch (CableError e) {
                return null;
            }
        }

        public static uint16 domain_id (uint8[] plain) {
            return (uint16) (plain[14] | (plain[15] << 8));
        }

        public static string hex (uint8[] data) {
            var sb = new StringBuilder ();
            foreach (uint8 b in data) sb.append_printf ("%02X", b);
            return sb.str;
        }

        public static string connect_url (uint8[] plain, uint8[] secret) throws CableError {
            string? host = domain (domain_id (plain));
            if (host == null) throw new CableError.PROTOCOL ("unknown tunnel server");
            uint8[] tunnel_id = derive (secret, {}, TUNNEL_ID, 16);
            return "wss://%s/cable/connect/%s/%s".printf (host, hex (plain[11:14]), hex (tunnel_id));
        }

        public static uint8[] make_credential_command (uint8[] client_hash, string rp_id, string rp_name, uint8[] user_id,
                                                       string user_name, string display_name, Gee.List<string> exclude, bool verify) {
            var w = new CborWriter ();
            w.raw ({ MSG_CTAP, CTAP_MAKE_CREDENTIAL });
            int entries = exclude.size > 0 ? 6 : 5;
            w.map (entries);
            w.integer (1).bytes (client_hash);
            w.integer (2).map (2).text ("id").text (rp_id).text ("name").text (rp_name);
            w.integer (3).map (3).text ("id").bytes (user_id).text ("name").text (user_name).text ("displayName").text (display_name != "" ? display_name : user_name);
            w.integer (4).array (1).map (2).text ("alg").integer (WebAuthnCore.ES256).text ("type").text ("public-key");
            if (exclude.size > 0) {
                var ids = new Gee.ArrayList<GLib.Bytes> ();
                foreach (string id in exclude) {
                    try {
                        ids.add (new GLib.Bytes (Base64Url.decode (id)));
                    } catch (WebAuthnError e) {
                    }
                }
                w.integer (5).array (ids.size);
                foreach (var id in ids) w.map (2).text ("id").bytes (id.get_data ()).text ("type").text ("public-key");
            }
            w.integer (7).map (verify ? 2 : 1).text ("rk").boolean (true);
            if (verify) w.text ("uv").boolean (true);
            return w.finish ();
        }

        public static uint8[] get_assertion_command (uint8[] client_hash, string rp_id, Gee.List<string> allow, bool verify) {
            var w = new CborWriter ();
            w.raw ({ MSG_CTAP, CTAP_GET_ASSERTION });
            var ids = new Gee.ArrayList<GLib.Bytes> ();
            foreach (string id in allow) {
                try {
                    ids.add (new GLib.Bytes (Base64Url.decode (id)));
                } catch (WebAuthnError e) {
                }
            }
            w.map ((ids.size > 0 ? 3 : 2) + (verify ? 1 : 0));
            w.integer (1).text (rp_id);
            w.integer (2).bytes (client_hash);
            if (ids.size > 0) {
                w.integer (3).array (ids.size);
                foreach (var id in ids) w.map (2).text ("id").bytes (id.get_data ()).text ("type").text ("public-key");
            }
            if (verify) w.integer (5).map (1).text ("uv").boolean (true);
            return w.finish ();
        }

        public static CborValue parse_ctap_response (uint8[] message) throws CableError {
            if (message.length < 2 || message[0] != MSG_CTAP) throw new CableError.PROTOCOL ("unexpected message from the phone");
            if (message[1] != 0) throw new CableError.AUTHENTICATOR ("%d".printf (message[1]));
            try {
                var value = new CborReader (message[2:message.length]).read ();
                if (value.kind != CborType.MAP) throw new CableError.PROTOCOL ("unexpected answer from the phone");
                return value;
            } catch (WebAuthnError e) {
                throw new CableError.PROTOCOL (e.message);
            }
        }
    }

    public class CableNoise : Object {
        private uint8[] ck;
        private uint8[] h;
        private uint8[] k = new uint8[32];
        private uint32 n = 0;

        public CableNoise (string name) {
            ck = new uint8[32];
            uint8[] raw = name.data;
            for (int i = 0; i < raw.length && i < 32; i++) ck[i] = raw[i];
            h = ck;
        }

        public uint8[] handshake_hash { get { return h; } }

        public void mix_hash (uint8[] data) {
            var buf = new ByteArray ();
            buf.append (h);
            buf.append (data);
            h = WebAuthnCore.digest (buf.data);
        }

        public void mix_key (uint8[] ikm) throws CableError {
            uint8[] output = Cable.bytes_of (CableCrypto.hkdf (new GLib.Bytes (ikm), new GLib.Bytes (ck), new GLib.Bytes ({}), 64));
            ck = output[0:32];
            k = output[32:64];
            n = 0;
        }

        public void mix_key_and_hash (uint8[] ikm) throws CableError {
            uint8[] output = Cable.bytes_of (CableCrypto.hkdf (new GLib.Bytes (ikm), new GLib.Bytes (ck), new GLib.Bytes ({}), 96));
            ck = output[0:32];
            mix_hash (output[32:64]);
            k = output[64:96];
            n = 0;
        }

        private uint8[] nonce () {
            var nonce = new uint8[12];
            nonce[0] = (uint8) (n >> 24);
            nonce[1] = (uint8) (n >> 16);
            nonce[2] = (uint8) (n >> 8);
            nonce[3] = (uint8) n;
            return nonce;
        }

        public uint8[] encrypt_and_hash (uint8[] plain) throws CableError {
            uint8[] ct = Cable.bytes_of (CableCrypto.seal (new GLib.Bytes (k), new GLib.Bytes (nonce ()), new GLib.Bytes (h), new GLib.Bytes (plain)));
            n++;
            mix_hash (ct);
            return ct;
        }

        public bool decrypt_and_hash (uint8[] ct, out uint8[] plain) {
            var opened = CableCrypto.open (new GLib.Bytes (k), new GLib.Bytes (nonce ()), new GLib.Bytes (h), new GLib.Bytes (ct));
            n++;
            plain = {};
            if (opened == null) return false;
            mix_hash (ct);
            plain = opened.get_data ();
            return true;
        }

        public void split (out uint8[] first, out uint8[] second) throws CableError {
            uint8[] output = Cable.bytes_of (CableCrypto.hkdf (new GLib.Bytes ({}), new GLib.Bytes (ck), new GLib.Bytes ({}), 64));
            first = output[0:32];
            second = output[32:64];
        }
    }

    public class CableCrypter : Object {
        private uint8[] read_key;
        private uint8[] write_key;
        private uint32 read_seq = 0;
        private uint32 write_seq = 0;

        public CableCrypter (uint8[] read_key, uint8[] write_key) {
            this.read_key = read_key;
            this.write_key = write_key;
        }

        private static uint8[] nonce (uint32 seq) {
            var nonce = new uint8[12];
            nonce[8] = (uint8) (seq >> 24);
            nonce[9] = (uint8) (seq >> 16);
            nonce[10] = (uint8) (seq >> 8);
            nonce[11] = (uint8) seq;
            return nonce;
        }

        public uint8[] encrypt (uint8[] message) throws CableError {
            int padded = (message.length + 1 + 31) & ~31;
            var buf = new uint8[padded];
            for (int i = 0; i < message.length; i++) buf[i] = message[i];
            buf[padded - 1] = (uint8) (padded - message.length - 1);
            return Cable.bytes_of (CableCrypto.seal (new GLib.Bytes (write_key), new GLib.Bytes (nonce (write_seq++)), new GLib.Bytes ({}), new GLib.Bytes (buf)));
        }

        public uint8[] decrypt (uint8[] ciphertext) throws CableError {
            var plain = CableCrypto.open (new GLib.Bytes (read_key), new GLib.Bytes (nonce (read_seq)), new GLib.Bytes ({}), new GLib.Bytes (ciphertext));
            if (plain == null) throw new CableError.PROTOCOL ("could not decrypt a message from the phone");
            read_seq++;
            uint8[] data = plain.get_data ();
            if (data.length == 0) throw new CableError.PROTOCOL ("empty message from the phone");
            int pad = data[data.length - 1];
            if (pad + 1 > data.length) throw new CableError.PROTOCOL ("broken message from the phone");
            return data[0:data.length - pad - 1];
        }
    }

    public class CableHandshake : Object {
        public const string PROTOCOL = "Noise_KNpsk0_P256_AESGCM_SHA256";
        private CableNoise noise;
        private uint8[] identity_key;
        private uint8[] ephemeral_key;

        public CableHandshake (uint8[] identity_key) {
            this.identity_key = identity_key;
        }

        public uint8[] initial_message (uint8[] psk) throws CableError {
            noise = new CableNoise (PROTOCOL);
            noise.mix_hash ({ 1 });
            noise.mix_hash (Cable.x962 (Cable.bytes_of (PasskeyCrypto.public_point (new GLib.Bytes (identity_key)))));
            noise.mix_key_and_hash (psk);
            ephemeral_key = Cable.bytes_of (PasskeyCrypto.generate ());
            uint8[] e_pub = Cable.x962 (Cable.bytes_of (PasskeyCrypto.public_point (new GLib.Bytes (ephemeral_key))));
            noise.mix_hash (e_pub);
            noise.mix_key (e_pub);
            uint8[] ct = noise.encrypt_and_hash ({});
            var buf = new ByteArray ();
            buf.append (e_pub);
            buf.append (ct);
            return buf.data;
        }

        public CableCrypter process_response (uint8[] response) throws CableError {
            if (response.length != 65 + 16 || response[0] != 4) throw new CableError.HANDSHAKE ("unexpected handshake answer");
            uint8[] peer = response[0:65];
            uint8[] ee = Cable.bytes_of (CableCrypto.ecdh (new GLib.Bytes (ephemeral_key), new GLib.Bytes (peer[1:65])));
            noise.mix_hash (peer);
            noise.mix_key (peer);
            noise.mix_key (ee);
            uint8[] se = Cable.bytes_of (CableCrypto.ecdh (new GLib.Bytes (identity_key), new GLib.Bytes (peer[1:65])));
            noise.mix_key (se);
            uint8[] plain;
            if (!noise.decrypt_and_hash (response[65:81], out plain) || plain.length != 0) throw new CableError.HANDSHAKE ("the phone failed the handshake");
            uint8[] write_key, read_key;
            noise.split (out write_key, out read_key);
            return new CableCrypter (read_key, write_key);
        }
    }
}
