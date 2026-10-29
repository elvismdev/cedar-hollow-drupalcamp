import speaker_byline from './speaker-byline.twig';

export default {
  title: 'Components/Speaker byline',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A speaker's name with an optional photo. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/speaker-byline)`,
      },
    },
  },
  render: (args) => speaker_byline(args),
};

export const Default = { args: {"name": "Alex Rivera"} };

export const WithPhoto = { args: {"name": "Alex Rivera", "image": "<img class=\"speaker-byline__img\" src=\"https://placehold.co/96x96/png\" alt=\"\" width=\"96\" height=\"96\">"} };
