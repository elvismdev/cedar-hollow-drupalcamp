// Stories follow uclahs/surface source/patterns/components/card (GPL-2.0-or-later).
import card from './card.twig';
import photo from '../../../stories/fixtures/images/shimla-cedars-3_2_400.avif';

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
export const SessionCardWithImage = { args: {"image": `<img class="card__img" src="${photo}" srcset="${photo} 400w" sizes="(min-width: 74rem) 23rem, (min-width: 59rem) calc((100vw - 5rem) / 3), (min-width: 39.5rem) calc((100vw - 3.5rem) / 2), calc(100vw - 2rem)" alt="" width="400" height="267" loading="eager">`, "heading": "Theming with SDC", "url": "/sessions/theming-with-sdc", "eyebrow": "Front end", "date_text": "Fri 12 Mar, 9:00am to 9:45am", "organization": "Hall A", "footer": "<p class=\"seats-indicator seats-indicator--open\">12 of 40 seats left</p>"} };
export const WithSummary = { args: {"heading": "Recipes replace Features", "url": "/sessions/recipes-in-practice", "eyebrow": "Site building", "summary": "Package a feature as a recipe and apply it to a fresh site.", "date_text": "Fri 12 Mar, 11:30am to 12:15pm"} };
export const WithTypeLabel = { args: {"image": "<img src=\"https://placehold.co/768x512/png\" alt=\"Placeholder image\" width=\"768\" height=\"512\">", "heading": "Leaders in the Field Seminar", "url": "/sessions", "eyebrow": "Virtual", "date_text": "October 31, 2024", "date_month": "Oct", "date_day": "31", "show_type": true} };
