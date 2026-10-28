import seats_indicator from './seats-indicator.twig';

export default {
  title: 'Atoms/Seats indicator',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `How many seats are left in a session, always as text. [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/atoms/seats-indicator)`,
      },
    },
  },
  render: (args) => seats_indicator(args),
};

export const Open = { args: {"remaining": 12, "capacity": 40, "state": "open", "text": "12 of 40 seats left"} };
export const Low = { args: {"remaining": 3, "capacity": 40, "state": "low", "text": "3 of 40 seats left"} };
export const Waitlist = { args: {"remaining": 0, "capacity": 1, "state": "waitlist", "text": "Full, wait list open"} };
export const Full = { args: {"remaining": 0, "capacity": 30, "state": "full", "text": "Full"} };
export const Unlimited = { args: {"capacity": 0, "state": "unlimited", "text": "Open seating"} };
