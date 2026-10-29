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

export const Default = { args: {"branding": "<a class=\"site-header__brand-link\" href=\"/\" rel=\"home\">Cedar Hollow DrupalCamp</a>", "navigation": "<nav class=\"main-menu\" aria-label=\"Main\"><button class=\"main-menu__toggle\" type=\"button\" aria-expanded=\"false\" aria-controls=\"main-menu\" data-menu-toggle>Menu</button><ul class=\"main-menu__list\" id=\"main-menu\"><li class=\"main-menu__item\"><a class=\"main-menu__link\" href=\"/sessions\">Sessions</a></li><li class=\"main-menu__item\"><a class=\"main-menu__link\" href=\"/agenda\">Agenda</a></li></ul></nav>"} };
