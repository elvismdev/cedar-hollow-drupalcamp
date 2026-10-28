// Stories follow uclahs/surface source/patterns/elements/readtime (GPL-2.0-or-later).
import readtime from './readtime.twig';

export default {
  title: 'Atoms/Read time',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `How long an article takes to read. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/readtime) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/elements/readtime)`,
      },
    },
  },
  render: (args) => readtime(args),
};

export const Default = { args: {"text": "5 min read"} };
