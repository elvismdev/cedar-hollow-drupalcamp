# Cedar Hollow DrupalCamp: a Drupal 11 component-theme demo

*   **Author:** Elvis Morales
*   **Status:** Approved
*   **Date:** 2026-10-28

--------------------------------------------------------------------------------

## Overview

Cedar Hollow DrupalCamp is a small, fictional event site built on Drupal 11. Its purpose is to show, in working code that others can open and review, how an engineer with WordPress and Symfony/Twig experience builds a Drupal 11 site using Drupal's conventions for theming, site building, configuration and deployment.

The site has a theme of reusable components, written first in Storybook and then used by Drupal. Landing pages are assembled in Drupal Canvas, Drupal's component-based page builder, from those components. Session pages, the session listing, the sign-up form and the site map are rendered by Drupal's theme layer (Twig templates, template suggestions and preprocess hooks), using the same components. Attendees can browse sessions, build a personal agenda that warns about time conflicts and shows how many seats are left, and sign up through the Entity Registration module (`registration`, called Registration below), which manages capacity and a wait list.

The theme's workflow comes from Surface, an existing Drupal theme by UCLA Health whose components are built in Storybook with Twig and Vite. This site rebuilds the parts it needs in Drupal 11's own component format.

Four things are delivered: the live site on a free Pantheon sandbox, the published Storybook, a public GitHub repository, and a short write-up of how it was planned, built and verified with AI assistance. They are shared by email with a small group of reviewers, who also receive an editor login.

## The Problem

The reviewers are experienced Drupal engineers. They need to judge, in a short time, whether someone whose recent work is mostly WordPress can do senior Drupal front-end work. A résumé and interviews describe that ability; they do not demonstrate it.

What would demonstrate it is a build that touches each part of the job description:

*   component-based theming documented in Storybook,
*   Drupal's theme layer (templates, suggestions, libraries, render arrays, preprocess hooks),
*   site building (content types, fields, Views, displays, contributed modules),
*   configuration management, Composer, npm and Git,
*   accessible, responsive output,
*   tests on the flows that matter,
*   a deploy to a real host,
*   judgment about where AI tools help and where their output must be checked.

The work has to be built, deployed and shared within about one working day. The reviewers know Drupal well, so mistakes in Drupal conventions, cache handling or module configuration will be noticed. Anything that does not work is worse than leaving it out.

The proposed solution is a small site that uses each required skill once, in the place where Drupal expects it, and backs every claim in the write-up with something the reviewer can open: a page, a story, a test, a commit or a configuration file.

## Goals

Every goal below must ship; there is no stretch tier. Each goal names the check that shows it was met.

1.  **The site is live and reachable.** The Pantheon sandbox URL loads the home page, the session listing, a session page and the sign-up form for an anonymous visitor. Check: the Playwright smoke suite against Pantheon passes, the Drupal log shows no PHP errors, and the browser console shows no errors.
2.  **Storybook is published and matches Drupal.** The published Storybook contains every theme component in its tier (Atoms, Components, Collections, Layouts). Check: for each component, the BEM class list of its root and child elements is the same in the default story and on the Drupal page that uses it, ignoring the `data-component-id` attribute Drupal adds.
3.  **Components are Single Directory Components usable in Canvas.** Every theme component has a `*.component.yml` and appears in the Canvas component library, grouped by tier. At least the home page and one other landing page are built in Canvas from these components. Check: the Canvas library lists every component, and both pages render.
4.  **The theme layer renders the non-Canvas pages.** Session pages, the session listing and the sign-up form are rendered through Twig templates, template suggestions and preprocess hooks that pass data to the same components. Check: Twig debug output names each template, and each file is named in the write-up.
5.  **Seat counts are near-live.** After a registration is saved, the agenda builder shows the new seat count for that session within one poll interval (30 seconds), without a manual cache clear. Check: in DDEV, a PHPUnit test registers and requests `/api/agenda` again; on Pantheon, a read-only check confirms the response carries the session's Registration cache tag and a `Cache-Control` header that stops the edge from storing it.
6.  **A full session sends the next sign-up to the wait list.** When a session is full, the next sign-up is wait-listed and the page says so in text. Check: a PHPUnit functional test.
7.  **The agenda builder is accessible and works without storage.** It can be operated with the keyboard alone, announces time conflicts in text, and still works for the length of the visit when browser storage is blocked. Check: Playwright tests for the keyboard path and for a page where `localStorage` throws, plus the manual screen-reader check.
8.  **Automated accessibility scans pass.** axe-core with the `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa` and `wcag22aa` tags reports zero violations on the home, agenda, about, session listing, session, sign-up, site map and login pages. A manual keyboard, screen-reader and 400 percent zoom check is recorded.
9.  **Critical flows are tested.** PHPUnit tests cover sign-up, capacity and the wait list, the seats endpoint's response and cache tags, and the session page's seat cache tag. Playwright tests cover filtering the session list, adding sessions to the agenda and seeing a conflict, and reaching the sign-up form. Check: all pass in DDEV.
10. **The site rebuilds from the repository.** `drush site:install --existing-config`, then the `cedar_hollow_demo_content` recipe (which includes the Canvas pages), then `drush cr`, produces the demo site. Check: `drush config:status` reports no differences.
11. **The repository is documented and committed in small units.** A README explains how to run it in DDEV, where to look for each skill area, and what was verified and how. Check: the README has each of these sections, and each commit message describes one change.

## Non-Goals

*   **Sending real email.** All mail, including Registration confirmations and Forward messages, goes to Drupal's log. No mail service is configured.
*   **A production-grade product.** No payments, no Drupal Commerce, no search server (Solr), no multilingual content, no single sign-on.
*   **Storing attendee schedules on the server.** The personal agenda lives in the visitor's browser only. A schedule is lost on another device; that is accepted.
*   **Porting all of Surface.** Only the components the site needs are rebuilt. Surface's slider, icon font, UCLA branding and Layout Builder layouts are not carried over.
*   **The Features module.** Configuration management and recipes cover packaging; the write-up explains why Features is not used.
*   **A production CSS bundle.** Each component ships its own CSS file and Drupal aggregates CSS per page.
*   **Claiming WCAG or Section 508 conformance.** The site is tested against WCAG 2.2 AA, which also covers the WCAG 2.0 AA criteria Section 508 references, and the results are reported. No conformance claim is made.
*   **Supporting browsers without modern CSS.** Browsers without native CSS nesting, cascade layers and container queries are not targeted.
*   **Continuous integration and deployment.** Tests run in DDEV and deploys are run by hand with Git and Terminus. A CI workflow is listed under Future Improvements.
*   **Edge caching.** Drupal's page cache max-age stays 0, so Pantheon's edge does not store anonymous pages. A demo with a handful of visitors does not need it, and it would make seat counts harder to keep fresh.

## Open Questions

*   **Code components in recipe default content.** Drupal.org issue #3580989 (open) reports that code component configuration is generated incorrectly during recipe install, so the agenda page in the content recipe may fail on a clean install. Resolved by spike: install the recipe on a fresh site and load the page.
*   **Does a configuration import write the code component's asset file?** Drupal.org issue #3591075 (open). Resolved by spike: after `drush deploy` on a clean database, request the agenda builder's script URL from the page source and expect HTTP 200.
*   **How does the agenda builder reach Canvas?** Pasted into the local Canvas editor from the repository's source file and exported to configuration, or pushed with the Canvas command-line tool (which also needs the `canvas_oauth` and `simple_oauth` modules). Resolved by spike; both outcomes keep the repository file as the source of truth.

## Critical User Journeys (CUJs)

### CUJ 1: An attendee plans a day and signs up

*   **Given**: An anonymous visitor on the published site, with sessions that have capacity set, and at least two sessions in the same time slot.
*   **When**: The visitor opens the session listing, filters by track, adds three sessions to their agenda (two of which overlap), and follows the sign-up link for one of them.
*   **Then**: The agenda shows the overlap as a text message that a screen reader announces once; each session shows its seats left; the sign-up form opens; after submitting it, the seat count for that session is lower when the agenda next loads.

### CUJ 2: A session fills up

*   **Given**: A session with one seat left (one seeded session is kept one seat from full; earlier reviewers may already have filled it, and the README says so).
*   **When**: Two visitors sign up one after the other.
*   **Then**: The first is registered; the second is placed on the wait list and told so on screen; the agenda shows the session as full with a wait list.

### CUJ 3: An editor builds a landing page

*   **Given**: A reviewer logged in with the shared editor account.
*   **When**: They open Canvas, add a component from the Atoms or Components group to the "Try Canvas here" page, change its text, and publish.
*   **Then**: The component renders with the theme's styles in the Canvas preview and on the published page, and the editor cannot create or edit code components, page templates or content templates.

### CUJ 4: A reviewer inspects a component

*   **Given**: A reviewer with the Storybook URL and the repository URL.
*   **When**: They open a component's story, look at its variants and accessibility panel, then follow the story's source link to its folder in the repository.
*   **Then**: The story renders the same BEM classes the Drupal site uses, the accessibility panel shows no violations, and the folder contains the component's `*.component.yml`, Twig template, CSS and story.

### CUJ 5: A developer rebuilds the site

*   **Given**: A clean clone of the repository and DDEV installed.
*   **When**: They follow the README's setup commands.
*   **Then**: The site installs with its configuration, the content recipe and its Canvas pages; the tests pass; `drush config:status` shows no differences.

## Technical Plan (Architecture)

### System overview

```text
                    Storybook (Vite, html renderer)
                    reads the same Twig, YAML and CSS files
                                  |
  web/themes/custom/cedar_hollow/components/<tier>/<name>/
     <name>.component.yml   <name>.twig   <name>.css   <name>.stories.js
                                  |
          +-----------------------+------------------------+
          |                                                |
  Drupal theme layer                               Drupal Canvas
  node--session--full and --teaser templates       landing pages (home, agenda,
  views listing + exposed form template            about,
  page.html.twig with header and footer            try Canvas here)
  OOP preprocess hooks
  (presenter templates include components)
          |                                                |
          +-----------------------+------------------------+
                                  |
                Drupal ^11.3: node types, fields, Views with
                Better Exposed Filters, Registration (+ wait
                list, confirmation), Smart Date, Sitemap, Forward,
                custom module cedar_hollow_core
                                  |
         /api/agenda JSON route  <---- loaded by the agenda builder
         (cache tags per session)      (Canvas code component, Preact
                                        with the React-compatible API)
                                  |
                    Pantheon sandbox (PHP 8.3, MariaDB 10.6),
                    frontend_build builds Storybook
```

