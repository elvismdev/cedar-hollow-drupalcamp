import hero from './hero.twig';
import photo from '../../../stories/fixtures/images/shimla-cedars-16_9_640.avif';

export default {
  title: 'Components/Hero',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A full-width image at the top of the front page, rendered by the hero block type's template. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/hero)`,
      },
    },
  },
  render: (args) => hero(args),
};

export const Default = { args: {"image": `<img class="hero__img" src="${photo}" srcset="${photo} 640w" sizes="(min-width: 74rem) 72rem, calc(100vw - 2rem)" alt="Cedar trees on a hillside" width="640" height="360" loading="eager" fetchpriority="high">`} };

// The session page passes its image (the page media view mode, in the
// narrower content column) to the same component.
export const SessionImage = { args: {"image": `<img class="hero__img" src="${photo}" srcset="${photo} 640w" sizes="(min-width: 46rem) 44rem, calc(100vw - 2rem)" alt="Server racks with patch cables in a small machine room" width="640" height="360" loading="eager" fetchpriority="high">`} };
