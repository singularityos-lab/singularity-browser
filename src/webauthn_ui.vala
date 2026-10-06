using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    [CCode (cname = "getpid", cheader_filename = "unistd.h")]
    private extern int process_id ();
    [CCode (cname = "getuid", cheader_filename = "unistd.h")]
    private extern int user_id ();

    namespace FidoCode {
    public const int OK = 0;
    public const int ERR_CREDENTIAL_EXCLUDED = 0x19;
    public const int ERR_KEEPALIVE_CANCEL = 0x2d;
    public const int ERR_NO_CREDENTIALS = 0x2e;
    public const int ERR_ACTION_TIMEOUT = 0x2f;
    public const int ERR_PIN_INVALID = 0x31;
    public const int ERR_PIN_BLOCKED = 0x32;
    public const int ERR_PIN_AUTH_BLOCKED = 0x34;
    public const int ERR_PIN_NOT_SET = 0x35;
    public const int ERR_PIN_REQUIRED = 0x36;
    public const int ERR_UV_BLOCKED = 0x3c;
    public const int ERR_OPERATION_DENIED = 0x27;
    }

    public class WebAuthnPrompt : Object {
        public const string ACTION_ID = "dev.sinty.browser.passkey";

        public Gtk.Application app { get; construct; }
        public Gtk.Window? parent { get; construct; }
        public string profile { get; construct; }

        public WebAuthnPrompt (Gtk.Application app, Gtk.Window? parent, string profile) {
            Object (app: app, parent: parent, profile: profile);
        }

        public static string error_reply (string name, string message) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("error");
            b.add_string_value (name);
            b.set_member_name ("message");
            b.add_string_value (message);
            b.end_object ();
            var g = new Json.Generator ();
            g.set_root (b.get_root ());
            return g.to_data (null);
        }

        private static string credential_reply (string credential) {
            return "{\"credential\":" + credential + "}";
        }

        public async string handle (string request, string page_origin) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (request);
                var root = parser.get_root ().get_object ();
                string kind = root.get_string_member ("kind");
                string claimed = root.has_member ("origin") ? root.get_string_member ("origin") : "";
                if (claimed != page_origin) throw new WebAuthnError.SECURITY (_("The request did not come from this page"));
                if (!WebAuthnCore.origin_allowed (page_origin)) throw new WebAuthnError.SECURITY (_("Passkeys need a secure connection"));
                if (profile == "" || profile == "private") throw new WebAuthnError.NOT_ALLOWED (_("Passkeys are not available in a private window"));
                var options = root.get_object_member ("publicKey");
                string challenge = options.get_string_member ("challenge");
                if (kind == "create") return credential_reply (yield create (options, challenge, page_origin));
                if (kind == "get") return credential_reply (yield get (options, challenge, page_origin));
                throw new WebAuthnError.NOT_SUPPORTED (_("Unknown passkey request"));
            } catch (WebAuthnError.INVALID_STATE e) {
                return error_reply ("InvalidStateError", e.message);
            } catch (WebAuthnError.SECURITY e) {
                return error_reply ("SecurityError", e.message);
            } catch (WebAuthnError.NOT_SUPPORTED e) {
                return error_reply ("NotSupportedError", e.message);
            } catch (Error e) {
                return error_reply ("NotAllowedError", e.message);
            }
        }

        private const string ON_COMPUTER = "computer";
        private const string ON_KEY = "key";
        private const string ON_PHONE = "phone";

        private static Gee.ArrayList<Singularity.Core.AppSettingOption> places (bool computer) {
            var list = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            if (computer) list.add (new Singularity.Core.AppSettingOption () { id = ON_COMPUTER, label = _("This Computer") });
            list.add (new Singularity.Core.AppSettingOption () { id = ON_PHONE, label = _("Phone or Tablet") });
            list.add (new Singularity.Core.AppSettingOption () { id = ON_KEY, label = _("Security Key") });
            return list;
        }

        private static string attachment_of (Json.Object options) {
            if (!options.has_member ("authenticatorSelection")) return "";
            var sel = options.get_member ("authenticatorSelection");
            if (sel.get_node_type () != Json.NodeType.OBJECT) return "";
            return WebAuthnCore.member_string (sel.get_object (), "authenticatorAttachment");
        }

        private static bool wants_verification (Json.Object options) {
            string uv = WebAuthnCore.member_string (options, "userVerification");
            if (options.has_member ("authenticatorSelection") && options.get_member ("authenticatorSelection").get_node_type () == Json.NodeType.OBJECT)
                uv = WebAuthnCore.member_string (options.get_object_member ("authenticatorSelection"), "userVerification");
            return uv != "discouraged";
        }

        private async string create (Json.Object options, string challenge, string origin) throws Error {
            string rp_id = WebAuthnCore.rp_id_for_create (options, origin);
            if (!WebAuthnCore.rp_matches (origin, rp_id)) throw new WebAuthnError.SECURITY (_("This site cannot create a passkey for %s").printf (rp_id));
            if (!WebAuthnCore.supports_es256 (options)) throw new WebAuthnError.NOT_SUPPORTED (_("The site asks for a key type this browser does not make"));
            var excluded = WebAuthnCore.credential_ids (options, "excludeCredentials");
            if (yield PasskeyStore.exists (rp_id, profile, excluded)) {
                yield notice (_("Passkey Already Saved"), _("This computer already has a passkey for your account on %s.").printf (rp_id));
                throw new WebAuthnError.INVALID_STATE (_("A passkey for this account already exists"));
            }
            var passkey = WebAuthnCore.new_passkey (options, rp_id, profile);
            string attachment = attachment_of (options);
            var dialog = new ConfirmDialog (app, _("Create a Passkey?"), "dialog-password",
                _("%s will let you sign in as %s without typing a password.").printf (rp_id, passkey.label),
                _("Create"), ConfirmDialog.ActionStyle.SUGGESTED);
            var group = new PreferencesGroup ();
            var where = new SelectionRow.with_options (_("Save On"), places (attachment != "cross-platform"), attachment == "cross-platform" ? ON_PHONE : ON_COMPUTER);
            group.add_row (where);
            dialog.custom_area.append (group);
            if (!(yield ask (dialog))) throw new WebAuthnError.NOT_ALLOWED (_("The passkey was not created"));
            if (where.current_value == ON_KEY) return yield create_on_key (options, passkey, excluded, challenge, origin);
            if (where.current_value == ON_PHONE) return yield create_on_phone (options, passkey, excluded, challenge, origin);
            yield verify_user (rp_id);
            yield PasskeyStore.save (passkey);
            return WebAuthnCore.registration (passkey, challenge, origin, true);
        }

        private async string get (Json.Object options, string challenge, string origin) throws Error {
            string rp_id = WebAuthnCore.rp_id_for_get (options, origin);
            if (!WebAuthnCore.rp_matches (origin, rp_id)) throw new WebAuthnError.SECURITY (_("This site cannot use passkeys of %s").printf (rp_id));
            var allowed = WebAuthnCore.credential_ids (options, "allowCredentials");
            var found = yield PasskeyStore.find (rp_id, profile, allowed);
            var choices = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            for (int i = 0; i < found.size; i++) choices.add (new Singularity.Core.AppSettingOption () { id = i.to_string (), label = found[i].label });
            choices.add (new Singularity.Core.AppSettingOption () { id = ON_PHONE, label = _("Phone or Tablet") });
            choices.add (new Singularity.Core.AppSettingOption () { id = ON_KEY, label = _("Security Key") });
            var dialog = new ConfirmDialog (app, _("Sign In with a Passkey"), "dialog-password",
                found.size > 0 ? _("Choose how to sign in to %s.").printf (rp_id) : _("This computer has no passkey for %s. Use a passkey on another device.").printf (rp_id),
                _("Continue"), ConfirmDialog.ActionStyle.SUGGESTED);
            var group = new PreferencesGroup ();
            var row = new SelectionRow.with_options (_("Passkey"), choices, found.size > 0 ? "0" : ON_PHONE);
            group.add_row (row);
            dialog.custom_area.append (group);
            if (!(yield ask (dialog))) throw new WebAuthnError.NOT_ALLOWED (_("Sign-in was canceled"));
            if (row.current_value == ON_KEY) return yield get_on_key (options, rp_id, allowed, challenge, origin);
            if (row.current_value == ON_PHONE) return yield get_on_phone (options, rp_id, allowed, challenge, origin);
            var chosen = found[int.parse (row.current_value).clamp (0, found.size - 1)];
            yield verify_user (rp_id);
            return WebAuthnCore.assertion (chosen, challenge, origin, true);
        }

        private async string? key_path () throws Error {
            while (true) {
                string? path = FidoDevice.find ();
                if (path != null) return path;
                var dialog = new ConfirmDialog (app, _("Insert Your Security Key"), "dialog-password",
                    _("Plug in your security key, then try again."), _("Try Again"), ConfirmDialog.ActionStyle.SUGGESTED);
                if (!(yield ask (dialog))) throw new WebAuthnError.NOT_ALLOWED (_("No security key"));
            }
        }

        private async string? key_pin (string path, string? message) throws Error {
            if (FidoDevice.needs_pin (path) != 1 && message == null) return null;
            var dialog = new ConfirmDialog (app, _("Security Key PIN"), "dialog-password",
                message ?? _("Enter the PIN of your security key."), _("Continue"), ConfirmDialog.ActionStyle.SUGGESTED);
            var entry = new PasswordEntry ();
            entry.show_peek_icon = true;
            entry.activates_default = true;
            entry.activate.connect (() => dialog.response (ConfirmDialog.Response.PRIMARY));
            dialog.custom_area.append (entry);
            Idle.add (() => {
                entry.grab_focus ();
                return Source.REMOVE;
            });
            if (!(yield ask (dialog, false))) throw new WebAuthnError.NOT_ALLOWED (_("No PIN was entered"));
            return entry.text;
        }

        private delegate int KeyCall ();

        private async int with_touch (owned KeyCall call) {
            var dialog = new ConfirmDialog (app, _("Touch Your Security Key"), "dialog-password",
                _("Touch the flashing button on your security key."), _("Cancel"), ConfirmDialog.ActionStyle.DEFAULT);
            if (parent != null) dialog.transient_for = parent;
            dialog.modal = true;
            bool finished = false;
            dialog.response.connect (() => {
                if (!finished) FidoDevice.cancel ();
            });
            dialog.present ();
            int rc = 0;
            new Thread<void> ("fido", () => {
                rc = call ();
                Idle.add (() => {
                    with_touch.callback ();
                    return Source.REMOVE;
                });
            });
            yield;
            finished = true;
            dialog.close ();
            return rc;
        }

        private static string key_error (int rc) {
            switch (rc) {
                case FidoCode.ERR_PIN_INVALID: return _("The PIN is wrong.");
                case FidoCode.ERR_PIN_BLOCKED:
                case FidoCode.ERR_PIN_AUTH_BLOCKED: return _("The security key is locked. Unplug it and plug it back in.");
                case FidoCode.ERR_UV_BLOCKED: return _("The security key could not confirm it is you.");
                case FidoCode.ERR_NO_CREDENTIALS: return _("This security key has no passkey for this site.");
                case FidoCode.ERR_CREDENTIAL_EXCLUDED: return _("This security key already has a passkey for this account.");
                case FidoCode.ERR_KEEPALIVE_CANCEL:
                case FidoCode.ERR_ACTION_TIMEOUT:
                case FidoCode.ERR_OPERATION_DENIED: return _("The security key was not touched.");
                default: return _("The security key reported an error (%d).").printf (rc);
            }
        }

        private static Gtk.Widget qr_view (string text) {
            var area = new DrawingArea ();
            area.content_width = 240;
            area.content_height = 240;
            area.halign = Align.CENTER;
            Singularity.QrCode? code = null;
            try {
                code = Singularity.QrCode.encode_text (text.up (), Singularity.QrEcLevel.LOW);
            } catch (Error e) {
                warning ("QR code: %s", e.message);
            }
            area.set_draw_func ((a, cr, width, height) => {
                cr.set_source_rgb (1, 1, 1);
                cr.paint ();
                if (code == null) return;
                int quiet = 2;
                double cell = double.min (width, height) / (code.size + quiet * 2);
                double ox = (width - cell * (code.size + quiet * 2)) / 2;
                double oy = (height - cell * (code.size + quiet * 2)) / 2;
                cr.set_source_rgb (0, 0, 0);
                for (int y = 0; y < code.size; y++) {
                    for (int x = 0; x < code.size; x++) {
                        if (code.get_module (x, y)) cr.rectangle (ox + (x + quiet) * cell, oy + (y + quiet) * cell, cell + 0.5, cell + 0.5);
                    }
                }
                cr.fill ();
            });
            return area;
        }

        private async uint8[] with_phone (bool create, uint8[] command) throws Error {
            var session = new CableSession (create);
            var dialog = new ConfirmDialog (app, create ? _("Save a Passkey on Your Phone") : _("Use a Passkey from Your Phone"), null, null, _("Cancel"), ConfirmDialog.ActionStyle.DEFAULT);
            dialog.has_cancel = false;
            if (parent != null) dialog.transient_for = parent;
            dialog.modal = true;
            dialog.custom_area.append (qr_view (session.qr));
            var label = new Label ("");
            label.wrap = true;
            label.max_width_chars = 40;
            label.justify = Justification.CENTER;
            dialog.custom_area.append (label);
            session.status.connect ((text) => label.label = text);
            var cancellable = new Cancellable ();
            bool finished = false;
            dialog.response.connect (() => {
                if (!finished) cancellable.cancel ();
            });
            dialog.present ();
            try {
                return yield session.transact (command, cancellable);
            } catch (Error e) {
                if (cancellable.is_cancelled ()) throw new WebAuthnError.NOT_ALLOWED (_("Canceled"));
                finished = true;
                dialog.close ();
                bool refused = e is CableError.AUTHENTICATOR;
                yield notice (_("Phone or Tablet"), refused ? _("Your phone did not complete the request.") : e.message);
                throw new WebAuthnError.NOT_ALLOWED (e.message);
            } finally {
                finished = true;
                dialog.close ();
            }
        }

        private async string create_on_phone (Json.Object options, Passkey template, Gee.List<string> excluded, string challenge, string origin) throws Error {
            string client = WebAuthnCore.client_data ("webauthn.create", challenge, origin);
            string rp_name = template.rp_id;
            if (options.has_member ("rp") && options.get_member ("rp").get_node_type () == Json.NodeType.OBJECT) {
                string n = WebAuthnCore.member_string (options.get_object_member ("rp"), "name");
                if (n != "") rp_name = n;
            }
            var command = Cable.make_credential_command (WebAuthnCore.digest (client.data), template.rp_id, rp_name, template.user_handle,
                template.user_name, template.display_name, excluded, wants_verification (options));
            var reply = Cable.parse_ctap_response (yield with_phone (true, command));
            var auth = reply.lookup_int (2);
            if (auth == null || auth.kind != CborType.BYTES) throw new WebAuthnError.UNKNOWN (_("The phone sent an incomplete answer"));
            uint8[] id = WebAuthnCore.credential_id_from_auth_data (auth.data);
            return WebAuthnCore.registration_response (id, client, auth.data, "cross-platform", { "hybrid", "internal" }, true);
        }

        private async string get_on_phone (Json.Object options, string rp_id, Gee.List<string> allowed, string challenge, string origin) throws Error {
            string client = WebAuthnCore.client_data ("webauthn.get", challenge, origin);
            var command = Cable.get_assertion_command (WebAuthnCore.digest (client.data), rp_id, allowed, wants_verification (options));
            var reply = Cable.parse_ctap_response (yield with_phone (false, command));
            var credential = reply.lookup_int (1);
            var auth = reply.lookup_int (2);
            var signature = reply.lookup_int (3);
            var user = reply.lookup_int (4);
            if (credential == null || credential.kind != CborType.MAP || auth == null || signature == null)
                throw new WebAuthnError.UNKNOWN (_("The phone sent an incomplete answer"));
            var id = credential.lookup ("id");
            if (id == null || id.kind != CborType.BYTES) throw new WebAuthnError.UNKNOWN (_("The phone sent an incomplete answer"));
            uint8[]? handle = null;
            if (user != null && user.kind == CborType.MAP) {
                var uid = user.lookup ("id");
                if (uid != null && uid.kind == CborType.BYTES) handle = uid.data;
            }
            return WebAuthnCore.assertion_response (id.data, client, auth.data, signature.data, handle, "cross-platform");
        }

        private async string create_on_key (Json.Object options, Passkey template, Gee.List<string> excluded, string challenge, string origin) throws Error {
            string path = yield key_path ();
            string client = WebAuthnCore.client_data ("webauthn.create", challenge, origin);
            var hash = new GLib.Bytes (WebAuthnCore.digest (client.data));
            string rp_name = template.rp_id;
            if (options.has_member ("rp") && options.get_member ("rp").get_node_type () == Json.NodeType.OBJECT) {
                string n = WebAuthnCore.member_string (options.get_object_member ("rp"), "name");
                if (n != "") rp_name = n;
            }
            string? pin = yield key_pin (path, null);
            bool verify = wants_verification (options);
            var exclude = WebAuthnCore.pack_ids (excluded);
            var user = new GLib.Bytes (template.user_handle);
            for (int attempt = 0; attempt < 3; attempt++) {
                GLib.Bytes? id = null, auth = null;
                int rc = yield with_touch (() => FidoDevice.make_credential (path, hash, template.rp_id, rp_name, user,
                    template.user_name, template.display_name, exclude, true, verify, pin, out id, out auth));
                if (rc == FidoCode.OK) return WebAuthnCore.registration_response (id.get_data (), client, auth.get_data (), "cross-platform", { "usb" }, true);
                if (rc == FidoCode.ERR_PIN_REQUIRED || rc == FidoCode.ERR_PIN_INVALID) {
                    pin = yield key_pin (path, rc == FidoCode.ERR_PIN_INVALID ? _("The PIN is wrong. Try again.") : null);
                    if (pin == null) pin = yield key_pin (path, _("Enter the PIN of your security key."));
                    continue;
                }
                if (rc == FidoCode.ERR_CREDENTIAL_EXCLUDED) throw new WebAuthnError.INVALID_STATE (key_error (rc));
                yield notice (_("Security Key"), key_error (rc));
                throw new WebAuthnError.NOT_ALLOWED (key_error (rc));
            }
            throw new WebAuthnError.NOT_ALLOWED (_("The PIN is wrong."));
        }

        private async string get_on_key (Json.Object options, string rp_id, Gee.List<string> allowed, string challenge, string origin) throws Error {
            string path = yield key_path ();
            string client = WebAuthnCore.client_data ("webauthn.get", challenge, origin);
            var hash = new GLib.Bytes (WebAuthnCore.digest (client.data));
            string? pin = yield key_pin (path, null);
            bool verify = wants_verification (options);
            var allow = WebAuthnCore.pack_ids (allowed);
            for (int attempt = 0; attempt < 3; attempt++) {
                GLib.Bytes? id = null, auth = null, sig = null, user = null;
                int rc = yield with_touch (() => FidoDevice.get_assertion (path, hash, rp_id, allow, verify, pin, out id, out auth, out sig, out user));
                if (rc == FidoCode.OK) return WebAuthnCore.assertion_response (id.get_data (), client, auth.get_data (), sig.get_data (), user != null ? user.get_data () : null, "cross-platform");
                if (rc == FidoCode.ERR_PIN_REQUIRED || rc == FidoCode.ERR_PIN_INVALID) {
                    pin = yield key_pin (path, rc == FidoCode.ERR_PIN_INVALID ? _("The PIN is wrong. Try again.") : _("Enter the PIN of your security key."));
                    continue;
                }
                yield notice (_("Security Key"), key_error (rc));
                throw new WebAuthnError.NOT_ALLOWED (key_error (rc));
            }
            throw new WebAuthnError.NOT_ALLOWED (_("The PIN is wrong."));
        }

        private async bool ask (ConfirmDialog dialog, bool focus = true) {
            if (parent != null) dialog.transient_for = parent;
            dialog.modal = true;
            bool ok = false;
            dialog.response.connect ((r) => {
                ok = r == ConfirmDialog.Response.PRIMARY;
                Idle.add (() => {
                    ask.callback ();
                    return Source.REMOVE;
                });
            });
            dialog.present ();
            if (focus) dialog.focus_primary ();
            yield;
            return ok;
        }

        private async void notice (string title, string text) {
            var dialog = new ConfirmDialog (app, title, "dialog-password", text, _("OK"), ConfirmDialog.ActionStyle.SUGGESTED);
            yield ask (dialog);
        }

        private async void verify_user (string rp_id) throws Error {
            try {
                yield check_identity (rp_id);
            } catch (WebAuthnError e) {
                throw e;
            } catch (Error e) {
                warning ("Passkey verification: %s", e.message);
                yield notice (_("Could Not Confirm It Is You"), _("The system could not ask for your password or fingerprint. Install the browser again, then try once more."));
                throw new WebAuthnError.NOT_ALLOWED (_("Your identity could not be confirmed"));
            }
        }

        private async void check_identity (string rp_id) throws Error {
            var authority = yield Polkit.Authority.get_async (null);
            var subject = new Polkit.UnixProcess.for_owner (process_id (), 0, user_id ());
            var details = new Polkit.Details ();
            details.insert ("site", rp_id);
            var result = yield authority.check_authorization (subject, ACTION_ID, details,
                Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION, null);
            if (!result.get_is_authorized ()) throw new WebAuthnError.NOT_ALLOWED (_("Your identity was not confirmed"));
        }
    }
}
