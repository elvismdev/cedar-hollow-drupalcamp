// Stories follow uclahs/surface source/patterns/components/callout (GPL-2.0-or-later).
import callout from './callout.twig';

export default {
  title: 'Components/Callout',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `An image with a title, teaser and button, stacked or side by side. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/callout) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/components/callout)`,
      },
    },
  },
  render: (args) => callout(args),
};

export const Stacked = { args: {"image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">", "heading": "Two days, three tracks", "teaser": "<p>Sessions on front end, back end and site building.</p>", "cta_text": "Browse sessions", "cta_url": "/sessions", "cta_variant": "primary", "layout": "stacked", "style": "default"} };
export const Horizontal = { args: {"image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">", "heading": "Build your own agenda", "teaser": "<p>Pick sessions and see time conflicts as you go.</p>", "cta_text": "Open the agenda", "cta_url": "/agenda", "cta_variant": "primary", "layout": "horizontal", "style": "default"} };
export const Quote = { args: {"image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">", "heading": "Components first", "teaser": "<p>One component set serves Storybook, Twig templates and Canvas.</p>", "layout": "stacked", "style": "quote"} };
