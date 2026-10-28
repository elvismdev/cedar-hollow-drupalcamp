# Spike results

Run on 2026-10-28 in DDEV (Drupal 11.4.11, Canvas 1.12.0, Registration 3.4.9) on a scratch install that was reinstalled before Phase 1. Each check used a value that could not pass by accident: a random token served by a probe route, or a deleted file that had to be recreated.

| Spike | Check | Result | Evidence |
| --- | --- | --- | --- |
| (a) | An SDC with `group: Atoms` registers in Canvas; one with `group: Elements` does not. | Pass | `sdc.spike_probe.probe-badge` created with status 1; the `Elements` component produced no component entity. |
| (b) | A code component fetches a same-origin JSON route and renders on a published Canvas page. | Pass | Page `/spike-probe` rendered "Token: 2fc6c81b2ade0f65", the random value served by `/spike/probe.json`; no console errors. |
| (c) | A recipe containing a Canvas page with that code component installs on a fresh site and the page renders (Drupal.org issue #3580989). | Pass | After `drush site:install minimal --existing-config` and `drush recipe`, the page rendered a second random token, "4eda218e3b452be0". |
| (d) | After a clean install from configuration, the code component's compiled script exists (Drupal.org issue #3591075). | Pass | `sites/default/files/astro-island/<hash>.js` was deleted before the install and was recreated with the same name. |
| (e) | Registration settings exported as default content attach to their sessions after a clean install. | Run in Phase 1 | Needs the session content type. |
| (f) | A wait-listed registration sends no confirmation mail. | Run in Phase 1 | Needs the session content type. |
| (g) | Views offers `views-exposed-form--sessions.html.twig`. | Run in Phase 1 | Needs the `sessions` View. |
| (h) | The registration form ID is `registration_attendee_register_form`. | Run in Phase 1 | Needs the `attendee` registration type. |
| (i) | A Storybook story resolves `include('cedar_hollow:card')` from `components/molecules/card/`. | Run in Phase 3 | Needs the theme and Storybook. |
| (j) | Canvas and contrib permission names exist. | Pass | `create canvas_page`, `edit canvas_page`, `publish auto-saves`, `administer code components`, `administer page template`, `administer content templates`, `access sitemap` and `access forward` are all defined. |

## Findings that change the plan

* **A code component can be created without the Canvas editor.** Canvas expects the compiled code as an ES module that imports `react/jsx-runtime` and `react`, which its import map points at Preact. `esbuild <file>.jsx --format=esm --jsx=automatic --jsx-import-source=react` produces that format, and a `JavaScriptComponent::create()` call with `js.original` and `js.compiled` validated with no violations and rendered. The agenda builder can therefore be built from its repository file by a script, instead of being pasted into the editor by hand.
* **Content export command.** In Drupal 11.4, `core/scripts/drupal` is deprecated in favour of `dr`, and running it from `web/` fails in this Composer layout because it looks for `vendor/` inside `web/`. Drush 13.8 provides the same command: `ddev drush content:export <entity_type> <id> --with-dependencies --dir=/var/www/html/recipes/<recipe>/content`.
* **Exported Canvas pages drop `component_version`**, and the recipe fills it in on import.
