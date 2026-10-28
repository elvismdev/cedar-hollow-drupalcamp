import session_list from './session-list.twig';

export default {
  title: 'Collections/Session list',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A list of session cards with an empty message. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/organisms/session-list)`,
      },
    },
  },
  render: (args) => session_list(args),
};

export const WithItems = { args: {"items": "<article class=\"card\"><div class=\"card__content\"><div class=\"eyebrow\"><span class=\"eyebrow__text\">Front end</span></div><h3 class=\"card__title\"><a href=\"/sessions\" class=\"title__link\">Session 1</a></h3></div></article><article class=\"card\"><div class=\"card__content\"><div class=\"eyebrow\"><span class=\"eyebrow__text\">Front end</span></div><h3 class=\"card__title\"><a href=\"/sessions\" class=\"title__link\">Session 2</a></h3></div></article>"} };
export const Empty = { args: {"items": "", "empty_text": "No sessions match these filters."} };
