// Stories follow uclahs/surface source/patterns/elements/breadcrumb (GPL-2.0-or-later).
import breadcrumb from './breadcrumb.twig';

export default {
  title: 'Atoms/Breadcrumb',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `The breadcrumb trail, fed by Drupal's breadcrumb template. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/breadcrumb) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/elements/breadcrumb)`,
      },
    },
  },
  render: (args) => breadcrumb(args),
};

export const Default = { args: {"breadcrumb": [{"url": "/", "text": "Home"}, {"url": "/sessions", "text": "Sessions"}, {"text": "Theming with SDC"}]} };
