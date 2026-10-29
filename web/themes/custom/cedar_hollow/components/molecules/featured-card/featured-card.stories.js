// Stories follow uclahs/surface source/patterns/components/featured-card (GPL-2.0-or-later).
import featured_card from './featured-card.twig';

export default {
  title: 'Components/Featured card',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A large card with an image and a call to action. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/featured-card) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/components/featured-card)`,
      },
    },
  },
  render: (args) => featured_card(args),
};

export const Event = { args: {"image": {"src": "https://placehold.co/768x512/png", "alt": "Placeholder image", "width": 768, "height": 512}, "heading": "Front end day", "url": "#", "eyebrow": "In-Person", "subtitle": "Two days of sessions on themes, components and site building.", "date_text": "March 12, 2027 | 9:00 AM to 5:00 PM", "cta_text": "See the full event", "cta_url": "/sessions", "cta_variant": "secondary", "more_dates_url": "#", "organization": "<a href=\"#\">Hall A</a>"} };
