#!/usr/bin/env python3
from __future__ import annotations

import html
import json
import re
import shutil
import textwrap
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
WEBSITE_DIR = SCRIPT_DIR.parent
PROJECT_ROOT = WEBSITE_DIR.parent
PUBLIC_ROOT = WEBSITE_DIR / "public_html"
ASSET_DIR = PUBLIC_ROOT / "assets"
IMAGE_DIR = ASSET_DIR / "images"

GITHUB_REPO = "https://github.com/TaterTotterson/Tater_Tunnel"
ONE_COMMAND_INSTALL = """curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \\
  -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh"""

NAV_ITEMS = [
    ("home", "Home", "index.html"),
    ("setup", "Setup", "setup/index.html"),
    ("routes", "Routes", "routes/index.html"),
    ("security", "Security", "security/index.html"),
    ("troubleshooting", "Troubleshooting", "troubleshooting/index.html"),
    ("docs", "Docs", "wiki/index.html"),
]

DOC_SOURCES = [
    ("readme", "Project README", PROJECT_ROOT / "README.md"),
    ("vps-install", "VPS Install", PROJECT_ROOT / "docs" / "VPS_INSTALL.md"),
    ("trust-boundaries", "Trust Boundaries", PROJECT_ROOT / "docs" / "TRUST_BOUNDARIES.md"),
    ("mvp-spec", "MVP Spec", PROJECT_ROOT / "docs" / "MVP_SPEC.md"),
]


def escape(value: object) -> str:
    return html.escape(str(value), quote=True)


def ensure_dirs() -> None:
    PUBLIC_ROOT.mkdir(parents=True, exist_ok=True)
    IMAGE_DIR.mkdir(parents=True, exist_ok=True)


def copy_root_asset(source: Path, target_name: str) -> None:
    target = IMAGE_DIR / target_name
    if source.exists() and not target.exists():
        shutil.copy2(source, target)


def page_base(depth: int) -> str:
    return "../" * depth


def nav_html(base: str, active: str) -> str:
    links = []
    for key, label, href in NAV_ITEMS:
        class_name = "nav-link is-active" if key == active else "nav-link"
        links.append(f'<a class="{class_name}" href="{base}{href}">{escape(label)}</a>')
    links.append(
        f'<a class="nav-link nav-link-github" href="{GITHUB_REPO}" target="_blank" rel="noreferrer">GitHub</a>'
    )
    return "\n".join(links)


def page_template(title: str, description: str, body: str, *, nav_key: str, depth: int = 0) -> str:
    base = page_base(depth)
    return textwrap.dedent(
        f"""\
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="description" content="{escape(description)}">
          <title>{escape(title)}</title>
          <link rel="stylesheet" href="{base}assets/site.css">
          <script src="{base}assets/site.js" defer></script>
        </head>
        <body data-page="{escape(nav_key)}">
          <header class="site-header">
            <a class="brand" href="{base}index.html" aria-label="Tater Tunnel home">
              <img src="{base}assets/images/tater-logo-primary.png" alt="Tater logo">
              <span>Tater Tunnel</span>
            </a>
            <button class="nav-toggle" type="button" aria-expanded="false" aria-controls="site-nav">Menu</button>
            <nav class="site-nav" id="site-nav">
              {nav_html(base, nav_key)}
            </nav>
          </header>
          <main>
            {body}
          </main>
          <footer class="site-footer">
            <p>Tater Tunnel docs are generated from this repository.</p>
            <p><a href="{GITHUB_REPO}" target="_blank" rel="noreferrer">View the project on GitHub</a></p>
          </footer>
        </body>
        </html>
        """
    )


def chip(label: str) -> str:
    return f'<span class="chip">{escape(label)}</span>'


def action_link(label: str, href: str, *, secondary: bool = False) -> str:
    class_name = "button button-secondary" if secondary else "button"
    return f'<a class="{class_name}" href="{escape(href)}">{escape(label)}</a>'


