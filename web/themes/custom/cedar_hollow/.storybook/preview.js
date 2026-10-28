// Adapted from uclahs/surface .storybook/preview.js (GPL-2.0-or-later): the
// Drupal behaviors shim, the decorator that attaches behaviors after each
// render, and stories sorted by Atomic Design tier.
/** @type { import('@storybook/html-vite').Preview } */
import { useEffect } from 'storybook/preview-api';

import './drupal/drupal';
import './drupal/once';

// Global theme CSS in the order of the base library, imported from source.
import '../css/layers.css';
import '../css/reset.css';
import '../css/props/colors.css';
import '../css/props/sizes.css';
import '../css/props/fonts.css';
import '../css/props/borders.css';
import '../css/props/shadows.css';
import '../css/props/animations.css';
import '../css/props/easing.css';
import '../css/props/aspects.css';
import '../css/props/zindex.css';
import '../css/props/brand.css';
import '../css/tokens.css';
import '../css/base.css';
import '../css/prose.css';
import '../css/forms.css';
import '../css/page.css';
import '../css/block.css';

// Each component's CSS, which Drupal attaches per component.
import.meta.glob('../components/**/*.css', { eager: true });

// Theme behaviors, so stories exercise the same scripts as Drupal.
import '../js/menu-toggle.js';

// Every story's "Source on GitHub" link starts with this.
globalThis.REPO_URL = 'https://github.com/elvismdev/cedar-hollow-drupalcamp';

// Surface's theme variant, as Drupal sets it in preprocess_html.
document.documentElement.dataset.theme = 'surface';

export const decorators = [
  (storyFn) => {
    useEffect(() => Drupal.attachBehaviors(), []); // eslint-disable-line no-undef
    return storyFn();
  },
];

const preview = {
  parameters: {
    options: {
      storySort: { order: ['Atoms', 'Components', 'Collections', 'Layouts', 'Agenda builder', '*'] },
    },
    a11y: { test: 'todo' },
  },
};

export default preview;
