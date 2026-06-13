# Tater Tunnel Website

This folder contains the static website and generated docs for Tater Tunnel.

## Build

```bash
python3 website/scripts/build_wiki.py
```

The output is written to:

```text
website/public_html/
```

## Update

Run the update wrapper after changing the app docs or website script:

```bash
python3 website/scripts/update_site.py
```

Use `--check` in CI or before pushing when you want the command to fail if the
generated site output differs from the committed tree.

```bash
python3 website/scripts/update_site.py --check
```

## Preview

The site is plain static HTML. You can open `website/public_html/index.html`
directly, or serve the folder with any static server.

```bash
python3 -m http.server 8080 -d website/public_html
```

## Generated Images

Mascot images were generated with the built-in image tool and copied into
`website/public_html/assets/images/` so the site does not depend on Codex cache
paths.
