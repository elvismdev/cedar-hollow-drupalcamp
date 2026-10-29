// Adapted from uclahs/surface .storybook/preview.js (GPL-2.0-or-later): the
// Drupal behaviors shim, the decorator that attaches behaviors after each
// render, and stories sorted by Atomic Design tier.
/** @type { import('@storybook/html-vite').Preview } */
import { useEffect } from 'storybook/preview-api';

import coreHiddenCss from '../../../../core/modules/system/css/components/hidden.module.css?inline';
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
import '../css/props/zindex.css';
import '../css/props/brand.css';
import '../css/tokens.css';
import '../css/base.css';
import '../css/prose.css';
import '../css/forms.css';
import '../css/page.css';

// Each component's CSS, which Drupal attaches per component.
import.meta.glob('../components/**/*.css', { eager: true });

// The main menu's stylesheet, which its library attaches in Drupal.
import '../css/main-menu.css';

// Every story's "Source on GitHub" link starts with this.
globalThis.REPO_URL = 'https://github.com/elvismdev/cedar-hollow-drupalcamp';

// Core's .visually-hidden, which Drupal pages load from the system module.
// Vite treats *.module.css as a CSS Module, so the file is added as text.
const coreHidden = document.createElement('style');
coreHidden.textContent = coreHiddenCss;
document.head.prepend(coreHidden);


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
