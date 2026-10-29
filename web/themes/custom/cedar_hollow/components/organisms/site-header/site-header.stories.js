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

export const Default = { args: {"branding": "<a class=\"site-header__brand-link\" href=\"/\" rel=\"home\">Cedar Hollow DrupalCamp</a>", "navigation": "<nav aria-label=\"Main\"><ul class=\"menu\"><li class=\"menu__item\"><a class=\"menu__link\" href=\"/sessions\">Sessions</a></li><li class=\"menu__item\"><a class=\"menu__link\" href=\"/agenda\">Agenda</a></li></ul></nav>"} };
