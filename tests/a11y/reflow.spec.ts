// WCAG 1.4.10 Reflow: at 320 CSS pixels wide (400 percent zoom of a 1280 pixel
// window) no page scrolls sideways.
import { test, expect } from "../fixtures";
test.use({ viewport: { width: 320, height: 640 } });
for (const path of ['/', '/agenda', '/about', '/sessions', '/sessions/caching-render-arrays', '/sitemap', '/user/login', '/try-canvas', '/credits', '/sessions/theming-with-sdc']) {
  test(`${path} reflows at 320 pixels`, async ({ page }) => {
    await page.goto(path);
    await page.waitForLoadState('networkidle');
    const [scroll, client] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
    expect(scroll, `${path} scrolls sideways at 320px`).toBeLessThanOrEqual(client);
  });
}
