using Gtk;

namespace Singularity.Apps.Browser {
    private delegate void SketchAction ();
    private class SketchPoint : Object {
        public double x;
        public double y;
        public SketchPoint (double x, double y) { this.x = x; this.y = y; }
    }

    private class SketchMark : Object {
        public uint tool;
        public Gdk.RGBA color;
        public double width;
        public string text = "";
        public Gee.ArrayList<SketchPoint> points = new Gee.ArrayList<SketchPoint> ();

        public void draw (Cairo.Context cr) {
            if (points.is_empty) return;
            var a = points[0];
            var b = points[points.size - 1];
            cr.save ();
            cr.set_source_rgba (color.red, color.green, color.blue, color.alpha);
            cr.set_line_width (width);
            cr.set_line_cap (Cairo.LineCap.ROUND);
            cr.set_line_join (Cairo.LineJoin.ROUND);
            if (tool == 1) cr.set_operator (Cairo.Operator.CLEAR);
            if (tool == 3) {
                cr.rectangle (double.min (a.x, b.x), double.min (a.y, b.y), Math.fabs (b.x - a.x), Math.fabs (b.y - a.y));
            } else if (tool == 4) {
                cr.save ();
                cr.translate ((a.x + b.x) / 2, (a.y + b.y) / 2);
                cr.scale (double.max (Math.fabs (b.x - a.x) / 2, 0.5), double.max (Math.fabs (b.y - a.y) / 2, 0.5));
                cr.arc (0, 0, 1, 0, 2 * Math.PI);
                cr.restore ();
            } else if (tool == 5) {
                var layout = Pango.cairo_create_layout (cr);
                layout.set_text (text, -1);
                layout.set_font_description (Pango.FontDescription.from_string ("Sans 16"));
                cr.move_to (a.x, a.y);
                Pango.cairo_show_layout (cr, layout);
            } else {
                cr.move_to (a.x, a.y);
                if (tool == 2 || tool == 6) {
                    cr.line_to (b.x, b.y);
                    if (tool == 6) {
                        double angle = Math.atan2 (b.y - a.y, b.x - a.x);
                        double tip = double.max (12, width * 4);
                        cr.move_to (b.x - tip * Math.cos (angle - 0.5), b.y - tip * Math.sin (angle - 0.5));
                        cr.line_to (b.x, b.y);
                        cr.line_to (b.x - tip * Math.cos (angle + 0.5), b.y - tip * Math.sin (angle + 0.5));
                    }
                }
                else foreach (var p in points) cr.line_to (p.x, p.y);
                if (points.size == 1) cr.line_to (a.x + 0.01, a.y);
            }
            cr.stroke ();
            cr.restore ();
        }
    }

    public class PageSketch : Box {
        private const string[] TOOL_ICONS = { "singularity-markup-pen-symbolic", "singularity-markup-eraser-symbolic", "singularity-markup-line-symbolic",
            "singularity-markup-rectangle-symbolic", "singularity-markup-ellipse-symbolic", "singularity-markup-text-symbolic",
            "singularity-markup-arrow-symbolic", "singularity-markup-highlighter-symbolic" };
        private const uint[] TOOL_ORDER = { 0, 7, 2, 6, 3, 4, 5, 1 };

        private Gdk.Pixbuf background;
        private Gdk.Texture texture;
        private DrawingArea canvas;
        private ScrolledWindow scroller;
        private Singularity.Widgets.ColorPickerButton color_button;
        private Singularity.Widgets.RibbonSelector width_selector;
        private Gee.ArrayList<Singularity.Widgets.RibbonToggle> tool_toggles = new Gee.ArrayList<Singularity.Widgets.RibbonToggle> ();
        private uint tool = 0;
        private double stroke = 3;
        private Gee.ArrayList<SketchMark> marks = new Gee.ArrayList<SketchMark> ();
        private Gee.ArrayList<SketchMark> undone = new Gee.ArrayList<SketchMark> ();
        private SketchMark? current;
        private double scale = 1;
        private double start_x;
        private double start_y;
        private double initial_offset;
        private bool syncing_tools = false;
        private double pending_offset = 0;
        private int queued_height = 0;
        private string page_uri;
        public signal void closed ();

