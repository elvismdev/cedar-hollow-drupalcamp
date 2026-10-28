import { h, render } from 'preact';
import { AgendaBuilder } from '../agenda-builder/agenda-builder.jsx';
import '../agenda-builder/agenda-builder.css';
import fixture from './fixtures/agenda.json';

const mount = (load) => {
  const el = document.createElement('div');
  render(h(AgendaBuilder, { heading: 'Build your agenda', load }), el);
  return el;
};

export default {
  title: 'Agenda builder/Agenda builder',
  tags: ['autodocs'],
  parameters: {
    docs: {
      description: {
        component: `Canvas code component: pick sessions, see time conflicts and seat counts from /api/agenda (a fixed fixture here). [Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/agenda-builder)`,
      },
    },
  },
};

export const Default = { render: () => mount(() => Promise.resolve(fixture)) };

export const LoadFailed = { render: () => mount(() => Promise.reject(new Error('Offline'))) };
