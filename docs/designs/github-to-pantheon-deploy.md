# GitHub-gated deploys to Pantheon Dev

*   **Author:** Elvis Morales
*   **Status:** Proposed
*   **Date:** 2026-10-30

--------------------------------------------------------------------------------

## Overview

The Cedar Hollow DrupalCamp site keeps its code on GitHub (`elvismdev/cedar-hollow-drupalcamp`, public) and runs on a Pantheon Sandbox site (`cedar-hollow-demo`) where only the Dev environment is initialized. Today a person moves code from GitHub to Dev by hand. This design replaces that with one GitHub workflow, `deploy-dev.yml`, which deploys a commit on `main` to Dev only after every CI job has passed on that commit, then runs `drush deploy` and checks the result.

Terms used below:

*   **Dev**: Pantheon's development environment, served at `dev-cedar-hollow-demo.pantheonsite.io`. It is the only initialized environment on this site.
*   **Pantheon's Git repository**: every Pantheon site has its own Git repository. Dev always runs that repository's `master` branch, which is why GitHub `main` is pushed to Pantheon `master`.
*   **Pantheon build workflow**: the background job Pantheon starts after each push to its repository, listed by `terminus workflow:list` as `Sync code on "dev"`. It syncs the code, runs Integrated Composer (`composer install`) and runs `frontend_build`, which here builds the theme's static Storybook (`storybook build`). Nothing built is committed to Git.
*   **`drush deploy`**: Drush's standard deploy command. It runs database updates, imports the configuration in `config/`, and runs deploy hooks. Pushing code does not run it.
*   **CI**: the GitHub workflow named `CI` in `.github/workflows/ci.yml`, with five jobs: `php-quality`, `theme`, `phpunit`, `e2e` and `visual`. None of them has an `if:` condition or `continue-on-error`, so a CI run that concludes `success` means all five ran and passed.
*   **Deploy contract**: the rules every deploy to Dev follows: the CI gate, the ordering of deploys, the three checks and the recovery. `docs/designs/cedar-hollow-drupalcamp.md` (Deployment) states it, this design records how it was reached and why, and `deploy-dev.yml` carries it out step by step.
*   **The smoke and accessibility suites**: the Playwright projects `smoke` and `a11y` in `tests/`, run by `pantheon-nightly.yml`.

## The Problem

A deploy today is a six-command checklist run from a laptop, written in `README.md` ("Deploy to Pantheon") and in `docs/designs/cedar-hollow-drupalcamp.md` (Deployment): `terminus backup:create`, `git push origin main`, `git push pantheon main:master`, `terminus workflow:wait`, `terminus drush cedar-hollow-demo.dev -- deploy -y`, and the image warm-up, followed by the smoke and accessibility suites. This has four weaknesses:

1.  **Nothing ties a deploy to a green CI run.** The push can send a commit that CI has not finished testing, or one CI has failed. The owner's rule is that Dev must never run code CI later fails.
2.  **Nothing enforces the checklist.** Skipping the backup, the wait for Pantheon's build, `drush deploy` or the warm-up leaves Dev running new code against old configuration, or without a restore point.
3.  **Two remotes can drift.** `pantheon/master` and `main` match today only because each push was done by hand and in order.
4.  **The deploy result is not recorded anywhere a reviewer can see.** Whether Dev's configuration matches `config/` after a deploy is checked only if the person remembers to run `config:status`.

The route that would remove the site's Pantheon repository, Pantheon's GitHub Application, needs a Gold or higher workspace, and Build Tools is retired (see Alternatives A and C). The remaining route is a GitHub workflow that pushes into the site's Pantheon repository and then does the rest of the deploy itself.

## Goals

*   A push to `main` changes Dev only after `php-quality`, `theme`, `phpunit`, `e2e` and `visual` all pass on that exact commit.
*   Pull request runs, including runs from forks, never start a job that can read the deploy secrets.
*   When the deploy run ends green, Dev runs the commit CI tested, `drush deploy` has completed, and all three checks pass. Any other outcome makes the run red.
    1.  `drush config:status` reports no differences and `drush updatedb:status` reports no pending updates.
    2.  The image warm-up gets HTTP 200 on every page and image derivative it requests.
    3.  The smoke and accessibility suites pass against Dev.
*   A backup of Dev is taken before each push, and its file name is recorded so that exact backup can be restored.
*   A newer push to `main` never cancels a deploy that is already running, a run that will not deploy never displaces one that will, and an older commit never replaces a newer one on Dev.
*   The local `pantheon` remote and every instruction that recreates it are removed. The deploy contract is written once, in `docs/designs/cedar-hollow-drupalcamp.md`, and `deploy-dev.yml` is its executable form.
*   A failed deploy can be diagnosed from the GitHub run page alone: the page marks the failed job and step, and the `deploy` job's summary lists the commit, the push result, the backup file, Pantheon's build status, Dev's head commit and check 1's output, each written as soon as it is known.

## Non-Goals

*   Deploying to Test or Live, or initializing them.
*   Pull request Multidevs (Multidev needs Gold or higher).
*   Building Composer dependencies or the theme in GitHub Actions. Pantheon keeps building both.
*   push-to-pantheon, Build Tools and Pantheon's GitHub Application.
*   Automatic rollback. Restoring a backup stays a manual Terminus step.
*   Syncing databases or uploaded files. The one-time recipe and image import has already run on the current Dev (24 image media entities, checked 2026-10-30) and is needed again only on a freshly created Dev, in the order given under Failure modes and recovery.
*   Running Lighthouse against Pantheon.
*   Automated rotation of the SSH key and the Personal Access Token. The token expires 90 days after creation, so its rotation is a manual, dated step in the README.
*   Blocking pushes to Pantheon made outside CI. Pantheon has no branch protection on this plan, so "CI only" is a convention. Detection is partial: a push of a commit that is not on `main` is caught at the next deploy, and a push of a commit already on `main` is not caught at all.
*   Shortening the time between a merge to `main` and Dev updating. It follows from waiting for every CI job and is accepted.
*   An emergency manual deploy path, and a manual approval step on each deploy.

## Open Questions

