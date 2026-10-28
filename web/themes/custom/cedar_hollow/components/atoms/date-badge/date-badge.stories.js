// Stories follow uclahs/surface source/patterns/elements/date-badge (GPL-2.0-or-later).
import date_badge from './date-badge.twig';

export default {
  title: 'Atoms/Date badge',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `The month and day of an event. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/date-badge) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/elements/date-badge)`,
      },
    },
  },
  render: (args) => date_badge(args),
};

export const Default = { args: {"month": "Oct", "day": "31", "size": "default", "tone": "default"} };
export const Small = { args: {"month": "Mar", "day": "12", "size": "small", "tone": "default"} };
