import { test, expect } from '../fixtures';

// The image a page shows first is fetched first and eagerly; every other
// image is lazy, and each responsive image tells the browser its size.
// Card and speaker-byline photos are decorative (the heading or name beside
// them carries the meaning), so their alt is empty; the others describe the
// photo.

test('the home page hero loads first', async ({ page }) => {
  await page.goto('/');
  const hero = page.locator('img.hero__img');
  await expect(hero).toHaveCount(1);
  await expect(hero).toHaveAttribute('loading', 'eager');
  await expect(hero).toHaveAttribute('fetchpriority', 'high');
  await expect(hero).toHaveAttribute('sizes', /.+/);
  await expect(hero).toHaveAttribute('alt', /\S/);
});

test('the first row of session cards loads first and the rest lazily', async ({ page }) => {
  await page.goto('/sessions');
  const cards = page.locator('img.card__img');
  await expect(cards).toHaveCount(12);
  for (const [index, card] of (await cards.all()).entries()) {
    if (index < 3) {
      await expect(card).toHaveAttribute('loading', 'eager');
      await expect(card).toHaveAttribute('fetchpriority', 'high');
    }
    else {
      await expect(card).toHaveAttribute('loading', 'lazy');
      await expect(card).not.toHaveAttribute('fetchpriority', /.*/);
    }
    await expect(card).toHaveAttribute('sizes', /.+/);
    await expect(card).toHaveAttribute('alt', '');
  }
});

test('a filtered listing loads its own first row first', async ({ page }) => {
  // These cards sit after the first row of the full listing, so they are
  // rendered lazily there; the eager copies are cached apart.
  await page.goto('/sessions');
  await page.goto('/sessions?day=sat');
  const cards = page.locator('img.card__img');
  await expect(cards).toHaveCount(6);
  for (const [index, card] of (await cards.all()).entries()) {
    await expect(card).toHaveAttribute('loading', index < 3 ? 'eager' : 'lazy');
  }
});

test('a session page loads its image first and the rest lazily', async ({ page }) => {
  await page.goto('/sessions/theming-with-sdc');
  const image = page.locator('.session img.hero__img');
  await expect(image).toHaveAttribute('loading', 'eager');
  await expect(image).toHaveAttribute('fetchpriority', 'high');
  await expect(image).toHaveAttribute('sizes', /.+/);
  await expect(image).toHaveAttribute('alt', /\S/);
  await expect(page.locator('img.speaker-byline__img')).toHaveAttribute('alt', '');
  await expect(page.locator('figure img')).toHaveAttribute('alt', /\S/);

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
  // Each source link names its photo, since the links go to different pages
  // (WCAG 2.4.4), and the name starts with the visible text (2.5.3).
  const sources = page.getByRole('link', { name: /^Wikimedia Commons page for \S/ });
  await expect(sources).toHaveCount(24);
  const names = await sources.evaluateAll((links) => links.map((link) => link.textContent));
  expect(new Set(names).size).toBe(24);
});
