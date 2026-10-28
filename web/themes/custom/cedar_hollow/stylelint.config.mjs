/** @type {import('stylelint').Config} */
export default {
  extends: ['stylelint-config-standard'],
  rules: {
    // BEM: block, block__element, block--modifier, block__element--modifier.
    'selector-class-pattern': '^[a-z][a-z0-9]*(-[a-z0-9]+)*(__[a-z0-9]+(-[a-z0-9]+)*)?(--[a-z0-9]+(-[a-z0-9]+)*)?$',
    'declaration-no-important': true,
    // Off: the rule compares nested selectors by their last compound only, so
    // Surface's prose rules for `pre > code::after` and `a.link::after`, which
    // never match the same element, are reported in either order. Cascade
    // order in this theme is set by @layer, not by source order.
    'no-descending-specificity': null,
  },
};
