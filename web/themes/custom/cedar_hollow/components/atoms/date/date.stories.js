// Stories follow uclahs/surface source/patterns/elements/date (GPL-2.0-or-later).
import date from './date.twig';

export default {
  title: 'Atoms/Date',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A date or date range with a calendar icon. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/date) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/elements/date)`,
      },
    },
  },
  render: (args) => date(args),
};

export const Default = { args: {"text": "November 23, 2023", "size": "default"} };
