import { test, expect } from '../fixtures';
import { STORYBOOK_URL } from '../playwright.config';

// Drupal pages that render each component.
const PAGES: Record<string, string[]> = {
  '/sessions': ['card', 'eyebrow', 'title', 'date', 'seats-indicator', 'session-list'],
  '/sessions/theming-with-sdc': ['page-section', 'date-badge', 'session-meta', 'seats-indicator', 'speaker-byline'],
  '/': ['button', 'callout', 'card-grid', 'card', 'title', 'site-header', 'site-footer'],
  '/about': ['two-column', 'tag', 'callout', 'title'],
};

const classesOf = (block: string) => {
  const pattern = new RegExp(`^${block}(__[a-z0-9-]+)?(--[a-z0-9-]+)?$`);
  return [...document.querySelectorAll('[class]')]
    .flatMap((el) => [...el.classList])
    .filter((name) => pattern.test(name));
};

test('every BEM class Drupal renders for a component appears in one of its stories', async ({ page }) => {
  const index = await (await page.request.get(`${STORYBOOK_URL}/index.json`)).json();
  const stories = Object.values(index.entries) as { id: string; importPath: string; type: string }[];

  for (const [path, blocks] of Object.entries(PAGES)) {
    await page.goto(path);
    for (const block of blocks) {
      const drupal = new Set(await page.evaluate(classesOf, block));
      expect(drupal.size, `${block} on ${path}`).toBeGreaterThan(0);

      const storybook = new Set<string>();
      const ids = stories.filter((s) => s.type === 'story' && s.importPath.endsWith(`/${block}/${block}.stories.js`)).map((s) => s.id);
      expect(ids.length, `stories for ${block}`).toBeGreaterThan(0);
      const story = await page.context().newPage();
      for (const id of ids) {
        await story.goto(`${STORYBOOK_URL}/iframe.html?id=${id}&viewMode=story`);
        await story.locator('#storybook-root > *').first().waitFor();
        (await story.evaluate(classesOf, block)).forEach((c) => storybook.add(c));
      }
      await story.close();

      const missing = [...drupal].filter((c) => !storybook.has(c));
      expect(missing, `${block} classes rendered on ${path} but in no story`).toEqual([]);
    }
  }
});
