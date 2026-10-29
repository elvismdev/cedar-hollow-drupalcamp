/**
 * @file
 * Agenda builder: pick sessions, see time conflicts and live seat counts.
 *
 * A Canvas code component. Canvas maps `react` to Preact, and Storybook
 * aliases it the same way, so this file imports only from `react`. Seats come
 * from /api/agenda; picks are kept in the browser and never sent anywhere.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

const STORAGE_KEY = 'cedarHollow.agenda.v1';
const REFRESH_MS = 30000;
const LOW_THRESHOLD = 5;
const TIME_ZONE = 'America/New_York';
const DAYS = { fri: 'Friday', sat: 'Saturday' };

const sessionTime = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', timeZone: TIME_ZONE });
const clockTime = (date) => date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

/**
 * Seats display state, the same rule as the theme's SeatsSummary service.
 */
export function seatsState(session) {
  if (!session.open) return { state: 'closed', text: 'Sign-up closed' };
  if (session.capacity === 0) return { state: 'unlimited', text: 'Open seating' };
  if (session.remaining === 0) {
    return session.waitlist ? { state: 'waitlist', text: 'Full, wait list open' } : { state: 'full', text: 'Full' };
  }
  const text = `${session.remaining} of ${session.capacity} seats left`;
  return { state: session.remaining <= LOW_THRESHOLD ? 'low' : 'open', text };
}

/**
 * Returns each pair of picked sessions whose times overlap.
 *
 * Sessions that only touch (one ends as the next starts) do not conflict.
 */
export function findConflicts(sessions) {
  const pairs = [];
  for (let i = 0; i < sessions.length; i += 1) {
    for (let j = i + 1; j < sessions.length; j += 1) {
      const a = sessions[i];
      const b = sessions[j];
      if (Date.parse(a.start) < Date.parse(b.end) && Date.parse(b.start) < Date.parse(a.end)) {
        pairs.push([a, b]);
      }
    }
  }
  return pairs;
}

function conflictStatus(count) {
  if (count === 0) return 'No time conflicts.';
  return count === 1 ? '1 time conflict in your agenda.' : `${count} time conflicts in your agenda.`;
}

/**
 * Reads stored picks; returns null when storage cannot be used.
 */
function readPicks() {
  try {
    const stored = JSON.parse(window.localStorage.getItem(STORAGE_KEY) || '{"picks":[]}');
    return Array.isArray(stored.picks) ? stored.picks.filter(Number.isInteger) : [];
  } catch (error) {
    return null;
  }
}

function writePicks(picks) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ picks }));
    return true;
  } catch (error) {
    return false;
  }
}

