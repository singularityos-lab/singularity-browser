using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public class TileDragPayload : Object {
        public string tile_id;

        public TileDragPayload (string tile_id) {
            this.tile_id = tile_id;
        }
    }

    public class TabGroup : Object {
        public string id;
        public string name;
        public string color;

        public TabGroup (string id, string name, string color) {
            this.id = id;
            this.name = name;
            this.color = color;
        }

        public const string[] COLORS = { "#3584e4", "#2ec27e", "#e5a50a", "#e66100", "#c01c28", "#9141ac", "#986a44", "#1c71d8" };
    }

    public class BrowserTile : Box {
        public string tile_id { get; construct; }
        public Gee.ArrayList<BrowserTab> tabs = new Gee.ArrayList<BrowserTab> ();
        public BrowserTab? active { get; private set; default = null; }
        public bool focused { get; private set; default = false; }

        private Box header;
        private Button grip;
        private Label single_title;
        public ChipBar chips;
        private Button add_button;
        private int label_chars = -2;
        private Stack stack;
        private Overlay overlay;
        private DrawingArea drop_overlay;
        private Singularity.Animation.MotionBin bin;
        private Singularity.TileZone drop_zone = Singularity.TileZone.CENTER;
        private Gee.HashMap<BrowserTab, ulong> handlers = new Gee.HashMap<BrowserTab, ulong> ();
        private Gee.HashMap<string, string> prefix_keys = new Gee.HashMap<string, string> ();
        private bool show_chips = true;
        private bool show_header = false;

        public signal void tab_selected (BrowserTab tab);
        public signal void tab_close_requested (BrowserTab tab);
        public signal void tab_context_requested (BrowserTab tab, Widget anchor);
        public signal void new_tab_requested ();
        public signal void strip_context_requested (Widget anchor, double x, double y);
        public signal void tab_dropped (string tab_id, BrowserTile target, Singularity.TileZone zone);
        public signal void tile_dropped (string tile_id, BrowserTile target, Singularity.TileZone zone);
        public signal void activated ();
        public signal void emptied ();
        public signal void order_changed ();

        public BrowserTile (string? id = null) {
            Object (tile_id: id ?? Uuid.string_random (), orientation: Orientation.VERTICAL, spacing: 0);
            hexpand = true;
            vexpand = true;
            add_css_class ("browser-tile");

            header = new Box (Orientation.HORIZONTAL, 2);
            header.add_css_class ("browser-tile-header");
            header.visible = false;

            grip = new Button.from_icon_name ("browser-tile-drag-symbolic");
            grip.add_css_class ("flat");
            grip.add_css_class ("browser-tile-grip");
            grip.tooltip_text = _("Move Tile");
            grip.valign = Align.CENTER;
            var drag = new DragSource ();
            drag.actions = Gdk.DragAction.MOVE;
            drag.prepare.connect ((x, y) => new Gdk.ContentProvider.for_value (new TileDragPayload (tile_id)));
            drag.drag_begin.connect ((d) => {
                drag.set_icon (new WidgetPaintable (this), 24, 24);
                add_css_class ("dragging");
            });
            drag.drag_end.connect (() => remove_css_class ("dragging"));
            grip.add_controller (drag);
            header.append (grip);

            single_title = new Label ("");
            single_title.add_css_class ("browser-tile-title");
            single_title.ellipsize = Pango.EllipsizeMode.END;
            single_title.hexpand = true;
            single_title.xalign = 0;
            single_title.visible = false;
            header.append (single_title);

            chips = new ChipBar ();
            chips.hexpand = false;
            var chip_scroll = chips.get_first_child () as ScrolledWindow;
            if (chip_scroll != null) chip_scroll.propagate_natural_width = true;
            chips.reorderable = true;
            chips.detachable = true;
            chips.close_tooltip = _("Close Tab");
            chips.max_label_chars = 22;
            chips.chip_activated.connect ((id) => {
                var tab = find (id);
                if (tab != null) select (tab);
            });
            chips.chip_closed.connect ((id) => {
                var tab = find (id);
                if (tab != null) tab_close_requested (tab);
            });
            chips.chips_reordered.connect (on_reordered);
            chips.chip_context_requested.connect ((id) => {
                var tab = find (id);
                var chip = chips.get_chip_widget (id);
                if (tab != null && chip != null) tab_context_requested (tab, chip);
            });
            chips.chip_double_activated.connect ((id) => {
                var tab = find (id);
                if (tab != null) tab_context_requested (tab, chips.get_chip_widget (id));
            });
            header.append (chips);

            add_button = new Button.from_icon_name ("list-add-symbolic");
            add_button.add_css_class ("flat");
            add_button.add_css_class ("browser-tile-add");
            add_button.tooltip_text = _("New Tab");
            add_button.valign = Align.CENTER;
            add_button.clicked.connect (() => new_tab_requested ());
            header.append (add_button);
            var strip_space = new Box (Orientation.HORIZONTAL, 0);
            strip_space.hexpand = true;
            header.append (strip_space);

            var strip_middle = new GestureClick ();
            strip_middle.button = Gdk.BUTTON_MIDDLE;
            strip_middle.released.connect ((n, x, y) => {
                var tab = tab_at (x, y);
                if (tab != null) tab_close_requested (tab);
                else if (!over_control (x, y)) new_tab_requested ();
            });
            header.add_controller (strip_middle);
            var strip_menu = new GestureClick ();
            strip_menu.button = Gdk.BUTTON_SECONDARY;
            strip_menu.pressed.connect ((n, x, y) => {
                if (tab_at (x, y) != null || over_control (x, y)) return;
                strip_menu.set_state (EventSequenceState.CLAIMED);
                strip_context_requested (header, x, y);
            });
            header.add_controller (strip_menu);
            append (header);

            stack = new Stack ();
            stack.hexpand = true;
            stack.vexpand = true;
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.transition_duration = Singularity.Motion.reduced () ? 0 : Singularity.Motion.Duration.SMALL.ms ();

            overlay = new Overlay ();
            overlay.child = stack;
            drop_overlay = new DrawingArea ();
            drop_overlay.can_target = false;
            drop_overlay.visible = false;
            drop_overlay.set_draw_func (draw_drop_zone);
            overlay.add_overlay (drop_overlay);
            var width_probe = new DrawingArea ();
            width_probe.can_target = false;
            width_probe.resize.connect ((w, h) => on_resized (w));
            overlay.add_overlay (width_probe);

            bin = new Singularity.Animation.MotionBin ();
            bin.child = overlay;
            bin.hexpand = true;
            bin.vexpand = true;
            append (bin);

            install_drop_targets (this, PropagationPhase.BUBBLE, true);
            install_drop_targets (bin, PropagationPhase.CAPTURE, false);

            var click = new GestureClick ();
            click.propagation_phase = PropagationPhase.CAPTURE;
            click.pressed.connect (() => activated ());
            add_controller (click);
            var focus = new EventControllerFocus ();
            focus.enter.connect (() => activated ());
            add_controller (focus);
        }

        private BrowserTab? tab_at (double x, double y) {
            var picked = header.pick (x, y, PickFlags.DEFAULT);
            while (picked != null && picked != header) {
                var chip = picked as Singularity.Widgets.Chip;
                if (chip != null) return find (chip.chip_id);
                picked = picked.get_parent ();
            }
            return null;
        }

        private bool over_control (double x, double y) {
            var picked = header.pick (x, y, PickFlags.DEFAULT);
            return picked != null && (picked == add_button || picked.is_ancestor (add_button) || picked == grip || picked.is_ancestor (grip));
        }

        private void on_resized (int width) {
            int chars = fitting_chars (width);
            if (chars != label_chars) {
                label_chars = chars;
                Idle.add (() => {
                    sync_all ();
                    return Source.REMOVE;
                });
            }
        }

        private int fitting_chars (int width) {
            int loose = 0;
            foreach (var tab in tabs) if (!tab.pinned) loose++;
            if (loose == 0) return chips.max_label_chars;
            int reserved = 56 + (grip.visible ? 30 : 0) + (tabs.size - loose) * 40;
            int per_chip = (width - reserved) / loose - 6;
            int chars = (per_chip - 62) / 7;
            if (chars < 5) return -1;
            return int.min (chars, chips.max_label_chars);
        }

        private double header_offset () {
            return header.visible ? header.get_height () : 0;
        }

        private void install_drop_targets (Widget widget, PropagationPhase phase, bool below_header) {
            var tab_target = new DropTarget (typeof (Singularity.Widgets.ChipDragPayload), Gdk.DragAction.MOVE);
            tab_target.propagation_phase = phase;
            tab_target.motion.connect ((x, y) => on_drag_motion (x, below_header ? y - header_offset () : y));
            tab_target.leave.connect (() => drop_overlay.visible = false);
            tab_target.drop.connect ((value, x, y) => {
                drop_overlay.visible = false;
                var payload = value.get_object () as Singularity.Widgets.ChipDragPayload;
                if (payload == null) return false;
                payload.handled = true;
                tab_dropped (payload.id, this, zone_at (x, below_header ? y - header_offset () : y));
                return true;
            });
            widget.add_controller (tab_target);

            var tile_target = new DropTarget (typeof (TileDragPayload), Gdk.DragAction.MOVE);
            tile_target.propagation_phase = phase;
            tile_target.motion.connect ((x, y) => on_drag_motion (x, below_header ? y - header_offset () : y));
            tile_target.leave.connect (() => drop_overlay.visible = false);
            tile_target.drop.connect ((value, x, y) => {
                drop_overlay.visible = false;
                var payload = value.get_object () as TileDragPayload;
                if (payload == null || payload.tile_id == tile_id) return false;
                tile_dropped (payload.tile_id, this, zone_at (x, below_header ? y - header_offset () : y));
                return true;
            });
            widget.add_controller (tile_target);
        }

        private Singularity.TileZone zone_at (double x, double y) {
            return Singularity.TileZone.at (x, y, bin.get_width (), bin.get_height ());
        }

        private Gdk.DragAction on_drag_motion (double x, double y) {
            drop_zone = zone_at (x, y);
            drop_overlay.visible = true;
            drop_overlay.queue_draw ();
            return Gdk.DragAction.MOVE;
        }

        private void draw_drop_zone (DrawingArea area, Cairo.Context cr, int width, int height) {
            double x = 0, y = 0, w = width, h = height;
            switch (drop_zone) {
                case Singularity.TileZone.LEFT: w /= 2; break;
                case Singularity.TileZone.RIGHT: x = width / 2.0; w /= 2; break;
                case Singularity.TileZone.TOP: h /= 2; break;
                case Singularity.TileZone.BOTTOM: y = height / 2.0; h /= 2; break;
                default:
                    x = width * 0.2; y = height * 0.2; w = width * 0.6; h = height * 0.6;
                    break;
            }
            var accent = Util.rgba (Services.accent_hex ());
            double r = 14;
            x += 6; y += 6; w = double.max (0, w - 12); h = double.max (0, h - 12);
            cr.new_sub_path ();
            cr.arc (x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc (x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc (x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path ();
            cr.set_source_rgba (accent.red, accent.green, accent.blue, 0.22);
            cr.fill_preserve ();
            cr.set_source_rgba (accent.red, accent.green, accent.blue, 0.85);
            cr.set_line_width (2);
            cr.stroke ();
        }

        public BrowserTab? find (string id) {
            foreach (var tab in tabs) if (tab.tab_id == id) return tab;
            return null;
        }

        public int pinned_count () {
            int count = 0;
            foreach (var tab in tabs) if (tab.pinned) count++;
            return count;
        }

        public void add_tab (BrowserTab tab, int position = -1, bool activate = true) {
            if (tab.pinned) position = int.min (position < 0 ? pinned_count () : position, pinned_count ());
            else if (position >= 0) position = int.max (position, pinned_count ());
            if (position < 0 || position > tabs.size) position = tabs.size;
            tabs.insert (position, tab);
            stack.add_named (tab, tab.tab_id);
            chips.add_chip (tab.tab_id, tab.display_title);
            reorder_chips ();
            handlers[tab] = tab.state_changed.connect (() => sync_chip (tab));
            sync_chip (tab);
            var chip = chips.get_chip_widget (tab.tab_id);
            if (chip != null) Singularity.Motion.reveal (chip, Singularity.Motion.Preset.FADE);
            if (activate || active == null) select (tab);
            update_header ();
        }

        public void detach_tab (BrowserTab tab) {
            int index = tabs.index_of (tab);
            if (index < 0) return;
            if (handlers.has_key (tab)) {
                tab.disconnect (handlers[tab]);
                handlers.unset (tab);
            }
            tabs.remove (tab);
            prefix_keys.unset (tab.tab_id);
            chips.remove_chip (tab.tab_id);
            stack.remove (tab);
            if (active == tab) {
                active = null;
                if (!tabs.is_empty) select (tabs[int.min (index, tabs.size - 1)]);
            }
            update_header ();
            if (tabs.is_empty) emptied ();
        }

        public void select (BrowserTab tab) {
            if (!tabs.contains (tab)) return;
            active = tab;
            tab.materialize ();
            stack.visible_child = tab;
            chips.set_active (tab.tab_id);
            if (label_chars == -1) sync_all ();
            single_title.label = tab.display_title;
            tab_selected (tab);
        }

        public void mark_focused (bool value) {
            focused = value;
            if (value) add_css_class ("focused");
            else remove_css_class ("focused");
        }

        public void configure (bool chips_visible, bool header_visible) {
            show_chips = chips_visible;
            show_header = header_visible;
            update_header ();
        }

        private void update_header () {
            header.visible = show_chips || show_header;
            chips.visible = show_chips;
            add_button.visible = show_chips;
            grip.visible = show_header;
            single_title.visible = !show_chips;
            if (active != null) single_title.label = active.display_title;
            int chars = fitting_chars (get_width ());
            if (get_width () > 0 && chars != label_chars) {
                label_chars = chars;
                sync_all ();
            }
        }

        public void reveal () {
            bin.scale = 0.97;
            bin.opacity = 0;
            Singularity.Motion.reveal (bin, Singularity.Motion.Preset.SCALE_FADE);
        }

        public void set_pinned (BrowserTab tab, bool pinned) {
            if (tab.pinned == pinned) return;
            tabs.remove (tab);
            tab.pinned = pinned;
            tabs.insert (pinned ? pinned_count () : pinned_count (), tab);
            reorder_chips ();
            sync_chip (tab);
            order_changed ();
        }

        public void move_tab (BrowserTab tab, int position) {
            if (!tabs.contains (tab)) return;
            tabs.remove (tab);
            position = position.clamp (0, tabs.size);
            if (tab.pinned) position = int.min (position, pinned_count ());
            else position = int.max (position, pinned_count ());
            tabs.insert (position, tab);
            reorder_chips ();
            order_changed ();
        }

        private void on_reordered (string[] ids) {
            drop_overlay.visible = false;
            var ordered = new Gee.ArrayList<BrowserTab> ();
            foreach (string id in ids) {
                var tab = find (id);
                if (tab != null) ordered.add (tab);
            }
            if (ordered.size != tabs.size) return;
            var pinned = new Gee.ArrayList<BrowserTab> ();
            var rest = new Gee.ArrayList<BrowserTab> ();
            foreach (var tab in ordered) {
                if (tab.pinned) pinned.add (tab);
                else rest.add (tab);
            }
            tabs.clear ();
            tabs.add_all (pinned);
            tabs.add_all (rest);
            Idle.add (() => {
                reorder_chips ();
                return Source.REMOVE;
            });
            order_changed ();
        }

        private void reorder_chips () {
            string[] ids = {};
            foreach (var tab in tabs) ids += tab.tab_id;
            Widget? parent = null;
            var first = chips.get_chip_widget (ids.length > 0 ? ids[0] : "");
            if (first != null) parent = first.get_parent ();
            if (parent == null) return;
            Widget? previous = null;
            foreach (string id in ids) {
                var chip = chips.get_chip_widget (id);
                if (chip == null || chip.get_parent () != parent) continue;
                if (previous == null) {
                    if (parent.get_first_child () != chip) chip.insert_after (parent, null);
                } else if (previous.get_next_sibling () != chip) {
                    chip.insert_after (parent, previous);
                }
                previous = chip;
            }
        }

        public HashTable<string, TabGroup>? groups = null;

        public void sync_chip (BrowserTab tab) {
            bool icon_only = tab.pinned || label_chars == -1;
            string label = icon_only ? "" : tab.display_title;
            chips.set_chip_label (tab.tab_id, label);
            chips.set_chip_closable (tab.tab_id, !tab.pinned && (label_chars != -1 || tab == active));
            var chip = chips.get_chip_widget (tab.tab_id);
            if (chip != null) {
                chip.tooltip_text = tab.display_title;
                if (icon_only) chip.add_css_class ("icon-only");
                else chip.remove_css_class ("icon-only");
                if (tab.is_private) chip.add_css_class ("private");
            }
            TabGroup? group = groups != null && tab.group_id != "" ? groups[tab.group_id] : null;
            string key;
            if (tab.loading && tab.materialized) key = "load";
            else if (tab.muted) key = "mute";
            else if (tab.playing_audio) key = "audio";
            else if (tab.favicon != null) key = "fav:%p".printf (tab.favicon);
            else key = tab.is_new_tab ? "new" : "web:" + tab.uri;
            key += group != null ? "|" + group.color : "";
            if (prefix_keys[tab.tab_id] != key) {
                prefix_keys[tab.tab_id] = key;
                var prefix = new Box (Orientation.HORIZONTAL, 5);
                prefix.valign = Align.CENTER;
                if (group != null) {
                    var dot = new Box (Orientation.HORIZONTAL, 0);
                    dot.add_css_class ("browser-group-dot");
                    dot.valign = Align.CENTER;
                    var css = new CssProvider ();
                    css.load_from_string (".browser-group-dot { background-color: %s; }".printf (group.color));
                    dot.get_style_context ().add_provider (css, STYLE_PROVIDER_PRIORITY_USER + 2);
                    prefix.append (dot);
                }
                if (key.has_prefix ("load")) {
                    var spinner = new Spinner ();
                    spinner.spinning = true;
                    spinner.set_size_request (14, 14);
                    prefix.append (spinner);
                } else if (key.has_prefix ("mute") || key.has_prefix ("audio")) {
                    var sound = new Image.from_icon_name (key.has_prefix ("mute") ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic");
                    sound.pixel_size = 14;
                    prefix.append (sound);
                } else if (tab.favicon != null) {
                    var image = new Image.from_paintable (tab.favicon);
                    image.pixel_size = 16;
                    prefix.append (image);
                } else if (Address.is_internal (tab.uri) && !tab.is_new_tab) {
                    string internal_icon = "document-open-recent-symbolic";
                    if (tab.uri == Address.BOOKMARKS) internal_icon = "user-bookmarks-symbolic";
                    else if (tab.uri == Address.DOWNLOADS) internal_icon = "folder-download-symbolic";
                    var image = new Image.from_icon_name (internal_icon);
                    image.pixel_size = 14;
                    prefix.append (image);
                } else {
                    var image = new Image.from_icon_name (key.has_prefix ("new") ? "tab-new-symbolic" : "web-browser-symbolic");
                    image.pixel_size = 14;
                    prefix.append (image);
                }
                chips.set_chip_prefix (tab.tab_id, prefix);
            }
            if (chip != null) {
                if (icon_only) chip.set_label_chars (0, 0);
                else {
                    int chars = label_chars > 0 ? label_chars : chips.max_label_chars;
                    chip.set_label_chars (int.min (chips.min_label_chars, chars), chars);
                }
            }
            if (tab == active) single_title.label = tab.display_title;
        }

        public void sync_all () {
            foreach (var tab in tabs) sync_chip (tab);
        }

        public Widget? chip_for (BrowserTab tab) {
            return chips.get_chip_widget (tab.tab_id);
        }
    }
}
