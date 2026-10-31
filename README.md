# Cedar Hollow DrupalCamp

A Drupal 11 demo site for a fictional two-day camp. Cedar Hollow DrupalCamp is a fictional event. This site is a demo, and mail is logged, never sent.

| | |
| --- | --- |
| Live site (Pantheon Dev) | https://dev-cedar-hollow-demo.pantheonsite.io |
| Storybook | https://dev-cedar-hollow-demo.pantheonsite.io/themes/custom/cedar_hollow/storybook/index.html |
| Source | https://github.com/elvismdev/cedar-hollow-drupalcamp |
| Architecture record | [docs/designs/cedar-hollow-drupalcamp.md](docs/designs/cedar-hollow-drupalcamp.md) |
| How it was built | [docs/how-this-was-built.md](docs/how-this-was-built.md) |

Pantheon shows a warning page on sandbox sites before the first visit; continue past it to reach the site.

## What it does

* **Theme.** The [uclahs/surface](https://github.com/uclahs/surface) theme carried to Drupal 11 Single Directory Components (SDC), so one component set renders in Storybook, in Twig templates and in Drupal Canvas. Surface's tokens and component CSS are ported by a script; its markup and BEM classes are kept.
* **Landing pages** (home, agenda, about, "Try Canvas here") are built in Canvas from the theme's components.
* **Sessions, the session listing, the sign-up form and the site map** are themed through Twig templates, template suggestions and preprocess hooks that call the same components.
* **Sign-up** uses Entity Registration: capacity, a wait list and a confirmation message. "Theming with SDC" has one seat, so the second sign-up goes to the wait list.
* **Agenda builder**: a Preact code component in Canvas that lists sessions with live seat counts from `/api/agenda`, keeps your picks in the browser and flags overlapping sessions.
* **Configuration** lives in `config/` and the session feature is also packaged as a recipe; the demo content ships as a second recipe.

## Where to look

| Skill | Files |
| --- | --- |
| Twig, template suggestions, preprocess | `web/themes/custom/cedar_hollow/templates/`, `src/Hook/ThemeHooks.php` |
| Components and Storybook | `web/themes/custom/cedar_hollow/components/{atoms,molecules,organisms,layouts}/`, `.storybook/` |
| Porting Surface | `scripts/port-surface-css.py` and the commit "Port uclahs/surface's CSS to standard CSS" |
| Standard CSS: BEM, cascade layers, tokens | `css/props/`, `css/tokens.css`, `css/layers.css`, each component's `.css` |
| Libraries | `cedar_hollow.libraries.yml` |
| Drupal Canvas | `config/canvas.*`, `recipes/cedar_hollow_demo_content/content/canvas_page/` |
| React-style code component | `web/themes/custom/cedar_hollow/agenda-builder/`, `scripts/build-agenda-builder.sh` |
| Site building: content types, fields, Views, displays | `config/`, `recipes/cedar_hollow_sessions/` |
| Custom module | `web/modules/custom/cedar_hollow_core/` (agenda endpoint, seat states, logged mail) |
| Recipes | `recipes/cedar_hollow_sessions/`, `recipes/cedar_hollow_demo_content/` |
| Tests | `web/modules/custom/cedar_hollow_core/tests/`, `tests/` |
| Images: media, image styles, responsive images, Focal Point, AVIF | `recipes/cedar_hollow_media/`, the ratio test `web/modules/custom/cedar_hollow_core/tests/src/Unit/ResponsiveImageRatioTest.php`, `ThemeHooks::preprocessField()` and `::preprocessMedia()`, the image scripts `scripts/*-demo-images.php` and `scripts/demo-images.json`, `/credits` |
| Performance | `tests/lighthouserc.cjs`, `tests/perf/` |
| Accessibility | `docs/accessibility.md` |

## Run it locally

Requires DDEV and Node 22.

```bash
git clone https://github.com/elvismdev/cedar-hollow-drupalcamp.git
cd cedar-hollow-drupalcamp
ddev start
scripts/rebuild.sh          # composer install, install from config, demo content recipe, drush deploy
ddev drush uli              # one-time admin login link
```

`scripts/rebuild.sh` destroys the local database and ends with `drush config:status` reporting no differences. The site is at the URL `ddev describe` prints.

Storybook, from `web/themes/custom/cedar_hollow`:

```bash
npm ci
npm run storybook           # development server on port 6006
npm run build               # static build into storybook/, which Drupal serves
npm run lint:css            # stylelint and scripts/check_css.py
```

After changing the agenda builder's JSX or CSS, run `scripts/build-agenda-builder.sh` and `ddev drush config:export -y`.

## Tests

| Suite | Command | Covers |
| --- | --- | --- |
| PHPUnit | `ddev exec vendor/bin/phpunit -c web/core/phpunit.xml.dist web/modules/custom/cedar_hollow_core` | Wait list and confirmation mail, the agenda endpoint's contract and cache invalidation, themed seat counts, the demo editor's access, logged mail. Functional tests build their site by applying the sessions recipe. |
| Playwright e2e and a11y | `cd tests && npm ci && npx playwright install chromium && npx playwright test --project=e2e --project=a11y` | Filtering, the agenda builder with mouse and keyboard, the agenda without storage, signing up, BEM parity between Drupal and Storybook, axe WCAG 2.2 AA scans, reflow at 320 pixels |
| Smoke (read-only) | `BASE_URL=https://dev-cedar-hollow-demo.pantheonsite.io npx playwright test --project=smoke --project=a11y` | Pages, the sign-up page and the agenda endpoint's headers |
| Images | part of the e2e run (`tests/e2e/images.spec.ts`) and `ddev drush php:script scripts/check-demo-images.php` | The hero and session images load eagerly with high fetch priority, cards eagerly, the rest lazily, all with `sizes`; the credits page; crops, files and size caps after a rebuild |
| Performance | `cd tests && NODE_EXTRA_CA_CERTS="$(mkcert -CAROOT)/rootCA.pem" npm run warm -- "$BASE_URL" && npm run test:perf` | Lighthouse mobile, median of five runs on the home page, the listing and a session: LCP under 2.5 s, CLS under 0.1, the hero as the home page's LCP element |
| Coding standards | `ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom web/themes/custom/cedar_hollow/src` | |

Locally `BASE_URL` defaults to `https://cedar-hollow.ddev.site:30001`; set it to your DDEV URL if it differs.

## How changes are reviewed

Every change reaches `main` through a pull request that must pass CI, an AI reviewer that reads it for bugs and security, and a review gate that stays red until each important finding has an owner reply. The reviewer is a copy of the owner's private review action, adapted here, and it reviews against the Drupal-specific rules in [`REVIEW.md`](REVIEW.md). [`docs/code-review-practice.md`](docs/code-review-practice.md) explains the practice, what was left out and why, and the maintainer runbook.

## Deploy to Pantheon

Deploys run through `.github/workflows/deploy-dev.yml` after every CI job passes on `main`; there is no manual push. Watch a run on the Actions tab or under the `pantheon-dev` deployment. A green run means Dev runs the commit, `drush deploy` completed, `config:status` and `updatedb:status` are clean, the image warm-up returned 200 everywhere (it runs only when the deployed commits change image styles, `scripts/demo-images.json` or the content recipe; the run summary says whether it ran), and the smoke and accessibility suites passed. A red run marks the failed step, and the `deploy` job's summary lists the commit, the push result, the backup file and the build status up to that point. To see which commit Dev runs:

```bash
terminus env:code-log cedar-hollow-demo.dev
```

Re-run only the newest `main` commit's CI run; re-running an older one cancels the newer commit's CI. To retry an older failure, push an empty commit. Re-running `deploy-dev.yml` itself is safe: it skips the push when Dev already runs the commit and waits for that commit's build.

Pantheon's build runs `composer install` and builds Storybook (`frontend_build` in `pantheon.yml`). Content reached Pantheon once, by database copy from DDEV.

On a freshly created Dev, the one-time recipe and image import must run after `drush deploy` and before the warm-up. The first deploy there is expected to end red at `warm` or `smoke`; then run:

```bash
terminus drush cedar-hollow-demo.dev -- recipe ../recipes/cedar_hollow_demo_content
terminus drush cedar-hollow-demo.dev -- php:script ../scripts/place-demo-images.php
```

and re-run `deploy-dev.yml`, which skips the push and must go green.

Restore Dev from the deploy run's backup file (a full restore was tested on 2026-10-28: every page returned 200, configuration matched the code and the reviewer account was intact), together with a revert on `main`, because code is corrected only through `main`:

```bash
terminus backup:restore cedar-hollow-demo.dev --file=<database backup file from the run summary> -y
```

If a deploy reports that Pantheon refused the push because its `master` holds a commit not on `main`, bring that commit into `main` through a pull request, without a saved remote or a force push:

```bash
git fetch "$(terminus connection:info cedar-hollow-demo.dev --field=git_url)" master
git switch -c pantheon-divergence main
git merge FETCH_HEAD
```

Open a pull request from `pantheon-divergence`; once it merges and CI passes, the next deploy is a fast-forward.

**Deploy credentials.** The site owner's own Pantheon account (identity not recorded here) holds the credentials, stored in the `pantheon-dev` GitHub Environment: the secrets `PANTHEON_SSH_KEY` and `TERMINUS_TOKEN` (a Personal Access Token), and the variable `PANTHEON_KNOWN_HOSTS` (the codeserver host key). Created on 2026-10-30. To rotate them:

```bash
ssh-keygen -t rsa -b 4096 -N '' -C 'cedar-hollow-drupalcamp deploy-dev' -f <scratch path>
terminus ssh-key:add <scratch path>.pub
gh secret set PANTHEON_SSH_KEY --env pantheon-dev < <scratch path>
terminus ssh-key:list                  # find the old key's ID
terminus ssh-key:remove <old key id>
rm <scratch path> <scratch path>.pub
```

The Personal Access Token expires 90 days after it is created, and a deploy then fails at the Terminus login step, so rotate it before then: in the Pantheon dashboard, Personal Settings, Personal Access Tokens, click Add token, store it with `gh secret set TERMINUS_TOKEN --env pantheon-dev`, then revoke the old token there.

The warm-up and the smoke and accessibility suites send a Pantheon bot-bypass token in the `x-pantheon-bot-bypass` header, so the edge's bot protection does not challenge them; it does not lift Pantheon's rate limits. It is the repository secret `PANTHEON_BOT_BYPASS_TOKEN`, sent only to `*.pantheonsite.io`. The current token expires on 2027-04-01 and the next one is valid from 2027-01-01, so replace the secret between those dates. Run the command below with `"current"` changed to `"next"` if it still lists the old token as current; the plugin's notice says which to send:

```bash
terminus self:plugin:install pantheon-systems/terminus-gcdn-plugin   # once
terminus gcdn:bot-bypass cedar-hollow-demo --format=json --fields=role,token \
  | jq -er '.[] | select(.role=="current") | .token' | tr -d '\n' \
  | gh secret set PANTHEON_BOT_BYPASS_TOKEN --repo elvismdev/cedar-hollow-drupalcamp
```

If the warm-up exits with code 75, the host rate-limited it rather than a page failing; its log lists the 429 response headers. Wait before re-running the failed jobs.

Clear test sign-ups so every session has its seats again:

```bash
ddev drush entity:delete registration -y                               # locally
terminus drush cedar-hollow-demo.dev -- entity:delete registration -y  # on Pantheon
```

## Notes

* "Theming with SDC" may already be full if someone signed up; that is how the wait list is shown.
* Sessions have no open or close dates, so sign-up never closes on its own.
* Reviewer access: a `demo-editor` account can edit Canvas pages and nothing else. The password is shared separately.

## What was verified, as of 2026-10-28

* `scripts/rebuild.sh` installs the site from code with no configuration differences.
* PHPUnit: 5 tests, 69 assertions, passing. Playwright against DDEV: e2e and a11y passing, with zero axe violations on the eight main pages.
* On Pantheon Dev: every main page returns 200, `/api/agenda` is sent with `no-cache`, and the Storybook build lists the same 45 stories as the local build.
* The Playwright smoke and a11y projects pass against Pantheon (21 checks), using Chromium's new headless mode; the default headless shell gets 403s for CSS and JavaScript there. Two sign-up checks are skipped on Pantheon because its edge may answer automated requests on that path with a bot challenge, which the tests do not try to get past; the sign-up flow is tested against DDEV.
* Each automated check was shown to fail on a known defect before its passing result was trusted. Details are in `docs/accessibility.md` and `docs/checks.md`.
