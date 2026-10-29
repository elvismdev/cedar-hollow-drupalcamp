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

export const Default = { args: {"legend": "Track", "options": "<div class=\"filter-group__option\"><input type=\"radio\" id=\"track-0\" name=\"track\" checked><label class=\"filter-group__label\" for=\"track-0\">Any track</label></div><div class=\"filter-group__option\"><input type=\"radio\" id=\"track-1\" name=\"track\"><label class=\"filter-group__label\" for=\"track-1\">Front end</label></div><div class=\"filter-group__option\"><input type=\"radio\" id=\"track-2\" name=\"track\"><label class=\"filter-group__label\" for=\"track-2\">Back end</label></div>"} };

export const WithHelpAndError = { args: {"legend": "Track", "required": true, "description_id": "track-description", "description": "Pick the track you want to follow.", "errors": "Choose a track.", "options": "<div class=\"filter-group__option\"><input type=\"radio\" id=\"track-h0\" name=\"track-h\" aria-describedby=\"track-description\"><label class=\"filter-group__label\" for=\"track-h0\">Front end</label></div>"} };