*   **`workflow_run` after a re-run**: whether re-running a failed CI job until it passes fires `workflow_run` with `conclusion: success`. If it does, the re-run rule under Ordering applies. If it does not, a flaky CI job is cleared only by a new commit on `main` (an empty commit is enough). Closed by rollout test 7.
*   **Build status values**: only `succeeded` has been seen in `workflow:list`. Step 6 waits on `finished_at` rather than on a status name, so it does not need the in-progress value; the failed value is recorded the first time a build fails.
*   **What Dev serves after a failed build**: whether Pantheon keeps serving the previous build or the partly built new one. Closed only if a build fails.
*   **`updatedb:status` with pending updates**: its clean output (nothing on stdout) was measured; the pending-update output was not. The rule "anything on stdout fails" covers both, but the summary text is confirmed only when an update is pending.
*   **Queue behaviour (CUJ 4)**: not testable on demand; recorded the first time two qualifying deploy runs overlap (rollout test 4).
*   **`deployments: write`**: GitHub may create the GitHub Environment deployment record without it. The design leaves it out; rollout test 1 shows whether it is needed.

## Critical User Journeys (CUJs)

### CUJ 1: A merged change reaches Dev

*   **Given**: Dev runs commit A, and A is an ancestor of the new commit.
*   **When**: Commit B lands on `main` and all five CI jobs pass on it.
*   **Then**: `deploy-dev.yml` starts. It backs up Dev, pushes B to Pantheon `master`, waits for Pantheon's build of B to succeed, runs `drush deploy`, and passes all three checks. The run is green, the `deploy` job's summary shows B, the backup file, the build status and check 1's output, and Dev serves B.

### CUJ 2: CI fails, Dev does not change

*   **Given**: Dev runs commit A.
*   **When**: Commit B lands on `main` and any one of the five CI jobs fails, or B's CI run is cancelled by a newer push.
*   **Then**: B's `deploy-dev.yml` run skips every job and does not join the deploy queue, so a deploy already waiting there still runs. Dev still runs A. No secret is read.

### CUJ 3: A pull request never deploys

*   **Given**: A pull request from a branch of this repository, or from a fork, including a fork whose branch is named `main`.
*   **When**: CI runs on it and passes.
*   **Then**: For a branch of this repository, no `deploy-dev.yml` run starts. For a fork, a run may start but skips every job. Dev does not change, and no job that can read the `pantheon-dev` secrets runs.

### CUJ 4: Two merges in quick succession

*   **Given**: Commit B's deploy is running.
*   **When**: Commit C lands on `main` and its CI passes while B's deploy is still running.
*   **Then**: B's deploy finishes, then C's deploy runs. If a later commit D also passes CI while C waits, C's waiting run is dropped and D runs after B; D contains C's changes. Only runs whose CI succeeded on a push to `main` in this repository take part in this queue. Dev never moves from a newer commit to an older one.

### CUJ 5: A deploy fails after the push

*   **Given**: The commit has been pushed to Pantheon.
*   **When**: Pantheon's build fails, `drush deploy` fails, or a check fails.
*   **Then**: The run is red, and the run page marks the failed job and step. The `deploy` job's summary already lists the commit, the backup file taken before the push and everything learned up to the failure. The owner fixes forward through `main`, or restores that backup with `terminus backup:restore cedar-hollow-demo.dev --file=<backup file> -y` and reverts on `main`.

### CUJ 6: A push of a commit that is not on `main` is noticed

*   **Given**: Pantheon `master` gained a commit that is not on `main`: a push made outside CI, a dashboard upstream update, or a commit made while Dev was in SFTP mode.
*   **When**: The next deploy runs.
*   **Then**: The push is refused because Pantheon `master` is not an ancestor of the commit being deployed. The run is red, Dev is unchanged, and the summary names the two possible causes: Pantheon `master` holds a commit not on `main`, or an older CI run was re-run by hand. The owner follows the divergence recovery below.

## Technical Plan (Architecture)

### Shape

One new GitHub workflow, `.github/workflows/deploy-dev.yml`, starts when CI completes. It has three jobs. `deploy` holds the secrets, moves the commit to Dev and runs check 1. `warm` runs check 2 without secrets. `smoke` reuses `pantheon-nightly.yml` for check 3. CI's behaviour does not change; only a comment is added to `ci.yml`.

```text
push to main
     |
     v
 ci.yml ("CI")  php-quality, theme, phpunit, e2e, visual
     |   (a newer push to main cancels the older CI run)
     | completed
     v
 deploy-dev.yml   on: workflow_run [CI] completed, branches [main]
     |   concurrency: pantheon-dev for qualifying runs, a unique group otherwise;
     |                cancel-in-progress: false
     |
     +-- job deploy   GitHub Environment pantheon-dev (url: Dev)
     |     guard: CI succeeded, event push, branch main, same repository
     |     1  check out workflow_run.head_sha, full history
     |     2  SSH key and pinned codeserver host key, PHP 8.3, Terminus 4.3.3
     |     3  terminus env:wake
     |     4  terminus backup:create; record the new database backup file name
     |     5  if Dev already runs <sha>: skip the push
     |        else: confirm Git mode, record the newest build start time,
     |              git push <Pantheon Git URL> <sha>:refs/heads/master (no --force)
     |     6  wait for this commit's Pantheon build to finish; require "succeeded"
     |     7  terminus drush cedar-hollow-demo.dev -- deploy -y
     |     8  check 1: config:status prints [], updatedb:status prints nothing
     |
     +-- job warm     needs: deploy; no GitHub Environment, no secrets
     |     check 2: npm ci, then npm run warm against Dev
     |
     +-- job smoke    needs: deploy, warm
           uses: ./.github/workflows/pantheon-nightly.yml
                 with environment: dev, ref: <sha>; no secrets passed
           check 3: the smoke and accessibility suites against Dev
```

`smoke` waits for `warm` because image derivatives generated by parallel requests on a cold site can answer 503, the reason the CI `e2e` job warms them first.

### Trigger and guards

`deploy-dev.yml` listens for `workflow_run` on the GitHub workflow named `CI`, type `completed`, branch `main`. A `workflow_run` workflow always runs from the default branch's copy of the file and can read secrets even when the CI run it follows came from a fork's pull request. The `branches: [main]` filter matches the head branch name, so a fork's branch named `main` also starts a run. The `deploy` job therefore runs only when all of these are true:

