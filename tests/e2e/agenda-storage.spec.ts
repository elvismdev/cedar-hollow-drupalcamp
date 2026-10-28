import { test, expect } from '../fixtures';

test('picks work in memory when localStorage throws', async ({ page }) => {
  await page.addInitScript(() => {
    Storage.prototype.getItem = () => { throw new Error('blocked'); };
    Storage.prototype.setItem = () => { throw new Error('blocked'); };
  });
  await page.goto('/agenda');
  await expect(page.getByText('Your agenda is kept only until you leave this page.')).toBeVisible();
  const button = page.getByRole('button', { name: 'Add to agenda: Theming with SDC' });
  await button.click();
  await expect(button).toHaveAttribute('aria-pressed', 'true');
});
