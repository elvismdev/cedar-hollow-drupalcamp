import { test, expect } from '../fixtures';

test('the sessions listing filters by track, then by day', async ({ page }) => {
  await page.goto('/sessions');
  const titles = page.locator('.session-list .card__title');
  await expect(titles).toHaveCount(12);

  await page.getByRole('radio', { name: 'Back end' }).check();
  await page.getByRole('button', { name: 'Show sessions' }).click();
  await expect(titles).toHaveText([
    'Caching render arrays',
    'Entity Registration for events',
    'Preprocess hooks without the mess',
    'Configuration and deploys on Pantheon',
  ]);

  await page.getByRole('radio', { name: 'Saturday' }).check();
  await page.getByRole('button', { name: 'Show sessions' }).click();
  await expect(titles).toHaveText(['Preprocess hooks without the mess', 'Configuration and deploys on Pantheon']);
});
