[CCode (cheader_filename = "vault_crypto.h", lower_case_cprefix = "browser_vault_")]
namespace Singularity.Apps.Browser.VaultCrypto {
    public static GLib.Bytes? random (uint length);
    public static GLib.Bytes? authenticate (GLib.Bytes key, GLib.Bytes data);
    public static GLib.Bytes? derive (GLib.Bytes key, GLib.Bytes salt, GLib.Bytes info);
    public static GLib.Bytes? seal (GLib.Bytes key, GLib.Bytes nonce, GLib.Bytes header, GLib.Bytes plain);
    public static GLib.Bytes? open (GLib.Bytes key, GLib.Bytes nonce, GLib.Bytes header, GLib.Bytes sealed);
    public static GLib.Bytes? signing_key ();
    public static GLib.Bytes? public_key (GLib.Bytes key);
    public static GLib.Bytes? exchange_key ();
    public static GLib.Bytes? exchange_public (GLib.Bytes key);
    public static GLib.Bytes? exchange (GLib.Bytes key, GLib.Bytes peer);
    public static GLib.Bytes? sign (GLib.Bytes key, GLib.Bytes data);
    public static bool verify (GLib.Bytes key, GLib.Bytes data, GLib.Bytes signature);
}
