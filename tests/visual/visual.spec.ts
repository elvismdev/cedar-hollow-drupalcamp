import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import { extname, join, normalize } from 'node:path';
import { test, expect } from '../fixtures';

// Visual regression on the design system's key templates, rendered by the
// static Storybook build. Run in the mcr.microsoft.com/playwright image, both
// locally and in CI, so fonts and rendering match the committed baselines.
const STORYBOOK_DIR = join(__dirname, '../../web/themes/custom/cedar_hollow/storybook');
const PORT = 6008;

const STORIES = [
  'components-card--session-card',
  'components-card--session-card-with-image',
  'components-hero--default',
  'components-speaker-byline--with-photo',
  'components-callout--stacked',
  'components-callout--horizontal',
  'components-featured-card--event',
  'atoms-seats-indicator--open',
  'atoms-seats-indicator--low',
  'atoms-seats-indicator--waitlist',
  'atoms-seats-indicator--full',
  'atoms-button--primary',
  'atoms-button--secondary',
  'collections-site-header--default',
  'collections-site-footer--default',
  'agenda-builder-agenda-builder--default',
];

const TYPES: Record<string, string> = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.avif': 'image/avif' };
// Stories use an external placeholder image; serve a fixed local one instead.
const PLACEHOLDER = '<svg xmlns="http://www.w3.org/2000/svg" width="768" height="512"><rect width="768" height="512" fill="#d9dee3"/></svg>';

let server: Server;

test.beforeAll(async () => {
  test.skip(!existsSync(join(STORYBOOK_DIR, 'iframe.html')), 'Build Storybook first: npm run build in the theme.');
  server = createServer((request, response) => {
    const path = normalize(decodeURIComponent((request.url ?? '/').split('?')[0])).replace(/^(\.\.[/\\])+/, '');
    let file = join(STORYBOOK_DIR, path);
    if (existsSync(file) && statSync(file).isDirectory()) file = join(file, 'index.html');
    if (!existsSync(file)) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' });
    createReadStream(file).pipe(response);
  });
  await new Promise<void>((resolve) => server.listen(PORT, resolve));
});

test.afterAll(async () => {
  await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()));
});

for (const id of STORIES) {
  test(`${id} matches its baseline`, async ({ page }) => {
    await page.route('https://placehold.co/**', (route) => route.fulfill({ contentType: 'image/svg+xml', body: PLACEHOLDER }));
    await page.setViewportSize({ width: 1024, height: 768 });
    await page.goto(`http://127.0.0.1:${PORT}/iframe.html?id=${id}&viewMode=story`);
    const root = page.locator('#storybook-root');
    await expect(root.locator(':scope > *').first()).toBeVisible();
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() => [...document.images].every((image) => image.complete && image.naturalWidth > 0));
    await expect(root).toHaveScreenshot(`${id}.png`, {
      animations: 'disabled',
      // The agenda builder prints the time its data was loaded.
      mask: [page.locator('.agenda-builder__freshness')],
    });
  });
}
