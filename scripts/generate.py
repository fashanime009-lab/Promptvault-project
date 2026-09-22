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
import re
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
# Optional: set this to a hosted form's submit URL (Mailchimp, ConvertKit,
# Formspree, ...) once you've connected an email provider. Until then the
# email capture block is simply left out of the rendered pages.
EMAIL_CAPTURE_ACTION = os.environ.get("EMAIL_CAPTURE_ACTION_URL", "").strip()
PROMPTS_PER_PDF_PAGE = 14
PREVIEW_COUNT = 6
RELATED_COUNT = 3

env = jinja2.Environment(loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)))


def slugify(text: str) -> str:
    text = text.lower().replace("&", " ")
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def load_packs():
    with open(CONTENT_DIR / "packs.json") as f:
        return json.load(f)


def load_blog():
    blog_path = CONTENT_DIR / "blog.json"
    if not blog_path.exists():
        return {"posts": []}
    with open(blog_path) as f:
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
    category_slug = slugify(pack["category"])
    pack_url = f"{SITE_URL}/packs/{pack['slug']}/"
    schema = {
        "@context": "https://schema.org",
        "@type": "CreativeWork",
        "name": pack["title"],
        "description": pack["description"],
        "url": pack_url,
        "isAccessibleForFree": True,
        "keywords": f"{pack['tool']}, {pack['category']}, AI prompts",
    }
    breadcrumb_schema = {
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Home", "item": f"{SITE_URL}/"},
            {"@type": "ListItem", "position": 2, "name": pack["category"], "item": f"{SITE_URL}/category/{category_slug}/"},
            {"@type": "ListItem", "position": 3, "name": pack["title"], "item": pack_url},
        ],
    }
    faqpage_schema = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": [
            {
                "@type": "Question",
                "name": "How do I use these prompts?",
                "acceptedAnswer": {
                    "@type": "Answer",
                    "text": f"Copy any prompt, paste it into {pack['tool']}, and replace anything in [brackets] with your own specifics before sending it.",
                },
            },
            {
                "@type": "Question",
                "name": "Is this really free?",
                "acceptedAnswer": {
                    "@type": "Answer",
                    "text": "Yes — no email, no account. You'll see one ad page on the way to the download, which is what funds free content like this.",
                },
            },
        ],
    }
    html = template.render(
        title=pack["title"],
        description=pack["description"],
        tool=pack["tool"],
        category=pack["category"],
        category_slug=category_slug,
        slug=pack["slug"],
        site_name=site_name,
        site_url=SITE_URL,
        share_url=pack_url,
        accent=ACCENT,
        accent_dark=ACCENT_DARK,
        prompt_count=len(pack["prompts"]),
        preview_prompts=pack["prompts"][:PREVIEW_COUNT],
        remaining_count=max(0, len(pack["prompts"]) - PREVIEW_COUNT),
        download_url=download_url,
        related_packs=pick_related(pack, all_packs),
        schema_json=json.dumps(schema),
        breadcrumb_json=json.dumps(breadcrumb_schema),
        faqpage_json=json.dumps(faqpage_schema),
        email_capture_action=EMAIL_CAPTURE_ACTION or None,
        year=datetime.now().year,
    )
    out_path.write_text(html)


FAQ_ITEMS = [
    (
        "Are these prompt packs really free?",
        "Yes — every pack is free to download, no email address or account required. You'll pass through one short ad page on the way to your download, which is how we keep the site running.",
    ),
    (
        "Do I need a paid ChatGPT or Midjourney subscription to use these?",
        "No. Most prompts work fine on free tiers — just copy the prompt, paste it into the tool, and replace anything in [brackets] with your own details.",
    ),
    (
        "Can I use these prompts for client or commercial work?",
        "Yes, the prompts themselves are free to use however you like — for yourself, your business, or your clients.",
    ),
    (
        "How often do you add new packs?",
        "New prompt packs are added regularly based on what's actually useful and trending — check back or bookmark this page.",
    ),
]


def render_index(data, blog_data, out_path):
    template = env.get_template("index_template.html")
    packs = data["packs"]
    for p in packs:
        p["prompt_count"] = len(p["prompts"])
    categories = sorted(set(p["category"] for p in packs))
    categories_with_slugs = [{"name": c, "slug": slugify(c)} for c in categories]
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
    faqpage_schema = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": [
            {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}}
            for q, a in FAQ_ITEMS
        ],
    }
    html = template.render(
        site_name=data["site_name"],
        tagline=data["tagline"],
        packs=packs,
        categories=categories_with_slugs,
        pack_count=len(packs),
        hero_samples=pick_hero_samples(packs),
        blog_teasers=blog_data["posts"][:3],
        faq_items=FAQ_ITEMS,
        email_capture_action=EMAIL_CAPTURE_ACTION or None,
        site_url=SITE_URL,
        schema_json=json.dumps(schema),
        faqpage_json=json.dumps(faqpage_schema),
        year=datetime.now().year,
    )
    out_path.write_text(html)