def command_box(command: str, label: str = "Terminal") -> str:
    return textwrap.dedent(
        f"""\
        <div class="command-box">
          <div class="command-head">
            <span>{escape(label)}</span>
            <button type="button" data-copy-code>Copy</button>
          </div>
          <pre><code>{escape(command.strip())}</code></pre>
        </div>
        """
    )


def simple_card(title: str, text: str, chips: list[str] | None = None) -> str:
    chip_html = f'<div class="chip-row">{"".join(chip(item) for item in chips or [])}</div>' if chips else ""
    return textwrap.dedent(
        f"""\
        <article class="info-card">
          <h3>{escape(title)}</h3>
          <p>{escape(text)}</p>
          {chip_html}
        </article>
        """
    )


def image_panel(src: str, alt: str, caption: str, base: str) -> str:
    return textwrap.dedent(
        f"""\
        <figure class="image-panel">
          <img src="{base}assets/images/{escape(src)}" alt="{escape(alt)}">
          <figcaption>{escape(caption)}</figcaption>
        </figure>
        """
    )


def render_home_page() -> str:
    base = ""
    setup_cards = "\n".join(
        [
            simple_card(
                "Home Agent",
                "Runs beside Tater on the user's home machine. It owns pairing, approved devices, route targets, and the local relay to Tater services.",
                ["macOS", "Windows", "Linux", "Docker path later"],
            ),
            simple_card(
                "VPS Agent",
                "Runs on the user's VPS. It gives the Home Agent a public rendezvous point, hosts WireGuard device peers, and relays approved requests.",
                ["Caddy HTTPS", "WireGuard", "No home ports"],
            ),
            simple_card(
                "Remote Devices",
                "Phones and laptops scan a WireGuard QR, connect to the VPS, and open approved relay URLs like 10.88.0.1:4174/relay/tater/.",
                ["QR setup", "Revokable", "Mobile friendly"],
            ),
        ]
    )
    body = f"""
    <section class="hero">
      <img class="hero-bg" src="assets/images/tater-tunnel-hero.png" alt="" aria-hidden="true">
      <div class="hero-copy">
        <span class="eyebrow">Secure relay + mobile VPN</span>
        <h1>Tater Tunnel</h1>
        <p>Bring your home Tater services with you through your own VPS, without opening inbound ports at home.</p>
        <div class="hero-actions">
          {action_link("Start setup", "setup/index.html")}
          {action_link("View routes", "routes/index.html", secondary=True)}
        </div>
        <div class="hero-facts" aria-label="Tater Tunnel highlights">
          <span>Home Agent -> VPS Agent</span>
          <span>WireGuard QR for phones</span>
          <span>Approved routes only</span>
        </div>
      </div>
    </section>

    <section class="section section-intro" id="overview">
      <div class="section-head">
        <span class="eyebrow">What it does</span>
        <h2>A simple path from phone to home Tater.</h2>
        <p>Tater Tunnel splits the problem into two easy pieces: the home computer makes an outbound relay connection, and mobile devices use a normal WireGuard profile to reach the VPS side.</p>
      </div>
      <div class="grid grid-3">
        {setup_cards}
      </div>
    </section>

    <section class="section flow-section">
      <div class="section-head">
        <span class="eyebrow">Traffic shape</span>
        <h2>The VPS relays. The Home Agent owns trust.</h2>
      </div>
      <div class="flow-strip" aria-label="Tunnel traffic flow">
        <div><strong>Phone</strong><span>WireGuard app</span></div>
        <b>-></b>
        <div><strong>VPS</strong><span>10.88.0.1 relay</span></div>
        <b>-></b>
        <div><strong>Home Agent</strong><span>approved routes</span></div>
        <b>-></b>
        <div><strong>Tater services</strong><span>local targets</span></div>
      </div>
    </section>

    <section class="section split-section">
      <div class="split-copy">
        <span class="eyebrow">One-command VPS setup</span>
        <h2>Blank VPS users get Caddy, WireGuard, firewall rules, and the service.</h2>
        <p>The interactive installer has a friendly terminal menu with update, blank VPS, advanced VPS, and setup-notes paths. Running the same command later lets users update an existing install.</p>
        {command_box(ONE_COMMAND_INSTALL, "Run on the VPS")}
      </div>
      {image_panel("tater-vps-secure.png", "Tater mascot beside a secure VPS", "Full setup keeps the raw agent port private and puts HTTPS in front with Caddy.", base)}
    </section>

    <section class="section split-section split-section-reverse">
      {image_panel("tater-mobile-qr.png", "Tater mascot holding a phone with a QR code", "Remote devices scan a generated WireGuard QR and then use relay URLs through 10.88.0.1.", base)}
      <div class="split-copy">
        <span class="eyebrow">Mobile path</span>
        <h2>Phones use the familiar VPN flow.</h2>
        <p>The Home Agent generates a device profile, the VPS Agent installs the WireGuard peer, and the user scans a QR in the WireGuard app. Revoking a device removes the VPS peer and the Home Agent record.</p>
        <div class="callout">
          <strong>Common route URL</strong>
          <code>http://10.88.0.1:4174/relay/tater/</code>
        </div>
      </div>
    </section>
    """
    return page_template(
        "Tater Tunnel | Secure relay for Tater",
        "Tater Tunnel pairs a Home Agent to a VPS and lets remote devices reach approved Tater services through WireGuard and a home relay.",
        body,
        nav_key="home",
        depth=0,
    )


