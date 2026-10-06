[CCode (cheader_filename = "passkey_crypto.h", lower_case_cprefix = "browser_passkey_")]
namespace Singularity.Apps.Browser.PasskeyCrypto {
    public static GLib.Bytes? generate ();
    public static GLib.Bytes? public_point (GLib.Bytes key);
    public static GLib.Bytes? public_der (GLib.Bytes key);
    public static GLib.Bytes? sign (GLib.Bytes key, GLib.Bytes data);
    public static GLib.Bytes? digest (GLib.Bytes data);
    public static GLib.Bytes? random (uint length);
    public static bool verify (GLib.Bytes point, GLib.Bytes data, GLib.Bytes signature);
}
