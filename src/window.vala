using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public class BrowserWindow : Singularity.Widgets.Window {
        public Services services { get; construct; }
        public Profile profile { get; private set; }
        public bool is_private { get; construct; }
        public WebAppInfo? webapp { get; construct; }

        private Singularity.TileTree tree = new Singularity.TileTree ();
        private Gee.HashMap<string, BrowserTile> tiles = new Gee.HashMap<string, BrowserTile> ();
        private HashTable<string, TabGroup> groups = new HashTable<string, TabGroup> (str_hash, str_equal);
        private BrowserTile? focused_tile = null;
        private Box page_root;
        private Box tiles_box;
        private UrlBubble url;
        private Button back_bubble;
        private Button forward_bubble;
        private Button reload_bubble;
        private Button downloads_bubble;
        private Button? open_in_browser = null;
        private Overlay root_overlay;
        private OverlaySearch? tab_search = null;
        private Popover? downloads_popover = null;
        private AppSidebar? tab_sidebar = null;
        private uint sidebar_source = 0;
        private uint save_source = 0;
        private bool immersive = false;
        private bool web_fullscreen = false;
        private bool vertical_tabs = false;
        private int group_counter = 0;
        private string password_origin = "";
        private bool password_known = false;
        private uint password_lookup = 0;
        private Gee.HashSet<BrowserTab> closing = new Gee.HashSet<BrowserTab> ();

        public signal void session_changed ();

        public BrowserWindow (BrowserApp app, Services services, bool is_private, WebAppInfo? webapp = null) {
            Object (application: app, services: services, is_private: is_private, webapp: webapp);
            profile = webapp != null ? services.main_profile : (is_private ? services.acquire_private () : services.main_profile);
            set_default_size (1180, 800);
            set_title (webapp != null ? webapp.name : (is_private ? _("Private Browsing") : _("Browser")));
            add_css_class ("browser-window");
            if (is_private) add_css_class ("private");
            if (webapp != null) add_css_class ("webapp");

            back_bubble = add_bubble_icon ("go-previous-symbolic", _("Back"), () => current_tab_do ((t) => t.go_back ()));
            forward_bubble = add_bubble_icon ("go-next-symbolic", _("Forward"), () => current_tab_do ((t) => t.go_forward ()));
            reload_bubble = add_bubble_icon ("view-refresh-symbolic", _("Reload"), () => {
                var tab = current_tab ();
                if (tab == null) return;
                if (tab.loading) tab.stop ();
                else tab.reload ();
            });
            set_bubble_priority (back_bubble, 30);
            set_bubble_priority (reload_bubble, 20);

            url = new UrlBubble (services);
            url.is_private = is_private;
            url.activated.connect ((u, mode) => open (u, mode));
            url.switch_to_tab.connect ((id) => {
                var tab = find_tab (id);
                if (tab != null) focus_tab (tab);
            });
            url.escaped.connect (() => current_tab_do ((t) => t.focus_page ()));
            url.tab_matcher = match_tabs;
            url.security_button.clicked.connect (show_site_popover);
            url.reader_button.clicked.connect (() => current_tab_do ((t) => t.toggle_reader ()));
            url.sketch_button.clicked.connect (() => current_tab_do ((t) => t.toggle_sketch.begin ()));
            url.bookmark_button.clicked.connect (toggle_bookmark);
            url.zoom_button.clicked.connect (() => current_tab_do ((t) => t.zoom_step (0)));
            url.password_button.clicked.connect (() => fill_password ());
            add_bubble_widget (url);
            set_bubble_priority (url, Singularity.Widgets.Window.BUBBLE_PRIORITY_PINNED);

            if (webapp != null) {
                open_in_browser = add_bubble_icon ("web-browser-symbolic", _("Open in Browser"), () => {
                    var tab = current_tab ();
                    if (tab != null && !Address.is_internal (tab.uri)) ((BrowserApp) application).open_in_main_browser (tab.uri);
                });
            }

            downloads_bubble = add_bubble_icon ("folder-download-symbolic", _("Downloads"), show_downloads_popover);
            downloads_bubble.visible = false;
            downloads_bubble.add_css_class ("browser-downloads-bubble");
            services.downloads.changed.connect (sync_downloads);
            services.downloads.started.connect ((item) => {
                if (!is_active) return;
                downloads_bubble.visible = true;
                Singularity.Motion.reveal (downloads_bubble, Singularity.Motion.Preset.FADE);
            });
            services.downloads.completed.connect (on_download_completed);

            page_root = new Box (Orientation.VERTICAL, 0);
            page_root.add_css_class ("browser-root");
            tiles_box = new Box (Orientation.HORIZONTAL, 0);
            tiles_box.hexpand = true;
            tiles_box.vexpand = true;
            tiles_box.add_css_class ("browser-tiles");
            page_root.append (tiles_box);
            root_overlay = new Overlay ();
            root_overlay.child = page_root;
            set_content (root_overlay);
            Singularity.Widgets.apply_view_edge (page_root);

            vertical_tabs = webapp == null && services.settings.get_string ("tabs-layout") == "vertical";
            if (vertical_tabs) ensure_sidebar ();
            services.settings.changed["tabs-layout"].connect (() => set_vertical_tabs (services.settings.get_string ("tabs-layout") == "vertical"));
            services.closed_changed.connect (() => {
                var action = lookup_action ("reopen-tab") as SimpleAction;
                if (action != null) action.set_enabled (!services.closed.is_empty && !is_private);
            });
            services.store.bookmarks_changed.connect (() => sync_bubbles ());

            install_actions ();
            var keys = new EventControllerKey ();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect (on_key);
            ((Widget) this).add_controller (keys);

            notify["fullscreened"].connect (() => {
                if (!fullscreened && immersive && !web_fullscreen) set_immersive (false);
            });
            close_request.connect (() => {
                if (!is_private && webapp == null) ((BrowserApp) application).save_session ();
                if (is_private) services.release_private ();
                return false;
            });
        }

        public delegate void TabCallback (BrowserTab tab);

        private void current_tab_do (TabCallback callback) {
            var tab = current_tab ();
            if (tab != null) callback (tab);
        }

        public BrowserTab? current_tab () {
            return focused_tile != null ? focused_tile.active : null;
        }

        public Gee.List<BrowserTile> tiles_in_order () {
            var list = new Gee.ArrayList<BrowserTile> ();
            foreach (string id in tree.tiles ())
                if (tiles.has_key (id)) list.add (tiles[id]);
            return list;
        }

        public Gee.List<BrowserTab> all_tabs () {
            var list = new Gee.ArrayList<BrowserTab> ();
            foreach (var tile in tiles_in_order ()) list.add_all (tile.tabs);
            return list;
        }

        public TabGroup? group (string id) {
            return id != "" ? groups[id] : null;
        }

        public BrowserTab? find_tab (string id) {
            foreach (var tile in tiles.values) {
                var tab = tile.find (id);
                if (tab != null) return tab;
            }
            return null;
        }

        private BrowserTile? tile_of (BrowserTab tab) {
            foreach (var tile in tiles.values)
                if (tile.tabs.contains (tab)) return tile;
            return null;
        }

        private Suggestion[] match_tabs (string query) {
            Suggestion[] result = {};
            string q = query.down ();
            var current = current_tab ();
            foreach (var tab in all_tabs ()) {
                if (tab == current || tab.is_new_tab) continue;
                if (tab.display_title.down ().contains (q) || tab.uri.down ().contains (q)) {
                    var s = new Suggestion (SuggestionKind.TAB, tab.display_title, Address.full_display (tab.uri), tab.uri, "browser-tabs-symbolic");
                    s.tab_id = tab.tab_id;
                    result += s;
                }
            }
            return result;
        }

        private BrowserTile create_tile (string? id = null) {
            var tile = new BrowserTile (id);
            tile.groups = groups;
            tiles[tile.tile_id] = tile;
            tile.tab_selected.connect ((tab) => {
                if (tile == focused_tile) on_current_changed ();
                queue_sidebar ();
                queue_save ();
            });
            tile.tab_close_requested.connect (close_tab);
            tile.tab_context_requested.connect (show_tab_menu);
            tile.new_tab_requested.connect (() => new_tab_in (tile));
            tile.strip_context_requested.connect ((anchor, x, y) => show_strip_menu (tile, anchor, x, y));
            tile.activated.connect (() => focus_tile (tile));
            tile.emptied.connect (() => remove_tile (tile));
            tile.order_changed.connect (() => {
                queue_sidebar ();
                queue_save ();
            });
            tile.tab_dropped.connect (on_tab_dropped);
            tile.tile_dropped.connect (on_tile_dropped);
            return tile;
        }

        private void connect_tab (BrowserTab tab) {
            tab.state_changed.connect (() => {
                if (tab == current_tab ()) on_current_changed ();
                if (tab_sidebar != null) queue_sidebar ();
                queue_save ();
            });
            tab.open_requested.connect ((u, mode) => {
                if (webapp != null && !webapp.in_scope (u)) {
                    ((BrowserApp) application).open_in_main_browser (u);
                    return;
                }
                open_from (tab, u, mode);
            });
            tab.popup_requested.connect ((related) => {
                var popup = new BrowserTab (services, profile, null, related);
                connect_tab (popup);
                var tile = tile_of (tab) ?? focused_tile;
                tile.add_tab (popup, tile.tabs.index_of (tab) + 1, true);
                update_counts ();
                return popup.view;
            });
            tab.close_requested.connect (() => close_tab (tab));
            tab.download_only.connect (() => {
                var tile = tile_of (tab);
                if (tile != null && (tile.tabs.size > 1 || tiles.size > 1)) close_tab (tab);
                else tab.load (Address.NEW_TAB);
            });
            tab.fullscreen_changed.connect ((on) => {
                web_fullscreen = on;
                if (on) {
                    set_immersive (true);
                    fullscreen ();
                } else {
                    unfullscreen ();
                    set_immersive (false);
                }
            });
            tab.import_requested.connect ((source) => ((BrowserApp) application).import_bookmarks (this, source));
        }

        public BrowserTab add_tab (string? uri, BrowserTile? tile = null, int position = -1, bool activate = true) {
            var target = tile ?? focused_tile ?? ensure_first_tile ();
            var tab = new BrowserTab (services, profile, uri);
            connect_tab (tab);
            target.add_tab (tab, position, activate);
            if (activate && tab.materialized == false) tab.materialize ();
            update_counts ();
            queue_save ();
            return tab;
        }

        private BrowserTile ensure_first_tile () {
            if (!tiles.is_empty && focused_tile != null) return focused_tile;
            var tile = create_tile ();
            tree.add (tile.tile_id);
            rebuild_layout ();
            focus_tile (tile);
            return tile;
        }

        public void open (string uri, TabOpen mode) {
            var tab = current_tab ();
            if (tab == null) {
                add_tab (uri);
                return;
            }
            if (mode == TabOpen.FOREGROUND) {
                if (tab.pinned && Address.site_key (uri) != Address.site_key (tab.uri) && !tab.is_new_tab) {
                    open_from (tab, uri, TabOpen.FOREGROUND);
                    return;
                }
                tab.load (uri);
                tab.focus_page ();
                return;
            }
            open_from (tab, uri, mode);
        }

        public void open_from (BrowserTab? source, string uri, TabOpen mode) {
            switch (mode) {
                case TabOpen.WINDOW:
                    ((BrowserApp) application).new_window (uri, is_private);
                    return;
                case TabOpen.TILE:
                    split (Singularity.TileZone.RIGHT, uri);
                    return;
                default:
                    var tile = source != null ? (tile_of (source) ?? focused_tile) : focused_tile;
                    if (tile == null) {
                        add_tab (uri);
                        return;
                    }
                    int position = source != null ? tile.tabs.index_of (source) + 1 : -1;
                    while (position > 0 && position < tile.tabs.size && tile.tabs[position].group_id != "" && source != null
                           && tile.tabs[position].group_id == source.group_id)
                        position++;
                    var tab = add_tab (uri, tile, position, mode == TabOpen.FOREGROUND);
                    if (source != null && source.group_id != "") {
                        tab.group_id = source.group_id;
                        tile.sync_chip (tab);
                    }
                    return;
            }
        }

        public void split (Singularity.TileZone zone, string? uri = null, BrowserTab? moving = null) {
            if (webapp != null) return;
            var anchor = focused_tile ?? ensure_first_tile ();
            var tile = create_tile ();
            tree.split (anchor.tile_id, tile.tile_id, zone);
            if (moving != null) {
                var from = tile_of (moving);
                if (from != null) from.detach_tab (moving);
                tile.add_tab (moving);
            } else {
                var tab = new BrowserTab (services, profile, uri ?? Address.NEW_TAB);
                connect_tab (tab);
                tile.add_tab (tab);
            }
            rebuild_layout ();
            focus_tile (tile);
            tile.reveal ();
            update_counts ();
            queue_save ();
            Idle.add (() => {
                var t = tile.active;
                if (t != null) {
                    if (t.is_new_tab) url.begin_editing ();
                    else t.focus_page ();
                }
                return Source.REMOVE;
            });
        }

        public void new_tile () {
            if (tree.size == 0) {
                split (Singularity.TileZone.RIGHT);
                return;
            }
            var anchor = focused_tile;
            int width = anchor != null ? anchor.get_width () : get_width ();
            int height = anchor != null ? anchor.get_height () : get_height ();
            split (height > width ? Singularity.TileZone.BOTTOM : Singularity.TileZone.RIGHT);
        }

        private void remove_tile (BrowserTile tile) {
            if (!tiles.has_key (tile.tile_id)) return;
            string? next = null;
            if (tile == focused_tile) {
                foreach (var dir in new Singularity.TileDirection[] { Singularity.TileDirection.LEFT, Singularity.TileDirection.UP, Singularity.TileDirection.RIGHT, Singularity.TileDirection.DOWN }) {
                    next = tree.neighbor (tile.tile_id, dir);
                    if (next != null) break;
                }
            }
            tree.remove (tile.tile_id);
            tiles.unset (tile.tile_id);
            if (tiles.is_empty) {
                focused_tile = null;
                close ();
                return;
            }
            rebuild_layout ();
            if (tile == focused_tile) {
                focused_tile = null;
                var ids = tree.tiles ();
                focus_tile (tiles[next != null && tiles.has_key (next) ? next : ids[0]]);
            }
            update_counts ();
            queue_save ();
        }

        public void close_tile () {
            var tile = focused_tile;
            if (tile == null) return;
            if (tiles.size == 1) {
                close ();
                return;
            }
            foreach (var tab in tile.tabs.to_array ()) services.remember_closed (tab.uri, tab.display_title, tab.pinned);
            remove_tile (tile);
        }

        public void close_tab (BrowserTab tab) {
            var tile = tile_of (tab);
            if (tile == null) return;
            if (!is_private) services.remember_closed (tab.uri, tab.display_title, tab.pinned);
            var chip = tile.chip_for (tab);
            if (tiles.size == 1 && tile.tabs.size == 1) {
                close ();
                return;
            }
            if (closing.contains (tab)) return;
            if (chip != null && chip.get_mapped () && !Singularity.Motion.reduced () && tab != tile.active) {
                closing.add (tab);
                chip.can_target = false;
                Singularity.Motion.conceal (chip, Singularity.Motion.Preset.FADE).done.connect (() => {
                    closing.remove (tab);
                    if (tile.tabs.contains (tab)) tile.detach_tab (tab);
                    update_counts ();
                    queue_save ();
                });
                return;
            }
            tile.detach_tab (tab);
            update_counts ();
            queue_save ();
        }

        public void reopen (ClosedTab item) {
            services.closed.remove (item);
            services.closed_changed ();
            var tab = add_tab (item.url);
            if (item.pinned && focused_tile != null) focused_tile.set_pinned (tab, true);
        }

        public void focus_tab (BrowserTab tab) {
            var tile = tile_of (tab);
            if (tile == null) return;
            focus_tile (tile);
            tile.select (tab);
            tab.focus_page ();
        }

        private void focus_tile (BrowserTile tile) {
            if (focused_tile == tile) return;
            if (focused_tile != null) focused_tile.mark_focused (false);
            focused_tile = tile;
            tile.mark_focused (tiles.size > 1);
            on_current_changed ();
            queue_sidebar ();
        }

        public void focus_direction (Singularity.TileDirection direction) {
            if (focused_tile == null) return;
            string? next = tree.neighbor (focused_tile.tile_id, direction);
            if (next != null && tiles.has_key (next)) {
                focus_tile (tiles[next]);
                var tab = focused_tile.active;
                if (tab != null) tab.focus_page ();
            }
        }

        public void move_direction (Singularity.TileDirection direction) {
            if (focused_tile == null) return;
            string? next = tree.neighbor (focused_tile.tile_id, direction);
            if (next == null) return;
            tree.swap (focused_tile.tile_id, next);
            rebuild_layout ();
            queue_save ();
        }

        private void on_tab_dropped (string tab_id, BrowserTile target, Singularity.TileZone zone) {
            var tab = find_tab (tab_id);
            if (tab == null) {
                ((BrowserApp) application).move_tab_between_windows (tab_id, this, target, zone);
                return;
            }
            move_tab_to (tab, target, zone);
        }

        public void move_tab_to (BrowserTab tab, BrowserTile target, Singularity.TileZone zone) {
            var source = tile_of (tab);
            if (zone == Singularity.TileZone.CENTER) {
                if (source == target) return;
                if (source != null) source.detach_tab (tab);
                target.add_tab (tab);
                focus_tile (target);
            } else {
                if (source == target && target.tabs.size == 1) return;
                focus_tile (target);
                var anchor = target;
                var tile = create_tile ();
                tree.split (anchor.tile_id, tile.tile_id, zone);
                if (source != null) source.detach_tab (tab);
                tile.add_tab (tab);
                rebuild_layout ();
                focus_tile (tile);
                tile.reveal ();
            }
            update_counts ();
            queue_save ();
        }

        public BrowserTab? take_tab (string tab_id) {
            var tab = find_tab (tab_id);
            if (tab == null) return null;
            var tile = tile_of (tab);
            if (tile != null) tile.detach_tab (tab);
            update_counts ();
            return tab;
        }

        public void adopt_tab (BrowserTab tab, BrowserTile? target, Singularity.TileZone zone) {
            connect_tab (tab);
            if (target == null) {
                ensure_first_tile ().add_tab (tab);
            } else if (zone == Singularity.TileZone.CENTER) {
                target.add_tab (tab);
            } else {
                var tile = create_tile ();
                tree.split (target.tile_id, tile.tile_id, zone);
                tile.add_tab (tab);
                rebuild_layout ();
                focus_tile (tile);
            }
            update_counts ();
            queue_save ();
        }

        private void on_tile_dropped (string tile_id, BrowserTile target, Singularity.TileZone zone) {
            if (!tiles.has_key (tile_id)) return;
            var moved = tiles[tile_id];
            if (zone == Singularity.TileZone.CENTER) {
                foreach (var tab in moved.tabs.to_array ()) {
                    moved.detach_tab (tab);
                    target.add_tab (tab, -1, false);
                }
                focus_tile (target);
                return;
            }
            tree.move (tile_id, target.tile_id, zone);
            rebuild_layout ();
            focus_tile (moved);
            moved.reveal ();
            queue_save ();
        }

        public void detach_tile () {
            if (focused_tile == null || tiles.size < 2) {
                var tab = current_tab ();
                if (tab != null && focused_tile != null && focused_tile.tabs.size > 1) {
                    focused_tile.detach_tab (tab);
                    update_counts ();
                    ((BrowserApp) application).window_with_tab (tab, is_private);
                }
                return;
            }
            var tile = focused_tile;
            var tabs_list = tile.tabs.to_array ();
            var win = ((BrowserApp) application).window_with_tab (null, is_private);
            foreach (var tab in tabs_list) {
                tile.detach_tab (tab);
                win.adopt_tab (tab, null, Singularity.TileZone.CENTER);
            }
        }

        private void rebuild_layout () {
            foreach (var tile in tiles.values) {
                var parent = tile.get_parent ();
                if (parent is Paned) {
                    var paned = (Paned) parent;
                    if (paned.start_child == tile) paned.start_child = null;
                    else if (paned.end_child == tile) paned.end_child = null;
                } else if (parent is Box) {
                    ((Box) parent).remove (tile);
                }
            }
            Widget? child;
            while ((child = tiles_box.get_first_child ()) != null) tiles_box.remove (child);
            if (tree.root != null) tiles_box.append (build_node (tree.root));
            bool multi = tiles.size > 1;
            foreach (var tile in tiles.values) {
                tile.configure (!vertical_tabs && !immersive && webapp == null, multi && !immersive);
                tile.mark_focused (multi && tile == focused_tile);
            }
            if (multi) tiles_box.add_css_class ("tiled");
            else tiles_box.remove_css_class ("tiled");
        }

        private Widget build_node (Singularity.TileNode node) {
            if (node.tile != null) {
                return tiles.has_key (node.tile) ? tiles[node.tile] : new Box (Orientation.VERTICAL, 0);
            }
            var paned = new Paned (node.orientation);
            paned.add_css_class ("browser-paned");
            paned.resize_start_child = true;
            paned.resize_end_child = true;
            paned.shrink_start_child = true;
            paned.shrink_end_child = true;
            paned.wide_handle = false;
            paned.start_child = build_node (node.start);
            paned.end_child = build_node (node.end);
            bool applying = true;
            paned.notify["position"].connect (() => {
                if (applying) return;
                int span = node.orientation == Orientation.HORIZONTAL ? paned.get_width () : paned.get_height ();
                if (span > 1) {
                    node.ratio = ((double) paned.position / span).clamp (0.1, 0.9);
                    queue_save ();
                }
            });
            paned.map.connect (() => {
                applying = true;
                int frames = 0;
                int last_span = -1;
                paned.add_tick_callback ((widget, clock) => {
                    int span = node.orientation == Orientation.HORIZONTAL ? paned.get_width () : paned.get_height ();
                    frames++;
                    if (span > 1 && span != last_span) {
                        last_span = span;
                        paned.position = (int) Math.round (span * node.ratio);
                        if (frames < 30) return Source.CONTINUE;
                    } else if (span <= 1 && frames < 30) {
                        return Source.CONTINUE;
                    }
                    applying = false;
                    return Source.REMOVE;
                });
            });
            return paned;
        }

        private void update_counts () {
            queue_sidebar ();
            var action = lookup_action ("close-tile") as SimpleAction;
            if (action != null) action.set_enabled (tiles.size > 1);
        }

        private void on_current_changed () {
            var tab = current_tab ();
            if (tab == null) return;
            url.show_tab (tab);
            sync_bubbles ();
            string window_title = webapp != null ? webapp.name : tab.display_title;
            if (is_private && webapp == null && !tab.is_new_tab) window_title = _("%s (Private)").printf (tab.display_title);
            set_title (window_title);
            check_password.begin (tab);
        }

        private void sync_bubbles () {
            var tab = current_tab ();
            if (tab == null) return;
            url.show_tab (tab);
            back_bubble.sensitive = tab.can_go_back;
            forward_bubble.sensitive = tab.can_go_forward;
            var image = reload_bubble.child as Image;
            string icon = tab.loading && tab.materialized && !Address.is_internal (tab.uri) ? "process-stop-symbolic" : "view-refresh-symbolic";
            if (image != null && image.icon_name != icon) {
                image.icon_name = icon;
                reload_bubble.tooltip_text = icon == "process-stop-symbolic" ? _("Stop") : _("Reload");
                Singularity.Motion.reveal (image, Singularity.Motion.Preset.FADE);
            }
            set_enabled ("back", tab.can_go_back);
            set_enabled ("forward", tab.can_go_forward);
            set_enabled ("reader", tab.reader_available || tab.reader_active);
            bool web = tab.printable_view () != null;
            set_enabled ("print", web);
            set_enabled ("find", web);
            set_enabled ("devtools", web);
            set_enabled ("install-webapp", web && Store.recordable (tab.uri) && !is_private);
            set_enabled ("share", !Address.is_internal (tab.uri));
        }

        private void set_enabled (string name, bool enabled) {
            var action = lookup_action (name) as SimpleAction;
            if (action != null) action.set_enabled (enabled);
        }

        private async void check_password (BrowserTab tab) {
            uint lookup = ++password_lookup;
            string? origin = Passwords.eligible (tab.uri) ? Address.origin_of (tab.uri) : null;
            if (origin == null || is_private) {
                password_known = false;
                url.set_password_available (false);
                return;
            }
            if (origin == password_origin && password_known) {
                url.set_password_available (password_known);
                return;
            }
            password_origin = origin;
            uint revision = tab.password_revision;
            var found = yield Passwords.lookup (origin, profile.id);
            if (lookup != password_lookup || tab != current_tab () || revision != tab.password_revision
                || Address.origin_of (tab.uri) != origin || is_private) return;
            password_known = found.length > 0;
            url.set_password_available (password_known);
        }

        private void fill_password () {
            var tab = current_tab ();
            if (tab == null || is_private) return;
            choose_password.begin (tab);
        }

        private async void choose_password (BrowserTab tab) {
            string? origin = Address.origin_of (tab.uri);
            if (origin == null || !Passwords.eligible (tab.uri) || profile.ephemeral) return;
            uint revision = tab.password_revision;
            var found = yield Passwords.lookup (origin, profile.id, true);
            if (found.length == 0 || current_tab () != tab || tab.password_revision != revision) return;
            Credential? selected = found[0];
            if (found.length > 1) {
                var options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
                for (int i = 0; i < found.length; i++) {
                    options.add (new Singularity.Core.AppSettingOption () { id = i.to_string (), label = found[i].username != "" ? found[i].username : _("No username") });
                }
                var dlg = new ConfirmDialog (get_application (), _("Choose a Saved Login"), null, origin, _("Fill"), ConfirmDialog.ActionStyle.SUGGESTED);
                dlg.transient_for = this;
                dlg.modal = true;
                var group = new PreferencesGroup ();
                var row = new SelectionRow.with_options (_("Username"), options, "0");
                group.add_row (row);
                dlg.custom_area.append (group);
                selected = null;
                dlg.response.connect ((response) => {
                    if (response == ConfirmDialog.Response.PRIMARY) selected = found[int.parse (row.current_value)];
                    Idle.add (() => { choose_password.callback (); return Source.REMOVE; });
                });
                dlg.present ();
                yield;
            }
            if (selected == null || current_tab () != tab || tab.password_revision != revision || profile.ephemeral) return;
            if (!yield tab.fill_password (selected, revision)) add_toast (new Toast (_("No password field to fill on this page")));
        }

        private void show_site_popover () {
            var tab = current_tab ();
            if (tab == null || Address.is_internal (tab.uri)) return;
            var popover = new SitePopover (tab, password_known);
            popover.set_parent (url.security_button);
            popover.fill_password.connect (fill_password);
            popover.closed.connect (() => Idle.add (() => {
                popover.unparent ();
                return Source.REMOVE;
            }));
            popover.popup ();
        }

        private void toggle_bookmark () {
            var tab = current_tab ();
            if (tab == null || !Store.recordable (tab.uri)) return;
            var existing = services.store.bookmark_for_url (tab.uri);
            var popover = new Popover ();
            popover.has_arrow = false;
            popover.add_css_class ("browser-bookmark-popover");
            var box = new Box (Orientation.VERTICAL, 10);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            box.set_size_request (300, -1);
            var heading = new Label (existing != null ? _("Edit Bookmark") : _("Bookmark Added"));
            heading.add_css_class ("heading");
            heading.xalign = 0;
            box.append (heading);
            int64 id = existing != null ? existing.id : services.store.add_bookmark (Store.ROOT, tab.display_title, tab.uri);
            var name = new Entry ();
            name.text = existing != null ? existing.title : tab.display_title;
            box.append (name);
            var folders = services.store.folders ();
            string[] labels = { _("Bookmarks") };
            int64[] ids = { Store.ROOT };
            int selected = 0;
            var current = services.store.bookmark (id);
            foreach (var f in folders) {
                labels += f.title;
                ids += f.id;
                if (current != null && current.parent == f.id) selected = labels.length - 1;
            }
            var folder = new DropDown.from_strings (labels);
            folder.selected = selected;
            box.append (folder);
            var buttons = new Box (Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            var remove_btn = new Button.with_label (_("Remove"));
            remove_btn.add_css_class ("destructive-action");
            remove_btn.clicked.connect (() => {
                services.store.remove_bookmark (id);
                popover.popdown ();
            });
            buttons.append (remove_btn);
            var done = new Button.with_label (_("Done"));
            done.add_css_class ("suggested-action");
            done.clicked.connect (() => popover.popdown ());
            buttons.append (done);
            box.append (buttons);
            popover.child = box;
            popover.set_parent (url.bookmark_button);
            bool removed = false;
            remove_btn.clicked.connect (() => removed = true);
            name.activate.connect (() => popover.popdown ());
            popover.closed.connect (() => {
                if (!removed && services.store.bookmark (id) != null)
                    services.store.update_bookmark (id, name.text.strip () != "" ? name.text.strip () : tab.display_title, tab.uri, ids[folder.selected]);
                Idle.add (() => {
                    popover.unparent ();
                    return Source.REMOVE;
                });
                sync_bubbles ();
            });
            sync_bubbles ();
            popover.popup ();
        }

        private void sync_downloads () {
            int active = services.downloads.active_count;
            bool any = services.downloads.session_count > 0;
            downloads_bubble.visible = any;
            var image = downloads_bubble.child as Image;
            if (image != null) image.icon_name = active > 0 ? "browser-download-active-symbolic" : "folder-download-symbolic";
            downloads_bubble.tooltip_text = active > 0
                ? ngettext ("%d Download, %d%%", "%d Downloads, %d%%", active).printf (active, (int) (services.downloads.overall_progress * 100))
                : _("Downloads");
        }

        private void on_download_completed (DownloadItem item) {
            if (!is_active) return;
            var toast = new Toast (_("“%s” downloaded").printf (item.name));
            toast.button_label = _("Open");
            toast.button_clicked.connect (() => Downloads.open (item));
            add_toast (toast);
        }

        private void show_downloads_popover () {
            if (downloads_popover == null) {
                downloads_popover = new Popover ();
                downloads_popover.has_arrow = false;
                downloads_popover.add_css_class ("browser-downloads-popover");
                downloads_popover.set_parent (downloads_bubble);
            }
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;
            box.set_size_request (340, -1);
            var group = new PreferencesGroup (_("Downloads"));
            var items = services.downloads.items;
            for (uint i = 0; i < items.get_n_items () && i < 6; i++)
                group.add_row (DownloadRow.build ((DownloadItem) items.get_item (i), services.downloads));
            box.append (group);
            var all = new Button.with_label (_("Show All Downloads"));
            all.clicked.connect (() => {
                downloads_popover.popdown ();
                open_library (Address.DOWNLOADS);
            });
            box.append (all);
            downloads_popover.child = box;
            downloads_popover.popup ();
        }

        public void open_library (string page) {
            foreach (var tab in all_tabs ()) {
                if (tab.uri == page) {
                    focus_tab (tab);
                    tab.refresh_native ();
                    return;
                }
            }
            var tab = current_tab ();
            if (tab != null && tab.is_new_tab) {
                tab.load (page);
                return;
            }
            add_tab (page);
        }

        private void show_tab_menu (BrowserTab tab, Widget anchor) {
            var tile = tile_of (tab);
            if (tile == null) return;
            var menu = new Singularity.Widgets.ContextMenu (anchor);
            menu.add_item (_("New Tab to the Right"), "tab-new-symbolic", () => open_from (tab, Address.NEW_TAB, TabOpen.FOREGROUND));
            menu.add_item (_("Reload"), "view-refresh-symbolic", () => tab.reload ());
            menu.add_item (_("Duplicate"), "edit-copy-symbolic", () => open_from (tab, tab.uri, TabOpen.FOREGROUND));
            menu.add_item (tab.pinned ? _("Unpin Tab") : _("Pin Tab"), "view-pin-symbolic", () => {
                tile.set_pinned (tab, !tab.pinned);
                queue_save ();
            });
            if (tab.playing_audio || tab.muted)
                menu.add_item (tab.muted ? _("Unmute Tab") : _("Mute Tab"), "audio-volume-muted-symbolic", () => tab.toggle_mute ());
            menu.add_separator ();
            menu.add_item (_("Add to New Group"), "folder-new-symbolic", () => add_to_new_group (tab));
            foreach (var g in groups.get_values ()) {
                if (g.id == tab.group_id) continue;
                var target_group = g;
                menu.add_item (_("Add to %s").printf (g.name), "folder-symbolic", () => set_group (tab, target_group.id));
            }
            if (tab.group_id != "") {
                menu.add_item (_("Remove from Group"), "edit-clear-symbolic", () => set_group (tab, ""));
                var current_group = group (tab.group_id);
                if (current_group != null) add_group_items (menu, current_group, anchor);
            }
            menu.add_separator ();
            if (webapp == null) {
                menu.add_item (_("Move to New Tile"), "view-dual-symbolic", () => {
                    focus_tile (tile);
                    if (tile.tabs.size > 1) split (Singularity.TileZone.RIGHT, null, tab);
                });
                menu.add_item (_("Move to New Window"), "window-new-symbolic", () => {
                    tile.detach_tab (tab);
                    update_counts ();
                    ((BrowserApp) application).window_with_tab (tab, is_private);
                });
            }
            menu.add_separator ();
            menu.add_item (_("Close Other Tabs"), "edit-clear-all-symbolic", () => {
                foreach (var other in tile.tabs.to_array ())
                    if (other != tab && !other.pinned) close_tab (other);
            });
            menu.add_item (_("Close Tab"), "window-close-symbolic", () => close_tab (tab));
            add_closed_items (menu);
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void new_tab_in (BrowserTile tile) {
            if (webapp != null) return;
            focus_tile (tile);
            var tab = add_tab (Address.NEW_TAB, tile);
            tile.select (tab);
            Idle.add (() => {
                url.begin_editing ();
                return Source.REMOVE;
            });
        }

        private void show_strip_menu (BrowserTile tile, Widget anchor, double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu (anchor);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            menu.set_pointing_to (rect);
            menu.add_item (_("New Tab"), "tab-new-symbolic", () => new_tab_in (tile));
            menu.add_item (_("Search Tabs…"), "system-search-symbolic", open_tab_search);
            add_closed_items (menu);
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void add_closed_items (Singularity.Widgets.ContextMenu menu) {
            if (is_private || services.closed.is_empty) return;
            menu.add_separator ();
            menu.add_item (_("Reopen Closed Tab"), "edit-undo-symbolic", () => activate_action ("reopen-tab", null));
            var recent = menu.add_submenu (_("Recently Closed"), "document-open-recent-symbolic");
            int shown = 0;
            foreach (var item in services.closed) {
                var closed_item = item;
                recent.add_item (item.title != "" ? item.title : Address.display (item.url), "web-browser-symbolic", () => reopen (closed_item));
                if (++shown >= 10) break;
            }
        }

        private void add_group_items (Singularity.Widgets.ContextMenu menu, TabGroup g, Widget anchor) {
            menu.add_item (_("Rename Group"), "document-edit-symbolic", () => rename_group (g, anchor));
            menu.add_item (_("Ungroup Tabs"), "edit-clear-all-symbolic", () => ungroup (g));
            menu.add_item (_("Close Group"), "window-close-symbolic", () => close_group (g));
        }

        private void show_group_menu (TabGroup g, Widget anchor) {
            Widget host = popover_host (anchor);
            var menu = new Singularity.Widgets.ContextMenu (host);
            point_at (menu, host, anchor);
            menu.add_item (_("New Tab in Group"), "tab-new-symbolic", () => new_tab_in_group (g));
            menu.add_separator ();
            add_group_items (menu, g, anchor);
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private Widget popover_host (Widget anchor) {
            return tab_sidebar != null && anchor.is_ancestor (tab_sidebar) ? tab_sidebar : anchor;
        }

        private void point_at (Popover popover, Widget host, Widget anchor) {
            if (host == anchor) return;
            Graphene.Rect bounds;
            if (!anchor.compute_bounds (host, out bounds)) return;
            Gdk.Rectangle rect = { (int) bounds.origin.x, (int) bounds.origin.y, (int) bounds.size.width, (int) bounds.size.height };
            popover.set_pointing_to (rect);
        }

        private void new_tab_in_group (TabGroup g) {
            BrowserTab? last = null;
            foreach (var t in all_tabs ()) if (t.group_id == g.id) last = t;
            if (last == null) return;
            open_from (last, Address.NEW_TAB, TabOpen.FOREGROUND);
        }

        private void ungroup (TabGroup g) {
            foreach (var t in all_tabs ()) if (t.group_id == g.id) t.group_id = "";
            prune_groups ();
            foreach (var t in tiles.values) t.sync_all ();
            queue_sidebar ();
            queue_save ();
        }

        private void close_group (TabGroup g) {
            foreach (var t in all_tabs ()) if (t.group_id == g.id && !t.pinned) close_tab (t);
        }

        public void open_tab_search () {
            if (webapp != null) return;
            if (immersive) set_immersive (false);
            if (tab_search == null) {
                tab_search = new OverlaySearch ();
                tab_search.add_css_class ("browser-tab-search");
                tab_search.placeholder = _("Search Tabs");
                tab_search.empty_text = _("No open or recently closed tab matches");
                var results = find_scroll (tab_search);
                if (results != null) {
                    results.height_request = -1;
                    results.propagate_natural_height = true;
                    results.max_content_height = 360;
                }
                tab_search.close_requested.connect (close_tab_search);
                tab_search.item_activated.connect (on_tab_search_pick);
                var focus = new EventControllerFocus ();
                focus.leave.connect (() => Idle.add (() => {
                    if (tab_search != null && tab_search.visible && get_focus () != null && !get_focus ().is_ancestor (tab_search))
                        close_tab_search ();
                    return Source.REMOVE;
                }));
                tab_search.add_controller (focus);
                root_overlay.add_overlay (tab_search);
            }
            OverlaySearchItem[] items = {};
            var current = current_tab ();
            var ordered = tiles_in_order ();
            int index = 1;
            foreach (var tile in ordered) {
                string category = ordered.size > 1 ? _("Tile %d").printf (index++) : _("Open Tabs");
                foreach (var tab in tile.tabs) {
                    string icon = tab == current ? "object-select-symbolic" : (tab.pinned ? "view-pin-symbolic" : (tab.is_new_tab ? "tab-new-symbolic" : "web-browser-symbolic"));
                    items += new OverlaySearchItem ("tab:" + tab.tab_id, icon, tab.display_title, Address.full_display (tab.uri), null, category);
                }
            }
            if (!is_private) {
                int shown = 0;
                foreach (var item in services.closed) {
                    items += new OverlaySearchItem ("closed:%d".printf (shown), "edit-undo-symbolic",
                        item.title != "" ? item.title : Address.display (item.url),
                        _("Recently closed, %s").printf (Address.full_display (item.url)), null, _("Recently Closed"));
                    if (++shown >= 10) break;
                }
            }
            tab_search.top_offset = (force_ssd || legacy_titlebar ? 0 : Singularity.Widgets.VIEW_EDGE_INSET_HEIGHT) + 10;
            tab_search.set_items (items);
            tab_search.clear_text ();
            tab_search.open ();
            Singularity.Motion.reveal (tab_search, Singularity.Motion.Preset.FADE);
        }

        private ScrolledWindow? find_scroll (Widget root) {
            for (var child = root.get_first_child (); child != null; child = child.get_next_sibling ()) {
                if (child is ScrolledWindow) return (ScrolledWindow) child;
                var found = find_scroll (child);
                if (found != null) return found;
            }
            return null;
        }

        private void close_tab_search () {
            if (tab_search == null || !tab_search.visible) return;
            tab_search.close ();
            current_tab_do ((t) => t.focus_page ());
        }

        private void on_tab_search_pick (string id) {
            tab_search.close ();
            if (id.has_prefix ("tab:")) {
                var tab = find_tab (id.substring (4));
                if (tab != null) focus_tab (tab);
            } else if (id.has_prefix ("closed:")) {
                int n = int.parse (id.substring (7));
                if (n >= 0 && n < services.closed.size) reopen (services.closed[n]);
            }
        }

        private void add_to_new_group (BrowserTab tab) {
            group_counter++;
            string id = Uuid.string_random ();
            string color = TabGroup.COLORS[(groups.size ()) % TabGroup.COLORS.length];
            groups[id] = new TabGroup (id, _("Group %d").printf (group_counter), color);
            set_group (tab, id);
        }

        public void rename_group (TabGroup g, Widget anchor) {
            var popover = new Popover ();
            popover.has_arrow = false;
            popover.add_css_class ("browser-bookmark-popover");
            var box = new Box (Orientation.VERTICAL, 10);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            box.set_size_request (280, -1);
            var heading = new Label (_("Rename Group"));
            heading.add_css_class ("heading");
            heading.xalign = 0;
            box.append (heading);
            var name = new Entry ();
            name.text = g.name;
            name.placeholder_text = _("Group Name");
            box.append (name);
            var colors = new Box (Orientation.HORIZONTAL, 6);
            string picked = g.color;
            var swatches = new Gee.ArrayList<ToggleButton> ();
            foreach (unowned string color in TabGroup.COLORS) {
                var swatch = new ToggleButton ();
                swatch.add_css_class ("browser-group-swatch");
                swatch.tooltip_text = _("Group Color");
                var dot = new Box (Orientation.HORIZONTAL, 0);
                dot.add_css_class ("browser-group-dot");
                dot.halign = Align.CENTER;
                dot.valign = Align.CENTER;
                var css = new CssProvider ();
                css.load_from_string (".browser-group-dot { background-color: %s; }".printf (color));
                dot.get_style_context ().add_provider (css, STYLE_PROVIDER_PRIORITY_USER + 2);
                swatch.child = dot;
                swatch.active = color == g.color;
                string value = color;
                swatch.toggled.connect (() => {
                    if (!swatch.active) {
                        if (picked == value) swatch.active = true;
                        return;
                    }
                    picked = value;
                    foreach (var other in swatches)
                        if (other != swatch) other.active = false;
                });
                swatches.add (swatch);
                colors.append (swatch);
            }
            box.append (colors);
            var buttons = new Box (Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            var done = new Button.with_label (_("Done"));
            done.add_css_class ("suggested-action");
            done.clicked.connect (() => popover.popdown ());
            buttons.append (done);
            box.append (buttons);
            popover.child = box;
            var host = popover_host (anchor);
            popover.set_parent (host);
            point_at (popover, host, anchor);
            name.activate.connect (() => popover.popdown ());
            popover.closed.connect (() => {
                string text = name.text.strip ();
                if (groups.contains (g.id) && ((text != "" && text != g.name) || picked != g.color)) {
                    if (text != "") g.name = text;
                    g.color = picked;
                    foreach (var t in tiles.values) t.sync_all ();
                    queue_sidebar ();
                    queue_save ();
                }
                Idle.add (() => {
                    popover.unparent ();
                    return Source.REMOVE;
                });
            });
            popover.popup ();
            name.grab_focus ();
        }

        private void rename_current_group () {
            var tab = current_tab ();
            if (tab == null) return;
            var g = group (tab.group_id);
            if (g == null) return;
            var tile = tile_of (tab);
            Widget? anchor = tile != null ? tile.chips.get_chip_widget (tab.tab_id) : null;
            if (anchor == null || !anchor.get_mapped ()) anchor = url;
            rename_group (g, anchor);
        }

        private void set_group (BrowserTab tab, string id) {
            tab.group_id = id;
            var tile = tile_of (tab);
            if (tile != null && id != "") {
                int last = -1;
                for (int i = 0; i < tile.tabs.size; i++)
                    if (tile.tabs[i].group_id == id && tile.tabs[i] != tab) last = i;
                if (last >= 0) tile.move_tab (tab, last + (tile.tabs.index_of (tab) > last ? 1 : 0));
            }
            prune_groups ();
            foreach (var t in tiles.values) t.sync_all ();
            queue_sidebar ();
            queue_save ();
        }

        private void prune_groups () {
            var used = new Gee.HashSet<string> ();
            foreach (var tab in all_tabs ()) if (tab.group_id != "") used.add (tab.group_id);
            foreach (string key in groups.get_keys ()) if (!used.contains (key)) groups.remove (key);
        }

        public void set_vertical_tabs (bool vertical) {
            if (webapp != null) return;
            vertical_tabs = vertical;
            if (vertical) ensure_sidebar ();
            set_sidebar_visible (vertical);
            rebuild_layout ();
            var action = lookup_action ("vertical-tabs") as SimpleAction;
            if (action != null) action.set_state (new Variant.boolean (vertical));
            queue_sidebar ();
        }

        private void ensure_sidebar () {
            if (tab_sidebar != null) return;
            tab_sidebar = new AppSidebar (250);
            tab_sidebar.add_css_class ("browser-tab-sidebar");
            set_sidebar (tab_sidebar);
            set_sidebar_visible (vertical_tabs);
            queue_sidebar ();
        }

        private void queue_sidebar () {
            if (tab_sidebar == null || sidebar_source != 0) return;
            sidebar_source = Idle.add (() => {
                sidebar_source = 0;
                rebuild_sidebar ();
                return Source.REMOVE;
            });
        }

        private void rebuild_sidebar () {
            if (tab_sidebar == null) return;
            var box = tab_sidebar.box;
            Widget? child;
            while ((child = box.get_first_child ()) != null) box.remove (child);
            var new_row = new SidebarRow ("tab-new-symbolic", _("New Tab"));
            new_row.clicked.connect (() => activate_action ("new-tab", null));
            box.append (new_row);
            var tile_list = tiles_in_order ();
            int index = 1;
            foreach (var tile in tile_list) {
                var pinned = new FlowBox ();
                pinned.selection_mode = SelectionMode.NONE;
                pinned.max_children_per_line = 5;
                pinned.min_children_per_line = 5;
                pinned.add_css_class ("browser-pinned-grid");
                bool any_pinned = false;
                if (tile_list.size > 1) box.append (new SidebarSectionLabel (_("Tile %d").printf (index++)));
                string current_group = "";
                foreach (var tab in tile.tabs) {
                    if (tab.pinned) {
                        any_pinned = true;
                        var button = new Button ();
                        button.add_css_class ("browser-pinned-tab");
                        if (tab == tile.active) button.add_css_class ("active");
                        button.tooltip_text = tab.display_title;
                        var image = tab.favicon != null ? new Image.from_paintable (tab.favicon) : new Image.from_icon_name ("web-browser-symbolic");
                        image.pixel_size = 16;
                        button.child = image;
                        var t = tab;
                        button.clicked.connect (() => focus_tab (t));
                        pinned.append (button);
                        continue;
                    }
                    if (any_pinned && pinned.get_parent () == null) box.append (pinned);
                    if (tab.group_id != current_group) {
                        bool leaving = current_group != "";
                        current_group = tab.group_id;
                        var g = group (tab.group_id);
                        if (g == null && leaving) {
                            var gap = new Separator (Orientation.HORIZONTAL);
                            gap.add_css_class ("browser-group-end");
                            box.append (gap);
                        }
                        if (g != null) {
                            var label = new SidebarSectionLabel (g.name);
                            label.add_css_class ("browser-group-label");
                            label.tooltip_text = _("Rename Group");
                            var rename_click = new GestureClick ();
                            var renamed = g;
                            rename_click.released.connect (() => rename_group (renamed, label));
                            label.add_controller (rename_click);
                            var group_menu = new GestureClick ();
                            group_menu.button = Gdk.BUTTON_SECONDARY;
                            group_menu.pressed.connect (() => show_group_menu (renamed, label));
                            label.add_controller (group_menu);
                            var dot = new Box (Orientation.HORIZONTAL, 0);
                            dot.add_css_class ("browser-group-dot");
                            dot.valign = Align.CENTER;
                            dot.halign = Align.START;
                            var css = new CssProvider ();
                            css.load_from_string (".browser-group-dot { background-color: %s; }".printf (g.color));
                            dot.get_style_context ().add_provider (css, STYLE_PROVIDER_PRIORITY_APPLICATION);
                            label.prepend (dot);
                            box.append (label);
                        }
                    }
                    box.append (sidebar_tab_row (tab, tile));
                }
                if (any_pinned && pinned.get_parent () == null) box.append (pinned);
            }
        }

        private Widget sidebar_tab_row (BrowserTab tab, BrowserTile tile) {
            var row = new Box (Orientation.HORIZONTAL, 8);
            row.add_css_class ("browser-sidebar-tab");
            if (tab == tile.active) row.add_css_class ("active");
            Image icon;
            if (tab.loading && tab.materialized) icon = new Image.from_icon_name ("content-loading-symbolic");
            else if (tab.favicon != null) icon = new Image.from_paintable (tab.favicon);
            else icon = new Image.from_icon_name (tab.is_new_tab ? "tab-new-symbolic" : "web-browser-symbolic");
            icon.pixel_size = 16;
            row.append (icon);
            var label = new Label (tab.display_title);
            label.ellipsize = Pango.EllipsizeMode.END;
            label.xalign = 0;
            label.hexpand = true;
            row.append (label);
            var close = new Button.from_icon_name ("window-close-symbolic");
            close.add_css_class ("flat");
            close.add_css_class ("browser-sidebar-close");
            close.tooltip_text = _("Close Tab");
            close.clicked.connect (() => close_tab (tab));
            row.append (close);
            var click = new GestureClick ();
            click.released.connect ((n, x, y) => {
                var picked = row.pick (x, y, PickFlags.DEFAULT);
                if (picked != null && (picked == close || picked.is_ancestor (close))) return;
                focus_tab (tab);
            });
            row.add_controller (click);
            var secondary = new GestureClick ();
            secondary.button = Gdk.BUTTON_SECONDARY;
            secondary.pressed.connect (() => show_tab_menu (tab, row));
            row.add_controller (secondary);
            var middle = new GestureClick ();
            middle.button = 2;
            middle.released.connect (() => close_tab (tab));
            row.add_controller (middle);
            return row;
        }

        public void set_immersive (bool on) {
            if (immersive == on) return;
            immersive = on;
            bubbles_hidden = on;
            page_root.margin_top = on || force_ssd || legacy_titlebar ? 0 : Singularity.Widgets.VIEW_EDGE_INSET_HEIGHT;
            if (on) page_root.add_css_class ("immersive");
            else page_root.remove_css_class ("immersive");
            if (on && tab_sidebar != null) set_sidebar_visible (false);
            else if (!on && vertical_tabs) set_sidebar_visible (true);
            rebuild_layout ();
            if (on && !web_fullscreen) {
                var toast = new Toast (_("Press Esc to leave reading mode"));
                toast.timeout = 3;
                add_toast (toast);
            }
        }

        public void toggle_fullscreen () {
            if (fullscreened) {
                unfullscreen ();
                set_immersive (false);
            } else {
                fullscreen ();
                set_immersive (true);
            }
        }

        private bool on_key (uint keyval, uint keycode, Gdk.ModifierType state) {
            if (keyval == Gdk.Key.Escape) {
                if (immersive && !web_fullscreen) {
                    if (fullscreened) unfullscreen ();
                    set_immersive (false);
                    return true;
                }
                var tab = current_tab ();
                if (tab != null && tab.find_open) {
                    tab.close_find ();
                    return true;
                }
                if (tab != null && tab.loading && !url.entry.has_focus) {
                    tab.stop ();
                    return false;
                }
            }
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (ctrl && (keyval == Gdk.Key.Tab || keyval == Gdk.Key.ISO_Left_Tab)) {
                cycle_tab (shift || keyval == Gdk.Key.ISO_Left_Tab ? -1 : 1);
                return true;
            }
            if (ctrl && (keyval == Gdk.Key.Page_Down || keyval == Gdk.Key.Page_Up)) {
                cycle_tab (keyval == Gdk.Key.Page_Down ? 1 : -1);
                return true;
            }
            return false;
        }

        public void cycle_tab (int delta) {
            var tile = focused_tile;
            if (tile == null || tile.tabs.size < 2 || tile.active == null) return;
            int index = (tile.tabs.index_of (tile.active) + delta + tile.tabs.size) % tile.tabs.size;
            tile.select (tile.tabs[index]);
            tile.tabs[index].focus_page ();
        }

        public void select_index (int n) {
            var tile = focused_tile;
            if (tile == null || tile.tabs.is_empty) return;
            int index = n >= 9 ? tile.tabs.size - 1 : n - 1;
            if (index >= 0 && index < tile.tabs.size) {
                tile.select (tile.tabs[index]);
                tile.tabs[index].focus_page ();
            }
        }

        private void add_simple (string name, owned TabCallback callback) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => {
                var tab = current_tab ();
                if (tab != null) callback (tab);
            });
            add_action (action);
        }

        private void add_plain (string name, owned Singularity.Widgets.Window.BubbleAction callback) {
            var action = new SimpleAction (name, null);
            action.activate.connect (() => callback ());
            add_action (action);
        }

        private void install_actions () {
            add_plain ("new-tab", () => {
                if (webapp != null) return;
                var tab = add_tab (Address.NEW_TAB);
                if (focused_tile != null) focused_tile.select (tab);
                Idle.add (() => {
                    url.begin_editing ();
                    return Source.REMOVE;
                });
            });
            add_simple ("close-tab", (t) => close_tab (t));
            add_plain ("reopen-tab", () => {
                if (is_private) return;
                var item = services.pop_closed ();
                if (item != null) {
                    var tab = add_tab (item.url);
                    if (item.pinned && focused_tile != null) focused_tile.set_pinned (tab, true);
                }
            });
            add_simple ("reload", (t) => t.reload ());
            add_simple ("reload-hard", (t) => t.reload (true));
            add_simple ("stop", (t) => t.stop ());
            add_simple ("back", (t) => t.go_back ());
            add_simple ("forward", (t) => t.go_forward ());
            add_plain ("focus-address", () => {
                if (immersive) set_immersive (false);
                url.begin_editing ();
            });
            add_plain ("search-web", () => {
                if (immersive) set_immersive (false);
                url.begin_editing ("? ");
            });
            add_simple ("find", (t) => t.open_find ());
            add_simple ("find-next", (t) => t.find_next ());
            add_simple ("find-previous", (t) => t.find_previous ());
            add_simple ("zoom-in", (t) => t.zoom_step (1));
            add_simple ("zoom-out", (t) => t.zoom_step (-1));
            add_simple ("zoom-reset", (t) => t.zoom_step (0));
            add_plain ("bookmark", toggle_bookmark);
            add_plain ("show-bookmarks", () => open_library (Address.BOOKMARKS));
            add_plain ("show-history", () => open_library (Address.HISTORY));
            add_plain ("show-downloads", () => open_library (Address.DOWNLOADS));
            add_simple ("reader", (t) => {
                t.toggle_reader ();
                if (t.reader_active && !immersive) set_immersive (true);
                else if (!t.reader_active && immersive && !fullscreened) set_immersive (false);
            });
            add_plain ("reading-mode", () => set_immersive (!immersive));
            add_plain ("fullscreen", toggle_fullscreen);
            add_simple ("print", (t) => ((BrowserApp) application).print_tab (this, t));
            add_simple ("sketch", (t) => t.toggle_sketch.begin ());
            add_simple ("share", (t) => {
                if (!Address.is_internal (t.uri)) Singularity.Share.uris (this, { t.uri }, t.display_title);
            });
            add_simple ("devtools", (t) => t.show_inspector ());
            add_simple ("mute-tab", (t) => t.toggle_mute ());
            add_simple ("pin-tab", (t) => {
                var tile = tile_of (t);
                if (tile != null) tile.set_pinned (t, !t.pinned);
                queue_save ();
            });
            add_simple ("group-tab", (t) => add_to_new_group (t));
            add_plain ("rename-group", rename_current_group);
            add_plain ("fill-password", fill_password);
            add_plain ("new-tile", new_tile);
            add_plain ("split-right", () => split (Singularity.TileZone.RIGHT));
            add_plain ("split-down", () => split (Singularity.TileZone.BOTTOM));
            add_plain ("close-tile", close_tile);
            add_plain ("detach-tile", detach_tile);
            add_plain ("focus-left", () => focus_direction (Singularity.TileDirection.LEFT));
            add_plain ("focus-right", () => focus_direction (Singularity.TileDirection.RIGHT));
            add_plain ("focus-up", () => focus_direction (Singularity.TileDirection.UP));
            add_plain ("focus-down", () => focus_direction (Singularity.TileDirection.DOWN));
            add_plain ("move-left", () => move_direction (Singularity.TileDirection.LEFT));
            add_plain ("move-right", () => move_direction (Singularity.TileDirection.RIGHT));
            add_plain ("move-up", () => move_direction (Singularity.TileDirection.UP));
            add_plain ("move-down", () => move_direction (Singularity.TileDirection.DOWN));
            add_plain ("next-tab", () => cycle_tab (1));
            add_plain ("previous-tab", () => cycle_tab (-1));
            add_plain ("search-tabs", open_tab_search);
            var reopen_closed = new SimpleAction ("reopen-closed", VariantType.INT32);
            reopen_closed.activate.connect ((p) => {
                int n = p.get_int32 ();
                if (!is_private && n >= 0 && n < services.closed.size) reopen (services.closed[n]);
            });
            reopen_closed.set_enabled (!is_private);
            add_action (reopen_closed);
            add_plain ("install-webapp", () => {
                var tab = current_tab ();
                if (tab != null) WebApps.install_dialog (this, tab);
            });
            add_plain ("close", () => close ());
            var select = new SimpleAction ("select-tab", VariantType.INT32);
            select.activate.connect ((p) => select_index (p.get_int32 ()));
            add_action (select);
            var link_tab = new SimpleAction ("open-link-tab", VariantType.STRING);
            link_tab.activate.connect ((p) => open_from (current_tab (), p.get_string (), TabOpen.BACKGROUND));
            add_action (link_tab);
            var link_tile = new SimpleAction ("open-link-tile", VariantType.STRING);
            link_tile.activate.connect ((p) => split (Singularity.TileZone.RIGHT, p.get_string ()));
            add_action (link_tile);
            var vertical = new SimpleAction.stateful ("vertical-tabs", null, new Variant.boolean (vertical_tabs));
            vertical.activate.connect (() => {
                services.settings.set_string ("tabs-layout", vertical_tabs ? "horizontal" : "vertical");
            });
            add_action (vertical);
            set_enabled ("reopen-tab", !services.closed.is_empty && !is_private);
        }

        private void queue_save () {
            if (is_private || webapp != null) return;
            if (save_source != 0) return;
            save_source = Timeout.add (600, () => {
                save_source = 0;
                session_changed ();
                return Source.REMOVE;
            });
        }

        public void write_session (Json.Builder builder) {
            builder.begin_object ();
            builder.set_member_name ("tiles");
            builder.begin_array ();
            foreach (var tile in tiles_in_order ()) {
                builder.begin_object ();
                builder.set_member_name ("id");
                builder.add_string_value (tile.tile_id);
                builder.set_member_name ("active");
                builder.add_int_value (tile.active != null ? tile.tabs.index_of (tile.active) : 0);
                builder.set_member_name ("focused");
                builder.add_boolean_value (tile == focused_tile);
                builder.set_member_name ("tabs");
                builder.begin_array ();
                foreach (var tab in tile.tabs) {
                    builder.begin_object ();
                    builder.set_member_name ("url");
                    builder.add_string_value (tab.session_uri () ?? "");
                    builder.set_member_name ("title");
                    builder.add_string_value (tab.title);
                    builder.set_member_name ("pinned");
                    builder.add_boolean_value (tab.pinned);
                    builder.set_member_name ("group");
                    builder.add_string_value (tab.group_id);
                    builder.end_object ();
                }
                builder.end_array ();
                builder.end_object ();
            }
            builder.end_array ();
            builder.set_member_name ("layout");
            builder.add_value (tree.to_json ());
            builder.set_member_name ("groups");
            builder.begin_array ();
            foreach (var g in groups.get_values ()) {
                builder.begin_object ();
                builder.set_member_name ("id");
                builder.add_string_value (g.id);
                builder.set_member_name ("name");
                builder.add_string_value (g.name);
                builder.set_member_name ("color");
                builder.add_string_value (g.color);
                builder.end_object ();
            }
            builder.end_array ();
            builder.end_object ();
        }

        public bool restore_session (Json.Object saved) {
            if (saved.has_member ("groups")) {
                var list = saved.get_array_member ("groups");
                for (uint i = 0; i < list.get_length (); i++) {
                    var g = list.get_object_element (i);
                    if (g == null || !g.has_member ("id")) continue;
                    string id = g.get_string_member ("id");
                    groups[id] = new TabGroup (id, g.get_string_member_with_default ("name", _("Group")), g.get_string_member_with_default ("color", TabGroup.COLORS[0]));
                    group_counter++;
                }
            }
            if (!saved.has_member ("tiles")) return false;
            var saved_tiles = saved.get_array_member ("tiles");
            string[] ids = {};
            BrowserTile? to_focus = null;
            for (uint i = 0; i < saved_tiles.get_length (); i++) {
                var st = saved_tiles.get_object_element (i);
                if (st == null || !st.has_member ("tabs")) continue;
                var tile = create_tile (st.get_string_member_with_default ("id", Uuid.string_random ()));
                var saved_tabs = st.get_array_member ("tabs");
                for (uint j = 0; j < saved_tabs.get_length (); j++) {
                    var s = saved_tabs.get_object_element (j);
                    if (s == null) continue;
                    string u = s.get_string_member_with_default ("url", "");
                    if (u == "") continue;
                    var tab = new BrowserTab (services, profile, null);
                    tab.restore (u, s.get_string_member_with_default ("title", ""));
                    tab.pinned = s.get_boolean_member_with_default ("pinned", false);
                    string gid = s.get_string_member_with_default ("group", "");
                    tab.group_id = groups.contains (gid) ? gid : "";
                    connect_tab (tab);
                    tile.add_tab (tab, -1, false);
                }
                if (tile.tabs.is_empty) {
                    tiles.unset (tile.tile_id);
                    continue;
                }
                int active = (int) st.get_int_member_with_default ("active", 0);
                tile.select (tile.tabs[active.clamp (0, tile.tabs.size - 1)]);
                ids += tile.tile_id;
                if (st.get_boolean_member_with_default ("focused", false)) to_focus = tile;
            }
            if (ids.length == 0) return false;
            Singularity.TileTree? restored = saved.has_member ("layout") ? Singularity.TileTree.from_json (saved.get_member ("layout"), ids) : null;
            if (restored != null) tree.replace_root (restored.root);
            else foreach (string id in ids) tree.add (id);
            rebuild_layout ();
            focus_tile (to_focus ?? tiles[ids[0]]);
            prune_groups ();
            foreach (var t in tiles.values) t.sync_all ();
            update_counts ();
            return true;
        }

        public void start_blank () {
            add_tab (Address.NEW_TAB);
        }
    }
}
