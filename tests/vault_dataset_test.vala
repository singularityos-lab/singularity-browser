using Singularity.Apps.Browser;

private Json.Object payload (string title) {
    var object = new Json.Object ();
    object.set_string_member ("title", title);
    return object;
}

public void dataset_tests () {
    try {
        var first = new VaultDataset (Uuid.string_random ());
        var second = new VaultDataset (Uuid.string_random ());
        string history = first.create ("history", payload ("Synthetic history"));
        string bookmark = first.create ("bookmark", payload ("Synthetic bookmark"));
        string password = first.create ("password", payload ("Synthetic password"));
        string session = first.create ("session", payload ("Synthetic session"));
        var baseline = first.snapshot ();
        second.merge (baseline);
        assert (second.items ().length == 4);
        assert (second.get_item (history).kind == "history");
        assert (second.get_item (password).kind == "password");
        assert (second.get_item (session).kind == "session");
        first.update (bookmark, "bookmark", payload ("First offline edit"));
        second.update (bookmark, "bookmark", payload ("Second offline edit"));
        var a = first.snapshot ();
        var b = second.snapshot ();
        var joined = new VaultDataset (Uuid.string_random ());
        joined.merge (a);
        joined.merge (b);
        var reversed = new VaultDataset (Uuid.string_random ());
        reversed.merge (b);
        reversed.merge (a);
        assert (joined.snapshot ().compare (reversed.snapshot ()) == 0);
        assert (joined.get_item (bookmark).versions.size == 2);
        joined.merge (baseline);
        assert (joined.get_item (bookmark).versions.size == 2);
        joined.update (bookmark, "bookmark", payload ("Chosen conflict resolution"));
        assert (joined.get_item (bookmark).versions.size == 1);
        first.merge (joined.snapshot ());
        second.merge (joined.snapshot ());
        assert (first.snapshot ().compare (second.snapshot ()) == 0);
        assert (first.get_item (bookmark).versions[0].payload.get_object ().get_string_member ("title") == "Chosen conflict resolution");
        var before_delete = first.snapshot ();
        first.update (password, "password", null);
        first.merge (before_delete);
        assert (first.get_item (password).versions.size == 1 && first.get_item (password).versions[0].deleted);
        second.update (password, "password", payload ("Offline password edit"));
        first.merge (second.snapshot ());
        assert (first.get_item (password).versions.size == 2);
        first.update (password, "password", null);
        second.merge (first.snapshot ());
        assert (second.get_item (password).versions.size == 1 && second.get_item (password).versions[0].deleted);
        var recovered = new VaultDataset (first.writer);
        recovered.merge (first.snapshot ());
        assert (recovered.clock == first.clock);
        recovered.update (session, "session", payload ("Recovered session"));
        assert (recovered.clock > first.clock);
        recovered.merge (new Bytes ("{\"format\":1,\"items\":[]}".data));
        assert (recovered.items ().length == 4);
        var unchanged = recovered.snapshot ();
        try {
            recovered.merge (new Bytes ("{\"format\":1,\"items\":[{\"id\":\"invalid\",\"kind\":\"password\"}]}".data));
            assert_not_reached ();
        } catch (IOError.INVALID_DATA e) {}
        assert (recovered.snapshot ().compare (unchanged) == 0);
        var parser = new Json.Parser ();
        parser.load_from_data ((string) unchanged.get_data (), (ssize_t) unchanged.get_size ());
        var items = parser.get_root ().get_object ().get_array_member ("items");
        items.get_object_element (0).get_array_member ("versions").get_object_element (0).set_int_member ("clock", 0);
        var generator = new Json.Generator ();
        generator.set_root (parser.get_root ());
        try {
            recovered.merge (new Bytes (generator.to_data (null).data));
            assert_not_reached ();
        } catch (IOError.INVALID_DATA e) {}
        assert (recovered.snapshot ().compare (unchanged) == 0);
        var mutable = payload ("Stable value");
        string immutable = recovered.create ("bookmark", mutable);
        mutable.set_string_member ("title", "External mutation");
        assert (recovered.get_item (immutable).versions[0].payload.get_object ().get_string_member ("title") == "Stable value");
        var returned = recovered.get_item (immutable).versions[0].payload;
        returned.get_object ().set_string_member ("title", "Returned value mutation");
        assert (recovered.get_item (immutable).versions[0].payload.get_object ().get_string_member ("title") == "Stable value");
    } catch (Error e) {
        error ("Vault dataset test: %s", e.message);
    }
}
