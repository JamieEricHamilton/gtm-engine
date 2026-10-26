# opsautomated.co.uk

Single page site. Source of truth is `page.html` (the design system is the token block at the top of its stylesheet).

Pipeline (Claude runs it; never edit dist/ by hand):
1. `python3 build.py [--booking URL] [--linkedin URL]` → wraps page.html into `dist/index.html` with the document skeleton, favicon, OG tags and live substitutions.
2. `python3 check.py` → renders dist/index.html in Chromium at 360 / 390 / 820 / 1280 / 1440 / 1920 and fails on: horizontal overflow, cursor clipped or wordmark not filling the column, hero headline over two lines, any font size off the type scale, section padding unequal or off the spacing scale or differing between sections, margins off the spacing scale, two chips on one line on phone, gutter under 16px.
3. Copy dist/ to ../site, then from ~/OpsAutomated: `export CLOUDFLARE_ACCOUNT_ID=CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN=$(grep '^CF_PAGES_TOKEN=' .secrets | cut -d= -f2) && npx -y wrangler@4 pages deploy ./site --project-name opsautomated --branch main` (token in ~/OpsAutomated/.secrets since 12 Oct 2026).

Design system (10 Oct 2026)
- Column 1040px, gutter 16-40px. Dark only: bg #0b0f14, text #f4f6f8, muted #aab4bf, faint #6c7884, line #1f2933, accent #2ee6a6.
- Faces: Archivo (display, wdth 108-112, weight 800), IBM Plex Sans (body), IBM Plex Mono (labels, data).
- Type scale: 13 / 15 / 17 / 20 / 24 / 32 / 52 (h2 fluid) / 64 (h1 fluid). Phone: md 18, h3 28, h4 22, h1 30 (28 under 376px). Wordmark fits the column with the cursor, 36-150px.
- Spacing scale: 8 / 16 / 24 / 32 / 48 / 64 / 96 / 128. Section padding: 96 desktop, 64 under 1000px, 56 under 700px, identical top and bottom for every section.
- Labels: 14px mono, .12em tracking, uppercase. Buttons 48px high. Chips 36px high, pill.
