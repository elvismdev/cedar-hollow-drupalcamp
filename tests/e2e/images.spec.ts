import { test, expect } from '../fixtures';

// The image a page shows first is fetched first and eagerly; every other
// image is lazy, and each responsive image tells the browser its size.

test('the home page hero loads first', async ({ page }) => {
  await page.goto('/');
  const hero = page.locator('img.hero__img');
  await expect(hero).toHaveCount(1);
  await expect(hero).toHaveAttribute('loading', 'eager');
  await expect(hero).toHaveAttribute('fetchpriority', 'high');
  await expect(hero).toHaveAttribute('sizes', /.+/);
});

test('session cards load eagerly with sizes', async ({ page }) => {
  await page.goto('/sessions');
  const cards = page.locator('img.card__img');
  await expect(cards).toHaveCount(12);
  for (const card of await cards.all()) {
    await expect(card).toHaveAttribute('loading', 'eager');
    await expect(card).toHaveAttribute('sizes', /.+/);
  }
});

test('a session page loads its image first and the rest lazily', async ({ page }) => {
  await page.goto('/sessions/theming-with-sdc');
  const image = page.locator('img.session__img');
  await expect(image).toHaveAttribute('loading', 'eager');
  await expect(image).toHaveAttribute('fetchpriority', 'high');
  await expect(image).toHaveAttribute('sizes', /.+/);

  const lazy = page.locator('img.speaker-byline__img, figure img');
  await expect(lazy).toHaveCount(2);
  for (const img of await lazy.all()) {
    await expect(img).toHaveAttribute('loading', 'lazy');
    await expect(img).toHaveAttribute('sizes', /.+/);
  }
  await expect(page.locator('figure figcaption')).toHaveText('Each component keeps its Twig, CSS and metadata in one directory.');
});

test('the credits page lists each photo with its licence', async ({ page }) => {
  await page.goto('/credits');
  await expect(page.getByText('The photos on this site come from Wikimedia Commons.')).toBeVisible();
  const rows = page.locator('table tbody tr');
  await expect(rows).toHaveCount(24);
  await expect(rows.filter({ hasText: 'Coniferous Forest - Green Valley 2014-05-08 1606' })).toHaveCount(1);
  await expect(page.getByRole('link', { name: 'CC BY' }).first()).toHaveAttribute('href', /creativecommons\.org\/licenses\/by\//);
});
