namespace Singularity.Apps.Browser.Keyring {
    public async GLib.List<Secret.Item> search (Secret.Schema schema, HashTable<string, string> attrs, Secret.SearchFlags flags) throws Error {
        var service = yield Secret.Service.get (Secret.ServiceFlags.OPEN_SESSION, null);
        var collection = yield Secret.Collection.for_alias (service, Secret.COLLECTION_DEFAULT, Secret.CollectionFlags.NONE, null);
        if (collection == null) return new GLib.List<Secret.Item> ();
        return yield collection.search (schema, attrs, flags, null);
    }
}