def render_setup_page() -> str:
    base = "../"
    body = f"""
    <section class="sub-hero">
      <span class="eyebrow">Setup</span>
      <h1>Get the VPS and Home Agent paired.</h1>
      <p>Start with the VPS, then claim it from the Home Agent UI, then add phone or laptop devices.</p>
    </section>

    <section class="section">
      <div class="step-list">
        <article class="step-block">
          <span>Step 1</span>
          <h2>Run the VPS setup command over SSH.</h2>
          <p>Use this for a blank Debian or Ubuntu VPS, or run it again later and choose the update path.</p>
          {command_box(ONE_COMMAND_INSTALL, "Recommended VPS command")}
        </article>
        <article class="step-block">
          <span>Step 2</span>
          <h2>Pick the installer path.</h2>
          <div class="grid grid-3">
            {simple_card("Blank VPS full install", "Installs the VPS Agent, WireGuard, Caddy automatic HTTPS, and UFW rules. Best for a new VPS.", ["80/tcp", "443/tcp", "51888/udp"])}
            {simple_card("Advanced existing VPS", "Installs only the VPS Agent. The user manages HTTPS reverse proxy and firewall rules.", ["Webmin friendly", "Manual proxy"])}
            {simple_card("Update existing install", "Downloads the latest code, preserves pairing/state, keeps the current service host/port, and restarts the service.", ["Safe update", "Keeps state"])}
          </div>
        </article>
        <article class="step-block">
          <span>Step 3</span>
          <h2>Start the Home Agent and claim the VPS.</h2>
          <p>For remote testing or a LAN-accessible machine, bind the Home Agent to all interfaces. In normal local use, 127.0.0.1 is enough.</p>
          {command_box("python3.11 -m tater_tunnel.home_agent --host 0.0.0.0 --port 4173", "Home Agent")}
          <div class="check-grid">
            <div><strong>VPS IP or Domain</strong><code>https://tunnel.example.com</code></div>
            <div><strong>Pairing Code</strong><code>shown by the installer</code></div>
            <div><strong>Security Mode</strong><code>standard</code></div>
          </div>
        </article>
        <article class="step-block">
          <span>Step 4</span>
          <h2>Add a phone or laptop.</h2>
          <p>Use the Home Agent device section to create a profile, scan the QR in the WireGuard app, then test the relay health route from the device.</p>
          {command_box("http://10.88.0.1:4174/api/health\nhttp://10.88.0.1:4174/relay/api/state", "Open from the connected device")}
        </article>
      </div>
    </section>

    <section class="section split-section">
      <div class="split-copy">
        <span class="eyebrow">Service checks</span>
        <h2>Useful VPS commands after install.</h2>
        {command_box("sudo systemctl status tater-tunnel-vps\nsudo journalctl -u tater-tunnel-vps -f\nsudo systemctl restart tater-tunnel-vps\nsudo wg show tater0", "VPS checks")}
      </div>
      {image_panel("tater-vps-secure.png", "Tater mascot beside a secure VPS", "Caddy handles public HTTPS. The raw agent service stays local or VPN-only.", base)}
    </section>
    """
    return page_template(
        "Tater Tunnel | Setup",
        "Install the Tater Tunnel VPS Agent, pair the Home Agent, and add WireGuard devices.",
        body,
        nav_key="setup",
        depth=1,
    )


