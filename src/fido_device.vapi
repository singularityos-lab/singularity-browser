[CCode (cheader_filename = "fido_device.h", lower_case_cprefix = "browser_fido_")]
namespace Singularity.Apps.Browser.FidoDevice {
    public static string? find ();
    public static int needs_pin (string path);
    public static int make_credential (string path, GLib.Bytes client_hash, string rp_id, string rp_name,
                                       GLib.Bytes user_id, string user_name, string display_name,
                                       GLib.Bytes exclude, bool resident, bool verify, string? pin,
                                       out GLib.Bytes? credential_id, out GLib.Bytes? auth_data);
    public static int get_assertion (string path, GLib.Bytes client_hash, string rp_id, GLib.Bytes allow,
                                     bool verify, string? pin,
                                     out GLib.Bytes? credential_id, out GLib.Bytes? auth_data,
                                     out GLib.Bytes? signature, out GLib.Bytes? user_id);
    public static void cancel ();
}
