#!/usr/bin/env bash
set -euo pipefail

# Syncs the redesigned templates + generator into your local promptpacks-site project.
# Run this from the project root: bash sync_promptpacks_redesign.sh

mkdir -p scripts
cat > scripts/generate.py << 'PVEOF_SYNC'
#!/usr/bin/env python3
"""
Automated pipeline: content/packs.json -> PDFs + landing pages + index page.

Run with no arguments to (re)generate the whole site into ../site/.

ShrinkEarn integration:
  - If SHRINKEARN_API_KEY is set in the environment, each pack's PDF will be
    uploaded/linked and wrapped in a ShrinkEarn short link automatically.
  - If not set, the download button falls back to a direct link to the PDF
    hosted on the same site (still fully functional, just not monetized yet).
  - Successful shortlinks are cached in content/shrinkearn_links.json so we
    never re-create a link for the same pack.
"""
import json
import os
import random
import sys
from datetime import datetime
from pathlib import Path

import jinja2
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
CONTENT_DIR = ROOT / "content"
SITE_DIR = ROOT / "site"
TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"
LINKS_CACHE = CONTENT_DIR / "shrinkearn_links.json"

ACCENT = "#b8892b"
ACCENT_DARK = "#7a5c17"
INK = "#161d27"
SITE_URL = os.environ.get("SITE_URL", "https://your-site.vercel.app").rstrip("/")
PROMPTS_PER_PDF_PAGE = 14
PREVIEW_COUNT = 4
RELATED_COUNT = 3

env = jinja2.Environment(loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)))


def load_packs():
    with open(CONTENT_DIR / "packs.json") as f:
        return json.load(f)


def load_links_cache():
    if LINKS_CACHE.exists():
        with open(LINKS_CACHE) as f:
            return json.load(f)
    return {}


def save_links_cache(cache):
    with open(LINKS_CACHE, "w") as f:
        json.dump(cache, f, indent=2)


def get_monetized_link(slug: str, pdf_public_url: str, cache: dict) -> str:
    """Return a ShrinkEarn short link for this pack's PDF, creating one via
    the API if a key is configured and none is cached yet. Falls back to the
    direct PDF URL if ShrinkEarn isn't wired up yet."""
    if slug in cache:
        return cache[slug]

    api_key = os.environ.get("SHRINKEARN_API_KEY")
    if not api_key:
        print(f"  [!] No SHRINKEARN_API_KEY set — using direct PDF link for '{slug}' (not monetized yet)")
        return pdf_public_url

    try:
        import requests
        resp = requests.get(
            "https://shrinkearn.com/api",
            params={"api": api_key, "url": pdf_public_url, "format": "text"},
            timeout=15,
        )
        resp.raise_for_status()
        short_link = resp.text.strip()
        if short_link.startswith("http"):
            cache[slug] = short_link
            save_links_cache(cache)
            print(f"  [+] Created ShrinkEarn link for '{slug}': {short_link}")
            return short_link
        else:
            print(f"  [!] ShrinkEarn API returned unexpected response for '{slug}': {short_link!r} — using direct link")
            return pdf_public_url
    except Exception as e:
        print(f"  [!] ShrinkEarn API call failed for '{slug}': {e} — using direct link")
        return pdf_public_url


def chunk_prompts(prompts):
    """Return list of chunks, each a list of (number, prompt) tuples."""
    chunks = []
    for i in range(0, len(prompts), PROMPTS_PER_PDF_PAGE):
        chunk = prompts[i:i + PROMPTS_PER_PDF_PAGE]
        numbered = [(i + j + 1, p) for j, p in enumerate(chunk)]
        chunks.append(numbered)
    return chunks