export function AgendaBuilder({ heading, load }) {
  const [sessions, setSessions] = useState(null);
  const [loadedAt, setLoadedAt] = useState(null);
  const [failed, setFailed] = useState(false);
  const [storageOk, setStorageOk] = useState(true);
  const [picks, setPicks] = useState([]);
  const loadRef = useRef(load);
  loadRef.current = load;

  useEffect(() => {
    const stored = readPicks();
    if (stored === null) {
      setStorageOk(false);
    } else {
      setPicks(stored);
    }
  }, []);

  const refresh = useCallback(() => {
    return loadRef.current()
      .then((data) => {
        setSessions(data.sessions);
        setLoadedAt(new Date());
        setFailed(false);
      })
      .catch(() => setFailed(true));
  }, []);

  useEffect(() => {
    refresh();
    const timer = window.setInterval(() => {
      if (document.visibilityState === 'visible') refresh();
    }, REFRESH_MS);
    const onVisible = () => {
      if (document.visibilityState === 'visible') refresh();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [refresh]);

  // Drop stored picks for sessions the site no longer lists.
  useEffect(() => {
    if (!sessions) return;
    const ids = new Set(sessions.map((s) => s.id));
    setPicks((current) => {
      const kept = current.filter((id) => ids.has(id));
      return kept.length === current.length ? current : kept;
    });
  }, [sessions]);

  const togglePick = (id) => {
    setPicks((current) => {
      const next = current.includes(id) ? current.filter((p) => p !== id) : [...current, id];
      if (storageOk && !writePicks(next)) setStorageOk(false);
      return next;
    });
  };

  const picked = useMemo(
    () => (sessions || []).filter((s) => picks.includes(s.id)),
    [sessions, picks],
  );
  const conflicts = useMemo(() => findConflicts(picked), [picked]);
  const overlapsById = useMemo(() => {
    const map = new Map();
    conflicts.forEach(([a, b]) => {
      map.set(a.id, [...(map.get(a.id) || []), b.title]);
      map.set(b.id, [...(map.get(b.id) || []), a.title]);
    });
    return map;
  }, [conflicts]);

  // Announce conflicts only when the set of conflicting pairs changes, so
  // seat refreshes stay silent.
  const signature = conflicts.map(([a, b]) => `${a.id}-${b.id}`).join(',');
  const [status, setStatus] = useState(conflictStatus(0));
  useEffect(() => {
    setStatus(conflictStatus(conflicts.length));
  }, [signature]); // eslint-disable-line react-hooks/exhaustive-deps

  const days = useMemo(() => {
    const grouped = {};
    (sessions || []).forEach((s) => {
      (grouped[s.day] = grouped[s.day] || []).push(s);
    });
    return Object.entries(grouped);
  }, [sessions]);

  return (
    <section className="agenda-builder" aria-labelledby="agenda-builder-heading">
      <h2 id="agenda-builder-heading" className="agenda-builder__heading">{heading}</h2>

      <div className="agenda-builder__notices">
        {loadedAt && !failed && <p className="agenda-builder__freshness">Updated at {clockTime(loadedAt)}</p>}
        {failed && (
          <p className="agenda-builder__notice">
            {loadedAt
              ? `Seat counts could not be updated. Showing counts from ${clockTime(loadedAt)}.`
              : 'Sessions could not be loaded.'}
          </p>
        )}
        {!storageOk && <p className="agenda-builder__notice">Your agenda is kept only until you leave this page.</p>}
        <p className="agenda-builder__status" role="status">{status}</p>
      </div>

      {!sessions && !failed && <p className="agenda-builder__loading">Loading sessions…</p>}

      {days.map(([day, daySessions]) => (
        <div className="agenda-builder__day" key={day}>
          <h3 className="agenda-builder__day-heading">{DAYS[day] || day}</h3>
          <ul className="agenda-builder__list">
            {daySessions.map((session) => {
              const seats = seatsState(session);
              const isPicked = picks.includes(session.id);
              const overlaps = overlapsById.get(session.id) || [];
              return (
                <li className={`agenda-builder__session${isPicked ? ' is-picked' : ''}`} key={session.id}>
                  <div className="agenda-builder__details">
                    <p className="agenda-builder__time">
                      {sessionTime.format(Date.parse(session.start))} to {sessionTime.format(Date.parse(session.end))}
                    </p>
                    <h4 className="agenda-builder__title">
                      <a className="agenda-builder__title-link" href={session.url}>{session.title}</a>
                    </h4>
                    <p className="agenda-builder__meta">{session.room} · {session.track}</p>
                    <p className={`seats-indicator seats-indicator--${seats.state}`}>{seats.text}</p>
                    {overlaps.map((title) => (
                      <p className="agenda-builder__conflict" key={title}>Overlaps with {title}.</p>
                    ))}
                  </div>
                  <div className="agenda-builder__actions">
                    <button
                      type="button"
                      className="button button--outlined agenda-builder__pick"
                      aria-pressed={isPicked ? 'true' : 'false'}
                      aria-label={`Add to agenda: ${session.title}`}
                      onClick={() => togglePick(session.id)}
                    >
                      Add to agenda
                    </button>
                    {session.registerUrl && (
                      <a className="button button--primary" href={session.registerUrl} aria-label={`Sign up: ${session.title}`}>
                        Sign up
                      </a>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </section>
  );
}

export default function AgendaBuilderComponent({ heading }) {
  const load = () => fetch('/api/agenda', { credentials: 'same-origin' }).then((response) => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  });
  return <AgendaBuilder heading={heading} load={load} />;
}
