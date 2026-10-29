import { test, expect } from '../fixtures';

// The main menu needs no JavaScript: on a phone the links sit behind a
// native disclosure, on a wide screen they show in a row, and only one copy
// of the links is ever visible or in the accessibility tree.

test.describe('on a phone', () => {
  test.use({ viewport: { width: 412, height: 823 } });

  test('the menu opens and closes by click and by keyboard', async ({ page }) => {
    await page.goto('/');
    const nav = page.getByRole('navigation', { name: 'Main' });
    const toggle = nav.getByText('Menu', { exact: true });
    const sessions = nav.getByRole('link', { name: 'Sessions' });
    await expect(toggle).toBeVisible();
    await expect(sessions).toBeHidden();

    await toggle.click();
    await expect(sessions).toBeVisible();
    await expect(nav.getByRole('link', { name: 'Sessions' })).toHaveCount(1);
    await toggle.click();
    await expect(sessions).toBeHidden();

    await toggle.focus();
    await page.keyboard.press('Enter');
    await expect(sessions).toBeVisible();
  });
});

test.describe('on a phone when the theme script fails to load', () => {
  test.use({ viewport: { width: 412, height: 823 } });

  test('the menu still opens', async ({ page }) => {
    // Serve every script empty: scripting stays on, but no behavior runs.
    await page.route('**/*.js*', (route) => route.fulfill({ contentType: 'text/javascript', body: '' }));
    await page.goto('/');
    const nav = page.getByRole('navigation', { name: 'Main' });
    await nav.getByText('Menu', { exact: true }).click();
    await expect(nav.getByRole('link', { name: 'Sessions' })).toBeVisible();
  });
});

test.describe('on a phone without JavaScript', () => {
  test.use({ viewport: { width: 412, height: 823 }, javaScriptEnabled: false });

  test('the menu still opens', async ({ page }) => {
    await page.goto('/');
    const nav = page.getByRole('navigation', { name: 'Main' });
    await nav.getByText('Menu', { exact: true }).click();
    await expect(nav.getByRole('link', { name: 'Sessions' })).toBeVisible();
  });
});

test.describe('on a wide screen', () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test('the links show in a row with no toggle', async ({ page }) => {
    await page.goto('/');
    const nav = page.getByRole('navigation', { name: 'Main' });
    await expect(nav.getByText('Menu', { exact: true })).toBeHidden();
    await expect(nav.getByRole('link', { name: 'Sessions' })).toBeVisible();
    await expect(nav.getByRole('link', { name: 'Sessions' })).toHaveCount(1);
  });

  test('the main and footer menus are one named landmark each', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByRole('navigation', { name: 'Main', exact: true })).toHaveCount(1);
    await expect(page.getByRole('navigation', { name: 'Footer', exact: true })).toHaveCount(1);
    await expect(page.getByRole('navigation', { name: 'Main', exact: true }).getByRole('navigation')).toHaveCount(0);
  });
});
