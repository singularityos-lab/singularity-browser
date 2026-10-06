namespace Singularity.Apps.Browser {

    public class BrowserSearchProvider : Singularity.SearchProviderService {
        private weak BrowserApp app;

        public BrowserSearchProvider (BrowserApp app) {
            this.app = app;
        }

        private Store store () {
            return app.services != null ? app.services.store : app.read_store ();
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            string query = string.joinv (" ", terms).strip ();
            if (query.length < 2) return {};
            string[] ids = {};
            var seen = new Gee.HashSet<string> ();
            foreach (var b in store ().search_bookmarks (query, 4)) {
                if (seen.contains (b.url)) continue;
                seen.add (b.url);
                ids += "b:" + b.url;
            }
            foreach (var h in store ().search_history (query, 6)) {
                if (seen.contains (h.url) || ids.length >= 6) continue;
                seen.add (h.url);
                ids += "h:" + h.url;
            }
            return ids;
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            var s = store ();
            foreach (string id in ids) {
                if (id.length < 3) continue;
                string url = id.substring (2);
                bool bookmark = id.has_prefix ("b:");
                string title = "";
                if (bookmark) {
                    var b = s.bookmark_for_url (url);
                    if (b != null) title = b.title;
                } else {
                    foreach (var h in s.search_history (url, 1)) if (h.url == url) title = h.title;
                }
                var meta = new Singularity.SearchResultMeta (id, title != "" ? title : Address.display (url));
                meta.description = bookmark ? _("Bookmark, %s").printf (Address.full_display (url)) : Address.full_display (url);
                meta.icon = new ThemedIcon (bookmark ? "user-bookmarks" : "dev.sinty.browser");
                meta.score = bookmark ? 2 : 1;
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            if (id.length > 2) app.open_uri_from_outside (id.substring (2));
            return null;
        }
    }
}
