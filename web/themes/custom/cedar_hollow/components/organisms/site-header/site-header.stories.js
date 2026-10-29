import site_header from './site-header.twig';

export default {
  title: 'Collections/Site header',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `The site name and main navigation. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/organisms/site-header)`,
      },
    },
  },
  render: (args) => site_header(args),
};

export const Default = { args: {"branding": "<a class=\"site-header__brand-link\" href=\"/\" rel=\"home\">Cedar Hollow DrupalCamp</a>", "navigation": "<nav aria-label=\"Main\"><div class=\"main-menu\"><details class=\"main-menu__disclosure\"><summary class=\"main-menu__toggle\">Menu</summary><ul class=\"main-menu__list main-menu__list--stacked\"><li class=\"main-menu__item\"><a class=\"main-menu__link\" href=\"/sessions\">Sessions</a></li><li class=\"main-menu__item\"><a class=\"main-menu__link\" href=\"/agenda\">Agenda</a></li></ul></details><ul class=\"main-menu__list main-menu__list--wide\"><li class=\"main-menu__item\"><a class=\"main-menu__link\" href=\"/sessions\">Sessions</a></li><li class=\"main-menu__item\"><a class=\"main-menu__link\" href=\"/agenda\">Agenda</a></li></ul></div></nav>"} };
