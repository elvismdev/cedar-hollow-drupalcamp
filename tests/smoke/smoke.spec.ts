import { test, expect } from '../fixtures';

for (const path of ['/', '/sessions', '/sessions/caching-render-arrays', '/agenda', '/sitemap']) {
  test(`${path} loads`, async ({ page }) => {
    const response = await page.goto(path);
    expect(response?.status()).toBe(200);
  });
}

test('the sign-up page loads', async ({ page }) => {
  await page.goto('/sessions/caching-render-arrays');
  await page.getByRole('link', { name: 'Sign up for this session' }).click();
  await expect(page.getByRole('heading', { name: 'Sign up: Caching render arrays' })).toBeVisible();
});

test('the agenda data is uncached at the edge and tagged per session', async ({ request }) => {
  const response = await request.get('/api/agenda');
  expect(response.status()).toBe(200);
  expect(response.headers()['cache-control']).toContain('no-cache');
  expect(response.headers()['x-drupal-cache-tags']).toMatch(/registration_list\.host_entity:node:\d+/);
});