def render_routes_page() -> str:
    base = "../"
    body = f"""
    <section class="sub-hero">
      <span class="eyebrow">Routes</span>
      <h1>Expose only the local apps you approve.</h1>
      <p>Routes are named paths under the VPS relay. The phone opens the VPS tunnel IP, and the Home Agent proxies the request to a local target.</p>
    </section>

    <section class="section">
      <div class="route-example">
        <div>
          <span class="eyebrow">Default</span>
          <h2>Home Agent and Tunnel UI</h2>
          <p>The built-in tunnel route is available at the base relay path after the phone is connected to WireGuard.</p>
        </div>
        <code>http://10.88.0.1:4174/relay/</code>
      </div>
      <div class="route-example">
        <div>
          <span class="eyebrow">Named route</span>
          <h2>Main Tater app</h2>
          <p>Add a route named <code>tater</code> to the Home Agent UI and point it at the local Tater app port.</p>
        </div>
        <code>http://10.88.0.1:4174/relay/tater/</code>
      </div>
      <div class="route-example">
        <div>
          <span class="eyebrow">LAN target</span>
          <h2>Another local service</h2>
          <p>Targets can also be another LAN machine if the Home Agent machine can reach it, for example an Emby host.</p>
        </div>
        <code>http://10.88.0.1:4174/relay/emby/</code>
      </div>
    </section>

    <section class="section">
      <div class="section-head">
        <span class="eyebrow">Route settings</span>
        <h2>Use the simple UI first, advanced switches only when an app needs them.</h2>
      </div>
      <div class="grid grid-3">
        {simple_card("Target URL", "The local URL the Home Agent can reach, such as http://127.0.0.1:8501 or http://10.4.20.204:8096.", ["Required"])}
        {simple_card("WebSockets", "Enable for apps that keep live UI state over WebSockets, streaming, or long-lived browser sessions.", ["Advanced"])}
        {simple_card("Host header", "Use only when an app expects its own public host or rejects the relay host.", ["Advanced"])}
      </div>
    </section>

    <section class="section split-section split-section-reverse">
      {image_panel("tater-mobile-qr.png", "Tater mascot with mobile QR setup", "Once the phone VPN is on, every route uses the 10.88.0.1 VPS tunnel address.", base)}
      <div class="split-copy">
        <span class="eyebrow">Examples</span>
        <h2>Route names become clean URLs.</h2>
        {command_box("Route name: tater\nLocal target: http://127.0.0.1:8501\nUse: http://10.88.0.1:4174/relay/tater/\n\nRoute name: emby\nLocal target: http://10.4.20.204:8096\nUse: http://10.88.0.1:4174/relay/emby/", "Access route examples")}
      </div>
    </section>
    """
    return page_template(
        "Tater Tunnel | Routes",
        "Add and test approved Tater Tunnel relay routes from the Home Agent UI.",
        body,
        nav_key="routes",
        depth=1,
    )


