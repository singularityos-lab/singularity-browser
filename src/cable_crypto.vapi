[CCode (cheader_filename = "cable_crypto.h", lower_case_cprefix = "browser_cable_")]
namespace Singularity.Apps.Browser.CableCrypto {
    public static GLib.Bytes? hkdf (GLib.Bytes ikm, GLib.Bytes salt, GLib.Bytes info, uint length);
    public static GLib.Bytes? hmac (GLib.Bytes key, GLib.Bytes data);
    public static GLib.Bytes? block_decrypt (GLib.Bytes key, GLib.Bytes block);
    public static GLib.Bytes? block_encrypt (GLib.Bytes key, GLib.Bytes block);
    public static GLib.Bytes? seal (GLib.Bytes key, GLib.Bytes nonce, GLib.Bytes aad, GLib.Bytes plain);
    public static GLib.Bytes? open (GLib.Bytes key, GLib.Bytes nonce, GLib.Bytes aad, GLib.Bytes sealed);
    public static GLib.Bytes? ecdh (GLib.Bytes private_key, GLib.Bytes peer_point);
}
