namespace Singularity.Apps.Browser {

    public class PagePrinter : Object {

        public static async bool to_pdf (WebKit.WebView view, string path, Gtk.PageSetup? setup = null) {
            var settings = new Gtk.PrintSettings ();
            settings.set_printer (GLib.dgettext ("gtk40", "Print to File"));
            settings.set (Gtk.PRINT_SETTINGS_OUTPUT_FILE_FORMAT, "pdf");
            settings.set (Gtk.PRINT_SETTINGS_OUTPUT_URI, File.new_for_path (path).get_uri ());
            var operation = new WebKit.PrintOperation (view);
            operation.print_settings = settings;
            var page = setup ?? new Gtk.PageSetup ();
            if (setup == null) page.set_paper_size (new Gtk.PaperSize (Gtk.PAPER_NAME_A4));
            operation.page_setup = page;
            bool ok = true;
            ulong finished = operation.finished.connect (() => Idle.add (to_pdf.callback));
            ulong failed = operation.failed.connect ((err) => {
                ok = false;
                warning ("Printing failed: %s", err.message);
            });
            operation.print ();
            yield;
            operation.disconnect (finished);
            operation.disconnect (failed);
            return ok && FileUtils.test (path, FileTest.IS_REGULAR);
        }

        public static async void print_with_dialog (Gtk.Window window, WebKit.WebView view, string title) {
            string dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity", "browser", "print");
            DirUtils.create_with_parents (dir, 0700);
            string path = Path.build_filename (dir, "page-%s.pdf".printf (Uuid.string_random ().substring (0, 8)));
            if (!yield to_pdf (view, path)) {
                FileUtils.unlink (path);
                return;
            }
            Poppler.Document document;
            try {
                document = new Poppler.Document.from_file (File.new_for_path (path).get_uri (), null);
            } catch (Error e) {
                warning ("Print preview: %s", e.message);
                FileUtils.unlink (path);
                return;
            }
            yield Singularity.Print.run_callbacks (window, title,
                (format) => document.get_n_pages (),
                (cr, index, format) => {
                    var page = document.get_page (index);
                    if (page == null) return;
                    double w, h;
                    page.get_size (out w, out h);
                    double scale = double.min (format.width / w, format.height / h);
                    cr.save ();
                    cr.translate ((format.width - w * scale) / 2, (format.height - h * scale) / 2);
                    cr.scale (scale, scale);
                    page.render_for_printing (cr);
                    cr.restore ();
                });
            FileUtils.unlink (path);
        }
    }
}
