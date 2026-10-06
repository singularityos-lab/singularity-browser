namespace Singularity.Apps.Browser {

    public class CableScanner : Object {
        private DBusConnection? bus = null;
        private string adapter = "";
        private uint added_id = 0;
        private uint changed_id = 0;
        private uint8[] eid_key;
        private bool done = false;

        public signal void found (uint8[] plain);

        public CableScanner (uint8[] eid_key) {
            this.eid_key = eid_key;
        }

        public async void start () throws Error {
            try {
                yield begin_scan ();
            } catch (CableError e) {
                throw e;
            } catch (Error e) {
                warning ("Bluetooth scan: %s", e.message);
                throw new CableError.BLUETOOTH (_("Bluetooth is not available. Turn it on to use a phone near this computer."));
            }
        }

        private async void begin_scan () throws Error {
            bus = yield Bus.get (BusType.SYSTEM, null);
            var objects = yield bus.call ("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects",
                null, new VariantType ("(a{oa{sa{sv}}})"), DBusCallFlags.NONE, 5000, null);
            var iter = objects.get_child_value (0).iterator ();
            string path;
            Variant ifaces;
            while (iter.next ("{o@a{sa{sv}}}", out path, out ifaces)) {
                var adapter_props = ifaces.lookup_value ("org.bluez.Adapter1", null);
                if (adapter_props != null && adapter == "") {
                    var powered = adapter_props.lookup_value ("Powered", VariantType.BOOLEAN);
                    if (powered != null && powered.get_boolean ()) adapter = path;
                }
            }
            if (adapter == "") throw new CableError.BLUETOOTH (_("Turn on Bluetooth to use a phone. Your phone needs to be near this computer."));
            added_id = bus.signal_subscribe ("org.bluez", "org.freedesktop.DBus.ObjectManager", "InterfacesAdded", null, null, DBusSignalFlags.NONE,
                (c, sender, obj, iface, sig, parameters) => {
                    var props = parameters.get_child_value (1).lookup_value ("org.bluez.Device1", null);
                    if (props != null) inspect (props);
                });
            changed_id = bus.signal_subscribe ("org.bluez", "org.freedesktop.DBus.Properties", "PropertiesChanged", null, null, DBusSignalFlags.NONE,
                (c, sender, obj, iface, sig, parameters) => {
                    if (parameters.get_child_value (0).get_string () != "org.bluez.Device1") return;
                    inspect (parameters.get_child_value (1));
                });
            var filter = new VariantBuilder (new VariantType ("a{sv}"));
            filter.add ("{sv}", "Transport", new Variant.string ("le"));
            filter.add ("{sv}", "DuplicateData", new Variant.boolean (true));
            yield bus.call ("org.bluez", adapter, "org.bluez.Adapter1", "SetDiscoveryFilter",
                new Variant.tuple ({ filter.end () }), null, DBusCallFlags.NONE, 5000, null);
            yield bus.call ("org.bluez", adapter, "org.bluez.Adapter1", "StartDiscovery", null, null, DBusCallFlags.NONE, 5000, null);
        }

        private void inspect (Variant props) {
            if (done) return;
            var data = props.lookup_value ("ServiceData", new VariantType ("a{sv}"));
            if (data == null) return;
            foreach (string uuid in new string[] { Cable.GOOGLE_UUID, Cable.FIDO_UUID }) {
                var value = data.lookup_value (uuid, null);
                if (value == null) continue;
                if (value.is_of_type (VariantType.VARIANT)) value = value.get_variant ();
                if (!value.is_of_type (new VariantType ("ay"))) continue;
                uint8[] advert = value.get_data_as_bytes ().get_data ();
                var plain = Cable.decrypt_advert (advert, eid_key);
                if (plain != null) {
                    done = true;
                    found (plain);
                    return;
                }
            }
        }

        public void stop () {
            done = true;
            if (bus == null) return;
            if (added_id != 0) bus.signal_unsubscribe (added_id);
            if (changed_id != 0) bus.signal_unsubscribe (changed_id);
            added_id = changed_id = 0;
            if (adapter != "") {
                bus.call.begin ("org.bluez", adapter, "org.bluez.Adapter1", "StopDiscovery", null, null, DBusCallFlags.NONE, 5000, null, (o, r) => {
                    try {
                        bus.call.end (r);
                    } catch (Error e) {
                    }
                });
            }
        }
    }

    public class CableTunnel : Object {
        private Soup.WebsocketConnection? socket = null;
        private Queue<GLib.Bytes> inbox = new Queue<GLib.Bytes> ();
        private SourceFunc? waiting = null;
        private bool closed = false;

        public async void connect_to (string url, Cancellable? cancellable) throws Error {
            var session = new Soup.Session ();
            session.timeout = 30;
            var message = new Soup.Message ("GET", url);
            string host = message.uri.get_host ();
            socket = yield session.websocket_connect_async (message, "wss://" + host, { "fido.cable" }, Priority.DEFAULT, cancellable);
            socket.max_incoming_payload_size = 1 << 20;
            socket.message.connect ((type, data) => {
                inbox.push_tail (data);
                wake ();
            });
            socket.closed.connect (() => {
                closed = true;
                wake ();
            });
        }

        private void wake () {
            if (waiting != null) {
                var cb = (owned) waiting;
                waiting = null;
                Idle.add ((owned) cb);
            }
        }

        public void send (uint8[] data) {
            if (socket != null && !closed) socket.send_message (Soup.WebsocketDataType.BINARY, new GLib.Bytes (data));
        }

        public async uint8[] receive (Cancellable? cancellable) throws Error {
            while (inbox.is_empty ()) {
                if (closed) throw new CableError.TUNNEL (_("The phone disconnected"));
                if (cancellable != null && cancellable.is_cancelled ()) throw new CableError.CANCELLED (_("Canceled"));
                ulong handler = 0;
                if (cancellable != null) handler = cancellable.connect (() => wake ());
                waiting = receive.callback;
                yield;
                if (cancellable != null && handler != 0) cancellable.disconnect (handler);
            }
            return inbox.pop_head ().get_data ();
        }

        public void close () {
            if (socket != null && !closed && socket.state == Soup.WebsocketState.OPEN) socket.close (1000, null);
            closed = true;
        }
    }

    public class CableSession : Object {
        public uint8[] identity_key { get; private set; }
        public uint8[] secret { get; private set; }
        public string qr { get; private set; }

        public signal void status (string text);

        public CableSession (bool create) throws CableError {
            identity_key = Cable.bytes_of (PasskeyCrypto.generate ());
            secret = Cable.bytes_of (PasskeyCrypto.random (16));
            uint8[] point = Cable.bytes_of (PasskeyCrypto.public_point (new GLib.Bytes (identity_key)));
            qr = Cable.qr_url (point, secret, create, get_real_time () / 1000000);
        }

        private async uint8[] wait_for_phone (Cancellable cancellable) throws Error {
            var scanner = new CableScanner (Cable.derive (secret, {}, Cable.EID_KEY, 64));
            uint8[]? plain = null;
            SourceFunc resume = wait_for_phone.callback;
            bool resumed = false;
            scanner.found.connect ((p) => {
                plain = p;
                if (!resumed) {
                    resumed = true;
                    Idle.add ((owned) resume);
                }
            });
            ulong handler = cancellable.connect (() => {
                Idle.add (() => {
                    if (!resumed) {
                        resumed = true;
                        wait_for_phone.callback ();
                    }
                    return Source.REMOVE;
                });
            });
            uint timeout = Timeout.add_seconds (180, () => {
                cancellable.cancel ();
                return Source.REMOVE;
            });
            try {
                yield scanner.start ();
                yield;
            } finally {
                scanner.stop ();
                cancellable.disconnect (handler);
                if (!cancellable.is_cancelled ()) Source.remove (timeout);
            }
            if (plain == null) throw new CableError.CANCELLED (_("No phone answered"));
            return plain;
        }

        public async uint8[] transact (uint8[] command, Cancellable cancellable) throws Error {
            status (_("Scan the QR code with your phone's camera. Keep Bluetooth on and the phone near this computer."));
            uint8[] plain = yield wait_for_phone (cancellable);
            status (_("Connecting to your phone…"));
            var tunnel = new CableTunnel ();
            try {
                yield tunnel.connect_to (Cable.connect_url (plain, secret), cancellable);
                var handshake = new CableHandshake (identity_key);
                tunnel.send (handshake.initial_message (Cable.derive (secret, plain, Cable.PSK, 32)));
                var crypter = handshake.process_response (yield tunnel.receive (cancellable));
                uint8[] post = crypter.decrypt (yield tunnel.receive (cancellable));
                bool framed = true;
                try {
                    var reader = new CborReader (post);
                    var map = reader.read ();
                    if (map.kind != CborType.MAP || reader.offset != post.length) framed = false;
                } catch (WebAuthnError e) {
                    framed = false;
                }
                status (_("Confirm on your phone…"));
                uint8[] request = framed ? command : command[1:command.length];
                tunnel.send (crypter.encrypt (request));
                while (true) {
                    uint8[] reply = crypter.decrypt (yield tunnel.receive (cancellable));
                    if (!framed) {
                        var buf = new ByteArray ();
                        buf.append ({ Cable.MSG_CTAP });
                        buf.append (reply);
                        reply = buf.data;
                    }
                    if (reply.length == 0) continue;
                    if (reply[0] == Cable.MSG_SHUTDOWN) throw new CableError.TUNNEL (_("The phone ended the connection"));
                    if (reply[0] != Cable.MSG_CTAP) continue;
                    if (framed) tunnel.send (crypter.encrypt ({ Cable.MSG_SHUTDOWN }));
                    return reply;
                }
            } finally {
                tunnel.close ();
            }
        }
    }
}
