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
// Pantheon sandboxes show a warning page unless this header is sent.
const headers = new URL(base).hostname.endsWith('.pantheonsite.io') ? { 'Deterrence-Bypass': '1' } : {};

const manifest = JSON.parse(readFileSync(new URL('../../scripts/demo-images.json', import.meta.url), 'utf8'));
const sessions = manifest.filter((entry) => entry.use === 'session').map((entry) => entry.target);
const pages = [...new Set(['/', '/sessions', '/credits', ...sessions])];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// The host's rate limit answers 429 without Retry-After, so requests are
// spaced, a 429 is retried after a growing pause, and a request still
// refused after the last pause stops the run instead of adding load.
const RETRY_PAUSES = [5000, 10000, 20000, 40000, 60000];
const REQUEST_GAP = 1000;

async function get(url) {
  for (const pause of [REQUEST_GAP, ...RETRY_PAUSES]) {
    await sleep(pause);
    const response = await fetch(url, { headers });
    const body = Buffer.from(await response.arrayBuffer());
    if (response.status !== 429) return { status: response.status, body };
  }
  console.error(`Still rate limited after ${RETRY_PAUSES.length} retries at ${url}; stopping.`);
  process.exit(1);
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
