## What and why

<!-- One or two sentences. What breaks without this, or what it enables. -->

## Testing

<!-- The command you ran and what it returned, not an assertion that it works.
     Paste the output. If a check could have passed without the change working,
     say what you did to rule that out.

     This repository's usual evidence:
       ddev exec vendor/bin/phpunit -c web/core/phpunit.xml.dist web/modules/custom/cedar_hollow_core
       npm run lint:css                 in web/themes/custom/cedar_hollow
       npm run test:storybook           in web/themes/custom/cedar_hollow
       npx playwright test --project=e2e --project=a11y    in tests/

     If nothing here exercises the change, say so. -->

## Risk

<!-- Tick one. The change sets the tier, not who wrote it.
     Low: docs, comments, a test. Medium: ordinary module, theme or config work.
     High: workflows, agent settings, dependencies, settings files, routes and
     permissions, roles and text formats, update and deploy hooks. -->

- [ ] Low
- [ ] Medium
- [ ] High

The changed paths can raise the tier to High, and a ticked box cannot lower it.
A High pull request needs an owner comment starting "Accepted at <sha>:" before
the review gate passes.

## How to revert

<!-- Say it concretely, so whoever undoes this does not have to work it out.

     The code: git revert -m 1 <merge>, then merge that revert through a pull
     request like any other change.

     Name every one-way step this change takes, and the manual step that undoes
     it, because reverting the code does not undo them:
       update hooks (hook_update_N) already run on Dev
       post-updates and deploy hooks already run on Dev
       configuration imported by drush deploy
       recipes already applied
       content created on Dev

     If there are none, say so. -->
