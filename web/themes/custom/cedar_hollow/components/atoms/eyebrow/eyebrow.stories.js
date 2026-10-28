// Stories follow uclahs/surface source/patterns/elements/eyebrow (GPL-2.0-or-later).
import eyebrow from './eyebrow.twig';

export default {
  title: 'Atoms/Eyebrow',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A short label above a title, optionally linked. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/eyebrow) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/elements/eyebrow)`,
      },
    },
  },
  render: (args) => eyebrow(args),
};

export const Default = { args: {"text": "This is a label", "url": "#", "tone": "default"} };
export const Text = { args: {"text": "Front end", "tone": "default"} };