*   `github.event.workflow_run.conclusion == 'success'`
*   `github.event.workflow_run.event == 'push'`
*   `github.event.workflow_run.head_branch == 'main'`
*   `github.event.workflow_run.head_repository.full_name == github.repository`

When any condition is false the `deploy` job is skipped, and `warm` and `smoke`, which need it, are skipped with it. The job checks out `github.event.workflow_run.head_sha`, never the moving tip of `main`, so Dev receives exactly the commit CI tested. Because the trigger matches the GitHub workflow by the name `CI`, renaming that workflow stops deploys without an error; a comment at the top of both files says so.

The secrets sit in the GitHub Environment `pantheon-dev`, whose deployment-branch rule allows only `main`. Under `workflow_run` the run's ref is always `main`, so this rule does not stop a fork-triggered run; the four guards above are the only control against runs that follow a pull request. What the rule does block is every other workflow that runs on another ref, which cannot read the secrets at all. The GitHub Environment's `url` is Dev's address, so each deploy appears in the repository's deployment history.

### Ordering and concurrency

CI cancels an older run on `main` when a newer push arrives, so in a burst of pushes only the newest commit gets a successful CI run. `deploy-dev.yml` sets workflow-level concurrency with `cancel-in-progress: false` and a group name computed from the same four guard conditions: a qualifying run joins `pantheon-dev`, and every other run gets its own group, `deploy-dev-skip-<run id>`. GitHub keeps one run in a group running and at most one waiting, and a newer waiting run replaces an older waiting one. Because only qualifying runs share `pantheon-dev`, a failed, cancelled or fork-triggered run can never replace a deploy that is waiting, and a running deploy is never cancelled. Keeping the group at workflow level also holds the lock through `warm` and `smoke`, so the next deploy does not start while Dev is being checked. One build at a time also matches the push-to-pantheon README's statement that Pantheon runs a single code sync at a time.

The push in step 5 has no `--force`, so a push that is not a fast-forward is refused. This happens in two cases: Pantheon `master` holds a commit that is not on `main` (CUJ 6), where Git reports `(fetch first)` because the runner does not have that commit, or an older CI run was re-run by hand after a newer commit was deployed, where Git reports `(non-fast-forward)`. Either way the run ends red, Dev is unchanged, and the summary names both causes. A push that fails for another reason (authentication, network, host key) prints Git's own error, which the summary includes.

**Re-run rule.** Re-run only the newest `main` commit's CI run. Re-running an older one joins CI's concurrency group and cancels the newer commit's CI. To retry an older failure, push an empty commit instead. A re-run of `deploy-dev.yml` itself is safe: step 5 finds Dev already on `<sha>`, skips the push, and step 6 waits for that commit's build, even one still running.

### Pantheon build status

Before pushing, step 5 records `LAST_BUILD_STARTED`, the largest `started_at` among the `Sync code on "dev"` entries in `terminus workflow:list cedar-hollow-demo --format=json`. Step 6 selects the build to judge:

*   after a push: the `Sync code on "dev"` entry with the largest `started_at` that is greater than `LAST_BUILD_STARTED`; until one appears, it keeps polling;
*   without a push (a re-run): the `Sync code on "dev"` entry with the largest `started_at`.

It polls every 15 seconds until that workflow has a `finished_at` value, for at most 900 seconds (the last four builds took 197 to 243 seconds), and then requires `status` to be `succeeded`. Both values are Pantheon's own timestamps, so the runner's clock is never compared with Pantheon's. If a push leaves no new workflow within 900 seconds, the step fails with "no Pantheon build started". The step also writes Dev's head commit, the `hash` of the first entry in `terminus env:code-log cedar-hollow-demo.dev --format=json`, to the summary. Terminus's own `workflow:wait` is not used.

### Credentials

