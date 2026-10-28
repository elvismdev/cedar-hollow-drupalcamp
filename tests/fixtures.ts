import { test as base, expect } from '@playwright/test';

/**
 * A test fails if the page logs a console error or throws.
 */
export const test = base.extend<{ consoleErrors: string[] }>({
  consoleErrors: [
    async ({ page }, use) => {
      const errors: string[] = [];
      page.on('console', (message) => {
        if (message.type() === 'error') errors.push(message.text());
      });
      page.on('pageerror', (error) => errors.push(error.message));
      await use(errors);
      expect(errors, 'browser console errors').toEqual([]);
    },
    { auto: true },
  ],
});

export { expect };

/**
 * Presses Tab until the focused element has the given accessible label.
 */
export async function tabTo(page, label: string, limit = 80): Promise<void> {
  for (let i = 0; i < limit; i += 1) {
    await page.keyboard.press('Tab');
    const current = await page.evaluate(() => document.activeElement?.getAttribute('aria-label') ?? document.activeElement?.textContent?.trim());
    if (current === label) return;
  }
  throw new Error(`Tab never reached "${label}"`);
}
