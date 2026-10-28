<!-- ai-best-practices:start -->
<!-- Do not edit by hand inside the ai-best-practices markers in AGENTS.md; this block is regenerated when you update drupal/ai_best_practices. -->

## Drupal AI best practices

This project uses [`drupal/ai_best_practices`](https://www.drupal.org/project/ai_best_practices)
to provide AI guidance tailored for Drupal development.

**Skill discovery:** Skills are installed into `skills.output_directory` from
`ai_best_practices.yaml` (`.agents/skills/`, or `.claude/skills/` for projects
set up from Claude Code) when you run `composer install` or `composer update`.
AI clients that support the
[Agent Skills specification](https://agentskills.io/specification) load skills
automatically from that directory — no manual listing needed. For clients that
do not yet support automatic discovery, this file (`AGENTS.md`) acts as a
compatibility fallback; add explicit skill references here only if your tooling
requires it.

**What to commit:** Add the skills output directory and `AGENTS.md` to version control so all
team members and CI environments share the same AI context. Also commit
tool-specific files such as `CLAUDE.md` and `GEMINI.md` if your team uses those
clients.

<!-- ai-best-practices:end -->

## Cedar Hollow DrupalCamp: project rules

Read `docs/designs/cedar-hollow-drupalcamp.md` before changing architecture; it holds the contracts (the `/api/agenda` response, the seats display states, fixed values) that several files share.

*   Drupal 11.4, Canvas 1.12, Entity Registration 3.4. Local environment is DDEV (`ddev start`); PHP 8.3 and MariaDB 10.6 match Pantheon.
*   CSS, BEM and Atomic Design work loads the `vanilla-css-bem-atomic` skill first. `npm run lint:css` in the theme runs stylelint, `scripts/check_css.py` and `scripts/check_hierarchy.py` (a component includes only lower tiers).
*   CSS is standard CSS: no Tailwind, Sass or utility classes. BEM class names, Atomic Design tiers in `components/atoms|molecules|organisms|layouts/`, cascade layers, tokens as custom properties.
*   Every theme component is a Single Directory Component; Canvas group labels are Atoms, Components, Collections and Layouts (`Elements` is reserved by Canvas).
*   Seat counts come only from Entity Registration's host entity. Any output that shows seats adds `$host->getRegistrationListCacheTag()`.
*   Mail is logged, never sent (`cedar_hollow_logger`).
*   Configuration in `config/` is the source of truth: change config in the UI or by script, then `ddev drush config:export -y`.
*   Tests: `ddev exec vendor/bin/phpunit -c web/core/phpunit.xml.dist web/modules/custom/cedar_hollow_core`. Functional tests build their site from `recipes/cedar_hollow_sessions`, so a change to session config belongs in both `config/` and the recipe.
*   Commits are small, one concern each, with no AI attribution lines.
