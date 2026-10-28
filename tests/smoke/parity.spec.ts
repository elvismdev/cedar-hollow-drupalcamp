import { test, expect } from '../fixtures';

// Content parity after content moves between environments, for example the
// database copy from DDEV to Pantheon: the same sessions with the same URLs,
// the same site map links, and every one of them answering on the target.
// Runs only when PARITY_SOURCE names the environment the content came from:
//   PARITY_SOURCE=https://cedar-hollow.ddev.site:30001 \
//   BASE_URL=https://dev-cedar-hollow-demo.pantheonsite.io \
//   npx playwright test --project=smoke parity
const SOURCE = process.env.PARITY_SOURCE;

type Snapshot = { sessions: string[]; links: string[] };

async function snapshot(page, base: string): Promise<Snapshot> {
  const agenda = await (await page.request.get(`${base}/api/agenda`)).json();
  await page.goto(`${base}/sitemap`);
  const links = await page.locator('main a[href^="/"]').evaluateAll((anchors) =>
    anchors.map((a) => a.getAttribute('href').split(/[?#]/)[0]));
  return {
    sessions: agenda.sessions.map((s) => `${s.title} -> ${s.url}`).sort(),
    links: [...new Set(links)].sort(),
  };
}

test('the target has the same sessions, URLs and site map as the source', async ({ page, baseURL }) => {
  test.skip(!SOURCE, 'Set PARITY_SOURCE to compare environments.');
  const source = await snapshot(page, SOURCE!);
  const target = await snapshot(page, baseURL!);
  expect(target.sessions).toEqual(source.sessions);
  expect(target.links).toEqual(source.links);
  expect(target.sessions.length).toBeGreaterThan(0);

  // Pantheon sandboxes refuse a burst of automated page loads; the smoke
  // suite loads the key pages there instead.
  if (baseURL!.includes('pantheonsite.io')) return;
  for (const path of [...target.sessions.map((s) => s.split(' -> ')[1]), ...target.links]) {
    const response = await page.goto(`${baseURL}${path}`);
    expect(response?.status(), path).toBe(200);
  }
});
