using Singularity.Apps.Browser;

int main (string[] args) {
    string id = args.length > 1 ? args[1] : "ddkjiahejlhfcafbddmgiahcphecmpfh";
    string root;
    try {
        root = DirUtils.make_tmp ("extension-store-XXXXXX");
    } catch (Error e) {
        printerr ("tmp: %s\n", e.message);
        return 1;
    }
    var manager = new ExtensionManager (root);
    var loop = new MainLoop ();
    int status = 0;
    manager.install_from_store.begin (id, null, (obj, res) => {
        try {
            var extension = manager.install_from_store.end (res);
            print ("installed %s %s %s (manifest %d)\n", extension.id, extension.name, extension.version, extension.manifest_version);
            print ("worker %s popup %s content scripts %d permissions %s hosts %s\n",
                extension.background_worker ?? "-", extension.popup ?? "-", extension.content_scripts.size,
                string.joinv (",", extension.permissions), string.joinv (",", extension.host_permissions));
        } catch (Error e) {
            printerr ("install failed: %s\n", e.message);
            status = 1;
        }
        loop.quit ();
    });
    loop.run ();
    ExtensionManager.remove_tree (root);
    return status;
}
