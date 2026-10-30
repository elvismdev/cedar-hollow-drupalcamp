// Requests every image derivative the main pages reference, once, so the
// first visitor or the performance check does not pay for generating them.
//
// Usage: npm run warm -- <base URL>
// On DDEV, Node needs DDEV's certificate authority:
// NODE_EXTRA_CA_CERTS="$(mkcert -CAROOT)/rootCA.pem" npm run warm -- https://cedar-hollow.ddev.site:30001
import { readFileSync } from 'node:fs';

const base = (process.argv[2] ?? '').replace(/\/$/, '');
if (!base) {
  console.error('Usage: npm run warm -- <base URL>');
  process.exit(2);
}
// Pantheon sandboxes show a warning page unless Deterrence-Bypass is sent, and
// PANTHEON_BOT_BYPASS_TOKEN (from `terminus gcdn:bot-bypass`) keeps the edge's
// bot protection from challenging these requests. Neither goes to other hosts.
const onPantheon = new URL(base).hostname.endsWith('.pantheonsite.io');
const botBypass = process.env.PANTHEON_BOT_BYPASS_TOKEN;
const headers = onPantheon
  ? { 'Deterrence-Bypass': '1', ...(botBypass ? { 'x-pantheon-bot-bypass': botBypass } : {}) }
  : {};

const manifest = JSON.parse(readFileSync(new URL('../../scripts/demo-images.json', import.meta.url), 'utf8'));
const sessions = manifest.filter((entry) => entry.use === 'session').map((entry) => entry.target);
const pages = [...new Set(['/', '/sessions', '/credits', ...sessions])];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Requests are spaced. A 429 waits for the host's Retry-After when it sends
// one (capped), or for a growing pause when it does not, and a request still
// refused after the last retry stops the run instead of adding load. Each 429
// logs the headers that name the layer that refused it.
const RETRY_PAUSES = [5000, 10000, 20000, 40000, 60000];
const REQUEST_GAP = 1000;
const MAX_RETRY_AFTER = 300_000;
// Exit code for "rate limited by the host", distinct from a page or image
// that answered with an error.
const EXIT_RATE_LIMITED = 75;
const DIAGNOSTIC_HEADERS = ['retry-after', 'server', 'via', 'x-served-by', 'x-cache', 'cf-ray', 'cf-mitigated', 'age', 'content-type'];

function describe429(response, body) {
  const seen = DIAGNOSTIC_HEADERS.filter((name) => response.headers.has(name))
    .map((name) => `${name}=${response.headers.get(name)}`);
  const text = body.toString('utf8').replace(/\s+/g, ' ').trim().slice(0, 120);
  return `429 headers: ${seen.join(' ') || '(none of the expected)'}; body: ${text || '(empty)'}`;
}

async function get(url) {
  let wait = REQUEST_GAP;
  for (let retry = 0; retry <= RETRY_PAUSES.length; retry += 1) {
    await sleep(wait);
    const response = await fetch(url, { headers });
    const body = Buffer.from(await response.arrayBuffer());
    if (response.status !== 429) return { status: response.status, body };
    console.error(`${describe429(response, body)} (${url})`);
    const retryAfter = Number(response.headers.get('retry-after'));
    wait = Number.isFinite(retryAfter) && retryAfter > 0
      ? Math.min(retryAfter * 1000, MAX_RETRY_AFTER)
      : RETRY_PAUSES[retry];
  }
  console.error(`Rate limited by the host, not a broken page: still 429 after ${RETRY_PAUSES.length} retries at ${url}; stopping.`);
  process.exit(EXIT_RATE_LIMITED);
}

const images = new Set();
for (const path of pages) {
  const { status, body } = await get(base + path);
  if (status !== 200) {
    console.error(`${path}: ${status}`);
    process.exitCode = 1;
    continue;
  }
  const html = body.toString('utf8');
  for (const [, attribute, value] of html.matchAll(/\s(src|srcset)="([^"]+)"/g)) {
    const urls = attribute === 'src' ? [value] : value.split(',').map((candidate) => candidate.trim().split(/\s+/)[0]);
    for (const url of urls) {
      if (/\/files\/styles\//.test(url)) images.add(new URL(url.replaceAll('&amp;', '&'), base + '/').href);
    }
  }
}

let failed = 0;
for (const url of images) {
  const { status } = await get(url);
  if (status !== 200) {
    console.error(`${status} ${url}`);
    failed += 1;
  }
}
console.log(`Warmed ${images.size - failed} of ${images.size} image derivatives from ${pages.length} pages.`);
if (failed) process.exitCode = 1;
