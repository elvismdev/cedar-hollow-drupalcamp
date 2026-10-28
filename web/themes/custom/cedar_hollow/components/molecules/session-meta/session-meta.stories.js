import session_meta from './session-meta.twig';

export default {
  title: 'Components/Session meta',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `When, where and in which track a session runs. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/session-meta)`,
      },
    },
  },
  render: (args) => session_meta(args),
};

export const Default = { args: {"time_range": "Fri 12 Mar, 9:00am to 9:45am", "room": "Hall A", "track": "Front end"} };
