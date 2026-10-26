# singularity-browser

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

Browser for the [Singularity Desktop Environment](https://github.com/singularityos-lab): browse the web with tiles, tabs and bubbles.

## Requirements

- [Meson](https://mesonbuild.com/) ≥ 1.0
- [Vala](https://vala.dev/) compiler
- GTK4, libgee-0.8, json-glib-1.0, libxml-2.0, sqlite3, libsoup-3.0, webkitgtk-6.0, libsecret-1, gnutls, polkit-gobject-1, libfido2, poppler-glib
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## Automation

With the Fotone engine installed, `singularity-webdriver` is a W3C WebDriver server that starts
Browser in its own automation session, so Selenium, WebdriverIO and other WebDriver clients can
drive it:

```sh
singularity-webdriver --port=4444
```

`singularity-browser-mcp` serves the same session to agents as an MCP server on standard input
and output. It starts its own driver, or uses an existing one with `--webdriver http://host:4444`.
Over SSH the agent runs it on the remote machine:

```sh
ssh host singularity-browser-mcp
```

`--undetectable`, accepted by both, keeps `navigator.webdriver` false for pages that refuse
automated sessions; the banner above the page still tells the person at the machine that Browser
is being driven. Browser itself takes `--automation-hidden`.

## License

GPL-3.0-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-browser. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
