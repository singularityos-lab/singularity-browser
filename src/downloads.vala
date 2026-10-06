namespace Singularity.Apps.Browser {

    public class DownloadItem : Object {
        public WebKit.Download? download { get; construct; }
        public string destination { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public double progress { get; set; default = 0; }
        public int64 received { get; set; default = 0; }
        public bool finished { get; set; default = false; }
        public bool failed { get; set; default = false; }
        public bool cancelled { get; set; default = false; }
        public string error { get; set; default = ""; }
        public string source { get; set; default = ""; }
        public int64 stored_id { get; set; default = 0; }
        public bool remembered { get; set; default = false; }
        public bool earlier { get; set; default = false; }

        public DownloadItem (WebKit.Download download) {
            Object (download: download);
        }

        public DownloadItem.stored (StoredDownload saved) {
            Object (download: null);
            stored_id = saved.id;
            name = saved.name;
            destination = saved.destination;
            source = saved.source;
            received = saved.size;
            progress = 1.0;
            error = saved.error;
            finished = saved.state == "done";
            failed = !finished;
            cancelled = saved.state == "cancelled";
            earlier = true;
        }

        public bool missing {
            get { return finished && (destination == "" || !FileUtils.test (destination, FileTest.EXISTS)); }
        }

        public bool active {
            get { return !finished && !failed; }
        }
    }

    public class Downloads : Object {
        public ListStore items = new ListStore (typeof (DownloadItem));
        public Store? store { get; construct; }

        public signal void started (DownloadItem item);
        public signal void completed (DownloadItem item);
        public signal void changed ();

        public Downloads (Store? store = null) {
            Object (store: store);
            if (store == null) return;
            foreach (var saved in store.downloads ())
                items.append (new DownloadItem.stored (saved));
        }

        public int session_count {
            get {
                int count = 0;
                for (uint i = 0; i < items.get_n_items (); i++)
                    if (!((DownloadItem) items.get_item (i)).earlier) count++;
                return count;
            }
        }

        public int active_count {
            get {
                int count = 0;
                for (uint i = 0; i < items.get_n_items (); i++)
                    if (((DownloadItem) items.get_item (i)).active) count++;
                return count;
            }
        }

        public double overall_progress {
            get {
                double sum = 0;
                int count = 0;
                for (uint i = 0; i < items.get_n_items (); i++) {
                    var item = (DownloadItem) items.get_item (i);
                    if (!item.active) continue;
                    sum += item.progress;
                    count++;
                }
                return count > 0 ? sum / count : 1.0;
            }
        }

        public void watch (WebKit.NetworkSession session, bool remember = true) {
            session.download_started.connect ((download) => track (download, remember));
        }

        private void record (DownloadItem item, string state) {
            if (!item.remembered || store == null || item.stored_id != 0 || item.name == "") return;
            item.stored_id = store.add_download (item.name, item.destination, item.source, item.received, state, item.error);
        }

        public void track (WebKit.Download download, bool remember = true) {
            var item = new DownloadItem (download);
            item.remembered = remember;
            var request = download.get_request ();
            if (request != null && request.uri != null) item.source = request.uri;
            download.decide_destination.connect ((suggested) => {
                string path = Util.unique_path (Util.downloads_dir (), suggested != null && suggested != "" ? suggested : "download");
                item.destination = path;
                item.name = Path.get_basename (path);
                download.set_destination (path);
                changed ();
                return true;
            });
            download.created_destination.connect ((dest) => {
                item.destination = dest;
                item.name = Path.get_basename (dest);
                changed ();
            });
            download.notify["estimated-progress"].connect (() => {
                item.progress = download.estimated_progress;
                item.received = (int64) download.get_received_data_length ();
                changed ();
            });
            download.finished.connect (() => {
                if (item.failed) return;
                item.finished = true;
                item.progress = 1.0;
                item.received = (int64) download.get_received_data_length ();
                if (item.destination != "") {
                    var uri = File.new_for_path (item.destination).get_uri ();
                    Gtk.RecentManager.get_default ().add_item (uri);
                }
                record (item, "done");
                completed (item);
                changed ();
            });
            download.failed.connect ((err) => {
                item.failed = true;
                item.cancelled = err.code == WebKit.DownloadError.CANCELLED_BY_USER;
                item.error = err.message;
                if (item.destination != "") FileUtils.unlink (item.destination);
                record (item, item.cancelled ? "cancelled" : "failed");
                changed ();
            });
            items.insert (0, item);
            started (item);
            changed ();
        }

        public void remove (DownloadItem item) {
            if (store != null) store.remove_download (item.stored_id);
            uint pos;
            if (items.find (item, out pos)) items.remove (pos);
            changed ();
        }

        public void clear_finished () {
            for (int i = (int) items.get_n_items () - 1; i >= 0; i--) {
                var item = (DownloadItem) items.get_item (i);
                if (item.active) continue;
                if (store != null) store.remove_download (item.stored_id);
                items.remove (i);
            }
            changed ();
        }

        public static void open (DownloadItem item) {
            if (item.destination == "") return;
            try {
                AppInfo.launch_default_for_uri (File.new_for_path (item.destination).get_uri (), null);
            } catch (Error e) {
                warning ("Could not open %s: %s", item.destination, e.message);
            }
        }

        public static void show_in_folder (DownloadItem item) {
            if (item.destination == "") return;
            string uri = File.new_for_path (item.destination).get_uri ();
            Bus.get.begin (BusType.SESSION, null, (obj, res) => {
                try {
                    var conn = Bus.get.end (res);
                    conn.call.begin ("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                        "org.freedesktop.FileManager1", "ShowItems", new Variant ("(ass)", new string[] { uri }, ""),
                        null, DBusCallFlags.NONE, 5000, null, (o, r) => {
                            try {
                                conn.call.end (r);
                            } catch (Error e) {
                                try {
                                    AppInfo.launch_default_for_uri (File.new_for_path (item.destination).get_parent ().get_uri (), null);
                                } catch (Error e2) {
                                }
                            }
                        });
                } catch (Error e) {
                }
            });
        }
    }
}