        public PageSketch (Gdk.Texture snapshot, string uri, double scroll_offset) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            texture = snapshot;
            page_uri = uri;
            background = Gdk.pixbuf_get_from_texture (snapshot);
            initial_offset = scroll_offset;
            tooltip_text = null;

            var ribbon = new Singularity.Widgets.ContextRibbon ();
            var context = ribbon.add_context ("sketch", _("Sketch"));
            string[] names = { _("Pen"), _("Eraser"), _("Line"), _("Rectangle"), _("Ellipse"), _("Text"), _("Arrow"), _("Highlighter") };
            foreach (uint id in TOOL_ORDER) {
                var toggle = context.add_toggle (TOOL_ICONS[id], names[id], names[id]);
                toggle.active = id == tool;
                uint chosen = id;
                toggle.toggled.connect ((on) => select_tool (chosen, on));
                tool_toggles.add (toggle);
            }
            context.add_separator ();
            var red = Gdk.RGBA ();
            red.parse ("#e53935");
            color_button = new Singularity.Widgets.ColorPickerButton (red);
            color_button.tooltip_text = _("Color");
            context.add_widget (color_button, _("Color"), "applications-graphics-symbolic");
            width_selector = context.add_selector (_("Stroke Width"), 9, "format-text-bold-symbolic");
            width_selector.add_option ("2", _("Fine"));
            width_selector.add_option ("3", _("Medium"));
            width_selector.add_option ("6", _("Bold"));
            width_selector.add_option ("12", _("Heavy"));
            width_selector.selected = "3";
            width_selector.changed.connect ((id) => stroke = double.parse (id));
            context.add_separator ();
            context.add_button ("edit-undo-symbolic", _("Undo"), _("Undo")).activated.connect (undo);
            context.add_button ("edit-redo-symbolic", _("Redo"), _("Redo")).activated.connect (redo);
            context.add_separator ();
            context.add_button ("edit-copy-symbolic", _("Copy"), _("Copy the Sketch")).activated.connect (copy);
            context.add_button ("document-save-symbolic", _("Save"), _("Save the Sketch as PNG")).activated.connect (() => save.begin ());
            var to_notes = context.add_button ("document-send-symbolic", _("Send to Notes"), _("Add the Sketch to a Note"));
            to_notes.activated.connect (() => Singularity.Notes.NotePicker.popup (to_notes.button, (id) => send_to_note (id)));
            to_notes.button.visible = Singularity.Notes.NotePicker.available ();
            context.add_button ("object-select-symbolic", _("Done"), _("Back to the Page")).activated.connect (() => closed ());
            append (ribbon);

            canvas = new DrawingArea ();
            canvas.hexpand = true;
            canvas.set_draw_func ((area, cr, w, h) => {
                scale = (double) w / background.width;
                cr.scale (scale, scale);
                render (cr);
            });
            scroller = new ScrolledWindow ();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.vexpand = true;
            scroller.child = canvas;
            append (scroller);
            scroller.hadjustment.notify["page-size"].connect (() => fit_height ((int) scroller.hadjustment.page_size));
            scroller.vadjustment.notify["upper"].connect (() => {
                var adj = scroller.vadjustment;
                if (pending_offset <= 0 || adj.upper < pending_offset) return;
                double target = pending_offset;
                pending_offset = 0;
                Idle.add (() => {
                    adj.value = double.min (target, adj.upper - adj.page_size);
                    return Source.REMOVE;
                });
            });
            canvas.resize.connect ((w, h) => fit_height (w));

