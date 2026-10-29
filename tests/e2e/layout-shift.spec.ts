import { test, expect } from '../fixtures';

// The home page must not move on a phone while it loads: the menu collapses
// before first paint, and images reserve their space through width and
// height.
test('the home page does not shift on a phone', async ({ page }) => {
  await page.setViewportSize({ width: 412, height: 823 });
  await page.addInitScript(() => {
    (window as unknown as { shift: number }).shift = 0;
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as unknown as { value: number; hadRecentInput: boolean }[]) {
        if (!entry.hadRecentInput) (window as unknown as { shift: number }).shift += entry.value;
      }
    }).observe({ type: 'layout-shift', buffered: true });
  });
  await page.goto('/', { waitUntil: 'load' });
  // Let the behaviors attached after load run and any shift be recorded.
  await page.waitForTimeout(1000);
  const shift = await page.evaluate(() => (window as unknown as { shift: number }).shift);
  expect(shift).toBe(0);
});
