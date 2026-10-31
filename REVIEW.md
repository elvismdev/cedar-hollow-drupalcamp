# What matters when reviewing this repository

This is a public Drupal 11 demo for a fictional DrupalCamp: Canvas pages,
session registration through Entity Registration, a theme of Single Directory
Components with Storybook, and GitHub workflows that test every pull request
and deploy `main` to a Pantheon Dev site. Two kinds of change land here: code a
visitor can reach, and machinery that tests, deploys or reviews code. Judge the
first by whether it holds under a real request with caching on, and the second
by whether it can actually fail.

## What failure looks like here

Not a crash. A crash is loud and gets fixed the same day. The failures that
matter here are silent. One class below has an eval case that scores the
reviewer against it; every other class is a hypothesis drawn from this stack,
not yet measured.

- **Cache metadata not bubbled** (hypothesis). A render array or response built
  from an entity, a config object or the current user that does not carry their
  tags and contexts. Under the page and dynamic page caches it serves stale or
  another visitor's output, and it looks correct with caches off.
- **Seat output without `getRegistrationListCacheTag()`** (hypothesis). Anything
  that shows seats taken or left must add `$host->getRegistrationListCacheTag()`,
  or a new registration leaves every cached count wrong.
- **A route without an access requirement** (hypothesis). Every route in a
  custom `*.routing.yml` needs a `requirements` entry that restricts it;
  `_access: 'TRUE'` on anything but a deliberately public read counts as none.
- **An entity query without `accessCheck()`** (hypothesis). Drupal 11 throws
  when it is missing, and `accessCheck(FALSE)` on output a visitor sees lists
  entities that visitor may not view.
- **`Markup::create` or Twig `|raw` on user data** (hypothesis). Both mark a
  string safe and skip escaping. Content from a registrant, an editor or a
  field must go through a text format or autoescaping instead.
- **A deploy or update hook that is not idempotent** (hypothesis).
  `hook_update_N`, `hook_post_update_NAME` and `hook_deploy_NAME` must leave the
  same result when run against a site that already has the change, because
  `drush deploy` runs them on Dev and a failed deploy can be re-run.
- **Config changed in `config/` without the recipe** (hypothesis). Functional
  tests build their site from `recipes/cedar_hollow_sessions`, so a config
  schema, permission or text format change made only in `config/` passes the
  tests against a site that differs from Dev.
- **An SDC prop used but not declared** (hypothesis). A Twig template that reads
  a prop or slot its `*.component.yml` does not declare renders empty in Canvas
  and Storybook without an error.
- **A procedural hook where an OOP hook exists** (hypothesis). Hooks in custom
  modules are classes with `#[Hook]` attributes in `src/Hook/`; a new function
  in a `.module` file splits the hook surface in two.
- **A workflow expression pasted into `run`** (hypothesis). `${{ }}` is
  substituted before the shell parses the script, so a quote in the value
  becomes syntax. Values reach `run` through `env`.
- **A wait shorter than what it waits for** (hypothesis). A timeout, deadline
  or retry budget below the duration of the thing it waits on fails on every
  slow run, or passes before the thing has finished.
- **A checkout without `ref` that tests other code than was deployed**
  (hypothesis). In a job started by `workflow_run`, `workflow_call` or
  `pull_request_target`, a bare checkout takes the default branch, so the job
  tests or ships a different commit than the one it reports on.
- **A variable used where it is undefined** (hypothesis). A shell variable or
  step output set in another step, job or branch of an `if` expands to empty,
  and an empty value often reads as success.
- **A comparison against command output that the tool also uses for logs**
  (covered by the eval case `deploy-dev-config-status`). Comparing a command's
  stdout to an expected value fails, or passes for the wrong reason, when the
  same tool writes its log lines to stdout. Ask what else the tool prints there,
  and whether the comparison was shown to fail on a known positive.

## Trust boundaries

Each role's reach is taken from its `config/user.role.*.yml` and from the
`requirements` in the custom routing file. Anything a role can reach, assume an
attacker holding that role will reach.

- **Anonymous visitor.** `access content`, `access forward`, `access sitemap`,
  `create attendee registration self`, `view media`. Reaches `/api/agenda`
  (`cedar_hollow_core.agenda`, GET only, `_permission: 'access content'`).
- **Registrant.** An anonymous visitor who submits a registration with
  `create attendee registration self`. Account sign-up is `admin_only`, so a
  registrant has no account; authenticated users hold the same five
  permissions as anonymous. Registration fields, the email address included,
  are untrusted input.
- **Editor** (`demo_editor`). `access toolbar`, `create canvas_page`,
  `create image media`, `edit canvas_page`, `publish auto-saves`,
  `view the administration theme`. The demo's editor credentials are shared
  with reviewers, so treat anything editor-level as reachable by any visitor of
  the Dev site.
- **Admin.** User 1, which bypasses every permission check while
  `security.enable_super_user` keeps its default. No role file grants it.
- **CI runner.** `ci.yml` runs on every pull request and every push to `main`
  with `contents: read` and no secrets; its MariaDB root password is a
  throwaway service value.
- **Pantheon deploy.** `workflow_run` after CI succeeds on a push to `main`, in
  the `pantheon-dev` environment, holding `PANTHEON_SSH_KEY`, `TERMINUS_TOKEN`
  and `PANTHEON_BOT_BYPASS_TOKEN`. It pushes code to Dev and runs `drush deploy`
  there. The smoke suites it calls receive only the bot-bypass token.

## Skip

Report nothing from these. They are vendored, generated, or not ours:

- `web/core/`, `web/modules/contrib/`, `web/themes/contrib/`,
  `web/libraries/`, `vendor/`, `node_modules/`.
- `package-lock.json` files, except to ask whether a change pulls in packages
  nobody asked for.
- Generated Storybook output (`web/themes/custom/cedar_hollow/storybook/`) and
  test artifacts (`tests/test-results/`, `tests/a11y-results/`,
  `tests/perf/reports/`).

## Deliberate

These look wrong and are intended. Flagging them is a false positive:

- **Mail is logged, never sent.** `system.mail` routes every message to the
  `cedar_hollow_logger` plugin, which writes it to the log. A missing mail
  transport or SMTP setting is not a defect.
- **The tests send a bypass header.** The Playwright smoke and accessibility
  projects send `Deterrence-Bypass: 1`, and on Pantheon the
  `x-pantheon-bot-bypass` token, so the sandbox warning page and the edge's bot
  check do not intercept the test browser. Only the step that runs the tests
  reads the token.

## How to report

- **Open with a count.** "4 findings: 1 important, 2 nits, 1 pre-existing."
  When there is nothing to fix, say exactly that. A clean review is a result.
- **Tag every finding**: `Important`, `Nit` or `Pre-existing`. `Pre-existing`
  marks anything the diff did not introduce; do not block on it. Untagged, an
  old bug reads as the author's fault.
- **Cap nits at three.** More is padding, and it costs more when the author is
  an agent, because an agent fixes a nit instead of waving it off.
- **Name the class once.** When a mistake repeats, describe the pattern so
  every instance gets fixed together, rather than listing each line.
- **File and line on every finding**, as evidence. A finding reasoned from a
  file name, a function name or a path, without opening it, is labelled a guess
  or dropped.
- **Flag an understated Risk tier.** When the change is riskier than the Risk
  box ticked in the pull request, say which tier fits and why.