def render_security_page() -> str:
    body = f"""
    <section class="sub-hero">
      <span class="eyebrow">Security</span>
      <h1>The VPS is a relay, not the trust boss.</h1>
      <p>The Home Agent owns device approval, relay tokens, route targets, and revocation. The VPS should hold only enough state to relay traffic and manage WireGuard peers.</p>
    </section>

    <section class="section">
      <div class="grid grid-2">
        {simple_card("TLS for Home Agent to VPS", "The full setup path puts Caddy in front of the VPS Agent so pairing and relay management happen over HTTPS with automatic certificates.", ["Caddy", "443/tcp"])}
        {simple_card("WireGuard for remote devices", "Phones and laptops use WireGuard to reach the VPS tunnel address. This gives the mobile VPN behavior users expect.", ["51888/udp", "QR profile"])}
        {simple_card("Token-protected management", "After claim, sensitive VPS endpoints require the relay management token from the Home Agent.", ["No public state dump"])}
        {simple_card("Revocation removes access", "Revoking a device removes the WireGuard peer and the Home Agent device record.", ["Lost device flow"])}
      </div>
    </section>

    <section class="section">
      <div class="section-head">
        <span class="eyebrow">Firewall shape</span>
        <h2>Blank VPS install keeps the raw agent port private.</h2>
      </div>
      <div class="port-table">
        <div><strong>80/tcp</strong><span>Caddy HTTP and ACME challenge</span></div>
        <div><strong>443/tcp</strong><span>Caddy HTTPS to 127.0.0.1:4174</span></div>
        <div><strong>51888/udp</strong><span>WireGuard device VPN</span></div>
        <div><strong>4174/tcp</strong><span>Localhost for Caddy, and tater0-only for VPN relay use</span></div>
      </div>
    </section>

    <section class="section">
      <div class="section-head">
        <span class="eyebrow">Hardening checklist</span>
        <h2>Before calling a setup production-ready.</h2>
      </div>
      <ul class="check-list">
        <li>Use a real DNS name and HTTPS URL for Home Agent to VPS pairing.</li>
        <li>Keep public TCP 4174 closed unless doing a short direct test.</li>
        <li>Open UDP 51888 for WireGuard devices.</li>
        <li>Use the Home Agent UI to revoke old or lost devices.</li>
        <li>Keep route targets narrow. Do not expose raw LAN access by default.</li>
        <li>Update the VPS with the same one-command installer when new tunnel fixes land.</li>
      </ul>
    </section>

    <section class="section">
      {command_box("curl -fsS https://tunnel.example.com/api/health\nsudo wg show tater0\nsudo ufw status verbose", "Security checks")}
    </section>
    """
    return page_template(
        "Tater Tunnel | Security",
        "Tater Tunnel security model, trust boundaries, TLS, WireGuard, firewall ports, and hardening checklist.",
        body,
        nav_key="security",
        depth=1,
    )


