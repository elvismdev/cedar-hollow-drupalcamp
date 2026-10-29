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

const images = new Set();
for (const path of pages) {
  const response = await fetch(base + path, { headers });
  if (response.status !== 200) {
    console.error(`${path}: ${response.status}`);
    process.exitCode = 1;
    continue;
  }
  const html = await response.text();
  for (const [, attribute, value] of html.matchAll(/\s(src|srcset)="([^"]+)"/g)) {
    const urls = attribute === 'src' ? [value] : value.split(',').map((candidate) => candidate.trim().split(/\s+/)[0]);
    for (const url of urls) {
      if (/\/files\/styles\//.test(url)) images.add(new URL(url.replaceAll('&amp;', '&'), base + '/').href);
    }
  }
}

let failed = 0;
for (const url of images) {
  const response = await fetch(url, { headers });
  await response.arrayBuffer();
  if (response.status !== 200) {
    console.error(`${response.status} ${url}`);
    failed += 1;
  }
}
console.log(`Warmed ${images.size - failed} of ${images.size} image derivatives from ${pages.length} pages.`);
if (failed) process.exitCode = 1;
