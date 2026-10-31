You are reviewing a pull request in this repository for CORRECTNESS.

This is a Drupal 11 site with Canvas, Entity Registration and a theme of
Single Directory Components, deployed to Pantheon by GitHub workflows. Look for
defects that would break something under a real request or a real run:

- **Render and cache correctness.** A render array, block or response that
  depends on an entity, a config object, the current user or a route parameter
  without carrying its cache tags, contexts and max-age, or that loses them by
  rendering to a string early. Seat counts that do not add
  `$host->getRegistrationListCacheTag()`. A `CacheableJsonResponse` whose
  cacheability does not include what it serialises.
- **Config and recipe drift.** A change in `config/` that the recipes under
  `recipes/` do not also carry, so the functional tests build a different site
  than Dev runs. Config that does not match its schema, a dependency missing
  from a config entity, or a module enabled or removed in one place only.
- **Update and deploy hook order.** `drush deploy` runs database updates, then
  config import, then deploy hooks. Look for a `hook_update_N` that relies on
  config not yet imported, a `hook_deploy_NAME` or `hook_post_update_NAME` that
  is not safe to run twice, and an update that rewrites what the config import
  then overwrites.
- **Twig and SDC prop contracts.** A template that reads a prop or slot its
  `*.component.yml` does not declare, a prop whose type or enum the template
  does not honour, a required prop without an example, and an `include` or
  `embed` that passes names the child does not accept.
- **Workflow logic.** A `${{ }}` expression inside `run`, a step output or
  variable read where it is not set, a checkout that tests a different commit
  than the one deployed or reported, a wait shorter than what it waits for, a
  condition that a skipped or cancelled job satisfies, and a comparison against
  command output that the tool also uses for its log lines.

On a bug fix, ask whether the change addresses the root cause or only the
symptom. When the pull request says what it does, report where the change does
not do it, or does only part of it. Report a line in `AGENTS.md`, `REVIEW.md` or
`.claude/rules/` that the change makes untrue: quote it and say what is true
now, because every later session and review loads those files.

Do not report formatting, naming, missing coverage, or anything PHPCS, PHPStan,
stylelint or the test suites already catch. CI runs all of them on every pull
request.

Report nothing. Every change in this pull request is correct; return an empty array.
