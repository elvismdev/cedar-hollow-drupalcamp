import { join, sep } from 'node:path';
import { storybookTest } from '@storybook/addon-vitest/vitest-plugin';
import { playwright } from '@vitest/browser-playwright';
import { defineConfig } from 'vite';
import twig from 'vite-plugin-twig-drupal';

const agendaBuilderDir = join(import.meta.dirname, 'agenda-builder') + sep;

// Canvas runs code components with an import map that points `react` at
// Preact. Storybook rewrites `react` imports to its own React copy, so for the
// agenda builder's source only, the imports and the JSX runtime are pointed at
// Preact before that happens.
const preactForCodeComponents = {
  name: 'preact-for-code-components',
  enforce: 'pre',
  transform(code, id) {
    if (!id.startsWith(agendaBuilderDir) || !id.endsWith('.jsx')) return null;
    const rewritten = code.replace(/from (['"])react\1/g, "from 'preact/compat'");
    return { code: `/** @jsxImportSource preact */\n${rewritten}`, map: null };
  },
};

// The only Vite configuration; Storybook's html-vite framework reuses it.
export default defineConfig({
  plugins: [
    preactForCodeComponents,
    twig({
      // "cedar_hollow:card" resolves by searching this folder's tier
      // subfolders for card/card.twig, the same id Drupal's SDC uses.
      namespaces: { cedar_hollow: join(import.meta.dirname, 'components') },
      // Canvas's toSrcSet filter returns null for plain URLs, the only kind
      // stories pass, so Storybook registers it with that result.
      functions: {
        toSrcSet: (twigInstance) => twigInstance.extendFilter('toSrcSet', () => null),
      },
    }),
  ],
  esbuild: { jsx: 'automatic', jsxImportSource: 'react' },
  // Drupal core names global stylesheets *.module.css; keep their class names
  // as written instead of scoping them as CSS Modules.
  css: { modules: { generateScopedName: '[local]' } },
  // Prebundled up front: found mid-run, they make Vite reload the page and a
  // cold Storybook Test run loses the story files that were loading.
  optimizeDeps: {
    include: ['twig', 'drupal-attribute', 'drupal-twig-extensions/twig', 'preact/compat', 'preact/jsx-dev-runtime'],
  },
  // Storybook Test: every story runs as a test in headless Chromium, with this
  // file's Twig plugin, so it renders as it does in Storybook. The Storybook
  // MCP server's test-run tool runs the same project.
  test: {
    projects: [{
      extends: true,
      plugins: [storybookTest({ configDir: join(import.meta.dirname, '.storybook') })],
      test: {
        name: 'storybook',
        browser: {
          enabled: true,
          headless: true,
          provider: playwright(),
          instances: [{ browser: 'chromium' }],
        },
      },
    }],
  },
});
