"""Post-deploy checks against the live site. Fails on any regression of the plumbing.
Usage: python3 verify_live.py [https://opsautomated.co.uk]
"""
import sys, urllib.request, urllib.error, time
BASE = (sys.argv[1] if len(sys.argv) > 1 else 'https://opsautomated.co.uk').rstrip('/')
fails = []
def get(url, allow_redirects=True):
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k): return None
    opener = urllib.request.build_opener() if allow_redirects else urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, headers={'User-Agent': 'opsautomated-verify', 'Cache-Control': 'no-cache'})
    try:
        r = opener.open(req, timeout=20); return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
def expect(cond, msg):
    if not cond: fails.append(msg)

s, h, b = get(BASE + '/')
expect(s == 200, f'home status {s}')
expect(b'rel="canonical" href="https://opsautomated.co.uk/"' in b, 'canonical missing')
expect(b'og:image' in b and b'application/ld+json' in b, 'share tags or JSON-LD missing')
expect(b'fonts.googleapis' not in b, 'Google Fonts still referenced')
expect(b'email-protection' not in b and b'email-decode' not in b, 'Cloudflare email obfuscation still on (turn off under Scrape Shield)')
hl = {k.lower(): v for k, v in h.items()}
for k in ('strict-transport-security', 'content-security-policy', 'x-content-type-options', 'referrer-policy', 'x-frame-options'):
    expect(k in hl, f'header missing: {k}')

for path, ctype in (('/robots.txt', 'text/plain'), ('/sitemap.xml', 'xml'), ('/llms.txt', 'text/plain')):
    s, h, b = get(BASE + path)
    expect(s == 200, f'{path} status {s}')
    expect(ctype in h.get('Content-Type', ''), f'{path} content-type {h.get("Content-Type")}')
    expect(b'<title>OpsAutomated</title>' not in b, f'{path} returns the homepage')

s, h, b = get(BASE + '/definitely-not-a-page-' + str(int(time.time())))
expect(s == 404, f'unknown path status {s}, expected 404')

s, h, b = get(BASE + '/fonts/archivo-var.woff2')
expect(s == 200 and 'immutable' in h.get('Cache-Control', ''), f'font cache header: {h.get("Cache-Control")}')

s, h, b = get('https://www.opsautomated.co.uk/', allow_redirects=False)
expect(s == 301 and h.get('Location', '').startswith('https://opsautomated.co.uk/'), f'www redirect: {s} {h.get("Location")}')

if fails:
    print('FAIL'); print('\n'.join(' - ' + f for f in fails)); sys.exit(1)
print('PASS: live site plumbing correct')
