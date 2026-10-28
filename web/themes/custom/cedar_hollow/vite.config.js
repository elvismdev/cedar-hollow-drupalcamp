import { join } from 'node:path';
import { defineConfig } from 'vite';
import twig from 'vite-plugin-twig-drupal';

// The only Vite configuration; Storybook's html-vite framework reuses it.
export default defineConfig({
  plugins: [
    twig({
      // "cedar_hollow:card" resolves by searching this folder's tier
      // subfolders for card/card.twig, the same id Drupal's SDC uses.
      namespaces: { cedar_hollow: join(import.meta.dirname, 'components') },
    }),
  ],
  resolve: {
    alias: { react: 'preact/compat', 'react-dom': 'preact/compat' },
  },
  esbuild: { jsx: 'automatic', jsxImportSource: 'preact' },
});
