namespace Singularity.Apps.Browser {

    public class ReaderArticle : Object {
        public string title = "";
        public string byline = "";
        public string site = "";
        public string content = "";
        public int text_length = 0;
    }

    public class Reader : Object {
        public const int MIN_TEXT = 500;

        private const string[] SKIP = {
            "script", "style", "noscript", "nav", "header", "footer", "aside", "form", "iframe", "svg",
            "button", "input", "select", "textarea", "template", "canvas", "object", "embed", "dialog", "menu"
        };
        private const string[] BLOCKS = {
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "figure",
            "figcaption", "table", "thead", "tbody", "tr", "td", "th", "hr", "dl", "dt", "dd"
        };
        private const string[] INLINES = { "a", "em", "strong", "b", "i", "code", "br", "img", "sup", "sub", "small", "mark", "q", "abbr", "span" };

        private string base_uri;
        private Gee.HashMap<Xml.Node*, double?> scores = new Gee.HashMap<Xml.Node*, double?> ();

        private Reader (string base_uri) {
            this.base_uri = base_uri;
        }

        public static ReaderArticle? extract (string html, string base_uri) {
            if (html.length == 0) return null;
            var doc = Html.Doc.read_memory (html.to_utf8 (), html.length, base_uri, "UTF-8",
                Html.ParserOption.NOERROR | Html.ParserOption.NOWARNING | Html.ParserOption.NONET | Html.ParserOption.RECOVER);
            if (doc == null) return null;
            var reader = new Reader (base_uri);
            var article = reader.run (doc);
            delete doc;
            return article;
        }

        private ReaderArticle? run (Html.Doc* doc) {
            Xml.Node* root = doc->get_root_element ();
            if (root == null) return null;
            var article = new ReaderArticle ();
            article.title = find_meta (root, "og:title") ?? find_title (root) ?? "";
            article.byline = find_meta (root, "author") ?? "";
            article.site = find_meta (root, "og:site_name") ?? Address.display (base_uri);
            score_tree (root);
            Xml.Node* best = null;
            double best_score = 0;
            foreach (var entry in scores.entries) {
                Xml.Node* node = entry.key;
                double score = entry.value * (1.0 - link_density (node));
                if (score > best_score) {
                    best_score = score;
                    best = node;
                }
            }
            if (best == null) return null;
            var out_html = new StringBuilder ();
            int text = 0;
            write_children (best, out_html, ref text, article.title);
            article.content = out_html.str;
            article.text_length = text;
            return text >= MIN_TEXT ? article : null;
        }

        private static string? attr (Xml.Node* node, string name) {
            string? value = node->get_prop (name);
            return value != null ? value.strip () : null;
        }

