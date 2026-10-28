import two_column from './two-column.twig';

export default {
  title: 'Layouts/Two columns',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `Primary and secondary columns that stack on small screens. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/layouts/two-column)`,
      },
    },
  },
  render: (args) => two_column(args),
};

export const Default = { args: {"ratio": "60-40", "primary": "<p>Primary column.</p>", "secondary": "<p>Secondary column.</p>"} };