def render_troubleshooting_page() -> str:
    body = f"""
    <section class="sub-hero">
      <span class="eyebrow">Troubleshooting</span>
      <h1>Follow the path one hop at a time.</h1>
      <p>Most tunnel issues are one of four things: pairing, VPS firewall, WireGuard handshake, or a route target that needs a base URL/WebSocket tweak.</p>
    </section>

    <section class="section">
      <div class="grid grid-2">
        {simple_card("Pairing says disabled", "That is normal after the VPS is claimed. Pairing mode should turn off so random new Home Agents cannot claim the VPS.", ["Expected after claim"])}
        {simple_card("Phone internet IP is not the VPS", "The current profile is for tunnel access to Tater routes, not always-full internet egress. Test 10.88.0.1 routes instead.", ["Split tunnel"])}
        {simple_card("No WireGuard handshake", "Confirm UDP 51888 is open on the VPS firewall and cloud firewall, then check sudo wg show tater0.", ["Firewall first"])}
        {simple_card("Blank route page", "Test the local target from the Home Agent machine. Then enable WebSockets or set the app's own base/public URL if it hard-codes assets.", ["Route health"])}
      </div>
    </section>

    <section class="section">
      <div class="section-head">
        <span class="eyebrow">Quick checks</span>
        <h2>Run the smallest possible test for each hop.</h2>
      </div>
      {command_box("curl -fsS https://tunnel.example.com/api/health\nsudo wg show tater0\ncurl -fsS http://10.88.0.1:4174/api/health\ncurl -fsS http://10.88.0.1:4174/relay/api/state", "Health checks")}
      {command_box("sudo systemctl status tater-tunnel-vps\nsudo journalctl -u tater-tunnel-vps -f\nsudo systemctl restart tater-tunnel-vps", "VPS service")}
    </section>

    <section class="section">
      <div class="section-head">
        <span class="eyebrow">Route debug pattern</span>
        <h2>Use the Home Agent route test before trying the phone.</h2>
      </div>
      <ol class="number-list">
        <li>Confirm the Home Agent UI shows the VPS as claimed and connected.</li>
        <li>Open the local target from the Home Agent machine.</li>
        <li>Use the route Test button in Access Routes.</li>
        <li>Connect the phone to WireGuard and open the displayed Use URL.</li>
        <li>If the page partially loads, enable WebSockets or configure that app's public/base URL.</li>
      </ol>
    </section>
    """
    return page_template(
        "Tater Tunnel | Troubleshooting",
        "Tater Tunnel troubleshooting checks for pairing, WireGuard, firewall, relay routes, and services.",
        body,
        nav_key="troubleshooting",
        depth=1,
    )


def render_inline_markdown(text: str) -> str:
    code_tokens: list[str] = []

    def save_code(match: re.Match[str]) -> str:
        code_tokens.append(f"<code>{escape(match.group(1))}</code>")
        return f"@@CODE{len(code_tokens) - 1}@@"

    tokenized = re.sub(r"`([^`]+)`", save_code, text)
    rendered = escape(tokenized)

    def link_replace(match: re.Match[str]) -> str:
        label = match.group(1)
        href = match.group(2)
        return f'<a href="{escape(href)}">{escape(label)}</a>'

    rendered = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link_replace, rendered)
    for index, code_html in enumerate(code_tokens):
        rendered = rendered.replace(f"@@CODE{index}@@", code_html)
    return rendered


def render_markdown(markdown: str) -> str:
    lines = markdown.splitlines()
    html_parts: list[str] = []
    paragraph: list[str] = []
    list_items: list[str] = []
    ordered_items: list[str] = []
    code_lines: list[str] = []
    in_code = False

    def flush_paragraph() -> None:
        if paragraph:
            html_parts.append(f"<p>{render_inline_markdown(' '.join(paragraph))}</p>")
            paragraph.clear()

    def flush_list() -> None:
        if list_items:
            html_parts.append("<ul>" + "".join(f"<li>{render_inline_markdown(item)}</li>" for item in list_items) + "</ul>")
            list_items.clear()
        if ordered_items:
            html_parts.append("<ol>" + "".join(f"<li>{render_inline_markdown(item)}</li>" for item in ordered_items) + "</ol>")
            ordered_items.clear()

    for line in lines:
        stripped = line.rstrip()
        if stripped.startswith("```"):
            if in_code:
                html_parts.append(f"<pre><code>{escape(chr(10).join(code_lines))}</code></pre>")
                code_lines.clear()
                in_code = False
            else:
                flush_paragraph()
                flush_list()
                in_code = True
            continue
        if in_code:
            code_lines.append(stripped)
            continue
        if not stripped:
            flush_paragraph()
            flush_list()
            continue
        heading = re.match(r"^(#{1,4})\s+(.+)$", stripped)
        if heading:
            flush_paragraph()
            flush_list()
            level = len(heading.group(1))
            html_parts.append(f"<h{level}>{render_inline_markdown(heading.group(2))}</h{level}>")
            continue
        bullet = re.match(r"^-\s+(.+)$", stripped)
        if bullet:
            flush_paragraph()
            ordered_items.clear()
            list_items.append(bullet.group(1))
            continue
        numbered = re.match(r"^\d+\.\s+(.+)$", stripped)
        if numbered:
            flush_paragraph()
            list_items.clear()
            ordered_items.append(numbered.group(1))
            continue
        paragraph.append(stripped)

    if in_code:
        html_parts.append(f"<pre><code>{escape(chr(10).join(code_lines))}</code></pre>")
    flush_paragraph()
    flush_list()
    return "\n".join(html_parts)


