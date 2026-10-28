import card_grid from './card-grid.twig';

export default {
  title: 'Collections/Card grid',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A responsive grid of cards. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/organisms/card-grid)`,
      },
    },
  },
  render: (args) => card_grid(args),
};

export const Three = { args: {"columns": "3", "items": "<article class=\"card\"><div class=\"card__content\"><div class=\"eyebrow\"><span class=\"eyebrow__text\">Front end</span></div><h3 class=\"card__title\"><a href=\"/sessions\" class=\"title__link\">Session 1</a></h3></div></article><article class=\"card\"><div class=\"card__content\"><div class=\"eyebrow\"><span class=\"eyebrow__text\">Front end</span></div><h3 class=\"card__title\"><a href=\"/sessions\" class=\"title__link\">Session 2</a></h3></div></article><article class=\"card\"><div class=\"card__content\"><div class=\"eyebrow\"><span class=\"eyebrow__text\">Front end</span></div><h3 class=\"card__title\"><a href=\"/sessions\" class=\"title__link\">Session 3</a></h3></div></article>"} };