            var drag = new GestureDrag ();
            drag.button = Gdk.BUTTON_PRIMARY;
            drag.drag_begin.connect (begin_mark);
            drag.drag_update.connect ((x, y) => {
                if (current == null || current.tool == 5) return;
                current.points.add (new SketchPoint (start_x + x / scale, start_y + y / scale));
                canvas.queue_draw ();
            });
            drag.drag_end.connect ((x, y) => {
                if (current == null) return;
                marks.add (current);
                current = null;
                undone.clear ();
                canvas.queue_draw ();
            });
            canvas.add_controller (drag);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                if (ctrl && (keyval == Gdk.Key.z || keyval == Gdk.Key.Z)) {
                    if ((state & Gdk.ModifierType.SHIFT_MASK) != 0) redo (); else undo ();
                    return true;
                }
                if (ctrl && keyval == Gdk.Key.c) {
                    copy ();
                    return true;
                }
                var adj = scroller.vadjustment;
                double step = adj.page_size * 0.9;
                switch (keyval) {
                    case Gdk.Key.Page_Down:
                    case Gdk.Key.space:
                        adj.value = adj.value + step;
                        return true;
                    case Gdk.Key.Page_Up:
                        adj.value = adj.value - step;
                        return true;
                    case Gdk.Key.Down:
                        adj.value = adj.value + 60;
                        return true;
                    case Gdk.Key.Up:
                        adj.value = adj.value - 60;
                        return true;
                    case Gdk.Key.Home:
                        adj.value = adj.lower;
                        return true;
                    case Gdk.Key.End:
                        adj.value = adj.upper - adj.page_size;
                        return true;
                    default:
                        break;
                }
                if (keyval == Gdk.Key.Escape) {
                    closed ();
                    return true;
                }
                return false;
            });
            add_controller (keys);
            focusable = true;
            map.connect (() => grab_focus ());
            debug ("sketch snapshot %dx%d, start at %.0f", background.width, background.height, initial_offset);
        }

        private void fit_height (int width) {
            if (width <= 0) return;
            int wanted = (int) Math.ceil ((double) background.height * width / background.width);
            if (canvas.content_height != wanted && wanted != queued_height) {
                queued_height = wanted;
                double offset = initial_offset;
                initial_offset = 0;
                Idle.add (() => {
                    if (offset > 0) pending_offset = offset * width / background.width;
                    canvas.content_height = queued_height;
                    return Source.REMOVE;
                });
            }
        }

        private void select_tool (uint id, bool on) {
            if (syncing_tools) return;
            syncing_tools = true;
            if (on) tool = id;
            for (int i = 0; i < tool_toggles.size; i++) tool_toggles[i].active = TOOL_ORDER[i] == tool;
            syncing_tools = false;
        }

        private void begin_mark (double x, double y) {
            start_x = x / scale;
            start_y = y / scale;
            if (start_x < 0 || start_y < 0 || start_x >= background.width || start_y >= background.height) return;
            if (tool == 5) {
                ask_text (x, y);
                return;
            }
            current = new_mark (tool);
            current.points.add (new SketchPoint (start_x, start_y));
            canvas.queue_draw ();
        }

        private SketchMark new_mark (uint kind) {
            var mark = new SketchMark ();
            mark.tool = kind;
            mark.color = color_button.color;
            mark.width = kind == 1 ? stroke * 4 : stroke;
            if (kind == 7) {
                mark.color.alpha = 0.3f;
                mark.width = stroke * 4;
            }
            return mark;
        }

        private void ask_text (double x, double y) {
            var popover = new Popover ();
            popover.set_parent (canvas);
            popover.pointing_to = { (int) x, (int) y, 1, 1 };
            popover.position = PositionType.BOTTOM;
            var entry = new Entry ();
            entry.placeholder_text = _("Type, then press Enter");
            entry.max_length = 1000;
            entry.width_chars = 28;
            popover.child = entry;
            double px = start_x, py = start_y;
            entry.activate.connect (() => {
                string text = entry.text.strip ();
                if (text != "") {
                    var mark = new_mark (5);
                    mark.text = text;
                    mark.points.add (new SketchPoint (px, py));
                    marks.add (mark);
                    undone.clear ();
                    canvas.queue_draw ();
                }
                popover.popdown ();
            });
            popover.closed.connect (() => Idle.add (() => {
                popover.unparent ();
                return Source.REMOVE;
            }));
            popover.popup ();
            entry.grab_focus ();
        }

        private void undo () {
            if (!marks.is_empty) undone.add (marks.remove_at (marks.size - 1));
            canvas.queue_draw ();
        }

        private void redo () {
            if (!undone.is_empty) marks.add (undone.remove_at (undone.size - 1));
            canvas.queue_draw ();
        }

        private void render (Cairo.Context cr) {
            Gdk.cairo_set_source_pixbuf (cr, background, 0, 0);
            cr.paint ();
            var ink = new Cairo.ImageSurface (Cairo.Format.ARGB32, background.width, background.height);
            var ctx = new Cairo.Context (ink);
            foreach (var mark in marks) mark.draw (ctx);
            if (current != null) current.draw (ctx);
            cr.set_source_surface (ink, 0, 0);
            cr.paint ();
        }

        private Cairo.ImageSurface flatten () {
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, background.width, background.height);
            render (new Cairo.Context (surface));
            return surface;
        }

        private void notify_user (string text) {
            var window = get_root () as Singularity.Widgets.Window;
            if (window != null) window.add_toast (new Singularity.Widgets.Toast (text));
        }

        private void copy () {
            var surface = flatten ();
            var pixbuf = Gdk.pixbuf_get_from_surface (surface, 0, 0, surface.get_width (), surface.get_height ());
            if (pixbuf == null) return;
            get_clipboard ().set_texture (Gdk.Texture.for_pixbuf (pixbuf));
            notify_user (_("Sketch copied"));
        }

        private void send_to_note (string? note_id) {
            send_to_note_async.begin (note_id);
        }

        private async void send_to_note_async (string? note_id) {
            string name = Singularity.Notes.NotePicker.attachment_name ("sketch", "png");
            string dir = Path.build_filename (Environment.get_user_cache_dir (), "dev.sinty.browser", "sketches");
            string path = Path.build_filename (dir, name);
            try {
                DirUtils.create_with_parents (dir, 0700);
                if (flatten ().write_to_png (path) != Cairo.Status.SUCCESS) throw new IOError.FAILED (_("The sketch could not be saved"));
                FileUtils.chmod (path, 0600);
                string block = "![%s]({link})\n".printf (_("Sketch"));
                if (page_uri != "") block += "<%s>\n".printf (page_uri);
                var note = yield Singularity.Notes.NotePicker.add_file (note_id, _("Page Sketch"), File.new_for_path (path), name, block);
                var window = get_root () as Singularity.Widgets.Window;
                if (window != null) window.add_toast (Singularity.Notes.NotePicker.toast (note, _("Sketch")));
            } catch (Error e) {
                notify_user (e.message);
            }
            FileUtils.remove (path);
        }

        private async void save () {
            var dialog = new FileDialog ();
            dialog.title = _("Save Page Sketch");
            dialog.initial_name = "page-sketch.png";
            var filter = new FileFilter ();
            filter.name = _("PNG Image");
            filter.add_mime_type ("image/png");
            var filters = new GLib.ListStore (typeof (FileFilter));
            filters.append (filter);
            dialog.filters = filters;
            try {
                var file = yield dialog.save ((Gtk.Window) get_root (), null);
                string? path = file.get_path ();
                if (path == null || flatten ().write_to_png (path) != Cairo.Status.SUCCESS) {
                    notify_user (_("The sketch could not be saved. Choose a local PNG file."));
                } else notify_user (_("Sketch saved"));
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) notify_user (e.message);
            }
        }
    }
}
