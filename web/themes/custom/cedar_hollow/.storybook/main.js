// Adapted from uclahs/surface .storybook/main.js (GPL-2.0-or-later).
/** @type { import('@storybook/html-vite').StorybookConfig } */
const config = {
  stories: ['../components/**/*.stories.js', '../stories/**/*.stories.js'],
  addons: ['@storybook/addon-docs', '@storybook/addon-a11y', '@storybook/addon-mcp'],
  framework: { name: '@storybook/html-vite', options: {} },
};

export default config;
