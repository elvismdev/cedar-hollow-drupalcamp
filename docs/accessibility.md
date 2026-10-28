# Accessibility

No conformance claim is made for this demo. This page records what was checked, with what, and what is still open.

## Automated checks

| Check | Tool | Pages | Result (2026-10-28, DDEV) |
| --- | --- | --- | --- |
| WCAG 2.2 A and AA rules | `@axe-core/playwright` 4.14.0 with tags `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa`, `wcag22aa` (`tests/a11y/a11y.spec.ts`) | Home, agenda, about, sessions listing, a session, its sign-up form, site map, log in | 0 violations on all 8 |
| Reflow (WCAG 1.4.10), the automated part of the 400 percent zoom check | Playwright at 320 CSS pixels wide (`tests/a11y/reflow.spec.ts`) | The same pages plus "Try Canvas here" | No page scrolls sideways |
| Keyboard path through the agenda builder | Playwright (`tests/e2e/agenda-builder.spec.ts`) | Agenda | Tab reaches each "Add to agenda" button, Space presses it, focus stays on it, and the status region announces the conflict once |
| Component accessibility while building | Storybook's accessibility panel (`@storybook/addon-a11y`) | Every story | Visual panel for reviewers; not a gate |
| Second opinion | `pa11y-ci` 5.0.0 (`npm run pa11y` in `tests/`) | The axe pages | Optional report |
| Third engine | Lighthouse 12.8.2 accessibility audit (desktop) | Agenda, on DDEV | 100 for accessibility and for best practices. Against the Pantheon sandbox Lighthouse runs as HeadlessChrome, which the edge refuses CSS and JavaScript, so that score is not used |

Each automated check was first shown to catch a known defect: axe reported `image-alt` and `color-contrast` for an image without alt text and light grey text injected into a page, and the reflow check failed with a 1000 pixel wide element injected.

## Manual checks

| Check | How | Result |
| --- | --- | --- |
| Skip link | Tab once on the home page, then Enter | The link is the first focus stop, is visible when focused, and moves focus to the main region |
| Agenda builder names | Accessibility tree in Chromium | Buttons read "Add to agenda: {session}" and links "Sign up: {session}", each starting with its visible text (WCAG 2.5.3) |
| Seat and pick states | Visual review | Full, wait list and picked states are shown in text or with a check mark, not by colour alone |
| Screen reader: Orca 42 on Linux with Chromium | Agenda builder, session listing, sign-up form, driven with real keystrokes; Orca's speech log recorded | Agenda: each button is announced as "Add to agenda: {session} toggle button not pressed", Space announces "pressed", and an overlap is announced once as "1 time conflict in your agenda." through the polite status region. Listing: heading navigation (H) reaches every session title. Sign-up: "Email entry required", then "Used only for this demo. Mail is never sent.", then "Save Registration push button". NVDA and VoiceOver were not run |
| Focus visibility | Tab to each button with a real keyboard and look at a screenshot | Fixed: ported Surface button styles cancelled the theme's focus ring, so focused buttons showed none. Now every button shows the theme's ring |

## Findings fixed during the checks

* Focused buttons, core form submits included, showed no focus ring; Surface's button `:focus` styles replaced it with a transparent outline. axe does not test focus visibility, so this came from tabbing through the page.

* The Forward link printed its icon with alt text equal to the link text, so screen readers heard the name twice. The link is now text only.
* The agenda builder's labels lost a space inside the flex button; the accessible name now comes from `aria-label`, starting with the visible text.

## Open findings

* On the sessions listing, session titles are level 3 headings directly under the level 1 page title, so a screen reader's heading list skips level 2.
