// Stories follow uclahs/surface source/patterns/components/quote (GPL-2.0-or-later).
import quote from './quote.twig';

export default {
  title: 'Components/Quote',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A quotation with its author, with or without an image. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/quote) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/components/quote)`,
      },
    },
  },
  render: (args) => quote(args),
};

export const Media = { args: {"quote": "<p>Build the component once and every page builder can use it.</p>", "author": "A camp organiser", "image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">"} };
export const Text = { args: {"quote": "<p>Build the component once and every page builder can use it.</p>", "author": "A camp organiser"} };