        private static string? find_meta (Xml.Node* node, string key) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (n->name.down () == "meta") {
                    string? p = attr (n, "property") ?? attr (n, "name");
                    if (p != null && p.down () == key) {
                        string? content = attr (n, "content");
                        if (content != null && content != "") return content;
                    }
                }
                if (n->name.down () == "body") continue;
                string? found = find_meta (n->children, key);
                if (found != null) return found;
            }
            return null;
        }

        private static string? find_title (Xml.Node* node) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                string name = n->name.down ();
                if (name == "title" || name == "h1") {
                    string text = collapse (n->get_content ());
                    if (text != "") return text;
                }
                string? found = find_title (n->children);
                if (found != null) return found;
            }
            return null;
        }

        private static string collapse (string? text) {
            if (text == null) return "";
            try {
                return new Regex ("\\s+").replace (text, -1, 0, " ").strip ();
            } catch (RegexError e) {
                return text.strip ();
            }
        }

        private static double class_weight (Xml.Node* node) {
            string hint = ((attr (node, "class") ?? "") + " " + (attr (node, "id") ?? "")).down ();
            double weight = 0;
            string[] bad = { "comment", "footer", "sidebar", "nav", "menu", "share", "social", "related", "promo", "advert", "banner", "cookie", "popup", "newsletter", "subscribe" };
            string[] good = { "article", "content", "post", "entry", "main", "story", "text", "body", "prose" };
            foreach (string b in bad) if (hint.contains (b)) weight -= 25;
            foreach (string g in good) if (hint.contains (g)) weight += 25;
            return weight;
        }

        private void score_tree (Xml.Node* node) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                string name = n->name.down ();
                if (name in SKIP) continue;
                if (name == "p" || name == "pre" || name == "blockquote") {
                    string text = collapse (n->get_content ());
                    if (text.length >= 25) {
                        double value = 1 + text.split (",").length + double.min (text.length / 100.0, 3);
                        add_score (n->parent, value);
                        if (n->parent != null) add_score (n->parent->parent, value / 2);
                    }
                    continue;
                }
                score_tree (n->children);
            }
        }

        private void add_score (Xml.Node* node, double value) {
            if (node == null || node->type != Xml.ElementType.ELEMENT_NODE) return;
            if (!scores.has_key (node)) {
                double initial = class_weight (node);
                string name = node->name.down ();
                if (name == "article" || name == "main") initial += 10;
                else if (name == "div") initial += 5;
                scores[node] = initial;
            }
            scores[node] = scores[node] + value;
        }

        private static double link_density (Xml.Node* node) {
            int total = collapse (node->get_content ()).length;
            if (total == 0) return 1;
            int links = link_text (node->children);
            return double.min (1.0, (double) links / total);
        }

        private static int link_text (Xml.Node* node) {
            int count = 0;
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (n->name.down () == "a") count += collapse (n->get_content ()).length;
                else count += link_text (n->children);
            }
            return count;
        }

        private string? absolute (string? href) {
            if (href == null || href == "") return null;
            string h = href.strip ();
            if (h.down ().has_prefix ("javascript:") || h.down ().has_prefix ("data:text")) return null;
            try {
                return Uri.resolve_relative (base_uri, h, UriFlags.NONE);
            } catch (Error e) {
                return null;
            }
        }

        private void write_children (Xml.Node* node, StringBuilder sb, ref int text, string title) {
            for (Xml.Node* n = node->children; n != null; n = n->next) write_node (n, sb, ref text, title);
        }

        private void write_node (Xml.Node* n, StringBuilder sb, ref int text, string title) {
            if (n->type == Xml.ElementType.TEXT_NODE || n->type == Xml.ElementType.CDATA_SECTION_NODE) {
                string content = n->content ?? "";
                string trimmed = content.replace ("\n", " ").replace ("\t", " ");
                if (trimmed.strip () == "" && trimmed.length > 0) {
                    sb.append (" ");
                    return;
                }
                text += trimmed.strip ().length;
                sb.append (Markup.escape_text (trimmed));
                return;
            }
            if (n->type != Xml.ElementType.ELEMENT_NODE) return;
            string name = n->name.down ();
            if (name in SKIP) return;
            if (class_weight (n) <= -25 && name != "p") return;
            if (name == "h1") {
                string heading = collapse (n->get_content ());
                if (heading == title) return;
                name = "h2";
            }
            if (name == "img") {
                string? src = absolute (attr (n, "src") ?? attr (n, "data-src"));
                if (src == null) return;
                sb.append ("<img src=\"%s\" alt=\"%s\">".printf (Markup.escape_text (src), Markup.escape_text (attr (n, "alt") ?? "")));
                return;
            }
            if (name == "br" || name == "hr") {
                sb.append ("<%s>".printf (name));
                return;
            }
            if (name == "a") {
                string? href = absolute (attr (n, "href"));
                if (href != null) sb.append ("<a href=\"%s\">".printf (Markup.escape_text (href)));
                write_children (n, sb, ref text, title);
                if (href != null) sb.append ("</a>");
                return;
            }
            if (name in BLOCKS || (name in INLINES && name != "span")) {
                if (name in BLOCKS && link_density (n) > 0.6 && collapse (n->get_content ()).length < 200 && name != "li") return;
                sb.append ("<%s>".printf (name));
                write_children (n, sb, ref text, title);
                sb.append ("</%s>".printf (name));
                if (name in BLOCKS) sb.append ("\n");
                return;
            }
            if (name == "div" || name == "section" || name == "article" || name == "main") {
                write_children (n, sb, ref text, title);
                sb.append ("\n");
                return;
            }
            write_children (n, sb, ref text, title);
        }

        public static string render (ReaderArticle article, string accent) {
            string byline = article.byline != "" ? "<span>%s</span>".printf (Markup.escape_text (article.byline)) : "";
            return """<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; style-src 'unsafe-inline'">
<title>%s</title><style>
:root { color-scheme: light dark; --fg: #1c1c1e; --muted: #6e6e73; --bg: #fbfbfa; --accent: %s; }
@media (prefers-color-scheme: dark) { :root { --fg: #ececec; --muted: #9a9aa0; --bg: #1c1c1e; } }
html { background: var(--bg); }
body { max-width: 42rem; margin: 0 auto; padding: 3.5rem 1.5rem 6rem; color: var(--fg);
  font: 1.18rem/1.7 "Iowan Old Style", "Source Serif 4", "Noto Serif", Georgia, serif; }
header { margin-bottom: 2.2rem; font-family: system-ui, sans-serif; }
.site { color: var(--accent); font-weight: 600; font-size: .85rem; letter-spacing: .04em; text-transform: uppercase; }
h1 { font: 700 2.1rem/1.2 system-ui, sans-serif; margin: .4rem 0 .6rem; }
.byline { color: var(--muted); font-size: .95rem; }
h2, h3, h4 { font-family: system-ui, sans-serif; line-height: 1.3; margin-top: 2rem; }
a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
img { max-width: 100%%; height: auto; border-radius: 10px; display: block; margin: 1.5rem auto; }
blockquote { margin: 1.5rem 0; padding-left: 1.2rem; border-left: 3px solid var(--accent); color: var(--muted); }
pre, code { font-family: ui-monospace, "Source Code Pro", monospace; font-size: .9em; }
pre { overflow-x: auto; padding: 1rem; border-radius: 10px; background: color-mix(in srgb, var(--fg) 6%%, transparent); }
figcaption { color: var(--muted); font-size: .9rem; text-align: center; }
table { border-collapse: collapse; width: 100%%; } td, th { border-bottom: 1px solid color-mix(in srgb, var(--fg) 12%%, transparent); padding: .4rem; }
</style></head><body><header><div class="site">%s</div><h1>%s</h1><div class="byline">%s</div></header>
<article>%s</article></body></html>""".printf (
                Markup.escape_text (article.title), accent, Markup.escape_text (article.site),
                Markup.escape_text (article.title), byline, article.content);
        }
    }
}