### Repository layout

The repository starts from Pantheon's `drupal-11-composer-managed` upstream so its `composer.json`, scaffold and settings match the host. Core is `^11.3`, locked in `composer.lock`. Top-level areas:

*   `web/themes/custom/cedar_hollow/`: the theme, its components, Storybook configuration, the agenda builder's source and story, and the theme's own `package.json` and lock file.
*   `web/modules/custom/cedar_hollow_core/`: the small custom module (agenda route, mail logger, form alter, deploy hooks, PHPUnit tests).
*   `config/`: the configuration sync directory and the source of truth for site configuration (the upstream's `settings.pantheon.php` sets it to `../config`).
*   `recipes/`: the `cedar_hollow_sessions` and `cedar_hollow_demo_content` recipes.
*   `tests/`: Playwright tests and accessibility scan configuration.
*   `scripts/`: the rebuild script and the CSS check script.
*   `.ddev/`, `pantheon.yml`, `README.md`, `docs/`.

Kept out of the public repository through the root `.gitignore`, checked before the first push: `research/`, `concepts_brief.md`, `design_draft.md` and the review reports, because they describe the reviewers.

### Content model

*   **Session** (node type `session`): title, body, `field_session_time` (Smart Date range), `field_track` (term reference), `field_room` (plain text), `field_day` (list: `fri`, `sat`; used by the listing's day filter), `field_speakers` (reference to Speaker nodes), `field_registration` (Registration field, registration type `attendee`), `field_forward` (Forward field shown as a "send to a colleague" link).
*   **Speaker** (node type `speaker`): name as title, short bio, optional photo (core image field, rendered through a responsive image style that uses core's viewport-sizing breakpoint group, so it does not depend on the theme). The demo content seeds no photos.
*   **Track** (vocabulary `track`): Front end, Back end and Site building.
*   **Landing pages**: Canvas page entities (home, agenda, about the demo, try Canvas here).

Registration settings per session (capacity, open and close dates, wait list) are content entities, so they ship with the demo content recipe. Most sessions get generous capacity; one session is seeded one seat from full with the wait list on.

### Contributed modules, chosen by what the site needs

| Module | Why the site needs it |
| --- | --- |
| `canvas` 1.12 | Landing pages. |
| `registration` 3.4 with `registration_waitlist` and `registration_confirmation` | Sign-up, capacity, the wait list, and a confirmation message (logged) when a registration completes. |
| `smart_date` 4.3 | Session start and end times with readable ranges and time-zone handling. |
| `better_exposed_filters` 7.2 (BEF) | The session listing's filters (track and day) rendered as accessible radio and checkbox groups instead of select lists. |
| `sitemap` 8.x-2.6 | A site map page, which gives a second way to find pages (WCAG 2.4.5 Multiple Ways). |
| `forward` 4.0 | "Send this session to a colleague" on session pages. Mail is logged, and the write-up shows the log entry. |

Not used because the site has no need for them: Key (no secrets to store once mail is logged), Image Style Generate (a bulk admin tool with nothing to show here), Twig Attributes (SDC already passes and merges `attributes`), Features (replaced by configuration management and recipes), Pantheon Advanced Page Cache (the edge does not cache pages; see Non-Goals), maillog (a short custom mail plugin does the same with no extra module).

### Theme and components

*   **Model.** The theme follows Surface's workflow (Storybook with the html renderer, Vite, BEM class names, Atomic Design tiers) but every component is a Single Directory Component (SDC, Drupal core's component format): `components/<tier>/<name>/` with `<name>.component.yml`, `<name>.twig`, `<name>.css` and `<name>.stories.js`. Machine names are unique across tiers, because a component's ID ignores its folder.

| Atomic Design tier | Folder | Canvas group | CSS layer |
| --- | --- | --- | --- |
| Atoms | `components/atoms/` | `Atoms` | `atoms` |
| Molecules | `components/molecules/` | `Components` | `components` |
| Organisms | `components/organisms/` | `Collections` | `collections` |
| Templates | `components/layouts/` | `Layouts` | `layouts` |

Canvas reserves the group name `Elements` (Surface's name for atoms), so the atoms tier is named `atoms` throughout. The project's CSS rules (`css-atomic-bem`, an AI-agent skill used during the build) call this layer `elements`; this design overrides that.

*   **Initial component set.** Atoms: button, heading, eyebrow, date badge, tag, seats indicator. Molecules: card, session meta (time, room, track), speaker byline, callout, filter group. Organisms: card grid, session list, site header, site footer. Layouts: page section (a width-constrained band with an optional heading), two-column. Visually hidden text uses core's `.visually-hidden` class and is not a component.
*   **Props for Canvas.** Props are flat scalars or enums with a title and, when required, an example. Read in the Canvas 1.12.0 source: no `type: object` props (Canvas cannot store them), no `minLength`, and SDC `variants:` are ignored, so anything an editor chooses is an enum prop. Repeating or nested content goes in slots. Rich text in Canvas allows no headings, so headings are their own string props.
*   **CSS.** Standard CSS only: design tokens as custom properties in a global `tokens` library listed in the theme's `.info.yml` (so the Canvas preview loads it), each component's CSS in its own file inside `@layer` order (reset, tokens, base, atoms, components, collections, layouts, utilities), native nesting without `&__` concatenation, container queries for component layout, `:focus-visible`, `prefers-reduced-motion`. Core and contrib CSS is unlayered and therefore wins over layered rules; collisions are fixed with `libraries-override`, never `!important`.
*   **Build.** No theme CSS bundle: Drupal attaches each component's CSS where it is used and aggregates per page in production. Vite runs Storybook locally and builds the static Storybook. Linting (stylelint and a CSS checker script kept in `scripts/`) runs locally.
*   **Story source links.** Each story links to its component's folder on GitHub through a `parameters.docs` source link built from one repository URL constant in the Storybook configuration.

### Theme layer (Twig, suggestions, preprocess)

*   **Session full page.** `node--session--full.html.twig` is a presenter: it has no markup of its own beyond a wrapper and passes data to components through `include('cedar_hollow:...')` with `only`. Render arrays (body, the Registration link, Forward) go into component slots; scalar values prepared in preprocess go into props, because string props reject render arrays. The fields not printed individually are still rendered (for example `content|without(...)` in a wrapper), so their cache metadata is kept.
*   **Session teaser.** `node--session--teaser.html.twig` includes `card`. A Canvas content template for the teaser is optional: built only if the first Canvas spike shows the Smart Date and track fields map to `card`'s props, because a content template replaces the Twig template and skips preprocess for its view mode.
*   **Session listing.** A View (`sessions`, page display at `/sessions`) lists sessions in the teaser view mode with BEF filters. Its exposed form is themed through Views' own template suggestion (`views-exposed-form--sessions.html.twig`) if Twig debug shows Views offers it; a theme suggestion hook is written only if it does not.
*   **Preprocess.** A theme hook class (themes support OOP hooks from Drupal 11.3) implements `preprocess_node` for sessions: date badge parts, time range, room, track label and the seats summary. Seats come from the Registration host entity (`getSpacesRemaining()`), and preprocess adds the session's Registration list cache tag (`getRegistrationListCacheTag()`) along with the cache metadata of every entity it reads, because the host entity's own cache tags do not change when someone registers.
*   **Libraries.** Global libraries: tokens and base styles. Component libraries are generated by SDC. The agenda builder's script comes from Canvas.
*   **Header and footer.** `html.html.twig` renders the skip link; `page.html.twig` renders the landmark regions and the `site-header` and `site-footer` components on every front-end route, Canvas pages included. The main menu is a block in the header region rendered through `menu--main.html.twig` into the header's navigation slot, with a `Drupal.behaviors` toggle for small screens. No Canvas page template is used, so editors cannot change the chrome, and Twig debug shows `page.html.twig` on every page.

### Canvas

*   **Pages.** Home, agenda, "about this demo" and "try Canvas here" are Canvas pages built from theme components. The agenda page contains the agenda builder. "Try Canvas here" is the page reviewers may edit.
*   **Code component.** The agenda builder is a Canvas code component. Its source of truth is a JSX and CSS file in the theme's repository folder. It reaches Canvas through the path the spike selects and is deployed as configuration. It is never edited on Pantheon, because Drupal.org issue #3591147 reports that a configuration import deletes code components created on the target site.

### Agenda builder and the seats endpoint

*   **Data.** One read-only route, `GET /api/agenda`, in `cedar_hollow_core` returns every published session with its times, room, track, register URL, capacity, seats remaining and wait-list state, as a cacheable JSON response tagged with each session's Registration list cache tag.
*   **Freshness.** Drupal's internal page cache and dynamic page cache store the response and drop it when the session's Registration list cache tag is invalidated, which happens whenever a registration for that session is saved or deleted. Page max-age stays 0, so Pantheon's edge does not store it.
*   **Client behaviour.** The component loads `/api/agenda` on mount, every 30 seconds while the tab is visible, and when the tab becomes visible again. Seat counts update silently; a visible "updated at" time shows when they were last loaded. Picks are saved to `localStorage`; if storage is unavailable the component keeps picks in memory and says so in text.
*   **Conflicts.** Two picked sessions conflict when `a.start < b.end && b.start < a.end` (sessions that only touch do not conflict). A conflict is shown as text next to both sessions and announced once through a polite live region.
*   **Sign-up.** Each session links to Registration's own form. The component never creates registrations.
*   **Accessibility contract.** Pick and remove are native `<button>` elements with `aria-pressed`; full and wait-list states are shown in text, not colour alone; focus stays on the control the user pressed.
*   **Storybook.** The agenda builder has a story in the theme's `stories/` folder that imports the same JSX source (Vite aliases `react` to `preact/compat`) and renders it with a fixed JSON fixture, so reviewers can try it without the Drupal site.

### Mail

Every outgoing message (Registration confirmations, Forward) is written to Drupal's log instead of being sent, through a custom `#[Mail]` plugin in `cedar_hollow_core`, set as `system.mail`'s default interface on every environment. Forward sends through core mail when the default interface is not `php_mail`, so its messages are logged too. Registration confirmations are sent when a registration reaches the `complete` state: the `attendee` type's default state is `complete`, and the first spike confirms that wait-listed registrations get no confirmation.

### Configuration, recipes and default content

*   **Configuration sync** in `config/` holds all site configuration and is applied with `drush deploy` on every environment. Canvas regenerates its `canvas.component.*` configuration on cache rebuild, so it is exported after every SDC change.
*   **Recipe `cedar_hollow_sessions`** packages the session feature (content types, fields, vocabulary, Registration type, View) as a reusable recipe, with `uuid` and `_core` removed from every configuration file. It is not applied to the demo site, whose configuration already contains it; it is proven by the PHPUnit functional tests, which apply it in `setUp()` with core's `RecipeTestTrait` to build their test site. The write-up contrasts it with Features and WP-CFM, a WordPress plugin that stores site settings as files, which the author once maintained.
*   **Recipe `cedar_hollow_demo_content`** ships default content made with core's `content:export` script: tracks, speakers, sessions, registration settings and the Canvas pages. The first spike checks that registration settings attach to the right sessions after a clean install. If they do not, default capacity and wait-list settings move to the Registration field's default value (configuration) and per-session values are set by a deploy hook keyed by node UUID.

### Editor access for reviewers

A `demo_editor` role may create, edit and publish Canvas pages. It cannot edit page templates, content templates, sessions or speakers, and does not have `administer code components`, `access site reports`, any registration viewing or administration permission, text format administration, or user, role, module, theme or configuration administration. A check confirms it gets HTTP 403 on `/admin/reports/dblog` and on a session's registrations list. The exact Canvas permission names are confirmed against the installed Canvas at scaffold time.

### Deployment

*   **Local.** DDEV with PHP 8.3 and MariaDB 10.6 to match Pantheon, Node 22 for the theme.
*   **Repository setup.** The Pantheon sandbox is created first from the `drupal-11-composer-managed` upstream and its repository cloned; GitHub is added as the public `origin`, and Pantheon's Git stays as a second remote, so no force push is needed.
*   **Pantheon.** `pantheon.yml` sets the PHP and database versions and a `frontend_build` entry for the theme path with `node_version: 22`, whose build command builds the static Storybook into the theme folder. Ignore rules for the theme's `node_modules/` and build output live in the repository root `.gitignore`, because the upstream ignores `.gitignore` files under `web/`. After the first build, the Storybook URL and its `iframe.html` and `index.json` are requested to confirm they are served. If the platform build cannot build Storybook, the fallback is building it locally, removing its ignore rule and committing the static output.
*   **Flow.** Deploys are `git push pantheon main:master`, then `terminus workflow:wait <site>.dev` until the platform build finishes, then `terminus drush <site>.dev -- deploy -y`.
*   **Content.** Content is copied to Pantheon once, from DDEV, by database and files sync. Before the export, local test registrations are deleted; after the import, the admin password is reset to a strong value or user 1 is blocked.
*   **Before sharing.** The sandbox is woken, the read-only smoke and accessibility suite runs against it with the `Deterrence-Bypass: 1` header (which skips the sandbox warning page), a Pantheon backup is taken with the restore command written in the README, and the shared commit is tagged. The editor account is blocked when the review period ends.

### Testing

*   **PHPUnit** (in `cedar_hollow_core`, each functional test building its site by applying the `cedar_hollow_sessions` recipe): a functional test that signs up for a session with capacity 1, then signs up a second user and asserts the wait list; a functional test of `/api/agenda` checking the seat count changes after a registration and the response carries the session's Registration list cache tag; an assertion that the session page's `X-Drupal-Cache-Tags` header carries the same tag.
*   **Playwright** (in `tests/`): filter the session list by track; add two overlapping sessions in the agenda and read the conflict text; reload and check picks persisted; run with `localStorage` throwing and check the in-memory notice; follow the register link to the form; complete the keyboard-only path through the agenda builder. Tests fail on any browser console error.
*   **Accessibility.** Playwright with `@axe-core/playwright` scans the pages listed in Goal 8 with the `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa` and `wcag22aa` tags (axe's target-size rule is tagged only `wcag22aa`). This is the only automated gate. pa11y-ci may run as an optional second report. Storybook's accessibility addon is a visual panel for reviewers. A manual keyboard, screen-reader and 400 percent zoom checklist is recorded in `docs/`.
*   **Against Pantheon** only the read-only smoke and accessibility suite runs, so the demo's seats are not used up.

## Alternatives Considered

### Alternative A: Build every page in Canvas

*   **Pros**: One editing tool for the whole site.
*   **Cons**: Registration's sign-up form cannot be placed in Canvas 1.12 (its only block shows status and needs an entity context Canvas does not provide). Views listings and the site map are routes, not Canvas pages. It would also hide the Twig templates, suggestions and preprocess hooks the job description asks for.
*   **Reason for Rejection**: Not possible for the sign-up flow, and it removes the theme-layer work the job description asks for.

### Alternative B: Keep Surface's namespaced Twig model (Components module) instead of SDC

*   **Pros**: Closest to Surface as published; less conversion work; Storybook setup already works.
*   **Cons**: Canvas offers only SDC (and its own code components) as components, so none of the theme would be usable in Canvas. Surface also declares no Drupal 11 support and needs the Components module.
*   **Reason for Rejection**: Incompatible with the Canvas goal and with Drupal 11's core component system.

### Alternative C: Layout Builder or Paragraphs instead of Canvas

*   **Pros**: Mature and widely known; no known blocking issues for this site's needs.
*   **Cons**: Neither uses SDC as its building block, so the Storybook components would need a second integration layer.
*   **Reason for Rejection**: Canvas uses the same component files as Storybook directly. The write-up explains when Layout Builder or Paragraphs would be the better choice.

### Alternative D: Tailwind, utility classes, Sass or PostCSS-only syntax

*   **Pros**: Less CSS to write per component; Tailwind is the default in Canvas code components and in two of the AI-agent skills used during the build.
*   **Cons**: Adds a required build step to every component; utility classes ("Atomic CSS") are a different idea from Atomic Design and work against BEM; PostCSS-only syntax such as custom media queries breaks when Drupal loads the CSS file unprocessed.
*   **Reason for Rejection**: The project requires standard CSS with BEM and Atomic Design, and standard CSS now covers nesting, layers and container queries without a build.

### Alternative E: One production CSS bundle built by Vite

*   **Pros**: A single file to inspect; full control of order and minification.
*   **Cons**: Loads every component's CSS on every page; duplicates Drupal's per-page aggregation; risks a component looking right on the site but unstyled in the Canvas preview, which loads each component's own CSS.
*   **Reason for Rejection**: Drupal already bundles per page; a second bundler adds work and a failure mode.

### Alternative F: The Features module for packaging configuration

*   **Pros**: Familiar to long-time Drupal developers; close in spirit to WordPress WP-CFM.
*   **Cons**: Features 8.x-3.17 is marked minimally maintained, and its project page points to recipes for most uses. Core configuration management already keeps a site's configuration in code.
*   **Reason for Rejection**: Configuration sync is the ongoing source of truth and recipes cover reusable packaging. The write-up explains the mapping from WP-CFM to configuration management, and from Features to recipes.

### Alternative G: JSON:API for the agenda builder's data

*   **Pros**: No custom PHP; a standard Drupal API.
*   **Cons**: JSON:API cannot return seats remaining (the Registration field stores only the registration type), so a second custom request is needed anyway; the client would also have to parse Smart Date's field structure and follow relationships for tracks.
*   **Reason for Rejection**: One small cacheable route returns exactly what the component needs, with cache tags that keep counts fresh.

### Alternative H: A Views REST export of Registration's `spaces_remaining` field

*   **Pros**: No custom controller; built in the Views UI.
*   **Cons**: The field returns display strings (for example "Unlimited") rather than numbers, and whether the export carries the per-session Registration cache tag is unverified.
*   **Reason for Rejection**: The custom route returns typed values with cache tags set explicitly and tested.

### Alternative I: Seat counts rendered at page load, without polling

*   **Pros**: No client polling, no extra requests; simpler tests.
*   **Cons**: Counts go stale while a visitor builds an agenda, which defeats the near-live requirement.
*   **Reason for Rejection**: Near-live counts are a requirement. Polling only while the tab is visible keeps the extra requests small.

### Alternative J: Core's date range field instead of Smart Date

*   **Pros**: In core; Canvas ships a matching shape for core date ranges, so a teaser content template could map times without custom work.
*   **Cons**: Less readable range formatting and no built-in handling for sessions within one day.
*   **Reason for Rejection**: Smart Date gives the range formatting the session pages need, and the teaser stays in Twig unless the spike shows the content template can map it.

### Alternative K: The agenda builder as a `Drupal.behaviors` script instead of a Canvas code component

*   **Pros**: The most Drupal-native way to add behaviour; no framework.
*   **Cons**: The agenda builder holds client state (picks, conflicts, loaded seat counts) that must re-render several parts of the page together; a component framework does that with less manual DOM code. A behaviour script cannot be placed by editors in Canvas, and the job description asks for JavaScript skills.
*   **Reason for Rejection**: The component's state justifies a component framework (Preact with the React-compatible API). Simpler behaviour elsewhere in the theme (for example a mobile menu toggle) uses `Drupal.behaviors` with `once`.

### Alternative L: Store the personal schedule on the server

*   **Pros**: Works across devices; could be shown to editors.
*   **Cons**: Needs login, a new entity or flag, a write route with CSRF protection and access control, and more tests.
*   **Reason for Rejection**: CUJ 1's visitor is anonymous, and a login requirement contradicts it; browser storage has no write route to secure.

### Alternative M: Playwright replaced by agent-browser, or Drupal's Nightwatch

*   **Pros**: agent-browser suits an AI agent checking pages during development; Nightwatch is what Drupal core uses.
*   **Cons**: agent-browser's accessibility command exits 0 even when it finds violations, and it is not a test runner with assertions and reports. Nightwatch needs a WebDriver setup that Playwright does not.
*   **Reason for Rejection**: Playwright with axe is the committed test suite run in DDEV; agent-browser is used while building to look at pages; PHPUnit covers Registration logic.

### Alternative N: Publish Storybook on GitHub Pages

*   **Pros**: Independent of Pantheon's build and of the sandbox being awake.
*   **Cons**: A second host and URL, and a workflow to maintain.
*   **Reason for Rejection**: Serving Storybook from the theme folder keeps one host and origin; a committed static build is the fallback if the platform build fails.

### Alternative O: A decoupled front end (Next.js, or Pantheon's P1)

*   **Pros**: Matches Pantheon's decoupled offering (P1, Pantheon's hosted front-end product, in paid beta); React throughout.
*   **Cons**: Moves the work away from Drupal's theme layer, which is what the job description is about; adds a second application to host.
*   **Reason for Rejection**: The job is Drupal theming. The write-up mentions when decoupling is worth it.

### Alternative P: Real email through a mail service

*   **Pros**: Reviewers could receive a confirmation.
*   **Cons**: Needs an account, a verified sender and a secret; public forms could send mail to any address.
*   **Reason for Rejection**: Logging every message shows the wiring without an outside dependency or abuse risk.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### Risks and mitigations

| Risk | Trigger | Impact | Mitigation | Check |
| --- | --- | --- | --- | --- |
| Sign-up abuse and seat exhaustion | Anyone, including crawlers, submits the public form | Sessions fill; CUJ 2 can no longer be shown | Generous seeded capacity; one session one seat from full, noted in the README; restoring the Pantheon backup resets seats, and the README documents one `drush` command that deletes registrations. Flood control is accepted as out of scope. | Restore command run once against a Pantheon backup before sharing |
| Attendee emails exposed | Reviewers type real addresses; logged mail includes recipients | One reviewer reads another's address | `demo_editor` has no log or registration viewing permissions; the email field says mail is never sent | 403 checks in Editor access |
| Editors break shared pages | The shared account edits chrome or session content | The site breaks for the next reviewer | `demo_editor` edits Canvas pages only; a backup and restore command exist before sharing | CUJ 3 |
| Local credentials on a public site | Database sync from DDEV | Weak admin password on a public URL | Reset admin password or block user 1 after import; delete local registrations before export | `terminus drush ... user:information admin` after import |
| Research files in the public repo | First push from the working folder | Reviewer-specific notes published | Root `.gitignore` excludes them; `git ls-files` checked before the first push | `git ls-files research concepts_brief.md` returns nothing |
| Code component asset missing | Configuration import does not write the script file (Drupal.org issue #3591075) | Agenda builder fails on a clean install or Pantheon | Spike checks the asset URL after `drush deploy`; fallback re-saves the component in a deploy hook | HTTP 200 on the script URL |
| Agenda page fails from the recipe | Drupal.org issue #3580989 | Goal 10 fails | Spike; fallback removes the agenda page from the content recipe and places the component after install | Clean install in DDEV |
| Sandbox asleep or showing its warning page | Inactivity; reviewers' first visit | Slow first load or a warning page | Wake the sandbox before sharing; README explains the warning page; screenshots kept if the sandbox is unavailable | Smoke suite run just before sharing |
| Schedule overrun | Spikes or Pantheon issues take longer than planned | Half-finished features; every goal is must-ship, so there is no stretch tier to cut | Each spike has a default if it fails (see each Open Question and fallback); work proceeds in the order of the Detailed Implementation Plan | Progress against the plan's phases |
| Overbooking the last seat | Two sign-ups submitted at the same moment | One extra registration | Accepted limit for a demo | None |

### Security and privacy

No secrets are stored in the repository. Mail is never sent. The only write surface for anonymous users is Registration's own form. The agenda route is read-only and needs `access content`.

### Performance

The agenda route returns one cached JSON document for all sessions; polling happens only while the tab is visible. Drupal's CSS and JS aggregation is on.

### Rollout and rollback

A Pantheon backup is taken before sharing and the restore command is in the README. The shared commit is tagged. Configuration changes go through `drush deploy`.

### Future Improvements

*   **Continuous integration**: A GitHub Actions workflow that lints CSS, builds Storybook and runs PHP lint and PHPCS with the Drupal standard, without deploying. It must pass `act --dryrun` before it is pushed.

### Additional Resources

*   Surface theme: https://github.com/uclahs/surface
*   Drupal Canvas project: https://www.drupal.org/project/canvas
*   Drupal.org issue #3580989 (code component config during recipe install): https://git.drupalcode.org/project/canvas/-/work_items/3580989
*   Drupal.org issue #3591075 (code component assets on config import): https://git.drupalcode.org/project/canvas/-/work_items/3591075
*   Drupal.org issue #3591147 (config import deletes code components): https://git.drupalcode.org/project/canvas/-/work_items/3591147
*   Entity Registration: https://www.drupal.org/project/registration
*   Features module status: https://www.drupal.org/project/features
*   Pantheon frontend builds: https://docs.pantheon.io/frontend-builds
*   Pantheon Drupal configuration workflow: https://docs.pantheon.io/drupal-configuration-management

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Paths are relative to the repository root. The theme machine name is `cedar_hollow`, the custom module is `cedar_hollow_core`, and `<site>` is the Pantheon site machine name chosen in item 0. Work proceeds phase by phase; each phase ends with the check named under it, and each logical change is one commit.

Reference implementations already checked against the installed versions are adapted, not rewritten. They come from the AI-agent skills used during the build; the adapted code lives in the files named in each item, so the repository does not depend on the skills. Source files, by skill:

*   Seats controller and route: `drupal-entity-registration/references/seats-endpoint.md`.
*   Registration and wait-list tests: `drupal-entity-registration/references/tests.md`.
*   Recipe layout: `drupal-recipes/references/camp_tracks/`.
*   `pantheon.yml`, DDEV parity and Terminus flow: `pantheon-drupal-ops/references/`.
*   Theme hook class and preprocess: `drupal-theme-layer/references/hooks.md`, `drupal-theme-layer/references/preprocess-and-suggestions.md`.
*   Storybook setup and Drupal shims: `drupal-storybook-theming/references/storybook-recipes.md`.
*   CSS examples and checker: `css-atomic-bem/references/example/`, `css-atomic-bem/scripts/check_css.py`.
*   Accessibility spec and patterns: `drupal-a11y-508/scripts/a11y.spec.ts`, `drupal-a11y-508/references/drupal-and-react-patterns.md`, `drupal-a11y-508/references/manual-checklist.md`.

### Contracts used by several items

#### C1. `/api/agenda` response

```json
{
  "generated": "2027-03-12T08:00:00-05:00",
  "sessions": [
    {
      "id": 12,
      "title": "Theming with SDC",
      "url": "/sessions/theming-with-sdc",
      "start": "2027-03-12T09:00:00-05:00",
      "end": "2027-03-12T09:45:00-05:00",
      "day": "fri",
      "room": "Hall A",
      "track": "Front end",
      "registerUrl": "/node/12/register",
      "capacity": 1,
      "remaining": 0,
      "full": true,
      "waitlist": true,
      "open": true
    }
  ]
}
```

| Key | Type | Rule |
| --- | --- | --- |
| `generated` | string, ISO 8601 | Time the response was built, site time zone. |
| `sessions` | array | Published sessions sorted by `start`, then `title`. |
| `id` | integer | Node ID. |
| `title`, `url`, `room`, `track` | string | `url` is `$node->toUrl()->toString(TRUE)->getGeneratedUrl()` (the `/sessions/<slug>` alias seeded in item 32); `track` is the term name (`field_track` has cardinality 1). |
| `start`, `end` | string, ISO 8601 | From `field_session_time`, formatted explicitly in `America/New_York`. |
| `day` | string | `field_day` value, `fri` or `sat`. |
| `registerUrl` | string or null | `Url::fromRoute('entity.node.registration.register', ['node' => id])->toString(TRUE)->getGeneratedUrl()`, with the `GeneratedUrl` cacheability added to the response; null when `open` is false. |
| `capacity` | integer | 0 means unlimited. |
| `remaining` | integer or null | `getSpacesRemaining()`; null when unlimited. |
| `full` | boolean | `remaining === 0`. |
| `waitlist` | boolean | `full` and the host is a wait-list host entity with the wait list enabled. |
| `open` | boolean | `isOpenForRegistration(TRUE)->isValid()`, with the result's cacheability added to the response. Seeded sessions have no open or close dates, so this does not change over time; the README says so. |

#### C2. Seats display state

One rule, implemented twice (PHP in item 22, JavaScript in item 29): `unlimited` when capacity is 0; `full` when remaining is 0 and the wait list is off; `waitlist` when remaining is 0 and the wait list is on; `low` when remaining is from 1 to 5; otherwise `open`. When `open` is false the state is `closed` regardless of seats. Text: `open` and `low` "{remaining} of {capacity} seats left"; `full` "Full"; `waitlist` "Full, wait list open"; `unlimited` "Open seating"; `closed` "Sign-up closed".

#### C3. Fixed values

*   Camp dates: Friday 12 March 2027 and Saturday 13 March 2027; site time zone `America/New_York`.
*   Breakpoints: tablet from 48em, desktop from 80em, used in `cedar_hollow.breakpoints.yml` and the CSS. Canvas previews at 375, 768 and 1280 pixels (`cedar_hollow.canvas.yml`).
*   Wait-list message on the form (Registration's own setting): "This session is full. Signing up adds you to the wait list." Message after a wait-listed sign-up (Registration's own text): "Registration placed on the wait list."
*   Email field description: "Used only for this demo. Mail is never sent."
*   Footer notice: "Cedar Hollow DrupalCamp is a fictional event. This site is a demo."
*   Agenda storage key `cedarHollow.agenda.v1`, value `{"picks":[<node id>, ...]}`. Storage notice: "Your agenda is kept only until you leave this page." Fetch failure notice: "Seat counts could not be updated. Showing counts from {time}." Freshness line: "Updated at {time}", the client time of the last successful fetch. `{time}` is `toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })`.
*   Conflict text next to each session in a conflict: "Overlaps with {other session title}." Status region: "{n} time conflicts in your agenda." ("1 time conflict in your agenda." for one) or "No time conflicts."
*   Registration confirmation: subject "Your Cedar Hollow sign-up"; body "You are signed up for [registration:host_entity:entity:title]. This is a demo; no mail is sent."
*   Speaker photo image styles (used only if a photo is added): `speaker_small` 192px and `speaker_large` 384px wide.

### Phase 0: Repository, environment and spikes

#### 0. Pantheon site and repository (no files)

*   **Proposed Changes**:
    1.  `terminus site:create <site> "Cedar Hollow DrupalCamp" drupal-11-composer-managed`, using the first free machine name of `cedar-hollow-demo`, `cedar-hollow-demo-2`, `cedar-hollow-demo-3`.
    2.  `terminus connection:set <site>.dev git`, then `git clone` the Dev repository URL from `terminus connection:info <site>.dev --field=git_url`.
    3.  `git remote rename origin pantheon`; `gh repo create elvismdev/cedar-hollow-drupalcamp --public`; `git remote add origin git@github.com:elvismdev/cedar-hollow-drupalcamp.git`. `REPO_URL` (items 23 and 26) is `https://github.com/elvismdev/cedar-hollow-drupalcamp`.
    4.  `git branch -m master main`; `git push -u origin main`. Pantheon's branch stays `master`, pushed with `git push pantheon main:master`.

#### 1. `composer.json`, `composer.lock` (Modify the upstream's)

*   **Type / Scope**: Composer project.
*   **Proposed Changes**: `composer require drupal/core-recommended:^11.3 drupal/canvas:~1.12.0 drupal/registration:~3.4.9 drupal/smart_date:^4.3 drupal/better_exposed_filters:~7.2.0 drupal/sitemap:^2.6 drupal/forward:~4.0.4` and `composer require --dev drupal/core-dev:^11.3`, first with `--dry-run -W`. If any package does not resolve, stop and update the design. Commit `composer.lock`.

#### 2. `.ddev/config.yaml` (Create)

*   **Type / Scope**: Local environment.
*   **Proposed Changes**: `name: cedar-hollow` (project URL `https://cedar-hollow.ddev.site`), `type: drupal11`, `docroot: web`, `php_version: "8.3"`, `database: {type: mariadb, version: "10.6"}`, `nodejs_version: "22"`. `web_environment`: `SIMPLETEST_DB=mysql://db:db@db/db`, `SIMPLETEST_BASE_URL=http://web`, `BROWSERTEST_OUTPUT_DIRECTORY=/var/www/html/web/sites/simpletest/browser_output`, `DDEV_PANTHEON_SITE=<site>`, `DDEV_PANTHEON_ENVIRONMENT=dev`.

#### 3. `pantheon.yml` (Create)

*   **Type / Scope**: Host configuration.
*   **Proposed Changes**:

    ```yaml
    api_version: 1
    php_version: 8.3
    database:
      version: 10.6
    frontend_build:
      enabled: true
      paths:
        - path: web/themes/custom/cedar_hollow
          node_version: 22
          build_command: build
    ```

    `build_step: true` is already set by the upstream's `pantheon.upstream.yml` and is not repeated.

#### 4. `.gitignore` (Modify the upstream's)

*   **Type / Scope**: Repository hygiene.
*   **Proposed Changes**: add `web/themes/custom/cedar_hollow/node_modules/`, `web/sites/default/local.services.yml`, `web/themes/custom/cedar_hollow/storybook/`, `tests/node_modules/`, `test-results/`, `playwright-report/`, `a11y-results/`, `.ddev/config.local.yaml`, `web/sites/default/settings.local.php`, `/research/`, `/concepts_brief.md`, `/design_draft.md`, `/*_report.md`. Rules live here because the upstream ignores `.gitignore` files under `web/`. If the Storybook fallback in item 41 step 6 is used, the `storybook/` rule is removed.

#### 5. `web/sites/default/settings.php` (Modify) and `web/sites/default/settings.local.php` (Create, ignored)

*   **Type / Scope**: Drupal settings.
*   **Proposed Changes**: `settings.php` sets `$settings['config_sync_directory'] = '../config';` (Pantheon's `settings.pantheon.php` sets the same path only on Pantheon), adds `$settings['container_yamls'][] = __DIR__ . '/services.yml';` if the upstream file does not already load it, and includes `settings.local.php` when present. `settings.local.php` (ignored) adds `$settings['container_yamls'][] = __DIR__ . '/local.services.yml';`; `local.services.yml` (ignored) sets `parameters: twig.config: {debug: true, auto_reload: true, cache: false}`. The README tells a fresh clone to create both from the examples in `docs/`.

#### 6. `web/sites/default/services.yml` (Create)

*   **Type / Scope**: Container parameters, committed.
*   **Proposed Changes**: `parameters: http.response.debug_cacheability_headers: true`, so `X-Drupal-Cache-Tags` and `X-Drupal-Cache-Contexts` are visible on DDEV and Pantheon for Goal 5's read-only check. It exposes cache tags only.

#### 7. Spikes and `docs/spikes.md` (Create)

*   **Type / Scope**: Go or no-go checks in DDEV on a scratch install (`ddev snapshot --name=pre-spike` first, `ddev snapshot restore pre-spike` after). Each result is recorded in `docs/spikes.md` with the command and outcome.

| Spike | Check | If it fails |
| --- | --- | --- |
| (a) | An SDC with `group: Atoms` appears in the Canvas library at `/admin/appearance/component/status` with no rejection. | Read the rejection reason and fix the component metadata before Phase 3. |
| (b) | A code component pasted into the local Canvas code editor fetches a same-origin JSON route and renders on a published Canvas page. | Stop and update the design: the fallback is a Vite library build of the same JSX into `web/themes/custom/cedar_hollow/dist/agenda-builder.js`, attached by a `cedar_hollow_core` block plugin (`#[Block(id: 'cedar_hollow_agenda_builder')]`) placed on the `/agenda` Canvas page. |
| (c) | A recipe with a Canvas page containing that code component installs on a fresh site and the page renders (Drupal.org issue #3580989). | The agenda page leaves the content recipe; `cedar_hollow_core_deploy_place_agenda()` in `cedar_hollow_core.deploy.php` creates it after install. |
| (d) | After `drush deploy` on a clean database, the code component's script URL from the page source returns HTTP 200 (Drupal.org issue #3591075). | `cedar_hollow_core_deploy_resave_agenda_builder()` loads and saves the `agenda_builder` code component. |
| (e) | `registration_settings` exported as default content attach to their sessions after a clean install. | Defaults move to the `field_registration` default value (config) and `cedar_hollow_core_deploy_session_settings()` sets per-session values keyed by node UUID. |
| (f) | A wait-listed registration sends no confirmation mail (expected from source: confirmation is sent only when the registration is complete). | Record the observed behaviour in `docs/spikes.md`; `RegistrationCapacityTest` asserts it either way. |
| (g) | Twig debug on `/sessions` lists `views-exposed-form--sessions.html.twig`. | A `theme_suggestions_views_exposed_form_alter` hook adds it. |
| (h) | The registration form ID is `registration_attendee_register_form` (from `EntityForm::getFormId()`); core adds no form-ID template suggestion. | Use the observed form ID in items 13, 21 and 22. |
| (i) | A Storybook story resolves `include('cedar_hollow:card')` from `components/molecules/card/`. | The Twig plugin gets one namespace per tier folder. |
| (j) | Confirm the Canvas permission names for `demo_editor` (from `canvas.permissions.yml`: `create canvas_page`, `edit canvas_page`, `publish auto-saves`) and record the routes `DemoEditorAccessTest` checks: the page editor `/canvas/editor/canvas_page/{id}`, the code component auto-save route `/canvas/api/v0/config/auto-save/js_component/{id}`, and `/admin/appearance/component/status`. | Use the names and paths found. |

*   **Phase 0 check**: `ddev start` succeeds; `ddev composer install` succeeds; all spike results are written.

### Phase 1: Site building configuration

#### 8. `config/*.yml` (Create via `ddev drush config:export -y`)

*   **Type / Scope**: Configuration sync directory, site-building part only. Exported at the end of this phase. Theme-dependent configuration (default theme, blocks) is added in item 18a.
*   **Proposed Changes**:
    *   **First install**: `ddev drush site:install minimal -y --site-name='Cedar Hollow DrupalCamp'`, then `ddev drush pm:install` with the modules below and `ddev drush theme:install claro`.
    *   **Modules** (`core.extension`; this list is complete and `config:status` must match it): node, text, options, file, image, link, taxonomy, views, path, block, toolbar, menu_ui, menu_link_content, breakpoint, responsive_image, page_cache, dynamic_page_cache, dblog, canvas, registration, registration_waitlist, registration_confirmation, smart_date, better_exposed_filters, sitemap, forward. Admin theme `claro` (`system.theme` `admin: claro`).
    *   **Site**: `system.site` name "Cedar Hollow DrupalCamp", `page.front: /home`; `system.date` default time zone `America/New_York`; `system.performance` `cache.page.max_age: 0`, CSS and JS aggregation on.
    *   **Content types and fields**: `session` with `body`, `field_session_time` (Smart Date range, required), `field_day` (list string `fri|Friday`, `sat|Saturday`, required, cardinality 1), `field_track` (term reference to `track`, required, cardinality 1), `field_room` (`string`, required), `field_speakers` (node reference to `speaker`, unlimited), `field_registration` (Registration, type `attendee`), `field_forward` (Forward); `speaker` with `body` and `field_photo` (image, optional). Vocabulary `track`.
    *   **Displays**: session `full` (`field_registration` as `registration_link`, `field_forward` as `forward_link`, `field_speakers` as rendered entity in `teaser` view mode) and `teaser`; speaker `teaser` (`field_photo` as responsive image `speaker_photo`); image styles `speaker_small` and `speaker_large`; responsive image style `speaker_photo` with breakpoint group `responsive_image` (core's viewport sizing, `sizes: (min-width: 48em) 12rem, 6rem`), so it has no theme dependency; the registration form display for `attendee` includes the anonymous email field.
    *   **Registration**: `registration.type.attendee` with workflow `registration`, `defaultState: complete`, third-party `registration_confirmation` settings `enable: true`, `subject` and `message` (`value` and `format`) from C3; `field_registration` default value: `status` enabled, capacity 40, maximum spaces 1, multiple registrations off, wait list enabled, wait-list capacity 0 (unlimited), autofill off, wait-list message enabled with the text in C3; `workflows.workflow.registration` including the `waitlist` state added by `registration_waitlist`.
    *   **View** `sessions`: page display `/sessions`, teaser view mode, sort by `field_session_time` start, then title; exposed filters `field_track` (BEF radios, "Any track") and `field_day` (BEF radios, "Both days").
    *   **Mail**: `system.mail` `interface.default: cedar_hollow_logger` (exported after item 12 exists, at the end of Phase 2); `forward.settings` defaults, so Forward also mails through the logger.
    *   **Sitemap**: `sitemap.settings` path `sitemap`, showing the front page, `menu:main` and the `track` vocabulary.
    *   **Roles and permissions**: anonymous and authenticated: `access content`, `create attendee registration self`, `access sitemap`, `access forward`. `demo_editor`: the Canvas page permissions from spike (j), `access toolbar`, `view the administration theme`; no other administration, code component, page template, report, user or registration permission.
#### 8a. `recipes/cedar_hollow_sessions/recipe.yml` and `config/*.yml` (Create, modelled on `camp_tracks`)

*   **Proposed Changes**: `name: Cedar Hollow sessions`, `type: Site feature`; `install:` node, text, options, file, image, link, taxonomy, views, path, breakpoint, responsive_image, registration, registration_waitlist, registration_confirmation, smart_date, better_exposed_filters, forward; `config: { strict: false }` (as in `camp_tracks`, so the recipe applies on a site where Registration's workflow already exists); `config/` holds, copied from this phase's export with `uuid` and `_core` removed: the session and speaker types, fields, displays, the `speaker_small`, `speaker_large` and `speaker_photo` styles, the `track` vocabulary, the `attendee` registration type and `workflows.workflow.registration` with its `waitlist` state and transitions, and the `sessions` View. No `config.import` entry: when a recipe installs `registration`, its workflow is not created from `config/install`, so the recipe ships the exported workflow itself.

*   **Phase 1 check**: `ddev drush config:status` reports no differences; `/sessions` lists sessions created by hand and filters by track and day.

### Phase 2: Custom module `cedar_hollow_core`

#### 9. `web/modules/custom/cedar_hollow_core/cedar_hollow_core.info.yml` (Create)

*   **Proposed Changes**: `core_version_requirement: ^11.3`; dependencies `drupal:node`, `drupal:taxonomy`, `registration:registration`, `registration:registration_waitlist`, `registration:registration_confirmation`, `smart_date:smart_date`.

#### 10. `web/modules/custom/cedar_hollow_core/cedar_hollow_core.routing.yml` (Create)

*   **Proposed Changes**:

    ```yaml
    cedar_hollow_core.agenda:
      path: '/api/agenda'
      defaults:
        _controller: '\Drupal\cedar_hollow_core\Controller\AgendaController::list'
      methods: [GET]
      requirements:
        _permission: 'access content'
    ```

    No `_format` requirement.

#### 11. `web/modules/custom/cedar_hollow_core/src/Controller/AgendaController.php` (Create, adapted from `seats-endpoint.md`)

*   **Type / Scope**: Controller with dependency injection through `create()`.
*   **Proposed Changes**: Builds C1. Entity query with `accessCheck(TRUE)`, published sessions sorted by `field_session_time.value`, then `title`. For each session: host entity from the `registration_host_entity` handler's `createHostEntity($node)`; wait-list values only when the host is an instance of `Drupal\registration_waitlist\HostEntityInterface`. Returns a `CacheableJsonResponse` with cache metadata: `node_list:session`, each node, each host entity (`addCacheableDependency($host)`), each `getRegistrationListCacheTag()`, each track term, URL metadata from `toString(TRUE)`, the cacheability of `isOpenForRegistration(TRUE)`, and contexts `user.permissions` and `user.node_grants:view`. No `user` context. No `Cache-Control` override.

#### 12. `web/modules/custom/cedar_hollow_core/src/Plugin/Mail/LoggerMail.php` (Create)

*   **Type / Scope**: Mail plugin, `#[Mail(id: 'cedar_hollow_logger', label: new TranslatableMarkup('Cedar Hollow log mailer'))]`.
*   **Proposed Changes**: `format()` joins the body array into plain text; `mail()` writes recipient, subject and body to the `cedar_hollow_core` log channel and returns TRUE.

#### 13. `web/modules/custom/cedar_hollow_core/src/Hook/RegistrationFormHooks.php` (Create)

*   **Type / Scope**: OOP hook class.
*   **Proposed Changes**: `#[Hook('form_registration_attendee_register_form_alter')]` sets `$form['anon_mail']['widget'][0]['value']['#description']` to the C3 text.

#### 14. `web/modules/custom/cedar_hollow_core/cedar_hollow_core.deploy.php` (Create only for failed spikes)

*   **Type / Scope**: Drush deploy hooks.
*   **Proposed Changes**: Contains only the deploy hooks named in the "If it fails" column of spikes (c), (d) and (e). Not created when all three pass.

#### 15. PHPUnit tests in `web/modules/custom/cedar_hollow_core/tests/src/` (Create, adapted from `tests.md`)

*   **Type / Scope**: Functional tests (`BrowserTestBase`) and one kernel test.
*   **Proposed Changes**: Functional tests use `$defaultTheme = 'stark'` (except where noted), `$modules = ['cedar_hollow_core', 'page_cache', 'dynamic_page_cache']`, and call `$this->applyRecipe('../recipes/cedar_hollow_sessions')` in `setUp()` (the subprocess runs from `web/`), which builds the session type, fields and Registration configuration and also proves the recipe. Test sessions get registration settings with `status` enabled.
    *   `Functional/RegistrationCapacityTest.php`: a session with capacity 1 and the wait list on; user A signs up and the registration is `complete`; user B signs up and the registration is `waitlist`; the page shows "Registration placed on the wait list."; one confirmation mail for A and none for B (`getMails()` with the test mail collector).
    *   `Functional/AgendaEndpointTest.php`: anonymous `GET /api/agenda` twice and asserts `X-Drupal-Cache: HIT` on the second; the JSON matches C1's keys and types; creates a registration; requests again and asserts `remaining` dropped by exactly 1; asserts `X-Drupal-Cache-Tags` contains `registration_list.host_entity:node:<nid>` and `X-Drupal-Cache-Contexts` does not contain the exact context `user` (`user.permissions` and `user.node_grants:view` are expected).
    *   `Functional/SessionPageCacheTagTest.php` (`@group cedar_hollow_theme`, `$defaultTheme = 'cedar_hollow'`): the session page's `X-Drupal-Cache-Tags` contains the session's Registration list tag.
    *   `Functional/DemoEditorAccessTest.php` (`@group cedar_hollow_theme`, `$modules` adds `canvas` and `dblog`): `setUp()` creates the role from `config/user.role.demo_editor.yml` (decoded with `Yaml::decode`) and a Canvas page and a code component; a `demo_editor` user gets 403 on `/admin/reports/dblog`, `/node/<nid>/registrations`, the code component auto-save route and `/admin/appearance/component/status` (paths from spike (j)), and 200 on `/canvas/editor/canvas_page/<id>`.
    *   `Kernel/LoggerMailTest.php`: sets `cedar_hollow_logger` as the default interface, sends a mail through the mail manager, asserts the result is TRUE and a `cedar_hollow_core` log entry contains the subject.
*   **Phase 2 check**: `ddev exec vendor/bin/phpunit -c web/core --exclude-group cedar_hollow_theme web/modules/custom/cedar_hollow_core` passes.

### Phase 3: Theme `cedar_hollow`

#### 16. `web/themes/custom/cedar_hollow/cedar_hollow.info.yml` (Create)

*   **Proposed Changes**: `type: theme`, `core_version_requirement: ^11.3`, `base theme: false`, regions `header`, `highlighted`, `content`, `footer`, `libraries: [cedar_hollow/base]`.

#### 17. `web/themes/custom/cedar_hollow/cedar_hollow.libraries.yml` (Create)

*   **Proposed Changes**: `base` library with `css: base:` entries `css/layers.css` (weight -100), `css/reset.css`, `css/tokens.css`, `css/base.css`; `menu-toggle` library with `js/menu-toggle.js` and dependencies `core/drupal`, `core/once`.

#### 18. `web/themes/custom/cedar_hollow/cedar_hollow.breakpoints.yml` and `cedar_hollow.canvas.yml` (Create)

*   **Proposed Changes**: breakpoints `cedar_hollow.mobile` (`all and (max-width: 47.9375em)`), `cedar_hollow.tablet` (`all and (min-width: 48em)`), `cedar_hollow.desktop` (`all and (min-width: 80em)`), each with `label`, `weight` and `multipliers: [1x]`; `canvas.yml` `viewports:` mobile 375, tablet 768, desktop 1280.

#### 18a. Theme configuration (Create via `ddev drush config:export -y` at the end of Phase 3)

*   **Proposed Changes**: `system.theme` `default: cedar_hollow`; blocks in theme `cedar_hollow`: `cedar_hollow_messages` (`system_messages_block`, region `content`, weight -10), `cedar_hollow_page_title` (`page_title_block`, region `content`, weight -9), `cedar_hollow_local_tasks` (`local_tasks_block`, region `content`, weight -8), `cedar_hollow_content` (`system_main_block`, region `content`, weight 0), `cedar_hollow_main_menu` (`system_menu_block:main`, region `header`, level 1, depth 1), `cedar_hollow_footer_menu` (`system_menu_block:footer`, region `footer`).

#### 19. `web/themes/custom/cedar_hollow/css/layers.css`, `reset.css`, `tokens.css`, `base.css` (Create, adapted from the `css-atomic-bem` examples)

*   **Proposed Changes**: `layers.css` contains only `@layer reset, tokens, base, atoms, components, collections, layouts, utilities;`. Each component's CSS uses the layer in the design's tier table: `atoms/` uses `atoms`, `molecules/` uses `components`, `organisms/` uses `collections`, `layouts/` uses `layouts`. Every other theme and component CSS file also starts with the same statement, so the order holds whichever file loads first. Tokens: colours with text contrast at least 4.5:1 and non-text contrast at least 3:1, a `clamp()` type scale, spacing, radius and focus ring. Base: element defaults, skip-link styles. Core's `.visually-hidden` is not redefined.

#### 20. `web/themes/custom/cedar_hollow/js/menu-toggle.js` (Create)

*   **Proposed Changes**: `Drupal.behaviors.cedarHollowMenuToggle` using `once()`; a button toggles `aria-expanded` and the menu's visibility below the tablet breakpoint.

#### 21. `web/themes/custom/cedar_hollow/src/Hook/ThemeHooks.php` (Create, adapted from `drupal-theme-layer`)

*   **Type / Scope**: OOP theme hooks (Drupal 11.3).
*   **Proposed Changes**: `#[Hook('preprocess_node__session')]` for all view modes: sets `date_badge` (`day`, `month`), `time_range`, `room`, `track_label`, and `seats` (`remaining`, `capacity`, `state` from C2, text from C2) from `createHostEntity($node)`; adds the host entity, the track term and `getRegistrationListCacheTag()` to the render cache metadata. `#[Hook('preprocess_page')]` sets `demo_notice` to the C3 footer text and `site_name` from `system.site` `name` (with `config:system.site` as a cacheable dependency). `#[Hook('theme_suggestions_form_alter')]` adds `form__registration_attendee_register_form` for that form ID; `#[Hook('preprocess_form')]` for the same form sets `form_heading` to "Sign up: {session title}", taking the session from the route's `node` parameter and adding the `route` cache context and the node as a cacheable dependency. A Views exposed-form suggestion hook only if spike (g) failed.

#### 22. Theme templates in `web/themes/custom/cedar_hollow/templates/` (Create)

*   **Proposed Changes**:
    *   `layout/html.html.twig`: skip link to `#main-content`.
    *   `layout/page.html.twig`: `include('cedar_hollow:site-header', {branding: '<a href="' ~ path('<front>') ~ '" rel="home">' ~ site_name ~ '</a>', navigation: page.header}, only)`; `<main id="main-content">` containing `page.highlighted` and `page.content`; `include('cedar_hollow:site-footer', {notice: demo_notice, links: page.footer}, only)`. Used on every front-end route, Canvas pages included.
    *   `navigation/menu--main.html.twig`: the main menu list with the toggle button, attaching `cedar_hollow/menu-toggle`.
    *   `content/node--session--full.html.twig`: `page-section` with `heading` = title; its `content` slot holds, in order: `date-badge`, `session-meta` and `seats-indicator` (from preprocess), `content.field_speakers`, `content.body`, `content.field_registration`, `content.field_forward`; then the rest of `content` through `content|without('body', 'field_registration', 'field_forward', 'field_session_time', 'field_room', 'field_track', 'field_speakers', 'field_day')` so its cache metadata is kept.
    *   `content/node--session--teaser.html.twig`: `card` with `eyebrow` = track label, `heading` = title, `url` = node URL, slot `meta` = `session-meta`, slot `footer` = `seats-indicator`.
    *   `content/node--speaker--teaser.html.twig`: `speaker-byline`.
    *   `views/views-view--sessions.html.twig`: `session-list` with the rows in its `items` slot.
    *   `views/views-exposed-form--sessions.html.twig`: each exposed filter inside `filter-group` with `legend` = the filter's `#title`; the BEF element's own title display is set to invisible so legends do not nest.
    *   `form/form--registration-attendee-register-form.html.twig`: the form inside `page-section` with `heading` = `form_heading`.

#### 23. Components in `web/themes/custom/cedar_hollow/components/<tier>/<name>/` (Create)

*   **Type / Scope**: Single Directory Components, each with `<name>.component.yml`, `<name>.twig`, `<name>.css` and `<name>.stories.js`. `group` is the tier's Canvas group.

| Folder | Component | Props (type, required, values) | Slots |
| --- | --- | --- | --- |
| `atoms/` | `button` | `label` string required; `url` string `uri-reference`; `variant` enum `primary`, `secondary`, `link`; `size` enum `small`, `medium`, `large` | none |
| `atoms/` | `heading` | `text` string required; `level` enum `h2`, `h3`, `h4` | none |
| `atoms/` | `eyebrow` | `text` string required | none |
| `atoms/` | `date-badge` | `day` string required; `month` string required | none |
| `atoms/` | `tag` | `label` string required | none |
| `atoms/` | `seats-indicator` | `remaining` integer; `capacity` integer required; `state` enum `open`, `low`, `full`, `waitlist`, `unlimited` required; `text` string required | none |
| `molecules/` | `card` | `eyebrow` string; `heading` string required; `url` string `uri-reference` required; `summary` string | `meta`, `footer` |
| `molecules/` | `session-meta` | `time_range` string required; `room` string required; `track` string required | none |
| `molecules/` | `speaker-byline` | `name` string required | `image` |
| `molecules/` | `callout` | `heading` string required; `tone` enum `info`, `warning` | `body` |
| `molecules/` | `filter-group` | `legend` string required | `options` |
| `organisms/` | `card-grid` | `columns` string enum `'2'`, `'3'`, `'4'` | `items` |
| `organisms/` | `session-list` | `empty_text` string | `items` |
| `organisms/` | `site-header` | none | `branding`, `navigation` |
| `organisms/` | `site-footer` | none | `links`, `notice` |
| `layouts/` | `page-section` | `heading` string; `width` enum `narrow`, `wide`, `full` | `content` |
| `layouts/` | `two-column` | `ratio` enum `50-50`, `60-40`, `40-60` | `primary`, `secondary` |

*   Every prop and slot has a `title`; required props have `examples`. Each `*.stories.js` sets `title: '<Canvas group>/<Name>'` (for example `Components/Card`, giving the story ID `components-card--default`), `tags: ['autodocs']`, and `parameters.docs.description.component` to the markdown `[Source on GitHub](${REPO_URL}/tree/main/web/themes/custom/cedar_hollow/components/<tier>/<name>)`. Stories cover the default, each enum value, long text and empty optional values.

#### 24. `web/themes/custom/cedar_hollow/package.json`, `package-lock.json` (Create)

*   **Proposed Changes**: Dev dependencies, each the latest version on the day of the build and written exactly (no `^`): `storybook`, `@storybook/html-vite`, `@storybook/addon-a11y`, `@storybook/addon-docs`, `vite`, `vite-plugin-twig-drupal`, `twig-drupal-filters`, `@drupal/once`, `preact`, `stylelint`, `stylelint-config-standard`. Scripts: `"storybook": "storybook dev -p 6006"`, `"build": "storybook build -o storybook"`, `"lint:css": "stylelint 'components/**/*.css' 'css/**/*.css' && python3 ../../../../scripts/check_css.py components css"`. No husky `prepare` script, which fails on Pantheon's build host.

#### 25. `web/themes/custom/cedar_hollow/vite.config.js` (Create)

*   **Proposed Changes**: The only Vite configuration (html-vite reuses it): the Twig plugin with `namespaces: { cedar_hollow: join(__dirname, 'components') }` (adjusted by spike (i)); `resolve.alias` `{ react: 'preact/compat', 'react-dom': 'preact/compat' }`; `esbuild: { jsx: 'automatic', jsxImportSource: 'preact' }`. No library build of theme CSS.

#### 26. `web/themes/custom/cedar_hollow/.storybook/main.js`, `preview.js`, `drupal/drupal.js`, `drupal/once.js` (Create, adapted from `storybook-recipes.md`)

*   **Proposed Changes**: stories from `../components/**/*.stories.js` and `../stories/**/*.stories.js`; addons `@storybook/addon-docs` and `@storybook/addon-a11y` (a panel with no test integration); the preview loads the global CSS; `drupal/drupal.js` defines `window.Drupal` with `behaviors` and `attachBehaviors(context)`; `drupal/once.js` exposes `@drupal/once` as `window.once`; a decorator calls `Drupal.attachBehaviors()` after render; `REPO_URL` constant for source links.

#### 27. `web/themes/custom/cedar_hollow/.stylelintrc.json` (Create)

*   **Proposed Changes**: extends `stylelint-config-standard`; `selector-class-pattern` `^[a-z][a-z0-9]*(-[a-z0-9]+)*(__[a-z0-9]+(-[a-z0-9]+)*)?(--[a-z0-9]+(-[a-z0-9]+)*)?$`; `declaration-no-important: true`.

#### 28. `scripts/check_css.py` (Create, copied from `css-atomic-bem`)

*   **Proposed Changes**: Copied unchanged (the checker has no tier or layer names).
*   **Phase 3 check**: `npm ci && npm run build && npm run lint:css` pass in the theme; `ddev drush cr && ddev drush config:export -y` and commit the `canvas.component.sdc.cedar_hollow.*` files and item 18a's configuration; `/admin/appearance/component/status` shows no rejected `cedar_hollow` component; Twig debug shows the templates in item 22; `ddev exec vendor/bin/phpunit -c web/core --group cedar_hollow_theme web/modules/custom/cedar_hollow_core` passes.

### Phase 4: Agenda builder

#### 29. `web/themes/custom/cedar_hollow/agenda-builder/agenda-builder.jsx`, `agenda-builder.css` (Create)

*   **Type / Scope**: The only source of the Canvas code component (Preact with the React-compatible API), following the patterns in `drupal-a11y-508/references/drupal-and-react-patterns.md`.
*   **Proposed Changes**:
    *   Imports only from `react`. Exports a named `AgendaBuilder({ heading, load })` and a default export that passes `load = () => fetch('/api/agenda', { credentials: 'same-origin' }).then((r) => r.json())`.
    *   Loads on mount, every 30000 ms while `document.visibilityState === 'visible'`, and on `visibilitychange` to visible.
    *   Picks stored under the C3 key; stored IDs missing from the response are dropped; if `localStorage` throws, picks stay in memory and the C3 storage notice is shown.
    *   On fetch failure, keeps the last data and shows the C3 failure notice; shows the C3 freshness line.
    *   Conflicts when `a.start < b.end && b.start < a.end`; the C3 conflict text next to each session in a conflict; one `role="status"` region with the C3 status text, changed only when the set of conflicting pairs changes; seat updates are not announced.
    *   Each session: a `<button>` with `aria-pressed` and a fixed label ("Add to agenda"); C2 state text; the register link when `registerUrl` is not null; focus stays on the pressed button.
    *   Styles use the theme's tokens through custom properties; no Tailwind.
*   **Delivery to Canvas**: `agenda-builder.jsx` is pasted into the local Canvas code editor's JavaScript field and `agenda-builder.css` into its CSS field, as component `agenda_builder` with prop `heading` (string, required, example "Build your agenda"), saved, and exported (spike (b)). The repository file stays the source; any change is made there first and pasted again.
*   **Phase 4 check**: `ddev drush config:export -y` and commit `canvas.js_component.agenda_builder` and its `canvas.component.*` entry; the agenda builder renders on a scratch Canvas page in DDEV; the item 30 story renders in Storybook.

#### 30. `web/themes/custom/cedar_hollow/stories/agenda-builder.stories.js`, `stories/fixtures/agenda.json` (Create)

*   **Proposed Changes**: The story imports the named `AgendaBuilder` and mounts it itself, because the html renderer accepts only a string or DOM node: `const el = document.createElement('div'); render(h(AgendaBuilder, { heading: 'Build your agenda', load: () => Promise.resolve(fixture) }), el); return el;`. The fixture follows C1 with two overlapping sessions, one full session with the wait list and one unlimited session.

### Phase 5: Recipes and content

#### 31. Canvas pages (Create in the local Canvas UI, published before export)

*   **Proposed Changes**:
    *   `/home`: `page-section` (wide, heading "Cedar Hollow DrupalCamp") holding a `callout` (info) and two `button`s ("Browse sessions" primary to `/sessions`, "Build your agenda" secondary to `/agenda`); a `card-grid` (3) of three `card`s, one per track, linking to `/sessions` filtered by that track.
    *   `/agenda`: `page-section` (wide) holding `agenda_builder` (heading "Build your agenda").
    *   `/about`: `two-column` (60-40) with a `heading`, a `callout` (warning) carrying the C3 footer notice, and a `tag` for each job-description skill shown.
    *   `/try-canvas`: `page-section` with one `heading` and one `callout`; the page reviewers may edit.

#### 32. `recipes/cedar_hollow_demo_content/recipe.yml` and `content/**` (Create)

*   **Proposed Changes**: Content: 3 tracks; 8 speakers; 12 sessions across 12 and 13 March 2027 with at least two overlapping pairs; each session aliased `/sessions/<slug>`; every `registration_settings` with `status` enabled; capacity 40 for every session except "Theming with SDC" (capacity 1, wait list on, no registrations); no open or close dates; no speaker photos (so no managed files to sync); main menu links Home, Sessions, Agenda, About, Try Canvas; footer menu links Site map (`/sitemap`) and Log in; the four Canvas pages from item 31. Exported with `ddev exec -d /var/www/html/web php core/scripts/drupal content:export <entity_type> <id> --with-dependencies --dir=../recipes/cedar_hollow_demo_content/content`, run for each `canvas_page`, `node`, `taxonomy_term`, `menu_link_content` and `registration_settings` entity (registration settings are linked by host ID, not by reference, so they are exported separately).

#### 33. `scripts/rebuild.sh` (Create)

*   **Proposed Changes**: `ddev composer install`; `ddev drush site:install minimal --existing-config -y`; `ddev drush recipe /var/www/html/recipes/cedar_hollow_demo_content`; `ddev drush deploy -y` (runs any deploy hooks from item 14); `ddev drush cr`; `ddev drush config:status`, which must report no differences.
*   **Phase 5 check**: `scripts/rebuild.sh` passes on a fresh DDEV database; every session has the capacity in item 32.

### Phase 6: End-to-end and accessibility tests

#### 34. `tests/package.json`, `tests/package-lock.json`, `tests/playwright.config.ts` (Create)

*   **Proposed Changes**: Run on the host, not in the container: `npm ci && npx playwright install --with-deps chromium`; single browser `chromium`. Dev dependencies `@playwright/test`, `@axe-core/playwright`, `pa11y-ci`, written exactly. `BASE_URL` defaults to `https://cedar-hollow.ddev.site`; `STORYBOOK_URL` defaults to `${BASE_URL}/themes/custom/cedar_hollow/storybook` (run `npm run build` in the theme first). Projects: `e2e` (DDEV only), `a11y` (DDEV and Pantheon), `smoke` (Pantheon, read-only). The `a11y` and `smoke` projects send `Deterrence-Bypass: 1`. A shared fixture fails a test on any browser console error.

#### 35. Playwright specs in `tests/` (Create)

*   **Proposed Changes**:
    *   `e2e/sessions-filter.spec.ts`: filter by track, then by day, and check the listed sessions.
    *   `e2e/agenda-builder.spec.ts` (CUJ 1's path: filter on `/sessions`, then add on `/agenda`): add two overlapping sessions, read the C3 conflict text, reload and check picks persisted; keyboard-only path: Tab to the "Add to agenda" button of the first session in an overlapping pair and press Space (`aria-pressed` becomes true, focus stays on it), Tab to the second session's button and press Space; the status region text changes once to the C3 conflict announcement.
    *   `e2e/agenda-storage.spec.ts`: `page.addInitScript` makes `localStorage.getItem` and `setItem` throw; the C3 storage notice appears and picks still work.
    *   `e2e/registration.spec.ts`: follow the register link for "Keynote" and submit the form; `afterAll` runs `execSync('ddev drush entity:delete registration -y')`, so reruns do not exhaust capacity.
    *   `e2e/bem-parity.spec.ts`: for each component, compare the sorted class lists of elements whose class starts with the component's block name, between `${STORYBOOK_URL}/iframe.html?id=<group>-<name>--default` and a Drupal page that uses it, ignoring `data-component-id`: `/sessions` for card, session-meta, seats-indicator, session-list, filter-group; the "Theming with SDC" session page for page-section, date-badge, speaker-byline; `/home` for button, callout, card-grid, heading, site-header, site-footer; `/about` for eyebrow, tag, two-column.
    *   `smoke/smoke.spec.ts`: home, `/sessions`, the "Keynote" session and its register page return 200 with no console errors; `/api/agenda` returns `Cache-Control` containing `no-cache` and `X-Drupal-Cache-Tags` containing a `registration_list.host_entity:node:` tag.
#### 36. `tests/a11y/a11y.spec.ts`, `tests/a11y/pa11yci.json` (Create, from `drupal-a11y-508`)

*   **Proposed Changes**: Pages exactly as Goal 8: `/home`, `/agenda`, `/about`, `/sessions`, the "Keynote" session, its register page, `/sitemap`, `/user/login`. Tags `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa`, `wcag22aa`; JSON report in `a11y-results/`. `pa11yci.json` uses `BASE_URL` and the bypass header; it is an optional report, not a gate.

#### 37. `docs/accessibility.md`, `docs/checks.md` (Create)

*   **Proposed Changes**: `accessibility.md`: tools and versions, results, the manual keyboard, screen reader (NVDA or VoiceOver) and 400 percent zoom checks from `drupal-a11y-508/references/manual-checklist.md`, and a statement that no conformance claim is made. `checks.md`: the manual checks for CUJ 3 (publishing a change on "Try Canvas here"), CUJ 4 (following a story's source link), Goal 1 (no PHP errors in `/admin/reports/dblog` after the smoke run) and Forward (submitting "Send to a colleague" on a session and finding the logged mail entry).
*   **Phase 6 check**: on the host, `npx playwright test --project=e2e --project=a11y` passes against DDEV.

### Phase 7: Deploy and share

#### 38. `README.md` (Create)

*   **Proposed Changes**: what the site is (fictional demo) and the C3 footer notice; links to the live site, Storybook (`https://dev-<site>.pantheonsite.io/themes/custom/cedar_hollow/storybook/index.html`) and the repository; a "where to look" table mapping each job-description skill to its files; DDEV setup with `scripts/rebuild.sh`; how to run each test suite; the deploy commands; the backup restore command; the command that clears registrations (`ddev drush entity:delete registration` locally, `terminus drush <site>.dev -- entity:delete registration` on Pantheon); a note that "Theming with SDC" may already be full; the sandbox warning page; that `open` does not change over time; what was verified and how; an "as of" date and the shared tag.

#### 39. `docs/designs/cedar-hollow-drupalcamp.md` (Modify)

*   **Proposed Changes**: Status changes to Approved after review; linked from the README as the architecture record.

#### 40. `docs/how-this-was-built.md` (Create)

*   **Proposed Changes**: Under 1,500 words: the plan and decisions; what AI tools did and what was checked by hand or by tests; each theme-layer file by name; the WordPress to Drupal mapping (WP-CFM to configuration management, Features to recipes, blocks to SDC, Elementor and the block editor to Canvas); when Layout Builder or Paragraphs, and when a decoupled front end, would be the better choice; the logged Forward mail entry as evidence that mail is logged, not sent.

#### 41. Pantheon deploy (no files)

*   **Proposed Changes**, in order:
    1.  `git ls-files | grep -E 'research|_report|concepts_brief|design_draft'` prints nothing.
    2.  `git push origin main`; `git push pantheon main:master`; `terminus workflow:wait <site>.dev`; confirm in the dashboard Workflow Logs that the frontend build ran.
    3.  Locally: `ddev drush entity:delete registration -y`; `ddev export-db --file=db.sql.gz`; `gunzip -c db.sql.gz | $(terminus connection:info <site>.dev --field=mysql_command)`. The demo content has no managed files, so no file sync is needed.
    4.  `terminus drush <site>.dev -- deploy -y`; `terminus drush <site>.dev -- cr`.
    5.  `terminus drush <site>.dev -- user:password admin "$(openssl rand -base64 24)"`; `terminus drush <site>.dev -- user:information admin` shows the account; `terminus drush <site>.dev -- user:create demo-editor --password="$(openssl rand -base64 18)"` (record the password for step 10); `terminus drush <site>.dev -- user:role:add demo_editor demo-editor`; a page on Pantheon contains no `<!-- THEME DEBUG -->` comment.
    6.  Request the Storybook URL, `iframe.html` and `index.json`; if any is missing, build Storybook locally, remove its `.gitignore` rule, commit the output and push again.
    7.  `curl -sI -H 'Deterrence-Bypass: 1' https://dev-<site>.pantheonsite.io/api/agenda` shows `Cache-Control` with `no-cache` and a `registration_list.host_entity:node:` cache tag.
    8.  `terminus env:wake <site>.dev`; `BASE_URL=https://dev-<site>.pantheonsite.io npx playwright test --project=smoke --project=a11y`.
    9.  `terminus backup:create <site>.dev`; run `terminus backup:restore <site>.dev --element=all -y` once and re-run the smoke project; record the restore command in the README; `git tag shared-<YYYY-MM-DD>` with the sharing date and `git push origin --tags`.
    10. Share the editor password separately from the email; block the `demo-editor` account with `terminus drush <site>.dev -- user:block demo-editor` once the hiring process for which the demo was shared has ended.

### Verification Plan

*   **Compilation/Build**: `ddev composer install`; `npm ci && npm run build` in the theme; `scripts/rebuild.sh` ends with `drush config:status` reporting no differences.
*   **PHPUnit**: `ddev exec vendor/bin/phpunit -c web/core web/modules/custom/cedar_hollow_core` (functional and kernel tests in item 15).
*   **Static Analysis & Linting**: `ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom web/themes/custom`; `npm run lint:css` in the theme.
*   **Test Coverage Requirement**: Not a percentage. Each goal and CUJ maps to a check: Goal 1 and CUJ 1 smoke and e2e specs; Goal 2 `bem-parity.spec.ts`; Goal 3 the component status page; Goal 4 Twig debug; Goal 5 `AgendaEndpointTest` and smoke; Goal 6 and CUJ 2 `RegistrationCapacityTest`; Goal 7 the agenda specs; Goal 8 the `a11y` project plus `docs/accessibility.md`; Goal 9 the PHPUnit and e2e suites; Goal 10 and CUJ 5 `rebuild.sh`; Goal 11 the README; CUJ 3 `DemoEditorAccessTest` plus `docs/checks.md`; CUJ 4 `bem-parity.spec.ts` plus `docs/checks.md`.
*   **E2E/Integration**: `npx playwright test` in `tests/` against DDEV (`e2e`, `a11y`) and against Pantheon (`smoke`, `a11y`); zero axe violations; zero browser console errors.

--------------------------------------------------------------------------------

*Drafted with EGM*