def render_pdf(pack, site_name, out_path, browser):
    template = env.get_template("pdf_template.html")
    html = template.render(
        title=pack["title"],
        description=pack["description"],
        tool=pack["tool"],
        site_name=site_name,
        site_url=SITE_URL,
        accent=ACCENT,
        accent_dark=ACCENT_DARK,
        prompt_chunks=chunk_prompts(pack["prompts"]),
    )
    page = browser.new_page()
    page.set_content(html, wait_until="load")
    page.pdf(path=str(out_path), print_background=True, format="A4")
    page.close()


def pick_hero_samples(packs):
    """Pick up to 2 real prompts (from packs with different tools, for variety)
    to show as sample cards in the homepage hero."""
    samples = []
    tools_seen = set()
    for p in packs:
        if p["tool"] in tools_seen:
            continue
        samples.append({"category": p["category"], "tool": p["tool"], "prompt": p["prompts"][0]})
        tools_seen.add(p["tool"])
        if len(samples) == 2:
            break
    return samples


def pick_related(pack, all_packs):
    others = [p for p in all_packs if p["slug"] != pack["slug"]]
    same_cat = [p for p in others if p["category"] == pack["category"]]
    rest = [p for p in others if p["category"] != pack["category"]]
    random.shuffle(same_cat)
    random.shuffle(rest)
    picks = (same_cat + rest)[:RELATED_COUNT]
    return picks


def render_landing_page(pack, site_name, download_url, all_packs, out_path):
    template = env.get_template("landing_template.html")
    schema = {
        "@context": "https://schema.org",
        "@type": "CreativeWork",
        "name": pack["title"],
        "description": pack["description"],
        "url": f"{SITE_URL}/packs/{pack['slug']}/",
        "isAccessibleForFree": True,
        "keywords": f"{pack['tool']}, {pack['category']}, AI prompts",
    }
    html = template.render(
        title=pack["title"],
        description=pack["description"],
        tool=pack["tool"],
        category=pack["category"],
        slug=pack["slug"],
        site_name=site_name,
        site_url=SITE_URL,
        accent=ACCENT,
        accent_dark=ACCENT_DARK,
        prompt_count=len(pack["prompts"]),
        preview_prompts=pack["prompts"][:PREVIEW_COUNT],
        remaining_count=max(0, len(pack["prompts"]) - PREVIEW_COUNT),
        download_url=download_url,
        related_packs=pick_related(pack, all_packs),
        schema_json=json.dumps(schema),
        year=datetime.now().year,
    )
    out_path.write_text(html)


def render_index(data, out_path):
    template = env.get_template("index_template.html")
    packs = data["packs"]
    for p in packs:
        p["prompt_count"] = len(p["prompts"])
    categories = sorted(set(p["category"] for p in packs))
    schema = {
        "@context": "https://schema.org",
        "@type": "CollectionPage",
        "name": data["site_name"],
        "description": data["tagline"],
        "url": f"{SITE_URL}/",
        "hasPart": [
            {
                "@type": "CreativeWork",
                "name": p["title"],
                "url": f"{SITE_URL}/packs/{p['slug']}/",
            }
            for p in packs
        ],
    }
    html = template.render(
        site_name=data["site_name"],
        tagline=data["tagline"],
        packs=packs,
        categories=categories,
        pack_count=len(packs),
        hero_samples=pick_hero_samples(packs),
        site_url=SITE_URL,
        schema_json=json.dumps(schema),
        year=datetime.now().year,
    )
    out_path.write_text(html)


def render_favicon(out_path):
    svg = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
