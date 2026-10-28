// Stories follow uclahs/surface source/patterns/elements/button (GPL-2.0-or-later).
import button from './button.twig';

export default {
  title: 'Atoms/Button',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `A link, or a button when there is no URL. Ported from Surface. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/button) | [Surface original](https://github.com/uclahs/surface/tree/76e5dc6/source/patterns/elements/button)`,
      },
    },
  },
  render: (args) => button(args),
};

export const Default = { args: {"text": "Hi, I am a button", "url": "#", "variant": "default"} };
export const Primary = { args: {"text": "Browse sessions", "url": "/sessions", "variant": "primary"} };
export const Secondary = { args: {"text": "Build your agenda", "url": "/agenda", "variant": "secondary"} };
export const Outlined = { args: {"text": "About this demo", "url": "/about", "variant": "outlined"} };
export const Link = { args: {"text": "Read more", "url": "/about", "variant": "link"} };
export const NoUrl = { args: {"text": "A button element", "variant": "primary"} };
