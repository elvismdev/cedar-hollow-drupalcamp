import { test, expect } from '../fixtures';

for (const path of ['/', '/sessions', '/sessions/caching-render-arrays', '/agenda', '/sitemap']) {
  test(`${path} loads`, async ({ page }) => {
    const response = await page.goto(path);
    expect(response?.status()).toBe(200);
  });
}

test('the sign-up page is served with its form', async ({ request, baseURL }) => {
  test.skip(baseURL?.includes('pantheonsite.io') ?? false, 'Pantheon sandboxes may answer automated requests on the sign-up path with a bot challenge, which a test must not get past; the e2e suite submits this form against DDEV.');
  const session = await (await request.get('/sessions/caching-render-arrays')).text();
  const register = session.match(/href="([^"]*\/register)"/)?.[1];
  expect(register, 'sign-up link on the session page').toBeTruthy();
  const response = await request.get(register!);
  expect(response.status()).toBe(200);
  const html = await response.text();
  expect(html).toContain('Sign up: Caching render arrays');
  expect(html).toContain('Save Registration');
});

test('the agenda data is uncached at the edge and tagged per session', async ({ request }) => {
  const response = await request.get('/api/agenda');
  expect(response.status()).toBe(200);
  expect(response.headers()['cache-control']).toContain('no-cache');
  expect(response.headers()['x-drupal-cache-tags']).toMatch(/registration_list\.host_entity:node:\d+/);
});
