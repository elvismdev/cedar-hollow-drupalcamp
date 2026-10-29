import speaker_byline from './speaker-byline.twig';
import photo from '../../../stories/fixtures/images/shimla-cedars-1_1_96.avif';

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

export const WithPhoto = { args: {"name": "Alex Rivera", "image": `<img class="speaker-byline__img" src="${photo}" srcset="${photo} 96w" sizes="3rem" alt="" width="96" height="96" loading="lazy">`} };
