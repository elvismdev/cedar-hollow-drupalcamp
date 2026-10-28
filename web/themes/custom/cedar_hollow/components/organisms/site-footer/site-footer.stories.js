import site_footer from './site-footer.twig';

export default {
  title: 'Collections/Site footer',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `Footer links and the demo notice. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/organisms/site-footer)`,
      },
    },
  },
  render: (args) => site_footer(args),
};

export const Default = { args: {"links": "<nav aria-label=\"Footer\"><ul><li><a href=\"/sitemap\">Site map</a></li><li><a href=\"/user/login\">Log in</a></li></ul></nav>", "notice": "Cedar Hollow DrupalCamp is a fictional event. This site is a demo."} };
