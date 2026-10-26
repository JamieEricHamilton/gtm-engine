// Companies House filings stream -> n8n webhook, SH01 only.
// Docs: GET https://stream.companieshouse.gov.uk/filings, Basic auth "<key>:", one JSON per line, blank line = heartbeat,
// ?timepoint=<last seen> to resume, 429 = back off a minute, 416 = timepoint too old (drop it).
const https = require('https');
const http = require('http');
const fs = require('fs');

const KEY = process.env.CH_STREAM_KEY;
const WEBHOOK = process.env.WEBHOOK_URL;
const STATE = process.env.STATE_FILE || '/state/timepoint';
if (!KEY || !WEBHOOK) { console.error('CH_STREAM_KEY and WEBHOOK_URL are required'); process.exit(1); }

let timepoint = null;
try { const t = fs.readFileSync(STATE, 'utf8').trim(); if (/^\d+$/.test(t)) timepoint = Number(t); } catch {}
let stats = { events: 0, sh01: 0, posted: 0, failed: 0, since: new Date().toISOString() };
let lastSave = 0;

function log(...a) { console.log(new Date().toISOString(), ...a); }
function saveTimepoint(force) {
  if (timepoint == null) return;
  const now = Date.now();
  if (!force && now - lastSave < 5000) return;
  lastSave = now;
  try { fs.writeFileSync(STATE, String(timepoint)); } catch (e) { log('state write failed', e.message); }
}

function post(body) {
  return new Promise((resolve) => {
    const data = Buffer.from(JSON.stringify(body));
    const u = new URL(WEBHOOK);
    const mod = u.protocol === 'https:' ? https : http;
    const req = mod.request(u, { method: 'POST', headers: { 'content-type': 'application/json', 'content-length': data.length }, timeout: 15000 }, (res) => {
      res.resume();
      res.on('end', () => resolve(res.statusCode));
    });
    req.on('error', (e) => { log('post error', e.message); resolve(0); });
    req.on('timeout', () => { req.destroy(); resolve(0); });
    req.end(data);
  });
}

async function handle(line) {
  let e; try { e = JSON.parse(line); } catch { return; }
  stats.events++;
  if (e.event && typeof e.event.timepoint === 'number') { timepoint = e.event.timepoint; saveTimepoint(false); }
  const d = e.data || {};
  const isSh01 = String(d.type || '').toUpperCase() === 'SH01' || (d.category === 'capital' && /allotment/i.test(String(d.description || '')));
  if (!isSh01 || (e.event && e.event.type === 'deleted')) return;
  stats.sh01++;
  let code = 0;
  for (let attempt = 0; attempt < 3 && !(code >= 200 && code < 300); attempt++) {
    if (attempt) await new Promise(r => setTimeout(r, 3000 * attempt));
    code = await post(e);
  }
  if (code >= 200 && code < 300) stats.posted++; else { stats.failed++; log('webhook failed', code, e.resource_uri); }
}

function connect() {
  const path = '/filings' + (timepoint != null ? '?timepoint=' + timepoint : '');
  log('connecting', path);
  const req = https.request({ host: 'stream.companieshouse.gov.uk', path, method: 'GET', headers: { Authorization: 'Basic ' + Buffer.from(KEY + ':').toString('base64') } }, (res) => {
    log('status', res.statusCode);
    if (res.statusCode === 429) { res.resume(); return setTimeout(connect, 60000); }
    if (res.statusCode === 416) { log('timepoint too old, dropping it'); timepoint = null; try { fs.unlinkSync(STATE); } catch {} res.resume(); return setTimeout(connect, 10000); }
    if (res.statusCode !== 200) { res.resume(); return setTimeout(connect, 10000); }
    let buf = '';
    let queue = Promise.resolve();
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (line) queue = queue.then(() => handle(line));
      }
    });
    res.on('end', () => { log('stream ended'); saveTimepoint(true); setTimeout(connect, 5000); });
    res.on('error', (e) => { log('stream error', e.message); saveTimepoint(true); setTimeout(connect, 5000); });
  });
  req.on('error', (e) => { log('connect error', e.message); setTimeout(connect, 5000); });
  req.end();
}

setInterval(() => { log('stats', JSON.stringify(stats), 'timepoint', timepoint); }, 3600000);
process.on('SIGTERM', () => { saveTimepoint(true); process.exit(0); });
connect();
