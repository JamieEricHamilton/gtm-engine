"""Build dist/ from page.html (the artifact source) plus static/ (robots, sitemap, llms, headers, redirects, fonts, assets).
Usage: python3 build.py [--booking URL] [--linkedin URL]
"""
import sys, pathlib, shutil, json
here = pathlib.Path(__file__).parent
args = sys.argv[1:]
def opt(name, default):
    return args[args.index(name) + 1] if name in args else default
booking = opt('--booking', 'https://calendar.app.google/a3V7NKaze5B8Ru9L6')
linkedin = opt('--linkedin', '')
SITE = 'https://opsautomated.co.uk/'

src = (here / 'page.html').read_text()
i = src.index('</style>') + len('</style>')
head_part, body_part = src[:i], src[i:]
body_part = body_part.replace('href="https://calendar.app.google/REPLACE_WITH_BOOKING_LINK" target="_blank" rel="noopener"',
                              f'href="{booking}"' + (' target="_blank" rel="noopener"' if booking.startswith('http') else ''))
if linkedin:
    body_part = body_part.replace('https://www.linkedin.com/in/REPLACE_WITH_PROFILE', linkedin)
else:
    body_part = body_part.replace('<a href="https://www.linkedin.com/in/REPLACE_WITH_PROFILE" target="_blank" rel="noopener">Jamie Hamilton</a>', 'Jamie Hamilton')
assert 'REPLACE_WITH' not in body_part, 'placeholder left in page'
assert 'fonts.googleapis' not in head_part, 'Google Fonts link still in page; fonts must be self-hosted'

description = 'AI agents for recruitment agencies. More placements without adding payroll. Built on your ATS, run and maintained by OpsAutomated.'
favicon = "data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 64 64%27%3E%3Crect width=%2764%27 height=%2764%27 rx=%2714%27 fill=%27%230b0f14%27/%3E%3Ctext x=%2710%27 y=%2745%27 font-family=%27Arial Black,Arial%27 font-weight=%27900%27 font-size=%2732%27 fill=%27%232ee6a6%27%3EO%3Ctspan fill=%27%23f4f6f8%27%3EA%3C/tspan%3E%3C/text%3E%3C/svg%3E"
org = {
  "@context": "https://schema.org",
  "@graph": [
    {"@type": "Organization", "@id": SITE + "#org", "name": "OpsAutomated", "url": SITE, "logo": SITE + "assets/og-v1.png",
     "email": "jamie@opsautomated.co.uk", "founder": {"@type": "Person", "name": "Jamie Hamilton", **({"sameAs": [linkedin]} if linkedin else {})},
     "address": {"@type": "PostalAddress", "addressLocality": "London", "addressCountry": "GB"},
     "parentOrganization": {"@type": "Organization", "name": "Soletax Ltd", "identifier": "17318329"}},
    {"@type": "ProfessionalService", "@id": SITE + "#service", "name": "OpsAutomated", "url": SITE,
     "provider": {"@id": SITE + "#org"}, "serviceType": "AI agent automation for recruitment agencies",
     "areaServed": {"@type": "Country", "name": "United Kingdom"},
     "audience": {"@type": "BusinessAudience", "name": "Recruitment agencies"},
     "description": description}
  ]
}
head_meta = f'''<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<link rel="canonical" href="{SITE}">
<meta name="description" content="{description}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="OpsAutomated">
<meta property="og:title" content="OpsAutomated">
<meta property="og:description" content="{description}">
<meta property="og:url" content="{SITE}">
<meta property="og:image" content="{SITE}assets/og-v1.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="OpsAutomated">
<meta name="twitter:description" content="{description}">
<meta name="twitter:image" content="{SITE}assets/og-v1.png">
<meta name="theme-color" content="#0b0f14">
<link rel="icon" href="{favicon}">
<link rel="preload" as="font" type="font/woff2" href="/fonts/archivo-var.woff2" crossorigin>
<script type="application/ld+json">{json.dumps(org, separators=(',', ':'))}</script>'''
# the page's own description meta is superseded by the one above
head_part = head_part.replace('<meta name="description" content="AI agents that do the admin inside your recruitment agency. Your consultants talk to candidates and clients. Everything else ticks over like clockwork.">\n', '')
html = f'''<!doctype html>
<html lang="en-GB">
<head>
{head_meta}
{head_part.strip()}
</head>
<body>
{body_part.strip()}
</body>
</html>
'''
dist = here / 'dist'
dist.mkdir(exist_ok=True)
(dist / 'index.html').write_text(html)

# 404 page: same shell, one line
style = head_part[head_part.index('<style>'):]
not_found = f'''<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex">
<title>Not found</title>
<link rel="icon" href="{favicon}">
{style}
</head>
<body>
<div class="wrap">
  <header class="nav"><a href="/" class="mark" aria-label="OpsAutomated"><span class="o">Ops</span><span>Automated</span><span class="bar"></span></a><a class="cta" href="/#book">Book a call</a></header>
  <section class="sec" style="border-bottom:0">
    <div class="eyebrow">404</div>
    <h2 style="margin-top:var(--s-2)">That page isn't here.</h2>
    <p class="lead">There is only one page. <a href="/">Back to it.</a></p>
  </section>
</div>
</body>
</html>
'''
(dist / '404.html').write_text(not_found)

# static files
static = here / 'static'
for p in static.rglob('*'):
    if p.is_file():
        target = dist / p.relative_to(static)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(p, target)
print('built dist/:', sorted(str(p.relative_to(dist)) for p in dist.rglob('*') if p.is_file()))
