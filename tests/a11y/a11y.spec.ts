import { mkdirSync, writeFileSync } from 'node:fs';
import AxeBuilder from '@axe-core/playwright';
import { test, expect } from '../fixtures';

// The pages named in the design's accessibility goal.
const PAGES = ['/', '/agenda', '/about', '/sessions', '/sessions/caching-render-arrays', '/sitemap', '/user/login'];
const TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'];

mkdirSync('a11y-results', { recursive: true });

for (const path of PAGES) {
  test(`axe finds no WCAG 2.2 AA violations on ${path}`, async ({ page }) => {
    await page.goto(path);
    if (path === '/agenda') await expect(page.locator('.agenda-builder__session').first()).toBeVisible();
    const results = await new AxeBuilder({ page }).withTags(TAGS).analyze();
    writeFileSync(`a11y-results/${path === '/' ? 'home' : path.slice(1).replace(/\//g, '_')}.json`, JSON.stringify(results.violations, null, 2));
    expect(results.violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`)).toEqual([]);
  });
}

test('axe finds no WCAG 2.2 AA violations on the sign-up page', async ({ page }) => {
  await page.goto('/sessions/caching-render-arrays');
  await page.getByRole('link', { name: 'Sign up for this session' }).click();
  await expect(page.getByRole('heading', { name: 'Sign up: Caching render arrays' })).toBeVisible();
  const results = await new AxeBuilder({ page }).withTags(TAGS).analyze();
  writeFileSync('a11y-results/register.json', JSON.stringify(results.violations, null, 2));
  expect(results.violations.map((v) => v.id)).toEqual([]);
});
