import { test, expect, tabTo } from '../fixtures';

const FIRST = 'Add to agenda: Theming with SDC';
const SECOND = 'Add to agenda: Caching render arrays';

test.beforeEach(async ({ page }) => {
  await page.goto('/agenda');
  await page.evaluate(() => window.localStorage.clear());
  await page.reload();
  await expect(page.getByRole('button', { name: FIRST })).toBeVisible();
});

test('an attendee finds sessions, adds two that overlap and keeps them after a reload', async ({ page }) => {
  await page.goto('/sessions');
  await page.getByRole('radio', { name: 'Front end' }).check();
  await page.getByRole('button', { name: 'Show sessions' }).click();
  await expect(page.locator('.session-list .card__title').first()).toHaveText('Theming with SDC');

  await page.goto('/agenda');
  await page.getByRole('button', { name: FIRST }).click();
  await page.getByRole('button', { name: SECOND }).click();

  await expect(page.getByText('Overlaps with Caching render arrays.')).toBeVisible();
  await expect(page.getByText('Overlaps with Theming with SDC.')).toBeVisible();
  await expect(page.getByRole('status')).toHaveText('1 time conflict in your agenda.');

  await page.reload();
  await expect(page.getByRole('button', { name: FIRST })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByRole('button', { name: SECOND })).toHaveAttribute('aria-pressed', 'true');
});

test('the keyboard path keeps focus and announces the conflict once', async ({ page }) => {
  await page.evaluate(() => {
    const status = document.querySelector('[role="status"]');
    (window as any).announced = [];
    new MutationObserver(() => (window as any).announced.push(status.textContent)).observe(status, { childList: true, characterData: true, subtree: true });
  });

  await tabTo(page, FIRST);
  await page.keyboard.press('Space');
  const first = page.getByRole('button', { name: FIRST });
  await expect(first).toHaveAttribute('aria-pressed', 'true');
  await expect(first).toBeFocused();

  await tabTo(page, SECOND);
  await page.keyboard.press('Space');
  await expect(page.getByRole('button', { name: SECOND })).toBeFocused();
  await expect(page.getByRole('status')).toHaveText('1 time conflict in your agenda.');
  expect(await page.evaluate(() => (window as any).announced)).toEqual(['1 time conflict in your agenda.']);
});
