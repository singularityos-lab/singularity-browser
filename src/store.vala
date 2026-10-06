namespace Singularity.Apps.Browser {

    public class HistoryEntry : Object {
        public string url;
        public string title;
        public int visits;
        public int64 last_visit;

        public HistoryEntry (string url, string title, int visits, int64 last_visit) {
            this.url = url;
            this.title = title;
            this.visits = visits;
            this.last_visit = last_visit;
        }
    }

    public class Bookmark : Object {
        public int64 id;
        public int64 parent;
        public bool is_folder;
        public string title;
        public string url;
        public int position;

        public Bookmark (int64 id, int64 parent, bool is_folder, string title, string url, int position) {
            this.id = id;
            this.parent = parent;
            this.is_folder = is_folder;
            this.title = title;
            this.url = url;
            this.position = position;
        }
    }

    public class StoredDownload : Object {
        public int64 id;
        public string name;
        public string destination;
        public string source;
        public int64 size;
        public string state;
        public string error;
        public int64 finished;

        public StoredDownload (int64 id, string name, string destination, string source, int64 size,
                               string state, string error, int64 finished) {
            this.id = id;
            this.name = name;
            this.destination = destination;
            this.source = source;
            this.size = size;
            this.state = state;
            this.error = error;
            this.finished = finished;
        }
    }

    public class Store : Object {
        public const int DOWNLOADS_KEPT = 200;

        public const int64 ROOT = 0;

        private Sqlite.Database db;
        private bool read_only;
        private bool durable = true;

        public signal void history_changed ();
        public signal void bookmarks_changed ();
        public signal void site_changed (string site, string key);

        public Store (string? path, bool read_only = false) {
            this.read_only = read_only;
            int flags = read_only ? Sqlite.OPEN_READONLY : Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE;
            string target = path ?? ":memory:";
            if (path != null && !read_only)
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            if (Sqlite.Database.open_v2 (target, out db, flags) != Sqlite.OK) {
                warning ("Browser store %s: %s", target, db != null ? db.errmsg () : "open failed");
                Sqlite.Database.open_v2 (":memory:", out db, Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE);
                this.read_only = false;
                durable = false;
            }
            db.busy_timeout (2000);
            if (!this.read_only) {
                exec ("PRAGMA journal_mode=WAL");
                exec ("""CREATE TABLE IF NOT EXISTS history (
                    url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 0,
                    last_visit INTEGER NOT NULL DEFAULT 0)""");
                exec ("""CREATE TABLE IF NOT EXISTS bookmarks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, parent INTEGER NOT NULL DEFAULT 0,
                    is_folder INTEGER NOT NULL DEFAULT 0, title TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '',
                    position INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL DEFAULT 0)""");
                exec ("""CREATE TABLE IF NOT EXISTS sites (
                    site TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (site, key))""");
                exec ("""CREATE TABLE IF NOT EXISTS downloads (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL DEFAULT '', destination TEXT NOT NULL DEFAULT '',
                    source TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'done',
                    error TEXT NOT NULL DEFAULT '', finished INTEGER NOT NULL DEFAULT 0)""");
                exec ("CREATE INDEX IF NOT EXISTS history_last ON history (last_visit)");
                exec ("CREATE INDEX IF NOT EXISTS bookmarks_parent ON bookmarks (parent, position)");
                if (path != null) FileUtils.chmod (path, 0600);
            }
        }

        private void exec (string sql) {
            string errmsg;
            if (db.exec (sql, null, out errmsg) != Sqlite.OK)
                warning ("Browser store: %s", errmsg);
        }

        private Sqlite.Statement prepare (string sql) {
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sql, -1, out stmt) != Sqlite.OK)
                warning ("Browser store: %s", db.errmsg ());
            return stmt;
        }

        private Sqlite.Statement sync_prepare (string sql) throws Error {
            if (read_only || !durable) throw new IOError.PERMISSION_DENIED (_("The browser archive is not writable"));
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sql, -1, out stmt) != Sqlite.OK) throw new IOError.FAILED (db.errmsg ());
            return stmt;
        }

        private void sync_done (Sqlite.Statement stmt) throws Error {
            if (stmt.step () != Sqlite.DONE) throw new IOError.FAILED (db.errmsg ());
        }

        public void sync_ready () throws Error {
            var stmt = sync_prepare ("""CREATE TABLE IF NOT EXISTS sync_links (
                scope TEXT NOT NULL, kind TEXT NOT NULL, local_key TEXT NOT NULL,
                id TEXT NOT NULL, stamp TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(scope, kind, local_key), UNIQUE(scope, id))""");
            sync_done (stmt);
        }

        public Json.Object[] sync_links (string scope) throws Error {
            sync_ready ();
            var stmt = sync_prepare ("SELECT kind, local_key, id, stamp FROM sync_links WHERE scope = ?1");
            stmt.bind_text (1, scope);
            Json.Object[] result = {};
            int status;
            while ((status = stmt.step ()) == Sqlite.ROW) {
                var row = new Json.Object ();
                row.set_string_member ("kind", stmt.column_text (0));
                row.set_string_member ("key", stmt.column_text (1));
                row.set_string_member ("id", stmt.column_text (2));
                row.set_string_member ("stamp", stmt.column_text (3));
                result += row;
            }
            if (status != Sqlite.DONE) throw new IOError.FAILED (db.errmsg ());
            return result;
        }

        public void sync_link (string scope, string kind, string key, string id, string stamp) throws Error {
            var stmt = sync_prepare ("""INSERT INTO sync_links VALUES (?1, ?2, ?3, ?4, ?5)
                ON CONFLICT(scope, kind, local_key) DO UPDATE SET stamp = ?5 WHERE id = ?4""");
            stmt.bind_text (1, scope);
            stmt.bind_text (2, kind);
            stmt.bind_text (3, key);
            stmt.bind_text (4, id);
            stmt.bind_text (5, stamp);
            sync_done (stmt);
            if (db.changes () != 1) throw new IOError.INVALID_DATA (_("The browser sync identifier changed"));
        }

        public HistoryEntry[] sync_history () throws Error {
            var stmt = sync_prepare ("SELECT url, title, visits, last_visit FROM history ORDER BY url");
            HistoryEntry[] result = {};
            int status;
            while ((status = stmt.step ()) == Sqlite.ROW)
                result += new HistoryEntry (stmt.column_text (0), stmt.column_text (1), stmt.column_int (2), stmt.column_int64 (3));
            if (status != Sqlite.DONE) throw new IOError.FAILED (db.errmsg ());
            return result;
        }

        public Bookmark[] sync_bookmarks () throws Error {
            var stmt = sync_prepare ("SELECT " + BOOKMARK_COLUMNS + " FROM bookmarks ORDER BY id");
            Bookmark[] result = {};
            int status;
            while ((status = stmt.step ()) == Sqlite.ROW)
                result += new Bookmark (stmt.column_int64 (0), stmt.column_int64 (1), stmt.column_int (2) != 0,
                    stmt.column_text (3), stmt.column_text (4), stmt.column_int (5));
            if (status != Sqlite.DONE) throw new IOError.FAILED (db.errmsg ());
            return result;
        }

        public void sync_visit (string url, string title, int visits, int64 last_visit, bool deleted) throws Error {
            var stmt = sync_prepare (deleted ? "DELETE FROM history WHERE url = ?1" :
                "INSERT INTO history VALUES (?1, ?2, ?3, ?4) ON CONFLICT(url) DO UPDATE SET title=?2, visits=?3, last_visit=?4");
            stmt.bind_text (1, url);
            if (!deleted) {
                stmt.bind_text (2, title);
                stmt.bind_int (3, visits);
                stmt.bind_int64 (4, last_visit);
            }
            sync_done (stmt);
            history_changed ();
        }

        public int64 sync_bookmark_link (string scope, string sync_id, string stamp, int64 id, int64 parent,
                                         bool folder, string title, string url, int position, bool deleted) throws Error {
            sync_done (sync_prepare ("BEGIN IMMEDIATE"));
            try {
                id = sync_bookmark (id, parent, folder, title, url, position, deleted, false);
                sync_link (scope, "bookmark", id.to_string (), sync_id, stamp);
                sync_done (sync_prepare ("COMMIT"));
                bookmarks_changed ();
                return id;
            } catch (Error e) {
                string error;
                db.exec ("ROLLBACK", null, out error);
                throw e;
            }
        }

        public int64 sync_bookmark (int64 id, int64 parent, bool folder, string title, string url, int position, bool deleted, bool notify = true) throws Error {
            if (deleted) {
                var stmt = sync_prepare ("DELETE FROM bookmarks WHERE id = ?1");
                stmt.bind_int64 (1, id);
                sync_done (stmt);
            } else if (id == 0) {
                var stmt = sync_prepare ("INSERT INTO bookmarks(parent,is_folder,title,url,position,added) VALUES (?1,?2,?3,?4,?5,?6)");
                stmt.bind_int64 (1, parent);
                stmt.bind_int (2, folder ? 1 : 0);
                stmt.bind_text (3, title);
                stmt.bind_text (4, url);
                stmt.bind_int (5, position);
                stmt.bind_int64 (6, get_real_time () / 1000000);
                sync_done (stmt);
                id = db.last_insert_rowid ();
            } else {
                var stmt = sync_prepare ("UPDATE bookmarks SET parent=?2,is_folder=?3,title=?4,url=?5,position=?6 WHERE id=?1");
                stmt.bind_int64 (1, id);
                stmt.bind_int64 (2, parent);
                stmt.bind_int (3, folder ? 1 : 0);
                stmt.bind_text (4, title);
                stmt.bind_text (5, url);
                stmt.bind_int (6, position);
                sync_done (stmt);
                if (db.changes () != 1) throw new IOError.NOT_FOUND (_("The local bookmark disappeared during sync"));
            }
            if (notify) bookmarks_changed ();
            return id;
        }

        private static string like_pattern (string query) {
            return "%" + query.strip ().down ().replace ("\\", "\\\\").replace ("%", "\\%").replace ("_", "\\_") + "%";
        }

        public static bool recordable (string? url) {
            if (url == null) return false;
            string? scheme = Address.scheme_of (url);
            return scheme == "http" || scheme == "https" || scheme == "file";
        }

        public void add_visit (string url, string title) {
            if (read_only || !recordable (url)) return;
            var stmt = prepare ("""INSERT INTO history (url, title, visits, last_visit) VALUES (?1, ?2, 1, ?3)
                ON CONFLICT(url) DO UPDATE SET visits = visits + 1, last_visit = ?3,
                title = CASE WHEN ?2 = '' THEN title ELSE ?2 END""");
            stmt.bind_text (1, url);
            stmt.bind_text (2, title);
            stmt.bind_int64 (3, get_real_time () / 1000000);
            stmt.step ();
            history_changed ();
        }

        public void set_title (string url, string title) {
            if (read_only || title == "") return;
            var stmt = prepare ("UPDATE history SET title = ?2 WHERE url = ?1");
            stmt.bind_text (1, url);
            stmt.bind_text (2, title);
            stmt.step ();
            if (db.changes () > 0) history_changed ();
        }

        private HistoryEntry[] read_history (Sqlite.Statement stmt) {
            HistoryEntry[] result = {};
            while (stmt.step () == Sqlite.ROW)
                result += new HistoryEntry (stmt.column_text (0), stmt.column_text (1) ?? "", stmt.column_int (2), stmt.column_int64 (3));
            return result;
        }

        public HistoryEntry[] search_history (string query, int limit) {
            var stmt = prepare ("""SELECT url, title, visits, last_visit FROM history
                WHERE lower(url) LIKE ?1 ESCAPE '\' OR lower(title) LIKE ?1 ESCAPE '\'
                ORDER BY (CASE WHEN lower(url) LIKE ?2 ESCAPE '\' OR lower(url) LIKE ?3 ESCAPE '\' THEN 0 ELSE 1 END),
                visits * 3 + last_visit / 86400 DESC LIMIT ?4""");
            string q = query.strip ().down ().replace ("\\", "\\\\").replace ("%", "\\%").replace ("_", "\\_");
            stmt.bind_text (1, like_pattern (query));
            stmt.bind_text (2, "%://" + q + "%");
            stmt.bind_text (3, "%://www." + q + "%");
            stmt.bind_int (4, limit);
            return read_history (stmt);
        }

        public HistoryEntry[] recent_history (int limit, int offset = 0) {
            var stmt = prepare ("SELECT url, title, visits, last_visit FROM history ORDER BY last_visit DESC LIMIT ?1 OFFSET ?2");
            stmt.bind_int (1, limit);
            stmt.bind_int (2, offset);
            return read_history (stmt);
        }

        public HistoryEntry[] top_sites (int limit) {
            var stmt = prepare ("""SELECT url, title, visits, last_visit FROM history
                WHERE url LIKE 'http%' ORDER BY visits DESC, last_visit DESC LIMIT ?1""");
            stmt.bind_int (1, limit * 4);
            HistoryEntry[] result = {};
            var seen = new GenericSet<string> (str_hash, str_equal);
            foreach (var entry in read_history (stmt)) {
                string site = Address.site_key (entry.url);
                if (site == "" || seen.contains (site)) continue;
                seen.add (site);
                result += entry;
                if (result.length >= limit) break;
            }
            return result;
        }

        public void remove_history (string url) {
            if (read_only) return;
            var stmt = prepare ("DELETE FROM history WHERE url = ?1");
            stmt.bind_text (1, url);
            stmt.step ();
            history_changed ();
        }

        public void clear_history (int64 since = 0) {
            if (read_only) return;
            var stmt = prepare ("DELETE FROM history WHERE last_visit >= ?1");
            stmt.bind_int64 (1, since);
            stmt.step ();
            history_changed ();
        }

        private Bookmark[] read_bookmarks (Sqlite.Statement stmt) {
            Bookmark[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                result += new Bookmark (stmt.column_int64 (0), stmt.column_int64 (1), stmt.column_int (2) != 0,
                                        stmt.column_text (3) ?? "", stmt.column_text (4) ?? "", stmt.column_int (5));
            }
            return result;
        }

        private const string BOOKMARK_COLUMNS = "id, parent, is_folder, title, url, position";

        public Bookmark[] children (int64 parent) {
            var stmt = prepare ("SELECT " + BOOKMARK_COLUMNS + " FROM bookmarks WHERE parent = ?1 ORDER BY position, id");
            stmt.bind_int64 (1, parent);
            return read_bookmarks (stmt);
        }

        public Bookmark[] folders () {
            return read_bookmarks (prepare ("SELECT " + BOOKMARK_COLUMNS + " FROM bookmarks WHERE is_folder = 1 ORDER BY parent, position, id"));
        }

        public Bookmark? bookmark (int64 id) {
            var stmt = prepare ("SELECT " + BOOKMARK_COLUMNS + " FROM bookmarks WHERE id = ?1");
            stmt.bind_int64 (1, id);
            var found = read_bookmarks (stmt);
            return found.length > 0 ? found[0] : null;
        }

        public Bookmark? bookmark_for_url (string url) {
            var stmt = prepare ("SELECT " + BOOKMARK_COLUMNS + " FROM bookmarks WHERE is_folder = 0 AND url = ?1 LIMIT 1");
            stmt.bind_text (1, url);
            var found = read_bookmarks (stmt);
            return found.length > 0 ? found[0] : null;
        }

        public Bookmark[] search_bookmarks (string query, int limit) {
            var stmt = prepare ("SELECT " + BOOKMARK_COLUMNS + """ FROM bookmarks WHERE is_folder = 0
                AND (lower(url) LIKE ?1 ESCAPE '\' OR lower(title) LIKE ?1 ESCAPE '\') ORDER BY title LIMIT ?2""");
            stmt.bind_text (1, like_pattern (query));
            stmt.bind_int (2, limit);
            return read_bookmarks (stmt);
        }

        public int count_bookmarks () {
            var stmt = prepare ("SELECT count(*) FROM bookmarks WHERE is_folder = 0");
            return stmt.step () == Sqlite.ROW ? stmt.column_int (0) : 0;
        }

        private int next_position (int64 parent) {
            var stmt = prepare ("SELECT coalesce(max(position), -1) + 1 FROM bookmarks WHERE parent = ?1");
            stmt.bind_int64 (1, parent);
            return stmt.step () == Sqlite.ROW ? stmt.column_int (0) : 0;
        }

        private int64 insert_bookmark (int64 parent, bool folder, string title, string url, bool notify) {
            if (read_only) return -1;
            var stmt = prepare ("INSERT INTO bookmarks (parent, is_folder, title, url, position, added) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
            stmt.bind_int64 (1, parent);
            stmt.bind_int (2, folder ? 1 : 0);
            stmt.bind_text (3, title);
            stmt.bind_text (4, url);
            stmt.bind_int (5, next_position (parent));
            stmt.bind_int64 (6, get_real_time () / 1000000);
            if (stmt.step () != Sqlite.DONE) return -1;
            int64 id = db.last_insert_rowid ();
            if (notify) bookmarks_changed ();
            return id;
        }

        public int64 add_bookmark (int64 parent, string title, string url) {
            return insert_bookmark (parent, false, title, url, true);
        }

        public int64 add_folder (int64 parent, string title) {
            return insert_bookmark (parent, true, title, "", true);
        }

        public void update_bookmark (int64 id, string title, string url, int64 parent) {
            if (read_only) return;
            var current = bookmark (id);
            if (current == null) return;
            var stmt = prepare ("UPDATE bookmarks SET title = ?2, url = ?3, parent = ?4, position = ?5 WHERE id = ?1");
            stmt.bind_int64 (1, id);
            stmt.bind_text (2, title);
            stmt.bind_text (3, url);
            stmt.bind_int64 (4, parent);
            stmt.bind_int (5, current.parent == parent ? current.position : next_position (parent));
            stmt.step ();
            bookmarks_changed ();
        }

        public void remove_bookmark (int64 id) {
            if (read_only) return;
            foreach (var child in children (id)) remove_bookmark_quiet (child.id);
            remove_bookmark_quiet (id);
            bookmarks_changed ();
        }

        private void remove_bookmark_quiet (int64 id) {
            foreach (var child in children (id)) remove_bookmark_quiet (child.id);
            var stmt = prepare ("DELETE FROM bookmarks WHERE id = ?1");
            stmt.bind_int64 (1, id);
            stmt.step ();
        }

        public int import_tree (ImportedBookmark root, int64 parent) {
            if (read_only) return 0;
            exec ("BEGIN");
            int count = import_children (root, parent);
            exec ("COMMIT");
            bookmarks_changed ();
            return count;
        }

        private int import_children (ImportedBookmark folder, int64 parent) {
            int count = 0;
            foreach (var child in folder.children) {
                if (child.is_folder) {
                    if (child.children.size == 0) continue;
                    int64 id = insert_bookmark (parent, true, child.title, "", false);
                    count += import_children (child, id);
                } else if (child.url != "") {
                    insert_bookmark (parent, false, child.title != "" ? child.title : child.url, child.url, false);
                    count++;
                }
            }
            return count;
        }

        public string? get_site (string site, string key) {
            if (site == "") return null;
            var stmt = prepare ("SELECT value FROM sites WHERE site = ?1 AND key = ?2");
            stmt.bind_text (1, site);
            stmt.bind_text (2, key);
            return stmt.step () == Sqlite.ROW ? stmt.column_text (0) : null;
        }

        public void set_site (string site, string key, string? value) {
            if (site == "" || read_only) return;
            if (value == null) {
                var stmt = prepare ("DELETE FROM sites WHERE site = ?1 AND key = ?2");
                stmt.bind_text (1, site);
                stmt.bind_text (2, key);
                stmt.step ();
            } else {
                var stmt = prepare ("INSERT INTO sites (site, key, value) VALUES (?1, ?2, ?3) ON CONFLICT(site, key) DO UPDATE SET value = ?3");
                stmt.bind_text (1, site);
                stmt.bind_text (2, key);
                stmt.bind_text (3, value);
                stmt.step ();
            }
            site_changed (site, key);
        }

        public int64 add_download (string name, string destination, string source, int64 size,
                                   string state, string error = "") {
            if (read_only) return 0;
            var stmt = prepare ("""INSERT INTO downloads (name, destination, source, size, state, error, finished)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)""");
            stmt.bind_text (1, name);
            stmt.bind_text (2, destination);
            stmt.bind_text (3, source);
            stmt.bind_int64 (4, size);
            stmt.bind_text (5, state);
            stmt.bind_text (6, error);
            stmt.bind_int64 (7, get_real_time () / 1000000);
            stmt.step ();
            int64 id = db.last_insert_rowid ();
            var trim = prepare ("DELETE FROM downloads WHERE id NOT IN (SELECT id FROM downloads ORDER BY id DESC LIMIT ?1)");
            trim.bind_int (1, DOWNLOADS_KEPT);
            trim.step ();
            return id;
        }

        public StoredDownload[] downloads () {
            var stmt = prepare ("SELECT id, name, destination, source, size, state, error, finished FROM downloads ORDER BY id DESC");
            StoredDownload[] result = {};
            while (stmt.step () == Sqlite.ROW)
                result += new StoredDownload (stmt.column_int64 (0), stmt.column_text (1) ?? "", stmt.column_text (2) ?? "",
                                              stmt.column_text (3) ?? "", stmt.column_int64 (4), stmt.column_text (5) ?? "done",
                                              stmt.column_text (6) ?? "", stmt.column_int64 (7));
            return result;
        }

        public void remove_download (int64 id) {
            if (read_only || id <= 0) return;
            var stmt = prepare ("DELETE FROM downloads WHERE id = ?1");
            stmt.bind_int64 (1, id);
            stmt.step ();
        }

        public string[] sites_with (string key, string value) {
            var stmt = prepare ("SELECT site FROM sites WHERE key = ?1 AND value = ?2");
            stmt.bind_text (1, key);
            stmt.bind_text (2, value);
            string[] result = {};
            while (stmt.step () == Sqlite.ROW) result += stmt.column_text (0);
            return result;
        }
    }
}