<rect width="24" height="24" rx="5" fill="#161d27"/>
<path d="M6 7.5h12M6 12h12M6 16.5h7" stroke="#b8892b" stroke-width="2" stroke-linecap="round"/>
</svg>"""
    out_path.write_text(svg)


def render_og_image(site_name, tagline, out_path, browser):
    html = f"""<!DOCTYPE html><html><head>
    <link href="https://fonts.googleapis.com/css2?family=Fraunces:wght@600&family=IBM+Plex+Sans:wght@400&display=swap" rel="stylesheet">
    <style>
    body {{ margin:0; width:1200px; height:630px; display:flex; flex-direction:column; justify-content:center; align-items:flex-start; padding:0 90px;
      background: #161d27; font-family: 'IBM Plex Sans', Arial, sans-serif; color:#f0eee7; box-sizing:border-box; }}
    .bar {{ width:64px; height:5px; background:#b8892b; margin-bottom:26px; }}
    h1 {{ font-family:'Fraunces', serif; font-size:66px; margin:0 0 20px; font-weight:600; color:#fff; }}
    p {{ font-size:26px; opacity:0.85; max-width:820px; margin:0; line-height:1.5; }}
    </style></head><body>
    <div class="bar"></div>
    <h1>{site_name}</h1>
    <p>{tagline}</p>
    </body></html>"""
    page = browser.new_page(viewport={"width": 1200, "height": 630})
    page.set_content(html, wait_until="load")
    page.screenshot(path=str(out_path))
    page.close()


def render_robots_and_sitemap(data, out_dir):
    (out_dir / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}/sitemap.xml\n")

    urls = [f"{SITE_URL}/"] + [f"{SITE_URL}/packs/{p['slug']}/" for p in data["packs"]]
    body = "\n".join(f"  <url><loc>{u}</loc></url>" for u in urls)
    sitemap = f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{body}\n</urlset>\n'
    (out_dir / "sitemap.xml").write_text(sitemap)


def main():
    data = load_packs()
    site_name = data["site_name"]
    links_cache = load_links_cache()

    SITE_DIR.mkdir(exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch()

        for pack in data["packs"]:
            slug = pack["slug"]
            pack_dir = SITE_DIR / "packs" / slug
            pack_dir.mkdir(parents=True, exist_ok=True)

            pdf_path = pack_dir / "pack.pdf"
            print(f"-> Rendering PDF for '{slug}' ({len(pack['prompts'])} prompts)")
            render_pdf(pack, site_name, pdf_path, browser)

            pdf_public_url = f"{SITE_URL}/packs/{slug}/pack.pdf"
            download_url = get_monetized_link(slug, pdf_public_url, links_cache)

            landing_path = pack_dir / "index.html"
            render_landing_page(pack, site_name, download_url, data["packs"], landing_path)
            print(f"  [+] Landing page: /packs/{slug}/")

        render_favicon(SITE_DIR / "favicon.svg")
        render_og_image(site_name, data["tagline"], SITE_DIR / "og-image.png", browser)
        browser.close()

    render_index(data, SITE_DIR / "index.html")
    render_robots_and_sitemap(data, SITE_DIR)
    print(f"\nDone. Site generated at: {SITE_DIR}")
    print(f"Packs: {len(data['packs'])}")


if __name__ == "__main__":
    sys.exit(main())
PVEOF_SYNC

mkdir -p scripts/templates
cat > scripts/templates/index_template.html << 'PVEOF_SYNC'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{ site_name }} — Free AI Prompt Packs for ChatGPT, Midjourney & Notion AI</title>
<meta name="description" content="{{ tagline }} {{ pack_count }} free, ready-to-use prompt packs — no email, no signup, just download and go.">
<link rel="canonical" href="{{ site_url }}/">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<meta property="og:type" content="website">
<meta property="og:title" content="{{ site_name }} — Free AI Prompt Packs">
<meta property="og:description" content="{{ tagline }}">
<meta property="og:url" content="{{ site_url }}/">
<meta property="og:image" content="{{ site_url }}/og-image.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600;9..144,700&family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<script type="application/ld+json">
{{ schema_json }}
</script>
<style>
  :root {
    --ink: #161d27;
    --ink-soft: #414a59;
    --muted: #7c7566;
    --paper: #f0eee7;
    --card: #fbfaf6;
    --rule: #d9d3c2;
    --gold: #b8892b;
    --gold-deep: #7a5c17;
    --serif: 'Fraunces', serif;
    --sans: 'IBM Plex Sans', sans-serif;
    --mono: 'IBM Plex Mono', monospace;
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body { font-family: var(--sans); margin: 0; background: var(--paper); color: var(--ink-soft); }
  a { color: inherit; }
  h1, h2 { font-family: var(--serif); color: var(--ink); }
  :focus-visible { outline: 2px solid var(--gold); outline-offset: 3px; }

  .band-ink { background: var(--ink); color: var(--paper); }

  .topnav { max-width: 1080px; margin: 0 auto; padding: 22px 24px; display: flex; justify-content: space-between; align-items: center; }
  .topnav .logo { font-family: var(--serif); font-weight: 600; font-size: 19px; text-decoration: none; color: #fff; display: flex; align-items: center; gap: 9px; }
  .topnav nav a { text-decoration: none; color: #cfc9b8; font-size: 14px; margin-left: 20px; border-bottom: 1px solid transparent; padding-bottom: 2px; }
  .topnav nav a:hover { color: #fff; border-color: var(--gold); }

  .hero { max-width: 1080px; margin: 0 auto; padding: 10px 24px 64px; display: grid; grid-template-columns: 1.2fr 1fr; gap: 40px; align-items: center; }
  .hero-copy h1 { font-size: clamp(30px, 4.4vw, 46px); line-height: 1.12; margin: 0 0 18px; font-weight: 600; letter-spacing: -0.01em; }
  .hero-copy p.tagline { color: #d7d2c3; font-size: 16px; line-height: 1.6; max-width: 46ch; margin: 0 0 22px; }
  .hero-copy p.meta { font-family: var(--mono); font-size: 13px; color: var(--gold); margin: 0; }

  .hero-cards { position: relative; height: 190px; }
  .sample-card { position: absolute; width: 280px; background: var(--card); border: 1px solid var(--rule); border-radius: 3px; padding: 16px 18px; box-shadow: 0 14px 30px rgba(0,0,0,0.28); }
  .sample-card::before { content: ""; position: absolute; top: 0; left: 18px; width: 30px; height: 3px; background: var(--gold); }
  .sample-card .sc-meta { font-size: 11px; color: var(--muted); margin: 0 0 8px; }
  .sample-card .sc-meta strong { color: var(--ink); font-weight: 600; }
  .sample-card p { font-family: var(--mono); font-size: 12.5px; line-height: 1.55; color: var(--ink-soft); margin: 0; }
  .sample-card.card-a { top: 0; left: 0; transform: rotate(-3deg); z-index: 2; }
  .sample-card.card-b { top: 46px; left: 88px; transform: rotate(3deg); z-index: 1; }

  .filters-wrap { background: var(--paper); border-bottom: 1px solid var(--rule); position: sticky; top: 0; z-index: 5; }
  .filters { max-width: 1080px; margin: 0 auto; padding: 0 24px; display: flex; gap: 4px; overflow-x: auto; scrollbar-width: thin; }
  .filter-btn { flex: 0 0 auto; background: none; border: none; border-bottom: 2px solid transparent; color: var(--muted); font-family: var(--sans); font-size: 14px; font-weight: 500; padding: 14px 12px 12px; cursor: pointer; white-space: nowrap; }
  .filter-btn:hover { color: var(--ink); }
  .filter-btn.active { color: var(--ink); border-color: var(--gold); font-weight: 600; }

  .grid { max-width: 1080px; margin: 0 auto; padding: 36px 24px 20px; display: grid; grid-template-columns: repeat(auto-fit, minmax(270px, 1fr)); gap: 18px; }
  .pack-card { position: relative; background: var(--card); border: 1px solid var(--rule); border-radius: 3px; padding: 22px 22px 20px; text-decoration: none; color: inherit; display: block; transition: transform 0.15s ease, box-shadow 0.15s ease; }
  .pack-card::before { content: ""; position: absolute; top: 0; left: 22px; width: 26px; height: 3px; background: var(--gold); }
  .pack-card:hover { transform: translateY(-3px); box-shadow: 0 10px 22px rgba(22,29,39,0.12); }
  .pack-card .meta-row { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 10px; font-size: 12px; color: var(--muted); }
  .pack-card .meta-row .cat { color: var(--gold-deep); font-weight: 600; }
  .pack-card .meta-row .tool { font-style: italic; }
  .pack-card h2 { font-size: 18px; margin: 0 0 8px; line-height: 1.3; font-weight: 600; }
  .pack-card p { font-size: 13.5px; color: var(--ink-soft); line-height: 1.55; margin: 0; }
  .pack-card .count { margin-top: 16px; font-family: var(--mono); font-size: 11.5px; color: var(--gold-deep); }

  .section { max-width: 700px; margin: 76px auto; padding: 0 24px; }
  .section h2 { font-size: 24px; margin: 0 0 28px; font-weight: 600; }
  .faq-item { border-top: 1px solid var(--rule); padding: 20px 0; }
  .faq-item:last-child { border-bottom: 1px solid var(--rule); }
  .faq-item h3 { font-family: var(--sans); font-size: 15px; font-weight: 600; color: var(--ink); margin: 0 0 8px; }
  .faq-item p { font-size: 14px; color: var(--ink-soft); margin: 0; line-height: 1.6; }

  footer { padding: 30px 24px 40px; text-align: left; }
  footer .foot-inner { max-width: 1080px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; font-size: 12.5px; color: #a39d8c; }
  footer a { text-decoration: none; margin-left: 16px; }
  footer a:hover { color: var(--gold); }

  @media (max-width: 860px) {
    .hero { grid-template-columns: 1fr; }
    .hero-cards { display: none; }
  }
  @media (max-width: 640px) {
    .topnav { padding: 18px 20px; }
    .topnav nav a { margin-left: 14px; font-size: 13px; }
    .hero { padding: 4px 20px 44px; }
    .grid { padding: 28px 20px 10px; gap: 14px; }
    .section { margin: 56px auto; padding: 0 20px; }
    footer .foot-inner { flex-direction: column; align-items: flex-start; }
    footer a:first-child { margin-left: 0; }
  }
  @media (prefers-reduced-motion: reduce) {
    * { transition: none !important; scroll-behavior: auto !important; }
  }
</style>
</head>
<body>
  <div class="band-ink">
    <div class="topnav">
      <a class="logo" href="/">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none"><rect x="1" y="1" width="22" height="22" rx="2" stroke="#b8892b" stroke-width="1.6"/><path d="M7 8h10M7 12h10M7 16h6" stroke="#b8892b" stroke-width="1.6" stroke-linecap="round"/></svg>
        {{ site_name }}
      </a>
      <nav>
        <a href="#packs">All packs</a>
        <a href="#faq">FAQ</a>
      </nav>
    </div>
    <div class="hero">
      <div class="hero-copy">
        <h1>A shelf of free prompt packs, ready to copy and use</h1>
        <p class="tagline">{{ tagline }} No email, no account — open a pack and start pasting.</p>
        <p class="meta">{{ pack_count }} packs currently on the shelf</p>
      </div>
      <div class="hero-cards">
        {% for s in hero_samples %}
        <div class="sample-card card-{{ 'a' if loop.index == 1 else 'b' }}">
          <p class="sc-meta"><strong>{{ s.tool }}</strong> · {{ s.category }}</p>
          <p>{{ s.prompt[:110] }}{% if s.prompt|length > 110 %}…{% endif %}</p>
        </div>
        {% endfor %}
      </div>
    </div>
  </div>

  <div class="filters-wrap">
    <div class="filters" id="filters">
      <button class="filter-btn active" data-filter="all">All</button>
      {% for cat in categories %}
      <button class="filter-btn" data-filter="{{ cat }}">{{ cat }}</button>
      {% endfor %}
    </div>
  </div>

  <div class="grid" id="packs">
    {% for pack in packs %}
    <a class="pack-card" data-category="{{ pack.category }}" href="/packs/{{ pack.slug }}/">
      <div class="meta-row">
        <span class="cat">{{ pack.category }}</span>
        <span class="tool">{{ pack.tool }}</span>
      </div>
      <h2>{{ pack.title }}</h2>
      <p>{{ pack.description[:110] }}{% if pack.description|length > 110 %}…{% endif %}</p>
      <div class="count">{{ pack.prompt_count }} prompts inside</div>
    </a>
    {% endfor %}
  </div>

  <div class="section" id="faq">
    <h2>Frequently asked questions</h2>
    <div class="faq-item">
      <h3>Are these prompt packs really free?</h3>
      <p>Yes — every pack on {{ site_name }} is free to download, no email address or account required. You'll pass through one short ad page on the way to your download, which is how we keep the site running.</p>
    </div>
    <div class="faq-item">
      <h3>Do I need a paid ChatGPT or Midjourney subscription to use these?</h3>
      <p>No. Most prompts work fine on free tiers — just copy the prompt, paste it into the tool, and replace anything in [brackets] with your own details.</p>
    </div>
    <div class="faq-item">
      <h3>Can I use these prompts for client or commercial work?</h3>
      <p>Yes, the prompts themselves are free to use however you like — for yourself, your business, or your clients.</p>
    </div>
    <div class="faq-item">
      <h3>How often do you add new packs?</h3>
      <p>New prompt packs are added regularly based on what's actually useful and trending — check back or bookmark this page.</p>
    </div>
  </div>

  <footer class="band-ink">
    <div class="foot-inner">
      <span>&copy; {{ year }} {{ site_name }}</span>
      <span>
        <a href="#packs">All packs</a>
        <a href="#faq">FAQ</a>
      </span>
    </div>
  </footer>

  <script>
    (function() {
      var buttons = document.querySelectorAll('.filter-btn');
      var cards = document.querySelectorAll('.pack-card');
      buttons.forEach(function(btn) {
        btn.addEventListener('click', function() {
          buttons.forEach(function(b) { b.classList.remove('active'); });
          btn.classList.add('active');
          var filter = btn.getAttribute('data-filter');
          cards.forEach(function(card) {
            if (filter === 'all' || card.getAttribute('data-category') === filter) {
              card.style.display = '';
            } else {
              card.style.display = 'none';
            }
          });
        });
      });
    })();
  </script>
</body>
</html>
PVEOF_SYNC

mkdir -p scripts/templates
cat > scripts/templates/landing_template.html << 'PVEOF_SYNC'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{ title }} | {{ site_name }}</title>
<meta name="description" content="{{ description }}">
<link rel="canonical" href="{{ site_url }}/packs/{{ slug }}/">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<meta property="og:type" content="article">
<meta property="og:title" content="{{ title }}">
<meta property="og:description" content="{{ description }}">
<meta property="og:url" content="{{ site_url }}/packs/{{ slug }}/">
<meta property="og:image" content="{{ site_url }}/og-image.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600;9..144,700&family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<script type="application/ld+json">
{{ schema_json }}
</script>
<style>
  :root {
    --ink: #161d27;
    --ink-soft: #414a59;
    --muted: #7c7566;
    --paper: #f0eee7;
    --card: #fbfaf6;
    --rule: #d9d3c2;
    --accent: {{ accent }};
    --accent-dark: {{ accent_dark }};
    --serif: 'Fraunces', serif;
    --sans: 'IBM Plex Sans', sans-serif;
    --mono: 'IBM Plex Mono', monospace;
  }
  * { box-sizing: border-box; }
  body { font-family: var(--sans); margin: 0; background: var(--paper); color: var(--ink-soft); }
  a { color: inherit; }
  h1, h2 { font-family: var(--serif); color: var(--ink); }
  :focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }

  .band-ink { background: var(--ink); color: var(--paper); }
  .topnav { max-width: 680px; margin: 0 auto; padding: 20px 24px; display: flex; justify-content: space-between; align-items: center; font-size: 13px; }
  .topnav a.logo { text-decoration: none; color: #fff; font-family: var(--serif); font-weight: 600; font-size: 17px; }
  .crumb { color: #a39d8c; }
  .crumb a { text-decoration: none; color: #a39d8c; }
  .crumb a:hover { color: var(--accent); }

  .hero { max-width: 640px; margin: 0 auto; padding: 48px 24px 8px; text-align: center; }
  .hero .strap { font-family: var(--serif); font-style: italic; color: var(--accent-dark); font-size: 15px; margin: 0 0 12px; }
  .hero h1 { font-size: clamp(26px, 4.6vw, 36px); line-height: 1.22; margin: 0 0 16px; font-weight: 600; }
  .hero p.desc { max-width: 52ch; margin: 0 auto; line-height: 1.6; font-size: 15px; }

  .wrap { max-width: 640px; margin: 0 auto; padding: 30px 24px 0; }
  .card { background: var(--card); border: 1px solid var(--rule); border-radius: 4px; padding: 30px; text-align: center; }
  .card p.count { font-family: var(--mono); color: var(--muted); margin: 0 0 20px; font-size: 13px; }
  .download-btn { display: inline-block; background: var(--accent); color: var(--ink); font-weight: 600; padding: 15px 32px; border-radius: 3px; text-decoration: none; font-size: 15.5px; transition: transform 0.15s ease, background 0.15s ease; }
  .download-btn:hover { background: var(--accent-dark); transform: translateY(-2px); }
  .note { font-size: 12px; color: var(--muted); margin: 16px 0 0; }

  .preview { margin-top: 52px; }
  .preview h2 { font-size: 19px; margin: 0 0 6px; font-weight: 600; }
  .preview .sub { font-size: 13px; color: var(--muted); margin: 0 0 18px; }
  .prompt-row { display: flex; gap: 14px; align-items: flex-start; padding: 14px 0; border-top: 1px solid var(--rule); }
  .prompt-row:last-of-type { border-bottom: 1px solid var(--rule); }
  .prompt-num { font-family: var(--mono); font-size: 12px; color: var(--accent-dark); flex: 0 0 22px; padding-top: 2px; }
  .prompt-text { font-family: var(--mono); font-size: 13.5px; line-height: 1.6; color: var(--ink-soft); flex: 1 1 auto; word-break: break-word; }
  .copy-btn { flex: 0 0 auto; background: none; border: 1px solid var(--rule); color: var(--muted); font-family: var(--sans); font-size: 11.5px; padding: 5px 10px; border-radius: 3px; cursor: pointer; }
  .copy-btn:hover { border-color: var(--accent); color: var(--ink); }
  .more { text-align: center; color: var(--muted); font-size: 13px; padding: 18px 0 0; }

  .mini-faq { margin-top: 52px; }
  .mini-faq h2 { font-size: 18px; margin: 0 0 16px; font-weight: 600; }
  .mini-faq details { border-top: 1px solid var(--rule); padding: 16px 0; }
  .mini-faq details:last-child { border-bottom: 1px solid var(--rule); }
  .mini-faq summary { font-family: var(--sans); font-size: 14px; font-weight: 600; color: var(--ink); cursor: pointer; }
  .mini-faq p { font-size: 13.5px; color: var(--ink-soft); margin: 10px 0 0; line-height: 1.6; }

  .related { margin-top: 52px; }
  .related h2 { font-size: 18px; margin: 0 0 14px; font-weight: 600; }
  .related-list a { display: flex; justify-content: space-between; gap: 16px; text-decoration: none; color: inherit; padding: 13px 0; border-top: 1px solid var(--rule); font-size: 14px; }
  .related-list a:last-child { border-bottom: 1px solid var(--rule); }
  .related-list a:hover .rl-title { color: var(--accent-dark); text-decoration: underline; }
  .rl-title { font-weight: 500; }
  .rl-cat { color: var(--muted); font-size: 12.5px; white-space: nowrap; }

  footer { padding: 28px 24px 44px; text-align: center; font-size: 12.5px; }
  footer a { text-decoration: none; }
  footer a:hover { color: var(--accent); }

  @media (max-width: 560px) {
    .topnav { padding: 16px 20px; }
    .hero { padding: 38px 20px 4px; }
    .wrap { padding: 24px 20px 0; }
    .card { padding: 24px 18px; }
    .download-btn { display: block; }
    .prompt-row { flex-wrap: wrap; }
    .copy-btn { margin-left: 36px; }
  }
  @media (prefers-reduced-motion: reduce) {
    * { transition: none !important; }
  }
</style>
</head>
<body>
  <div class="band-ink">
    <div class="topnav">
      <a class="logo" href="/">{{ site_name }}</a>
      <div class="crumb"><a href="/">Home</a> / {{ category }}</div>
    </div>
  </div>

  <div class="hero">
    <p class="strap">A free {{ tool }} prompt pack</p>
    <h1>{{ title }}</h1>
    <p class="desc">{{ description }}</p>
  </div>

  <div class="wrap">
    <div class="card">
      <p class="count">{{ prompt_count }} ready-to-use prompts · free PDF</p>
      <a class="download-btn" href="{{ download_url }}" rel="nofollow noopener" target="_blank">Download the PDF</a>
      <p class="note">You'll pass through one short ad page on the way to your download — thanks for supporting free content.</p>
    </div>

    <div class="preview">
      <h2>Inside this pack</h2>
      <p class="sub">A preview of what you'll get — copy any line straight into {{ tool }}.</p>
      {% for prompt in preview_prompts %}
      <div class="prompt-row">
        <span class="prompt-num">{{ '%02d'|format(loop.index) }}</span>
        <span class="prompt-text">{{ prompt }}</span>
        <button class="copy-btn" type="button" onclick="pvCopy(this)">Copy</button>
      </div>
      {% endfor %}
      <p class="more">+ {{ remaining_count }} more prompts in the full PDF</p>
    </div>

    <div class="mini-faq">
      <h2>Quick questions</h2>
      <details>
        <summary>How do I use these prompts?</summary>
        <p>Copy any prompt, paste it into {{ tool }}, and replace anything in [brackets] with your own specifics before sending it.</p>
      </details>
      <details>
        <summary>Is this really free?</summary>
        <p>Yes — no email, no account. You'll see one ad page on the way to the download, which is what funds free content like this.</p>
      </details>
    </div>

    {% if related_packs %}
    <div class="related">
      <h2>See also</h2>
      <div class="related-list">
        {% for rp in related_packs %}
        <a href="/packs/{{ rp.slug }}/">
          <span class="rl-title">{{ rp.title }}</span>
          <span class="rl-cat">{{ rp.category }}</span>
        </a>
        {% endfor %}
      </div>
    </div>
    {% endif %}
  </div>

  <footer>
    &copy; {{ year }} {{ site_name }} · <a href="/">More free prompt packs</a>
  </footer>

  <script>
    function pvCopy(btn) {
      var row = btn.closest('.prompt-row');
      var text = row.querySelector('.prompt-text').innerText;
      var reset = function() { btn.textContent = 'Copy'; };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function() {
          btn.textContent = 'Copied';
          setTimeout(reset, 1500);
        }).catch(function() {
          btn.textContent = 'Select & copy';
          setTimeout(reset, 1500);
        });
      }
    }
  </script>
</body>
</html>
PVEOF_SYNC
