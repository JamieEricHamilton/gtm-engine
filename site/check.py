"""Design-system drift harness for opsautomated.co.uk.
Renders dist/index.html in Chromium at phone, tablet and desktop widths and fails if
anything is off the system defined at the top of page.html. Run before every deploy.
Usage: python3 check.py [path/to/index.html]
"""
import sys, pathlib, asyncio, threading, functools
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from playwright.async_api import async_playwright

DIST = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent / 'dist').resolve()
class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(DIST)))
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f'http://127.0.0.1:{srv.server_address[1]}/'
VIEWPORTS = [('phone', 390, 844), ('phone-small', 360, 780), ('tablet', 820, 1180), ('laptop', 1280, 800), ('desktop', 1440, 900), ('wide', 1920, 1080)]

TYPE_SCALE = {13, 14, 15, 16, 17, 18, 20, 22, 24, 28, 32, 36, 52, 64}   # px, plus the fluid h1/h2 and the fitted wordmark
SPACE_SCALE = {0, 8, 16, 24, 32, 48, 56, 64, 96, 128}
TEXT_SELECTORS = ['.nav a.cta', '.eyebrow', '.hero h2', '.lead', '.btn', '.proof p', '.sec h2', '.work span', '.work .note', '.steps .k', '.steps p', '.fine',
                  '.agent .role', '.agent p', '.tiers .k', '.tiers h3', '.tiers p', '.flow .k', '.flow h3', '.flow p', '.chip',
                  '.book h2', '.book .mail', '.foot']

JS_ALL = """
(sel) => [...document.querySelectorAll(sel)].map(el => { const cs = getComputedStyle(el); const r = el.getBoundingClientRect();
  return { fs: parseFloat(cs.fontSize), lh: parseFloat(cs.lineHeight), mt: parseFloat(cs.marginTop), x: r.left, y: r.top + scrollY, w: r.width, h: r.height }; })
"""
JS_SECTIONS = """
() => [...document.querySelectorAll('section.sec, section.book, section.hero')].map(s => { const cs = getComputedStyle(s);
  return { id: s.id, pt: parseFloat(cs.paddingTop), pb: parseFloat(cs.paddingBottom) }; })
"""

async def run():
    failures, notes = [], []
    async with async_playwright() as p:
        b = await p.chromium.launch()
        for name, vw, vh in VIEWPORTS:
            pg = await b.new_page(viewport={'width': vw, 'height': vh}, device_scale_factor=1)
            await pg.goto(URL)
            await pg.wait_for_timeout(3000)
            F = lambda msg: failures.append(f'[{name} {vw}px] {msg}')

            fonts = await pg.evaluate("[...document.fonts].filter(f=>f.status==='loaded').map(f=>f.family)")
            for fam in ('Archivo', 'IBM Plex Sans', 'IBM Plex Mono'):
                if fam not in fonts: F(f'font not loaded: {fam}')

            # 1. never scroll sideways
            dw = await pg.evaluate('document.documentElement.scrollWidth')
            if dw > vw: F(f'horizontal overflow: document {dw}px wide')

            # 2. wordmark fits the column with the cursor visible
            wm = (await pg.evaluate(JS_ALL, '.type'))[0]
            cur = (await pg.evaluate(JS_ALL, '#cursor'))[0]
            if cur['w'] < 3: F('cursor collapsed')
            if cur['x'] + cur['w'] > wm['x'] + wm['w'] + 1: F('cursor clipped outside the column')
            if cur['x'] + cur['w'] < wm['x'] + wm['w'] * 0.9: F(f'wordmark does not fill the column ({round(cur["x"]+cur["w"])} of {round(wm["x"]+wm["w"])})')

            # 3. hero headline: two lines everywhere
            h2 = (await pg.evaluate(JS_ALL, '.hero h2'))[0]
            lines = round(h2['h'] / h2['lh'])
            if lines > 2: F(f'hero headline wraps to {lines} lines')

            # 4. type sizes on the scale (fluid headings and the fitted wordmark exempt)
            for sel in TEXT_SELECTORS:
                for el in await pg.evaluate(JS_ALL, sel):
                    if sel in ('.hero h2', '.sec h2', '.book h2'): continue
                    if round(el['fs']) not in TYPE_SCALE: F(f'{sel} font-size {el["fs"]}px off scale')

            # 5. section rhythm: every section has equal top/bottom padding on the spacing scale, and all sections match
            secs = await pg.evaluate(JS_SECTIONS)
            pads = set()
            for s in secs:
                if s['id'] == 'top': continue   # hero has its own rhythm
                if round(s['pt']) != round(s['pb']): F(f'section #{s["id"]} padding top {s["pt"]} != bottom {s["pb"]}')
                if round(s['pt']) not in SPACE_SCALE: F(f'section #{s["id"]} padding {s["pt"]} off scale')
                pads.add(round(s['pt']))
            if len(pads) > 1: F(f'sections use different paddings: {sorted(pads)}')

            # 6. margins on the spacing scale
            for sel in ['.eyebrow', '.hero h2', '.lead', '.hero .actions', '.steps', '.lead.after', '.fine', '.work', '.roster', '.tiers', '.flow', '.ats', '.book .actions', '.proof p', '.work .note']:
                for el in await pg.evaluate(JS_ALL, sel):
                    if round(el['mt']) not in SPACE_SCALE: F(f'{sel} margin-top {el["mt"]}px off scale')

            # 7. phone: one chip per line
            if vw <= 700:
                chips = await pg.evaluate(JS_ALL, '.work span')
                ys = [round(c['y']) for c in chips]
                if len(ys) != len(set(ys)): F('two chips share a line on phone')

            # 8. gutter never below 16px
            wrap = (await pg.evaluate(JS_ALL, '.wrap'))[0]
            if wrap['x'] < 16: F(f'side gutter {wrap["x"]}px')

            notes.append(f'{name:12} {vw}px  wordmark {round(wm["fs"])}px  hero h2 {round(h2["fs"])}px/{lines} lines  sections {sorted(pads)}')
            await pg.close()
        await b.close()
    print('\n'.join(notes))
    if failures:
        print('\nFAIL'); print('\n'.join(failures)); sys.exit(1)
    print('\nPASS: design system holds at all widths')

asyncio.run(run())
