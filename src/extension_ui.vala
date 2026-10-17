using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Browser {

    public class ExtensionsPopover : Popover {
        private Services services;
        private Stack stack;
        private WebKit.WebView? popup_view;

        public signal void open_url (string url);

        public ExtensionsPopover (Services services, Widget anchor) {
            this.services = services;
            has_arrow = false;
            add_css_class ("browser-extensions-popover");
            set_parent (anchor);
            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.vhomogeneous = false;
            stack.hhomogeneous = false;
            child = stack;
            closed.connect (() => {
                if (popup_view != null) {
                    popup_view.try_close ();
                    popup_view = null;
                }
            });
        }

        public void show_list () {
            var box = page_box ();
            var group = new PreferencesGroup (_("Extensions"));
            int shown = 0;
            foreach (var extension in services.extension_manager.extensions) {
                if (!services.extension_manager.is_enabled (extension.id)) continue;
                var row = new ActionRow (extension.name, extension.action_title != null && extension.action_title != extension.name ? extension.action_title : null);
                row.add_prefix (extension_icon (extension, 24));
                string? badge = services.extensions.badge_for (extension.id);
                if (badge != null && badge != "") {
                    var label = new Label (badge);
                    label.add_css_class ("browser-extension-badge");
                    row.add_suffix (label);
                }
                row.activatable = true;
                row.activated.connect (() => {
                    if (extension.popup != null) show_popup (extension);
                    else {
                        services.extensions.action_clicked (extension);
                        popdown ();
                    }
                });
                group.add_row (row);
                shown++;
            }
            if (shown == 0) {
                var empty = new StatusPage ();
                empty.compact = true;
                empty.icon_name = "application-x-addon-symbolic";
                empty.title = _("No Extensions");
                empty.description = _("Add extensions from the Chrome Web Store.");
                box.append (empty);
            } else {
                box.append (group);
            }
            var actions = new Box (Orientation.HORIZONTAL, 8);
            actions.homogeneous = true;
            var store = new Button.with_label (_("Chrome Web Store"));
            store.clicked.connect (() => {
                popdown ();
                open_url ("https://" + ExtensionManager.STORE_HOST + "/category/extensions");
            });
            var manage = new Button.with_label (_("Manage"));
            manage.clicked.connect (show_manage);
            actions.append (store);
            actions.append (manage);
            box.append (actions);
            replace (box);
        }

        private void show_manage () {
            var box = page_box ();
            box.append (back_button ());
            var group = new PreferencesGroup (_("Installed Extensions"));
            foreach (var extension in services.extension_manager.extensions) {
                var row = new ActionRow (extension.name, _("Version %s").printf (extension.version));
                row.add_prefix (extension_icon (extension, 24));
                if (extension.options_page != null) {
                    var options = new Button.from_icon_name ("emblem-system-symbolic");
                    options.tooltip_text = _("Options");
                    options.valign = Align.CENTER;
                    options.add_css_class ("flat");
                    options.clicked.connect (() => {
                        popdown ();
                        open_url (services.extensions.page_url (extension, extension.options_page));
                    });
                    row.add_suffix (options);
                }
                var remove = new Button.from_icon_name ("user-trash-symbolic");
                remove.tooltip_text = _("Remove");
                remove.valign = Align.CENTER;
                remove.add_css_class ("flat");
                remove.clicked.connect (() => {
                    try {
                        services.extension_manager.uninstall (extension.id);
                    } catch (Error e) {
                        warning ("Extension could not be removed: %s", e.message);
                    }
                    show_manage ();
                });
                row.add_suffix (remove);
                var toggle = new Switch ();
                toggle.valign = Align.CENTER;
                toggle.active = services.extension_manager.is_enabled (extension.id);
                toggle.notify["active"].connect (() => services.extension_manager.set_enabled (extension.id, toggle.active));
                row.add_suffix (toggle);
                group.add_row (row);
            }
            box.append (group);
            replace (box);
        }

        private void show_popup (Extension extension) {
            var box = new Box (Orientation.VERTICAL, 0);
            box.append (back_button ());
            if (popup_view != null) popup_view.try_close ();
            popup_view = services.extensions.create_page_view (extension);
            popup_view.set_size_request (380, 480);
            popup_view.load_uri (services.extensions.page_url (extension, extension.popup));
            var view = popup_view;
            view.load_changed.connect ((event) => {
                if (event != WebKit.LoadEvent.FINISHED) return;
                view.evaluate_javascript.begin ("[document.documentElement.scrollWidth, document.documentElement.scrollHeight]", -1, null, null, null, (obj, res) => {
                    try {
                        var size = view.evaluate_javascript.end (res);
                        int width = size.object_get_property_at_index (0).to_int32 ();
                        int height = size.object_get_property_at_index (1).to_int32 ();
                        view.set_size_request (width.clamp (200, 800), height.clamp (80, 600));
                    } catch (Error e) {
                    }
                });
            });
            view.close.connect (() => popdown ());
            box.append (view);
            replace (box);
        }

        private Widget back_button () {
            var back = new Button.from_icon_name ("go-previous-symbolic");
            back.tooltip_text = _("Back");
            back.halign = Align.START;
            back.add_css_class ("flat");
            back.clicked.connect (show_list);
            return back;
        }

        private Box page_box () {
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 10;
            box.margin_end = 10;
            box.set_size_request (340, -1);
            return box;
        }

        private void replace (Widget page) {
            var previous = stack.visible_child;
            stack.add_child (page);
            stack.visible_child = page;
            if (previous != null && previous != page) {
                Idle.add (() => {
                    if (previous.get_parent () == stack) stack.remove (previous);
                    return Source.REMOVE;
                });
            }
        }

        public static Widget extension_icon (Extension extension, int size) {
            var icon_widget = icon_image (extension, size);
            icon_widget.margin_end = 8;
            return icon_widget;
        }

        private static Image icon_image (Extension extension, int size) {
            string? icon = extension.icon_for (size);
            if (icon != null) {
                try {
                    string file = extension.resolve (icon);
                    if (FileUtils.test (file, FileTest.IS_REGULAR)) {
                        var picture = new Image.from_file (file);
                        picture.pixel_size = size;
                        return picture;
                    }
                } catch (ExtensionError e) {
                }
            }
            var fallback = new Image.from_icon_name ("application-x-addon-symbolic");
            fallback.pixel_size = size;
            return fallback;
        }
    }

    namespace ExtensionPermissions {

        public string[] describe (Extension extension) {
            string[] lines = {};
            foreach (string host in extension.host_permissions) {
                if (host == "<all_urls>" || host == "*://*/*" || host == "https://*/*" || host == "http://*/*") {
                    lines += _("Read and change all your data on all websites");
                    break;
                }
            }
            if (lines.length == 0 && extension.host_permissions.length > 0) {
                lines += _("Read and change your data on %s").printf (string.joinv (", ", extension.host_permissions));
            }
            bool all_sites = false;
            foreach (var script in extension.content_scripts) {
                foreach (string m in script.matches) {
                    if (m == "<all_urls>" || m.has_prefix ("*://*/") || m == "https://*/*" || m == "http://*/*") all_sites = true;
                }
            }
            if (all_sites && lines.length == 0) lines += _("Read and change all your data on all websites");
            foreach (string permission in extension.permissions) {
                switch (permission) {
                    case "tabs":
                    case "webNavigation":
                        lines += _("Read your browsing history");
                        break;
                    case "history":
                        lines += _("Read and change your browsing history");
                        break;
                    case "bookmarks":
                        lines += _("Read and change your bookmarks");
                        break;
                    case "clipboardRead":
                        lines += _("Read data you copy and paste");
                        break;
                    case "clipboardWrite":
                        lines += _("Change data you copy and paste");
                        break;
                    case "downloads":
                        lines += _("Manage your downloads");
                        break;
                    case "notifications":
                        lines += _("Show notifications");
                        break;
                    case "nativeMessaging":
                        lines += _("Talk to other programs on this computer");
                        break;
                    case "declarativeNetRequest":
                    case "declarativeNetRequestWithHostAccess":
                        lines += _("Block content on any page");
                        break;
                    case "privacy":
                        lines += _("Change your privacy settings");
                        break;
                    case "management":
                        lines += _("Manage your apps, extensions and themes");
                        break;
                }
            }
            string[] unique = {};
            foreach (string line in lines) {
                if (!(line in unique)) unique += line;
            }
            return unique;
        }
    }
}
