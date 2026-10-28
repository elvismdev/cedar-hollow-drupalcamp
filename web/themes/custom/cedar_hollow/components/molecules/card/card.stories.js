// Stories follow uclahs/surface source/patterns/components/card (GPL-2.0-or-later).
import card from './card.twig';

export default {
  title: 'Components/Card',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A content card for events, articles and pages. Ported from Surface; the footer slot is a Cedar Hollow addition for seat counts. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/molecules/card) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/components/card)`,
      },
    },
  },
  render: (args) => card(args),
};

export const EventCard = { args: {"image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">", "heading": "Leaders in the Field Seminar", "url": "#", "eyebrow": "Virtual", "date_text": "October 31, 2024 | 1:30 pm - 2:30 pm", "date_month": "Oct", "date_day": "31", "organization": "<a href=\"#\">Cedar Hollow School of Web Development</a>", "more_dates_url": "#"} };
export const ArticleCard = { args: {"image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">", "heading": "Recipes replace Features", "url": "#", "date_text": "October 31, 2024", "readtime": "5 min read"} };
export const PageCard = { args: {"image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">", "heading": "About this demo", "url": "#"} };
export const SessionCard = { args: {"heading": "Theming with SDC", "url": "/sessions/theming-with-sdc", "eyebrow": "Front end", "date_text": "Fri 12 Mar, 9:00am to 9:45am", "organization": "Hall A", "footer": "<p class=\"seats-indicator seats-indicator--open\">12 of 40 seats left</p>"} };
