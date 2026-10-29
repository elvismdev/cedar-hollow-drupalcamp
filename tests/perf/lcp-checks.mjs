// Reads the median Lighthouse CI reports and checks what the assertions
// cannot: the LCP element on / is the hero image, no LCP image is lazy, and
// no stylesheet or script was refused with a 403.
import { readFileSync } from 'node:fs';

const manifest = JSON.parse(readFileSync(new URL('./reports/manifest.json', import.meta.url), 'utf8'));
const failures = [];
for (const entry of manifest.filter((run) => run.isRepresentativeRun)) {
  const lhr = JSON.parse(readFileSync(entry.jsonPath, 'utf8'));
  const path = new URL(entry.url).pathname;
  const audits = lhr.audits;
  const selector = audits['largest-contentful-paint-element']?.details?.items?.[0]?.items?.[0]?.node?.selector ?? '';
  const lcp = Math.round(audits['largest-contentful-paint'].numericValue);
  const cls = audits['cumulative-layout-shift'].numericValue.toFixed(3);
  const ttfb = Math.round(audits['server-response-time']?.numericValue ?? NaN);
  console.log(`${path}: LCP ${lcp} ms, CLS ${cls}, server response ${ttfb} ms, LCP element ${selector || '(none)'}`);

  if (path === '/' && !/img\.hero__img$/.test(selector)) {
    failures.push(`${path}: the LCP element is "${selector}", not img.hero__img`);
  }
  if (audits['lcp-lazy-loaded']?.score === 0) {
    failures.push(`${path}: the LCP image is lazy-loaded`);
  }
  for (const request of audits['network-requests']?.details?.items ?? []) {
    if (request.statusCode === 403 && ['Stylesheet', 'Script'].includes(request.resourceType)) {
      failures.push(`${path}: ${request.resourceType} ${request.url} answered 403`);
    }
  }
}
if (failures.length) {
  console.error(`LCP checks failed:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
