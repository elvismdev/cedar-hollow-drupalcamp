import { defineConfig, devices } from '@playwright/test';

// DDEV serves this project on port 30001 locally.
export const BASE_URL = process.env.BASE_URL ?? 'https://cedar-hollow.ddev.site:30001';
export const STORYBOOK_URL = process.env.STORYBOOK_URL ?? `${BASE_URL}/themes/custom/cedar_hollow/storybook`;

// Pantheon sandboxes show a warning page unless this header is sent.
const bypass = { 'Deterrence-Bypass': '1' };

export default defineConfig({
  timeout: 60_000,
  reporter: [['list']],
  use: {
    ...devices['Desktop Chrome'],
    // The full Chromium build in its new headless mode. The default headless
    // shell's requests are refused on Pantheon sandboxes: CSS and JS come back
    // as 403 pages.
    channel: 'chromium',
    baseURL: BASE_URL,
    ignoreHTTPSErrors: true,
  },
  projects: [
    // Changes data (registrations), so DDEV only.
    { name: 'e2e', testDir: './e2e' },
    { name: 'a11y', testDir: './a11y', use: { extraHTTPHeaders: bypass } },
    // Storybook screenshots; run in the Playwright Docker image (npm run test:visual).
    { name: 'visual', testDir: './visual', use: { channel: undefined } },
    // Read-only, safe against Pantheon.
    { name: 'smoke', testDir: './smoke', use: { extraHTTPHeaders: bypass } },
  ],
});
