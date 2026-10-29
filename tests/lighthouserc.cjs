// Lighthouse CI: the default mobile configuration, performance only, five
// runs per page, asserted on the median run. Runs against BASE_URL (DDEV by
// default) with Playwright's Chromium, so no separate Chrome is needed.
const { chromium } = require('@playwright/test');

const base = (process.env.BASE_URL ?? 'https://cedar-hollow.ddev.site:30001').replace(/\/$/, '');
const pages = ['/', '/sessions', '/sessions/caching-render-arrays'];

module.exports = {
  ci: {
    collect: {
      url: pages.map((path) => base + path),
      numberOfRuns: 5,
      chromePath: process.env.CHROME_PATH ?? chromium.executablePath(),
      settings: {
        onlyCategories: ['performance'],
        chromeFlags: '--headless=new --ignore-certificate-errors',
      },
    },
    assert: {
      assertMatrix: [
        {
          matchingUrlPattern: '.*',
          aggregationMethod: 'median-run',
          assertions: {
            'largest-contentful-paint': ['error', { maxNumericValue: 2500 }],
            'cumulative-layout-shift': ['error', { maxNumericValue: 0.1 }],
          },
        },
        {
          matchingUrlPattern: '.*',
          aggregationMethod: 'median-run',
          assertions: {
            'largest-contentful-paint': ['warn', { maxNumericValue: 2000 }],
          },
        },
      ],
    },
    upload: { target: 'filesystem', outputDir: 'perf/reports' },
  },
};
