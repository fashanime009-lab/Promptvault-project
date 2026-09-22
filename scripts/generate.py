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

ACCENT = "#7c6fe0"
ACCENT_DARK = "#4b3f9e"
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
        site_url=SITE_URL,
        schema_json=json.dumps(schema),
        year=datetime.now().year,
    )
    out_path.write_text(html)


def render_favicon(out_path):
    svg = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
<rect width="24" height="24" rx="7" fill="#7c6fe0"/>
<path d="M7 12.5L10.5 16L17 8" stroke="white" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>
</svg>"""
    out_path.write_text(svg)


def render_og_image(site_name, tagline, out_path, browser):
    html = f"""<!DOCTYPE html><html><head><style>
    body {{ margin:0; width:1200px; height:630px; display:flex; flex-direction:column; justify-content:center; align-items:center;
      background: linear-gradient(135deg, #1a1a2e, #4b3f9e 55%, #7c6fe0); font-family: Arial, sans-serif; color:#fff; text-align:center; }}
    h1 {{ font-size:76px; margin:0 0 20px; font-weight:800; }}
    p {{ font-size:28px; opacity:0.9; max-width:800px; margin:0; }}
    </style></head><body>
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
