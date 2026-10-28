// Optional second report; axe in a11y.spec.ts is the gate.
const base = process.env.BASE_URL || 'https://cedar-hollow.ddev.site:30001';
module.exports = {
  defaults: { standard: 'WCAG2AA', headers: { 'Deterrence-Bypass': '1' }, ignoreHTTPSErrors: true },
  urls: ['/', '/agenda', '/about', '/sessions', '/sessions/caching-render-arrays', '/sitemap', '/user/login'].map((path) => base + path),
};