def doc_summary(markdown: str) -> str:
    for line in markdown.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and not stripped.startswith("```"):
            return stripped
    return "Generated from the current Tater Tunnel source tree."


def render_docs_index(docs: list[dict[str, str]]) -> str:
    cards = "\n".join(
        textwrap.dedent(
            f"""\
            <article class="info-card">
              <h3><a href="{escape(doc['slug'])}.html">{escape(doc['title'])}</a></h3>
              <p>{escape(doc['summary'])}</p>
            </article>
            """
        )
        for doc in docs
    )
    body = f"""
    <section class="sub-hero">
      <span class="eyebrow">Generated docs</span>
      <h1>Source-backed Tater Tunnel docs.</h1>
      <p>This section is rebuilt from the README and docs folder so the website follows the app code.</p>
    </section>
    <section class="section">
      <div class="grid grid-2">
        {cards}
      </div>
    </section>
    """
    return page_template(
        "Tater Tunnel | Docs",
        "Generated Tater Tunnel documentation index.",
        body,
        nav_key="docs",
        depth=1,
    )


def render_doc_page(doc: dict[str, str]) -> str:
    body = f"""
    <section class="sub-hero doc-sub-hero">
      <span class="eyebrow">Generated docs</span>
      <h1>{escape(doc['title'])}</h1>
      <p>{escape(doc['summary'])}</p>
    </section>
    <article class="section doc-content">
      {doc['html']}
    </article>
    """
    return page_template(
        f"Tater Tunnel | {doc['title']}",
        doc["summary"],
        body,
        nav_key="docs",
        depth=1,
    )


def write_file(relative_path: str, contents: str) -> None:
    target = PUBLIC_ROOT / relative_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(contents, encoding="utf-8")


def build_docs() -> list[dict[str, str]]:
    docs: list[dict[str, str]] = []
    for slug, title, path in DOC_SOURCES:
        if not path.exists():
            continue
        markdown = path.read_text(encoding="utf-8")
        docs.append(
            {
                "slug": slug,
                "title": title,
                "source": str(path.relative_to(PROJECT_ROOT)),
                "summary": doc_summary(markdown),
                "html": render_markdown(markdown),
            }
        )
    return docs


def main() -> None:
    ensure_dirs()
    copy_root_asset(PROJECT_ROOT / "assets" / "tater-logo-primary.png", "tater-logo-primary.png")

    docs = build_docs()
    write_file("index.html", render_home_page())
    write_file("setup/index.html", render_setup_page())
    write_file("routes/index.html", render_routes_page())
    write_file("security/index.html", render_security_page())
    write_file("troubleshooting/index.html", render_troubleshooting_page())
    write_file("wiki/index.html", render_docs_index(docs))
    for doc in docs:
        write_file(f"wiki/{doc['slug']}.html", render_doc_page(doc))

    manifest = {
        "generator": "website/scripts/build_wiki.py",
        "sourceRoot": ".",
        "pages": [
            "index.html",
            "setup/index.html",
            "routes/index.html",
            "security/index.html",
            "troubleshooting/index.html",
            "wiki/index.html",
            *[f"wiki/{doc['slug']}.html" for doc in docs],
        ],
        "docs": [{"title": doc["title"], "source": doc["source"], "output": f"wiki/{doc['slug']}.html"} for doc in docs],
    }
    write_file("site-manifest.json", json.dumps(manifest, indent=2) + "\n")
    print(f"Built Tater Tunnel website at {PUBLIC_ROOT}")


if __name__ == "__main__":
    main()
