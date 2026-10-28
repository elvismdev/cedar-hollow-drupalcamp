import page_section from './page-section.twig';

export default {
  title: 'Layouts/Page section',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A width-constrained band of content with an optional heading. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/layouts/page-section)`,
      },
    },
  },
  render: (args) => page_section(args),
};

export const Wide = { args: {"heading": "Featured sessions", "width": "wide", "content": "<p>Content placed in the section.</p>"} };
export const Narrow = { args: {"width": "narrow", "content": "<p>A narrow column of text for reading.</p>"} };
