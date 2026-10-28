// Stories follow uclahs/surface source/patterns/elements/title (GPL-2.0-or-later).
import title from './title.twig';

export default {
  title: 'Atoms/Title',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A heading at a chosen level, optionally linked. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/title) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/elements/title)`,
      },
    },
  },
  render: (args) => title(args),
};

export const Default = { args: {"text": "A vibrant, supportive culture is essential to advancing our mission.", "level": "2"} };
export const Linked = { args: {"text": "Theming with Single Directory Components", "level": "3", "url": "#"} };
export const SizeSmall = { args: {"text": "Theming with SDC", "level": "3", "size": "small", "url": "/sessions/theming-with-sdc"} };
export const SizeMedium = { args: {"text": "Two days, three tracks", "level": "2", "size": "medium"} };
export const SizeLarge = { args: {"text": "Build your agenda", "level": "3", "size": "large"} };
