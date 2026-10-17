[CCode (cheader_filename = "extension_crypto.h", lower_case_cprefix = "browser_extension_crypto_")]
namespace Singularity.Apps.Browser.ExtensionCrypto {
    public static bool verify (GLib.Bytes public_key, GLib.Bytes data, GLib.Bytes signature, bool ecdsa);
}