*   **Pantheon account**: the owner's own Pantheon account, the only member of the site's team. A Personal Access Token and an SSH key both carry that account's access to every site it can reach. This is accepted and listed under Risks.
*   **SSH key**: a new RSA 4096 key generated for CI only (Pantheon rejects ed25519: `terminus ssh-key:add` reports "SSH keys of type 'ed25519' are not yet supported"). The private half is the GitHub Environment secret `PANTHEON_SSH_KEY`, written to `~/.ssh/id_rsa` with mode 600.
*   **Personal Access Token**: a new Personal Access Token on the same account, GitHub Environment secret `TERMINUS_TOKEN` (the name Pantheon's GitHub Actions guide uses), passed to the Terminus action as `pantheon-machine-token`, which runs `terminus auth:login --machine-token`; that flag accepts Personal Access Tokens. Pantheon no longer creates new Machine Tokens. A Personal Access Token expires 90 days after creation (docs.pantheon.io personal-access-tokens, reviewed 2026-09-21).
*   **Git URL**: read at run time with `terminus connection:info cedar-hollow-demo.dev --field=git_url` and pushed to directly, so CI creates no remote named `pantheon` and nothing hard-codes the site UUID.
*   **Codeserver host key**: the GitHub Environment variable `PANTHEON_KNOWN_HOSTS` (read as `vars.PANTHEON_KNOWN_HOSTS`) holds the `[codeserver.dev.<site uuid>.drush.in]:2222 ssh-rsa ...` line, written to `~/.ssh/known_hosts`. Its trusted source is the entry already in the owner's `~/.ssh/known_hosts` from the manual pushes. The `git push` therefore checks the host key.
*   **Appserver host keys**: `terminus drush` builds its own SSH command, and Terminus 4.3.3 passes `-o "StrictHostKeyChecking=no"` (`SSHBaseCommand.php` line 388). Steps 7 and 8 therefore run without host key checking. This is an accepted risk, listed under Risks.
*   **Terminus**: installed by `pantheon-systems/terminus-github-actions` v1.2.11 with `terminus-version: 4.3.3` and `disable-cache: true`. Its `action.yml` declares `disable-cache` ("Disable session cache and force a new session to be initiated"); the cache is off because GitHub Actions caches written on `main` can be restored by pull request runs. PHP 8.3 via `shivammathur/setup-php`, the same version the CI jobs use.
*   The README records which account holds the credentials (without naming it), the secrets' creation date and the rotation steps. The run summary prints no account name or email, because run pages on a public repository are public.

### Checks

| Check | Job | Command | Fails the run when |
|---|---|---|---|
| 1 | `deploy` | `terminus drush cedar-hollow-demo.dev -- config:status --format=json` and `-- updatedb:status --format=json`, with Drush's log lines (`[notice]`, `[success]` and the like) removed, because `terminus drush` returns them on stdout with the JSON | `config:status` prints anything other than `[]`, `updatedb:status` prints anything on stdout, or either exits non-zero. Measured: `config:status` exits 0 even when configuration differs, so the output decides. |
| 2 | `warm` | `npm ci`, then `npm run warm -- https://dev-cedar-hollow-demo.pantheonsite.io`, in `tests/` | any page or image derivative returns non-200. The script already exits non-zero on that and sends `Deterrence-Bypass`. |
| 3 | `smoke` | `pantheon-nightly.yml` called with `environment: dev` and `ref: <sha>` | any smoke or accessibility test fails |

Check 2 runs in its own job because `npm ci` runs dependency install scripts, and those must not run where the SSH key and the Terminus session are present.

`pantheon-nightly.yml` gains a `workflow_call` trigger with two string inputs, `environment` (default `dev`) and `ref`. Its `workflow_dispatch` trigger keeps its `choice` input, which `workflow_call` does not accept. Its checkout uses `inputs.ref` when it is set, so check 3 runs the tests from the deployed commit and not from the newest `main`. The deploy and the nightly schedule therefore run the same suites from one file. No secrets are passed to it.

### Run summary

Each step of the `deploy` job appends what it learned to that job's step summary as soon as it learns it: the commit, whether it pushed (or the refusal message), the backup file, the build workflow `id` and status, Dev's head commit, and check 1's output. A failure part-way therefore leaves every fact gathered before it. The run page marks the failed job and step, and `warm` and `smoke` each show their own result. The failure table below says what each failure means for Dev.

### Failure modes and recovery

| Fails at | Dev is left | Recovery |
|---|---|---|
| steps 1 to 3 (checkout, SSH, Terminus login, wake) | unchanged | re-run `deploy-dev.yml`; a login failure usually means the Personal Access Token expired: rotate `TERMINUS_TOKEN`, then re-run |
| step 4 backup | unchanged | re-run `deploy-dev.yml` |
| step 5: Dev is in SFTP mode | unchanged | `terminus connection:set cedar-hollow-demo.dev git`, then re-run |
| step 5: push refused (`fetch first` or `non-fast-forward`) | unchanged | divergence recovery, or nothing if an older CI run was re-run by hand |
| step 5: push fails otherwise (authentication, host key, network) | unchanged | fix the credential or variable, then re-run `deploy-dev.yml` |
| step 6: build failed, or no build started | new code pushed, build not succeeded, old database and config; what Pantheon serves is unverified | a new commit on `main` that fixes the build; a re-run judges the same failed build and stays red |
| step 7 `drush deploy` | new code, updates or config partly applied | fix forward through `main`; restore the step 4 backup with `--file=` and revert on `main` only if data is damaged |
| step 8 (check 1) | new code deployed, config or updates not as expected | fix forward through `main` |
| `warm` or `smoke` (checks 2 and 3) | new code fully deployed but not behaving as intended | fix forward through `main`; restore the backup only if data is damaged |
| job stopped by its timeout, a manual cancel or a lost runner after the push | new code, possibly before `drush deploy`; Pantheon's build continues | re-run `deploy-dev.yml`: it skips the push and waits for that build |

**Divergence recovery.** Without a saved remote: `git fetch "$(terminus connection:info cedar-hollow-demo.dev --field=git_url)" master`, create a branch from `main`, merge `FETCH_HEAD` into it, and open a pull request to `main`. When it merges and CI passes, the next deploy is a fast-forward. No force push is used.

**Restoring.** Code is corrected only through `main`. A restore uses the database backup file named in the run summary (`terminus backup:restore cedar-hollow-demo.dev --file=<file> -y`), not `--element=`, which restores whichever backup is newest. It is paired with a revert on `main`, which reaches Dev after a full CI run.

**A freshly created Dev.** The one-time recipe and image import must run after `drush deploy` and before the warm-up, which the workflow cannot pause for. The order is: the first deploy run on a fresh Dev is expected to end red at `warm` or `smoke`; then run `terminus drush cedar-hollow-demo.dev -- recipe ../recipes/cedar_hollow_demo_content` and `terminus drush cedar-hollow-demo.dev -- php:script ../scripts/place-demo-images.php`; then re-run `deploy-dev.yml`, which skips the push and must go green.

### Risks and mitigations

| Risk | Impact | Mitigation | Residual |
|---|---|---|---|
| A push to Pantheon of a commit already on `main` | Dev runs a commit CI may not have finished testing, until the next deploy | AGENTS.md rule; no local remote; the README documents no push | undetected |
| A push of a commit not on `main`, a dashboard upstream update, or an SFTP-mode commit | every deploy is refused until recovered | CUJ 6, divergence recovery | found only at the next deploy |
| `terminus drush` without host key checking | a network attacker between the runner and the appserver could impersonate it during steps 7 and 8 | the codeserver push is pinned; the key is intended only for this site, though it reaches every site on the owner's account | accepted |
| The SSH key and Personal Access Token on the owner's account | a leaked credential reaches every site the owner can access | GitHub Environment secrets, read only by the guarded job; Terminus session cache off; rotation recorded | accepted |
| The Personal Access Token expires after 90 days | every deploy fails at the Terminus login | expiry date recorded in the README with the rotation steps | depends on rotating before the date |
| A dependency install script in `tests/` | could read secrets if run beside them | check 2 runs in a job with no secrets | none known |
| A GitHub cancel or timeout after the push | Pantheon's build keeps running while GitHub stops | the deploy group never cancels in progress; a re-run waits for that build | a manual cancel still interrupts |
| The scheduled nightly overlaps a deploy | a false nightly failure | the nightly runs at 06:30 UTC; overlap accepted rather than shared locking | occasional false failure |
| Pantheon serves a challenge page to deploy-time requests, despite the `Deterrence-Bypass` header both suites send | check 2 could pass on a 200 challenge page | check 3 asserts page content, so the run goes red; the run never tries to get past a challenge | the cause must be read from the smoke report |
| Renaming the `CI` workflow | deploys stop without an error | comment in both files | depends on the comment being read |
| Public run pages and README | anything printed is public | no secret or account identity in the summary or the README | none known |

### Documentation

`docs/designs/cedar-hollow-drupalcamp.md`'s Deployment section states the deploy contract (the CI gate, the ordering, the three checks and the recovery) and names `deploy-dev.yml` as the executable steps, without repeating them. The README keeps only operator facts: that deploys happen through `deploy-dev.yml`, where to watch them, the re-run rule, how to restore a backup, divergence recovery, the fresh-Dev order, and the credentials and their rotation. AGENTS.md gains one rule for local clones: never add a `pantheon` remote or push to Pantheon.

## Alternatives Considered

### Alternative A: Pantheon's GitHub Application (external repository integration)

*   **Pros**: Removes the site's Pantheon repository, so GitHub is the only repository. Merges to `main` deploy to Dev without a CI job, and each pull request gets a Multidev.
*   **Cons**: Requires a Gold, Platinum or Diamond workspace (docs.pantheon.io/guides/external-repositories/github, reviewed 2026-08-26). It deploys on merge without waiting for CI. In "Native GitHub workflows on Pantheon" (livestream, 2025-06-19) it had no on-server development mode and reported failed backups during its beta.
*   **Reason for Rejection**: Not available on this Sandbox plan, and it would not wait for CI before Dev changes.

### Alternative B: push-to-pantheon 0.9.6 with `skip_build_tools: true`

*   **Pros**: Pantheon's recommended replacement for Build Tools. It installs Terminus and writes GitHub deployment records.
*   **Cons**:
    *   Its main feature, pull request Multidevs, needs Multidev, which this plan lacks.
    *   It always pushes with `--force` (`scripts/main.sh` line 667), so a late older run could overwrite a newer deploy, and a divergent Pantheon `master` would be overwritten instead of reported.
    *   Without `skip_build_tools: true` it switches to Build Tools on its own the day Live is initialized.
    *   Its README advises against using it with Integrated Composer, which this site uses.
    *   It is Early Access, before 1.0, and asks for `deployments: write` and `pull-requests: write`.
    *   It neither waits for Pantheon's build nor runs `drush deploy`, so the job needs Terminus and the same steps anyway.
*   **Reason for Rejection**: On this plan it reduces to a forced `git push` and adds risk without removing any step.

### Alternative C: Terminus Build Tools plugin

*   **Pros**: Commands for pushing build output, waiting for code sync and managing Multidevs. Installs and loads on Terminus 4.3.3 (tested in an isolated plugin folder).
*   **Cons**: Pantheon's Build Tools guide says no further updates, bug fixes or security patches will be provided, and tells sites to move off it. Its last code release was 3.0.11 (2025-05-08). `build:env:push` force-pushes and runs no `drush deploy`. Its `composer.json` still declares Terminus `^3`.
*   **Reason for Rejection**: Retired by its maintainer.

### Alternative D: `drush deploy` from a Pantheon Quicksilver hook

*   **Pros**: Runs on Pantheon after every code sync, including a push made outside CI. Keeps Terminus SSH out of the GitHub job.
*   **Cons**: Its result appears only in Pantheon's dashboard, so the GitHub run could be green while the config import failed. Whether `sync_code` fires before or after the Composer and theme builds is not settled. It adds deploy logic to `pantheon.yml`, and the usual script path `/web/private/scripts/quicksilver` is git-ignored (`.gitignore:64`).
*   **Reason for Rejection**: A failed deploy must turn the GitHub run red; this alternative cannot.

### Alternative E: a deploy job inside `ci.yml`

*   **Pros**: One file. A `needs:` list on the five jobs gives the CI gate, and changing line 13 to `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` stops pushes to `main` from cancelling each other.
*   **Cons**: With today's `cancel-in-progress: true`, a newer push can cancel the deploy after the push and before `drush deploy`, leaving new code against old configuration. The fix makes every run on `main` queue behind the previous one, each up to the `e2e` job's 60-minute timeout. The deploy secrets would be referenced in the same file that runs on every pull request.
*   **Reason for Rejection**: A deploy must not be cancellable halfway and must have its own concurrency, independent of CI's; the owner chose the separate `deploy-dev.yml`.

### Alternative F: building Composer and the theme in GitHub Actions

*   **Pros**: push-to-pantheon's README reports faster deploys; the build is visible in the GitHub log.
*   **Cons**: Built files (vendor, contrib modules, Storybook output) would have to be committed into the site's Pantheon repository on every deploy, which the current `.gitignore` and `frontend_build` setup exist to avoid. It duplicates what Integrated Composer and `frontend_build` already do.
*   **Reason for Rejection**: Pantheon already builds both; nothing in the goals needs the build moved.

### Alternative G: repository secrets instead of a GitHub Environment

*   **Pros**: Nothing to configure beyond two secrets.
*   **Cons**: Every workflow in the repository can read repository secrets, so a later edit to any workflow could expose them under weaker conditions. No deployment history.
*   **Reason for Rejection**: Secrets limited to one GitHub Environment are readable only by jobs that declare it; the owner chose the `pantheon-dev` GitHub Environment.

### Alternative H: keep the manual push as an emergency path

*   **Pros**: Dev can still be updated when GitHub Actions is down or a flaky test blocks CI.
*   **Cons**: It bypasses the CI gate, and Pantheon cannot tell an emergency push from any other.
*   **Reason for Rejection**: It would let Dev run untested code; the owner removed the manual push entirely. A flaky job is cleared by re-running the newest commit's CI run or by an empty commit.

### Alternative I: a pre-push comparison step

*   **Pros**: Fetching Pantheon `master` before pushing would end a stale re-run green as "superseded" instead of red, and would report divergence before the push.
*   **Cons**: An older commit reaches the deploy job only through a hand re-run of an old CI run. The step would need an output that every later job reads in order to skip itself, plus its own test. The refused fast-forward push already catches both cases.
*   **Reason for Rejection**: Complexity for a case that needs a deliberate hand re-run.

### Alternative J: a separate summary job

*   **Pros**: One table at the end of the run.
*   **Cons**: It needs every fact passed from `deploy` as a job output, a third copy of the guard conditions, and a scripted copy of the failure table. The run page already marks the failed job and step, and the `deploy` job's own summary already holds every fact.
*   **Reason for Rejection**: It duplicates what GitHub shows and adds no control.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Security**: secrets only in the `pantheon-dev` GitHub Environment, read only by the `deploy` job behind four `if:` guards; no npm install in that job; third-party actions in `deploy` pinned by commit SHA, a deliberate departure from the repository's tag pins because that job holds the secrets; the codeserver host key pinned, and `terminus drush` running without host key checking as an accepted risk; workflow permissions `contents: read`; no secret or account identity in the public run summary or README.
*   **Runtime**: after a merge, Dev updates once CI finishes (bounded by the `e2e` job's 60-minute timeout), plus the backup, Pantheon's build (197 to 243 seconds measured), `drush deploy` and the checks. Accepted by the owner.
*   **Rollback**: by fixing forward through `main`, or by restoring the step 4 backup by file name and reverting on `main`. No automatic rollback.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Item 8 (settings) is done before the pull request is merged, because the merge starts the first deploy. Items 1 to 7 land through one pull request, one concern per commit in the order listed, merged with a merge commit. A pull request cannot exercise `deploy-dev.yml`, because `workflow_run` runs the default branch's copy, so the merge is the first real deploy; the owner follows its run page until every job finishes. Item 9 comes last.

### Target Files to Create/Modify

#### 1. `.github/workflows/pantheon-nightly.yml` (Modify)

*   **Type / Scope**: GitHub Actions workflow.
*   **Proposed Changes**:
    *   Add an `on.workflow_call` block with two string inputs: `environment` (default `dev`) and `ref` (default empty). `workflow_dispatch` keeps its `choice` input.
    *   The checkout step passes `ref: ${{ inputs.ref }}`. When it is empty, `actions/checkout` uses the commit that started the run, so scheduled and manual runs are unchanged.
    *   `BASE_URL` keeps its current expression, which reads `inputs.environment` and falls back to `dev`.
    *   Jobs, Playwright projects and artifact upload are unchanged, and its actions keep their tag pins.
*   **Why**: Check 3 reuses these suites, so there is one copy of them.

#### 2. `.github/workflows/deploy-dev.yml` (Create)

*   **Type / Scope**: GitHub Actions workflow.
*   **Proposed Changes**:
    *   Header comment: it runs after the GitHub workflow named `CI` in `ci.yml`, and renaming that workflow stops deploys.
    *   `on.workflow_run`: `workflows: [CI]`, `types: [completed]`, `branches: [main]`.
    *   The guard expression, written out in full in two places, the concurrency `group` and the `deploy` job's `if:`:
        `github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push' && github.event.workflow_run.head_branch == 'main' && github.event.workflow_run.head_repository.full_name == github.repository`
    *   Workflow-level `concurrency`: `group: ${{ (<guard expression>) && 'pantheon-dev' || format('deploy-dev-skip-{0}', github.run_id) }}`, `cancel-in-progress: false`.
    *   Workflow-level `permissions: { contents: read }`.
    *   Job `deploy`:
        *   `if: <guard expression>`; `environment: { name: pantheon-dev, url: https://dev-cedar-hollow-demo.pantheonsite.io }`; `runs-on: ubuntu-24.04`; `timeout-minutes: 40`.
        *   Env: `SITE: cedar-hollow-demo`, `SHA: ${{ github.event.workflow_run.head_sha }}`. No job outputs.
        *   Steps (each appends its fact to `$GITHUB_STEP_SUMMARY` as soon as it has it):
            1.  `actions/checkout` with `ref: ${{ github.event.workflow_run.head_sha }}` and `fetch-depth: 0`; write `$SHA` to the summary.
            2.  Write `PANTHEON_SSH_KEY` to `~/.ssh/id_rsa` (mode 600) and `vars.PANTHEON_KNOWN_HOSTS` to `~/.ssh/known_hosts`; `shivammathur/setup-php` with PHP 8.3; `pantheon-systems/terminus-github-actions` with `pantheon-machine-token: ${{ secrets.TERMINUS_TOKEN }}`, `terminus-version: 4.3.3`, `disable-cache: true`.
            3.  `terminus env:wake "$SITE.dev"`.
            4.  Save the keys of `terminus backup:list "$SITE.dev" --format=json`; run `terminus backup:create "$SITE.dev"`; list again and take the one `_backup_database` key that was not there before, recording its `file`. If there is no new key, fail with "backup not found". No clock is compared.
            5.  Read the first `hash` from `terminus env:code-log "$SITE.dev" --format=json`. If it equals `$SHA`, record "already deployed, push skipped" and set `PUSHED=false`. Otherwise:
                *   `terminus env:info "$SITE.dev" --field=connection_mode` must print `git`, or fail with "Dev is in SFTP mode; run `terminus connection:set cedar-hollow-demo.dev git` and re-run".
                *   Record `LAST_BUILD_STARTED`, the largest `started_at` among the `Sync code on "dev"` entries in `terminus workflow:list "$SITE" --format=json` (0 if there are none).
                *   `git push "$(terminus connection:info "$SITE.dev" --field=git_url)" "$SHA:refs/heads/master" 2>push.err`.
                *   On failure, if `push.err` matches `\[rejected\].*\((non-fast-forward|fetch first)\)`, write: "Pantheon refused the push: its master is not an ancestor of this commit. Either Pantheon master holds a commit that is not on main (follow the divergence recovery in the README), or an older CI run was re-run by hand after a newer commit deployed (nothing to do)." Otherwise write `push.err`. Fail either way.
                *   On success, set `PUSHED=true`.
            6.  Select the build: if `PUSHED=true`, the `Sync code on "dev"` entry with the largest `started_at` greater than `LAST_BUILD_STARTED` (none yet means keep polling); otherwise the `Sync code on "dev"` entry with the largest `started_at`. Poll `terminus workflow:list "$SITE" --format=json` every 15 seconds until the selected entry has a `finished_at` value, for at most 900 seconds. Fail with "no Pantheon build started" if `PUSHED=true` and no new entry appears, with "Pantheon build still running after 900 seconds" on timeout, and unless `status` is `succeeded`. Write the `id`, `status` and Dev's head `hash`.
            7.  `terminus drush "$SITE.dev" -- deploy -y`.
            8.  Capture the stdout of `terminus drush "$SITE.dev" -- config:status --format=json` and of `-- updatedb:status --format=json`, dropping lines that match `^\s*\[(notice|warning|success|info|ok|error)\]` (Terminus returns Drush's log lines on stdout). Fail unless the first, with surrounding whitespace removed, is `[]` and the second is empty or whitespace only, or if either exits non-zero. Write both.
        *   Actions pinned by commit SHA, version in a trailing comment: `actions/checkout` and `shivammathur/setup-php` at the commit their `v4` and `v2` tags point to when the file is written (`git ls-remote https://github.com/<owner>/<repo> 'refs/tags/<tag>^{}'`), and `pantheon-systems/terminus-github-actions` at v1.2.11 (`34305c662bb28fb2935aa5556cab46643a0c5170`).
    *   Job `warm`: `needs: deploy`; no `environment`; `runs-on: ubuntu-24.04`; `timeout-minutes: 15`; `actions/checkout` with `ref: ${{ github.event.workflow_run.head_sha }}`; `actions/setup-node` v4 with Node 22 (tag pins, as in `ci.yml`, since this job holds no secrets); in `tests/`, `npm ci` and `npm run warm -- https://dev-cedar-hollow-demo.pantheonsite.io`.
    *   Job `smoke`: `needs: [deploy, warm]`; `uses: ./.github/workflows/pantheon-nightly.yml` with `environment: dev` and `ref: ${{ github.event.workflow_run.head_sha }}`; no `secrets:`.
*   **Why**: The executable form of the deploy contract.

#### 3. `.github/workflows/ci.yml` (Modify)

*   **Type / Scope**: GitHub Actions workflow.
*   **Proposed Changes**: A comment above `name: CI`: "`deploy-dev.yml` starts when this workflow, matched by the name `CI`, succeeds on `main`. Renaming it stops deploys, and adding `if:` or `continue-on-error` to a job would let a deploy run without that job passing." No behaviour change.
*   **Why**: The dependency must be visible from both files.

#### 4. `README.md` (Modify)

*   **Type / Scope**: Documentation. The "Deploy to Pantheon" section, from its heading (line 81 today) through the restore command block (line 109), is replaced. "Clear test sign-ups" (line 111 on) is unchanged.
*   **Proposed Changes**: the new section contains, in order:
    1.  Deploys run through `.github/workflows/deploy-dev.yml` after every CI job passes on `main`; there is no manual push. Watch a run on the Actions tab or under the `pantheon-dev` deployment. A green run means Dev runs the commit and all three checks passed; a red run marks the failed step, and the `deploy` job's summary lists what happened up to it. `terminus env:code-log cedar-hollow-demo.dev` shows which commit Dev runs.
    2.  The re-run rule from the Technical Plan.
    3.  Pantheon's build runs `composer install` and builds Storybook (`frontend_build` in `pantheon.yml`). Content reached Pantheon once, by database copy from DDEV. (Kept from today's text.)
    4.  The fresh-Dev order, with the two import commands.
    5.  Restore: "Restore Dev from the deploy run's backup file (a full restore was tested on 2026-10-28: every page returned 200, configuration matched the code and the reviewer account was intact):" followed by `terminus backup:restore cedar-hollow-demo.dev --file=<database backup file from the run summary> -y`, together with a revert on `main`.
    6.  Divergence recovery, with its commands.
    7.  "Deploy credentials": the site owner's own Pantheon account (identity not recorded here); `PANTHEON_SSH_KEY`, `TERMINUS_TOKEN` and `PANTHEON_KNOWN_HOSTS` in the `pantheon-dev` GitHub Environment; their creation date and the token's expiry date; rotation: generate a new key pair, `terminus ssh-key:add` the new public key, replace the secret, `terminus ssh-key:remove` the old key; before the token expires, add a new Personal Access Token in the Pantheon dashboard, replace `TERMINUS_TOKEN`, revoke the old token.
*   **Why**: The README keeps only operator facts, and no instruction may recreate the remote.

#### 5. `docs/designs/cedar-hollow-drupalcamp.md` (Modify)

*   **Type / Scope**: Design document. Edits are applied from the bottom of the file up, so the line numbers below stay valid.
*   **Proposed Changes**:
    *   Line 812, step 9 of item 41 (Phase 7: Deploy and share; contains `terminus backup:restore <site>.dev --element=all -y`): append " (historical; restores now use `--file=` with the backup file named in the deploy run summary)".
    *   Line 805 (`git push origin main`; `git push pantheon main:master`; ...): append " (historical; superseded by `deploy-dev.yml`)".
    *   Lines 487 and 488 (`git remote rename origin pantheon` ...; `git branch -m master main` ...): append " (historical: the `pantheon` remote; superseded by `deploy-dev.yml`)" to each. The GitHub repository and `REPO_URL` facts on line 487 still hold.
    *   Lines 379 to 382 (the "Future Improvements" heading and its only entry, "Continuous deployment: CI now exists ...; deploying from it to Pantheon remains a future step."): remove both.
    *   Line 239 (Flow): replace with "**Flow.** `.github/workflows/deploy-dev.yml` deploys a commit on `main` to Dev only after every CI job passed on it. Deploys run one at a time and never move Dev to an older commit. Each deploy backs up Dev, pushes without `--force`, waits for Pantheon's build to succeed, runs `drush deploy`, and goes red unless `config:status` and `updatedb:status` are clean, the image warm-up returns 200 everywhere, and the smoke and accessibility suites pass. Code is corrected through `main`; a restore uses the backup file named in the run summary."
    *   Line 237 (Repository setup): replace "and Pantheon's Git stays as a second remote, so no force push is needed." with "and only `deploy-dev.yml` pushes to Pantheon's Git repository, without force, so no local `pantheon` remote exists."
    *   Line 65 (Non-Goal "Continuous deployment"): retitle the bullet "**Continuous deployment to Test and Live.**" and replace "Deploys are run by hand with Git and Terminus." with "Dev is deployed by `deploy-dev.yml` after CI passes; promotion to Test and Live stays manual."
*   **Why**: This document owns the deploy contract, and every instruction that recreates the remote or restores the newest backup must be marked or replaced.

#### 6. `docs/designs/cedar-hollow-images.md` (Modify)

*   **Type / Scope**: Design document. Edits applied from the bottom up.
*   **Proposed Changes**:
    *   Line 804 ("**Deploy**: the six rollout steps, then `config:status` ..."): append " (historical; later deploys run through `deploy-dev.yml`)".
    *   Line 492: replace with "Rollback is restoring the database from the deploy run's backup file and reverting on `main`; configuration cannot simply be reverted once media and crops exist."
    *   Line 491: replace "later deploys add only the backup and the warm-up." with "later deploys are run by `deploy-dev.yml`."
    *   Line 472: unchanged; it already says "Roll back by restoring the backup".
    *   Line 294: replace with "Every later deploy is run by `deploy-dev.yml`, which takes the backup, runs the warm-up and runs the smoke and accessibility suites."
    *   Lines 287 to 292 (the six rollout steps): add above them "(historical: the one-time rollout as run before `deploy-dev.yml` existed; on a freshly created Dev, follow the fresh-Dev order in the README)".
*   **Why**: It instructs a manual push and a rollback by redeploying an older commit, which a fast-forward-only push refuses.

#### 7. `AGENTS.md` (Modify)

*   **Type / Scope**: Agent instructions. Appended as a new bullet after line 42, the last bullet of the "Cedar Hollow DrupalCamp: project rules" list, outside the generated `ai_best_practices` block.
*   **Proposed Changes**: "Dev is deployed only by `.github/workflows/deploy-dev.yml` after CI passes on `main`. In a local clone, never add a `pantheon` Git remote or push to Pantheon; to change Dev, merge to `main`."
*   **Why**: Agents are the actors most likely to run the old command.

#### 8. Settings, before the pull request is merged (no files)

*   **Key pair** (owner's machine): `ssh-keygen -t rsa -b 4096 -N '' -C 'cedar-hollow-drupalcamp deploy-dev' -f <scratch path>`.
*   **Pantheon** (owner's account): `terminus ssh-key:add <scratch path>.pub`; create a Personal Access Token named `cedar-hollow-drupalcamp deploy-dev` (Personal Settings, Personal Access Tokens) and note its 90-day expiry date in the dashboard.
*   **GitHub**:
    *   Create the GitHub Environment `pantheon-dev`: deployment branches `main` only, no required reviewers.
    *   Add GitHub Environment secrets: `PANTHEON_SSH_KEY` (contents of `<scratch path>`) and `TERMINUS_TOKEN`.
    *   Add the GitHub Environment variable `PANTHEON_KNOWN_HOSTS`: every key line printed by `ssh-keygen -F "[codeserver.dev.<site uuid>.drush.in]:2222"`, without the `# Host ... found` comments. `<site uuid>` is `terminus site:info cedar-hollow-demo --field=id`.
*   **Clean up**: delete `<scratch path>` and `<scratch path>.pub`.

#### 9. Local remote (no files, last)

*   `git remote remove pantheon`, only on the owner's explicit direction after rollout tests 1 and 3 pass.

### Verification Plan

*   **Static, before the pull request**: `act -l` and `act --dryrun` for `deploy-dev.yml` and `pantheon-nightly.yml`, run with `-P ubuntu-24.04=catthehacker/ubuntu:act-24.04`. These prove syntax and structure only: `act` cannot run `workflow_run`, GitHub Environments, the DDEV `e2e` job or real Pantheon calls.
*   **Docs audit, before the pull request**:
    *   `grep -rnE "push pantheon|pantheon main:master|remote (add|rename) .*pantheon|rename origin pantheon|--element=all" README.md AGENTS.md docs/ --exclude=github-to-pantheon-deploy.md`: every hit carries a "historical" marker.
    *   `git diff main -- <changed files> | grep '^+' | grep -P '[\x{2013}\x{2014}]'`: returns nothing.
*   **Rollout tests, in order:**
    1.  **The merge deploys.** The green run's `deploy` summary shows a push, Dev's head equal to the merged SHA, build status `succeeded`, the backup file, `config:status` `[]` and empty `updatedb:status`, and `warm` and `smoke` succeeded. It also shows whether a deployment record appeared without `deployments: write`. The log shows no Terminus cache save and no "Unexpected input" warning. A successful push also confirms the pinned codeserver host key is accepted; test 3 checks the refusal.
    2.  **Re-run after a cancel.** Merge an empty commit, cancel its deploy run right after step 5, and re-run it at once: the re-run skips the push, waits for that build and ends green.
    3.  **Host key refused.** Set `PANTHEON_KNOWN_HOSTS` to a wrong key, merge an empty commit, and expect step 5 to fail with a host key error and Dev unchanged. Restore the variable, re-run, and expect a push and a green run.
    4.  **Queue, observed when it occurs.** It cannot be staged on demand: a deploy run queues only after its commit's full CI run passes, a newer push cancels the older CI run, and a re-run of an older green deploy would push an older commit and be refused. The first time two qualifying runs overlap, record from the run pages that the second waited in `pantheon-dev` and the first was not cancelled. Until then, CUJ 4 rests on GitHub's documented concurrency behaviour.
    5.  **Skipped runs do not queue.** Push twice to `main` while the first commit's CI is still running: the first CI run is cancelled, and its `deploy-dev.yml` run skips every job and creates no deployment.
    6.  **Pull requests.** An ordinary pull request creates no `deploy-dev.yml` run. A fork pull request from a branch named `main`, if one can be opened, shows a run that skips every job.
    7.  **CI re-run.** Re-run one job of the newest commit's CI run: record whether `workflow_run` fires, which closes that open question.

--------------------------------------------------------------------------------

*Drafted with EGM*
