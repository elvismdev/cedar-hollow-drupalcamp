import filter_group from './filter-group.twig';

export default {
  title: 'Components/Filter group',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A labelled group of filter options. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/filter-group)`,
      },
    },
  },
  render: (args) => filter_group(args),
};

export const Default = { args: {"legend": "Track", "options": "<label><input type=\"radio\" name=\"track\" checked> Any track</label><label><input type=\"radio\" name=\"track\"> Front end</label><label><input type=\"radio\" name=\"track\"> Back end</label>"} };