def render_category_pages(data, out_dir):
    template = env.get_template("category_template.html")
    packs = data["packs"]
    categories = sorted(set(p["category"] for p in packs))
    categories_with_slugs = [{"name": c, "slug": slugify(c)} for c in categories]

    for cat in categories:
        cat_slug = slugify(cat)
        cat_packs = [p for p in packs if p["category"] == cat]
        cat_url = f"{SITE_URL}/category/{cat_slug}/"
        schema = {
            "@context": "https://schema.org",
            "@type": "CollectionPage",
            "name": f"{cat} — {data['site_name']}",
            "description": f"Free {cat} prompt packs for ChatGPT, Midjourney, and Notion AI.",
            "url": cat_url,
            "hasPart": [
                {"@type": "CreativeWork", "name": p["title"], "url": f"{SITE_URL}/packs/{p['slug']}/"}
                for p in cat_packs
            ],
        }
        breadcrumb_schema = {
            "@context": "https://schema.org",
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Home", "item": f"{SITE_URL}/"},
                {"@type": "ListItem", "position": 2, "name": cat, "item": cat_url},
            ],
        }
        out_path = out_dir / "category" / cat_slug
        out_path.mkdir(parents=True, exist_ok=True)
        html = template.render(
            site_name=data["site_name"],
            category=cat,
            category_slug=cat_slug,
            packs=cat_packs,
            site_url=SITE_URL,
            schema_json=json.dumps(schema),
            breadcrumb_json=json.dumps(breadcrumb_schema),
            year=datetime.now().year,
        )
        (out_path / "index.html").write_text(html)
        print(f"  [+] Category page: /category/{cat_slug}/")

    return categories_with_slugs


def render_blog_index(data, blog_data, out_dir):
    template = env.get_template("blog_index_template.html")
    out_path = out_dir / "blog"
    out_path.mkdir(parents=True, exist_ok=True)
    html = template.render(
        site_name=data["site_name"],
        posts=blog_data["posts"],
        site_url=SITE_URL,
        year=datetime.now().year,
    )
    (out_path / "index.html").write_text(html)
    print("  [+] Blog index: /blog/")


def render_blog_posts(data, blog_data, out_dir):
    template = env.get_template("blog_post_template.html")
    packs_by_slug = {p["slug"]: p for p in data["packs"]}
    for post in blog_data["posts"]:
        related_packs = [packs_by_slug[s] for s in post.get("related_slugs", []) if s in packs_by_slug]
        post_url = f"{SITE_URL}/blog/{post['slug']}/"
        schema = {
            "@context": "https://schema.org",
            "@type": "BlogPosting",
            "headline": post["title"],
            "description": post["description"],
            "datePublished": post["date"],
            "url": post_url,
            "author": {"@type": "Organization", "name": data["site_name"]},
        }
        breadcrumb_schema = {
            "@context": "https://schema.org",
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Home", "item": f"{SITE_URL}/"},
                {"@type": "ListItem", "position": 2, "name": "Blog", "item": f"{SITE_URL}/blog/"},
                {"@type": "ListItem", "position": 3, "name": post["title"], "item": post_url},
            ],
        }
        out_path = out_dir / "blog" / post["slug"]
        out_path.mkdir(parents=True, exist_ok=True)
        html = template.render(
            site_name=data["site_name"],
            post=post,
            related_packs=related_packs,
            site_url=SITE_URL,
            schema_json=json.dumps(schema),
            breadcrumb_json=json.dumps(breadcrumb_schema),
            year=datetime.now().year,
        )
        (out_path / "index.html").write_text(html)
        print(f"  [+] Blog post: /blog/{post['slug']}/")


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


def render_robots_and_sitemap(data, blog_data, categories_with_slugs, out_dir):
    (out_dir / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}/sitemap.xml\n")

    urls = (
        [f"{SITE_URL}/", f"{SITE_URL}/blog/"]
        + [f"{SITE_URL}/packs/{p['slug']}/" for p in data["packs"]]
        + [f"{SITE_URL}/category/{c['slug']}/" for c in categories_with_slugs]
        + [f"{SITE_URL}/blog/{post['slug']}/" for post in blog_data["posts"]]
    )
    body = "\n".join(f"  <url><loc>{u}</loc></url>" for u in urls)
    sitemap = f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{body}\n</urlset>\n'
    (out_dir / "sitemap.xml").write_text(sitemap)


def main():
    data = load_packs()
    blog_data = load_blog()
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

    categories_with_slugs = render_category_pages(data, SITE_DIR)
    render_blog_index(data, blog_data, SITE_DIR)
    render_blog_posts(data, blog_data, SITE_DIR)
    render_index(data, blog_data, SITE_DIR / "index.html")
    render_robots_and_sitemap(data, blog_data, categories_with_slugs, SITE_DIR)
    print(f"\nDone. Site generated at: {SITE_DIR}")
    print(f"Packs: {len(data['packs'])}")
    print(f"Blog posts: {len(blog_data['posts'])}")
    print(f"Categories: {len(categories_with_slugs)}")


if __name__ == "__main__":
    sys.exit(main())
