import tag from './tag.twig';

export default {
  title: 'Atoms/Tag',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A short label, such as a skill or a track. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/tag)`,
      },
    },
  },
  render: (args) => tag(args),
};

export const Default = { args: {"label": "Twig"} };
