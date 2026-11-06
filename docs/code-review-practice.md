# Code review practice

Most of this repository is written by an AI coding agent working under one maintainer, the owner. This page explains how a change gets from the agent's session to `main`, what reviews it on the way, and what the owner does when something goes red.

## The practice

**Every change reaches `main` through a pull request.** A repository ruleset, `main-protection` (kept as `.github/rulesets/main-protection.json`), rejects direct pushes for everyone, blocks force pushes and deletion of `main`, allows merge commits only, and requires the CI jobs to pass on a branch that is up to date with `main`. Merge commits keep the project's small single-concern commits on `main` as written.

**Before a pull request opens, the agent checks its own work.** Claude Code runs PostToolUse hooks after each file the agent edits: PHP_CodeSniffer with the same `phpcs.xml.dist` CI uses, stylelint and `scripts/check_css.py` on theme CSS, and `scripts/check_hierarchy.py` on Twig and component definitions. The agent then runs Claude Code's `/code-review` and `/security-review` on the branch and fills in the pull request template: what and why, the testing commands with their output, a risk tier, and how to revert.

**An AI reviewer reads each pull request from two angles, bugs and security.** It is a copy of the owner's private review action, adapted here. The review runs on `pull_request_target`, so the workflow, its scripts, its prompts and `REVIEW.md` all come from `main`: a pull request cannot change the code or rules that review it. The pull request's own code is fetched outside the working directory as data. It is read, never executed, and none of its instruction files load.

**The agents can only read.** The reviewer and its verifiers are allowed Read, Glob and Grep. Every other tool is denied by name, and each agent's trace is checked afterwards; any other tool fails the job. With no shell, an agent cannot reach the secrets in its job even if text in the pull request tries to steer it.

**Findings are voted on before they are posted.** Three verifier agents try to refute each finding. A finding that two of them refute, or judge to be style only, is dropped. The rest are screened for the job's secrets and then posted as inline comments by `github-actions[bot]`, each tagged important, nit or pre-existing.

**The review gate decides whether the pull request can merge.** It is a required check, it is never skipped, and when it fails it prints one exact message naming the cause. It stays red while an important finding has no owner reply in its thread, while a High pull request has no acknowledgement, or while a review could not run.

**A path classifier sets the risk tier.** The author ticks Low, Medium or High in the template. A script from `main` reads the changed paths and raises the tier to High when any of them touches workflows, agent settings, `REVIEW.md` or `AGENTS.md`, dependencies, settings files, routes and permissions, roles, text formats, or update and deploy hooks. A ticked box can raise the tier and never lower it. A High pull request gets a larger turn budget for its review and needs the owner's acknowledgement before the gate passes.

**Rounds are capped.** Each angle reviews a pull request at most three times. A push that only merges `main` into the branch spends no round. At the cap the gate stays red until the owner acknowledges the pull request.

**An eval scores the reviewer after each change to it merges.** When the reviewer's workflow, prompts or `REVIEW.md` change on `main`, and weekly, the eval replays the reviewer against cases taken from this project's history: one real incident it must catch and three clean commits it must pass quietly. A case that does worse than the baseline opens or updates an issue labelled `reviewer-eval`. The eval is advisory and never a required check, because scoring a branch's reviewer before merge would mean running that branch's code with the token.

**Outside pull requests are not accepted.** The project takes issues instead. A guard job comments once on a pull request from a fork and fails, and the review jobs refuse to run for a fork, so no job holding the token is reachable from outside the repository.

**One credential.** The reviewer and eval use the owner's subscription token, `CLAUDE_CODE_OAUTH_TOKEN`, stored in a GitHub Environment named `claude-agents` whose branch policy allows `main` only. A workflow added on a branch cannot read it.

## Glossary

*   **Angle**: one of the two directions the reviewer reads a pull request from, bugs or security. Each angle is its own job with its own prompt.
*   **Verifier**: an agent that reads a finding and the diff and tries to refute the finding. Three verifiers vote on each finding.
*   **Round**: one review of a pull request by one angle. Each angle has three rounds per pull request.
*   **Gate**: the required "Review gate" check that turns the review jobs' results and the review threads into one pass or fail, with a named cause.
*   **Answered**: an important finding is answered when a comment by the owner follows the reviewer's first comment in its thread. Resolving a thread, or the thread going outdated, does not answer it. A finding edited by anyone but the reviewer or the owner stays important and unanswered, and an owner comment edited by anyone else does not count. The reviewer posts as `github-actions`, which every workflow in the repository shares, so an edit under that name is not proof the reviewer made it.
*   **Acknowledgement**: one owner comment on the pull request starting "Accepted at <sha>:", with the full 40-character sha, followed by a reason. It clears the High tier and the round cap for that commit, or for a later commit that only merges `main` into it.
*   **Tier**: the pull request's risk, High or Normal, from the ticked box and the changed paths, whichever is higher.
*   **Eval**: the advisory workflow that replays the reviewer against known cases after the reviewer changes.
*   **Baseline**: the eval's recorded expected result per case, written by the owner from the first run. A known miss stays in it with its reason.
*   **Bypass**: the Repository admin's right, under the ruleset, to merge a pull request whose checks are red. It applies to pull requests only, and GitHub records each use.

## What I left out and why

*   **Merge queue.** GitHub does not offer one for repositories owned by a user account. The cost is that a merge from `main` re-runs the full CI, including the end-to-end job.
*   **Required approvals.** With one maintainer, nobody else can approve, and a pull request author cannot approve their own.
*   **CODEOWNERS.** There is one owner of every path, so it would add a rule that says nothing.
*   **Stale-approval dismissal.** There are no approvals to dismiss.
*   **A separate agent identity.** The agent works as the owner's GitHub account. A second account or a GitHub App would make the agent's actions distinguishable, at the cost of another identity and credential to keep. The agent's limits are rules in `AGENTS.md`: on pull requests it authored it never replies to findings, re-runs the gate, posts an acknowledgement, merges or uses the bypass. Every action it takes is visible on the public pull request.
*   **Fork pull requests.** Accepting them means either running a token-holding job for code from outside the repository, or a second path into the reviewer. Taking issues instead keeps the token out of reach.

## Maintainer runbook

### A red gate, by cause

The gate prints one of these messages. `<angle>` is "bugs", "security", or "bugs and security".

| Message | What to do |
|---|---|
| "Outside pull requests are not accepted; please open an issue." | Close the pull request. If the change is wanted, make it on a branch of this repository. |
| "Draft pull request: the review runs when it is marked ready." | Mark the pull request ready for review; that starts the review. |
| "Review did not run (<cause>) for <angle>." | Act on the cause below, then re-run the review jobs (Re-run failed jobs). |
| "Round cap reached for <angle>. Waiting for 'Accepted at <full head sha>:' (the full 40-character sha)." | Read the commits pushed since the last reviewed round. If they are right, post "Accepted at <full head sha>: <reason>", copying the sha from the message, and re-run the gate. Only the full 40-character sha counts: a short one can be moved to another commit by a tag named after it. |
| "Review threads could not be read." | Usually a GitHub API failure. Re-run the gate. |
| "100 or more review threads; the gate cannot decide." | Split the pull request. |
| "<N> important findings unanswered." | Reply in each thread the gate lists: "Fixed in <sha>" after pushing the fix, or the reason the finding stands. A push starts a new round; a reply alone needs only a re-run of the gate. |
| "High risk: waiting for 'Accepted at <full head sha>:' (the full 40-character sha)." | Read the change, then post "Accepted at <full head sha>: <reason>", copying the sha from the message, and re-run the gate. |

Causes for "Review did not run":

*   `token_or_quota`: the token expired, is invalid or was revoked, or the subscription's usage is exhausted. Rotate the token (below), or wait for usage to return, or use the bypass for an urgent change.
*   `no_agent_ran`: the agent step produced nothing. Re-run the job, then read its log. If the log shows claude-code-action failing on a git command before the agent starts, the checkout of `main` is missing or broken: the action restores `.claude`, `CLAUDE.md` and similar files from `main` with git before every review.
*   `tool_violation`: an agent used a tool other than Read, Glob or Grep, passed a tool input field outside that tool's schema, or read a path outside the workspace (`.git` excluded), the pull request head or the diff input folder. The log names each refused call by tool and position, the rule that refused it and, when it is one of the tool's own fields, the field, but never a value. Read the job log before anything else; treat it as possible prompt injection through the pull request's content.
*   `secret_screen`: a finding or summary matched one of the job's secrets, so nothing was posted. Read the job log to see which output tripped the screen before re-running, and rotate the token if the log shows it outside the screen.
*   `head_mismatch`: the fetched head is not the commit the API reports, usually because of a push during the run. Re-run the job.
*   `empty_diff`: the API reports changed files but the diff was empty. Re-run the job.
*   `infrastructure`: a runner or network failure. Re-run the job.
*   `missing`: a review job ended without reporting a state. Read the job log.

To re-run only the gate, use Re-run jobs > Review gate on the run, or:

```bash
gh run view <run-id> --json jobs --jq '.jobs[] | {name, databaseId}'
gh run rerun <run-id> --job <job-id>
```

The job id is the `databaseId` from the first command, not the number in the job's URL. Re-running only the gate reuses the review jobs' results from the same run, so no agent runs again.

### The bypass merge

When a change cannot wait for the gate, for example a fix while the subscription is exhausted, merge it with the admin bypass:

```bash
gh pr merge <number> --merge --admin
```

GitHub records the bypass on the pull request. Say why on the pull request before merging.

### Rotating the token

```bash
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN --env claude-agents
```

The second command reads the new value from standard input. Then re-run a failed review job to confirm the new token works.

### Updating protection

The ruleset is applied from `.github/rulesets/main-protection.json`. To change it, edit the file through a pull request, then apply it by id:

```bash
id=$(gh api repos/{owner}/{repo}/rulesets --jq '.[]|select(.name=="main-protection").id')
gh api -X PUT "repos/{owner}/{repo}/rulesets/$id" --input .github/rulesets/main-protection.json
```

Add a new required check only after the workflow job that produces it has merged, or every open pull request waits for a check that never reports.

### Rolling back protection

Remove the required check first, then revert the workflow that produces it. In the other order, every open pull request waits on a check that no longer runs.

1.  Remove the check's context from `.github/rulesets/main-protection.json` and apply the ruleset with the `PUT` above.
2.  Revert the workflow's merge with `git revert -m 1 <merge>` and merge the revert through a pull request.

## Residual risks

*   **The agent acts as the owner.** Its limits in `AGENTS.md` are a convention, not a control: the account it uses could reply to findings, re-run the gate, acknowledge or bypass. Every such action is visible on the public pull request.
*   **A same-named check.** A workflow on a branch is also a GitHub Actions job, so it could report a check named "Review gate" beside the real one. The required checks are pinned to the GitHub Actions app, only the owner's account can push branches, and any change under `.github/` is High. Whether GitHub counts such a branch job toward the required check is recorded when the gate becomes required.
*   **Prompt injection through pull request content.** With no shell, denied tools, the trace check, the secret screen and the verifier vote, an injected instruction cannot read secrets or post them. It can still produce a misleading finding, so the owner reads every finding.
*   **Subscription exhaustion.** The reviewer shares the owner's subscription with the owner's own sessions. Round and turn caps bound the usage, the gate names the cause, and the bypass covers urgent changes.
*   **A weakened reviewer merges.** A change to the reviewer is High and needs an acknowledgement, and the eval runs when it lands on `main`. Pull requests reviewed between that merge and the eval's result are reviewed by the changed reviewer.
*   **`PANTHEON_BOT_BYPASS_TOKEN` is a repository-level secret.** Any workflow on a branch can read it. This practice does not address it; it is an open question.

## Cost

Measured on the first gate canary, 2026-10-31, on GitHub-hosted `ubuntu-24.04` runners.

*   **A reviewing round** runs both angles in parallel. Each review job took 80 to 99 seconds, including the checkout, the head fetch and installing Claude Code.
*   **Agent sessions per round.** Each angle starts one reviewer session. When the reviewer reports findings, three verifier sessions follow, so a round costs two sessions when both angles find nothing and up to eight when both report findings. Every session runs on the owner's subscription with a 40-turn budget (60 for a High pull request).
*   **A round that spends nothing.** A push that only merges `main`, or any push after the cap, starts no agent: the job ends in 8 to 9 seconds.
*   **At most three reviewing rounds per angle** on one pull request, so at most 24 agent sessions before the cap asks for an owner acknowledgement.
*   **The gate** takes about 6 seconds and starts no agent.

Token counts are not shown in the job log, because the action's full output stays hidden on a public repository.

## Audit

The pull request review reads one change at a time. The security audit reads the whole custom codebase. It runs as `.github/workflows/security-audit.yml`, uses Cloudflare's `security-audit` skill (MIT, vendored under `.github/security-audit/skill/`), and posts what it verified to one rolling issue labelled `security-audit`.

### What it does

*   **Reads the project's own code.** The scope is the custom modules and theme, configuration, recipes, scripts, workflows and tests. Drupal core, contributed modules, vendor code and the vendored skill are out of scope; `composer audit` and `npm audit` in CI cover known advisories in dependencies.
*   **Proves what it can.** For each lead that needs a running site, two agents each write a proof-of-concept script without seeing the other's. A job with no token runs both against a throwaway copy of the site: Drupal on SQLite, built from this repository's configuration and demo content, inside a sandbox with no network, with one test account per role.
*   **Reports and stops there.** It updates the issue with the commit it read, the agent invocations each job used against its cap, the counts, and each published finding with its attack path, both scripts' results and a proposed fix. Attack paths are public by the owner's choice, and the issue says so.

### What it does not do

*   **It blocks nothing.** It is never a required check.
*   **It fixes nothing.** A fix goes through a normal pull request.
*   **It never contacts Pantheon Dev** or any deployed site. Every reproduction targets the throwaway site.
*   **It never gives an agent a shell.** Agents can read, search and write only into their own output folder. Project code runs only in the two jobs that hold no token.
*   **It publishes nothing unverified.** Rejected, disputed and unvalidated candidates appear only as counts.

### How a finding is verified

1.  **The skill's own verifiers.** A fresh subagent that did not find a candidate checks it, and a second fresh subagent checks every final record. The skill's two validators then run as trusted steps.
2.  **Two independent scripts.** Both proof-of-concept scripts run in the sandbox, and a fresh agent reads both results.
3.  **A cross-check on another model.** One more fresh verifier per final record, on a model none of the earlier jobs ran on, re-reads the record, both scripts and their output.
4.  **A tie-break on a third model.** When the cross-check disagrees, one tie-break verifier decides, at most three per run. If it also disagrees, the finding is removed from the run and kept, with both reasons, in `disputed.json` in the saved state.

**Confirmed** means both scripts showed the claimed result in this run, as the test account of the lower-trust role, over HTTP for a web boundary. Only a confirmed finding carries a severity. A finding confirmed last month is proven again by two new scripts, never carried over. A cross-check can lower, demote or reject a confirmed finding, never raise it. Anything else is a lead, with no severity and a stated blocker.

### Dev's data

Pantheon Dev holds demo content and one demo editor account whose credentials are shared with reviewers, so anything an editor can do, any visitor can do. Its only other data is what visitors type into the public sign-up form. It holds no production data. A published attack path against Dev reaches that and nothing more.

### Audit runbook

#### Dispatching a run

The workflow runs on a schedule (`0 6 * * 6`): it wakes every Saturday at 06:00 UTC, and `prepare.sh` lets only the first Saturday of the month through. It can also be dispatched on `main`; every job after prepare is skipped on any other ref.

```bash
gh workflow run security-audit.yml --ref main -f publish=false
gh workflow run security-audit.yml --ref main -f canary=denied-read
```

With `publish=false` the whole audit runs, but the rendered issue body is sealed as the `audit-report` artifact instead of posted, and no `audit-state` is saved. A canary also forces `publish` to false and runs only the jobs it needs. The job log prints `<canary>: pass` or `<canary>: fail`.

| `canary` | Jobs run | What it checks |
|---|---|---|
| `denied-read` | prepare, source | Reads of runner files, credentials and `/proc` are refused by a permission rule, and a read in the checkout works |
| `denied-write` | prepare, source | Writes to the runner's command files, agent settings and the checkout are refused |
| `subagent-bash` | prepare, source | A subagent asked to run Bash has no Bash |
| `subagent-findings-write` | prepare, source | A subagent's write to `findings.json` fails the run check |
| `script-isolation` | prepare, source, build-site, poc-write | One script writer's read of the other's scratch fails the run check |
| `sandbox-secrets` | prepare, source, build-site, poc-write, poc-run | A script in the sandbox finds none of the tokens or keys |
| `reopen-records` | prepare, source, build-site, poc-write, poc-run | The sandbox key cannot open the run records it sealed |

#### Re-enabling the schedule

GitHub disables a scheduled workflow after a period with no repository activity, and emails a warning first. Push events are not disabled that way, so the CI job "Security audit schedule health" runs `.github/security-audit/check-audit-health.sh` on every push to `main`. It warns when the audit workflow is not active, when none of its last 10 completed runs on `main` has a successful report job, or when the newest that does started more than 40 days ago. While the workflow file has no schedule, the script stops after the active check and prints a notice: it reads no run history, so neither of the last two warnings can fire. It always exits 0, so it never stops a deploy.

When the email or the warning arrives:

```bash
gh workflow enable security-audit.yml
```

#### Rotating and storing the keys

Two `age` key pairs seal what the jobs hand on. The agents' private key, `AUDIT_AGENTS_AGE_KEY`, is in the `claude-agents` environment. The sandbox's, `AUDIT_SANDBOX_AGE_KEY`, is in `audit-sandbox`. The public halves are `.github/security-audit/keys/agents.pub` and `sandbox.pub`. To rotate the agents' key, on the owner's machine, from the root of a clone:

1.  Generate the key in a temporary folder outside the clone, so it can never be committed:

    ```bash
    d=$(mktemp -d)
    age-keygen -o "$d/agents.key"
    ```

2.  Copy the `AGE-SECRET-KEY-` line from `"$d/agents.key"` into the password manager before setting the secret: a secret cannot be read back, and the owner's copy is the only way to open sealed files locally.
3.  Set the secret from the same line:

    ```bash
    grep '^AGE-SECRET-KEY-' "$d/agents.key" | gh secret set AUDIT_AGENTS_AGE_KEY --env claude-agents
    ```

4.  Write the public half and commit it through a pull request. Every run checks that its private key opens what is sealed to its own public key and not the other one, so runs fail at that check until the pull request merges.

    ```bash
    age-keygen -y "$d/agents.key" > .github/security-audit/keys/agents.pub
    ```

5.  Delete the temporary folder:

    ```bash
    rm -rf "$d"
    ```

For the sandbox key, use `sandbox.key`, `AUDIT_SANDBOX_AGE_KEY`, `--env audit-sandbox` and `sandbox.pub`. The sandbox key opens only the scripts sent to the sandbox, so its rotation needs no reset.

#### Resetting state after rotating the agents' key

The saved state is sealed to the old key, so the next run cannot open it and fails. There is no reset input. Instead, delete the `audit-state` artifact that the issue's state marker names; the next run then finds no prior state, starts a fresh ledger, and lists the old findings as "not re-checked this run".

```bash
run=$(gh issue view <issue> --json body --jq .body \
  | sed -n 's/^<!-- security-audit-state \(.*\) -->$/\1/p' | jq -r '.run_id // empty')
if [ -z "$run" ]; then
  echo "The issue has no state marker; there is no saved state to reset."
else
  id=$(gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts?name=audit-state" \
    --jq '[.artifacts[] | select(.expired == false)][0].id // empty')
  if [ -z "$id" ]; then
    echo "Run $run has no unexpired audit-state artifact; the next run starts fresh already."
  else
    echo "Deleting audit-state artifact $id of run $run."
    gh api -X DELETE "repos/{owner}/{repo}/actions/artifacts/$id"
  fi
fi
```

#### Opening a sealed file locally

Every artifact a run uploads is kept for one day, except `audit-state`, which is kept for 90. Two are plain: `run-metadata` (the run's facts, no findings) and `audit-site` (the throwaway site as a `.tar.gz`, with its test accounts). Every other one is a tar archive sealed with `age`:

| Artifact | Sealed to | Holds |
|---|---|---|
| `audit-source`, `audit-poc-write`, `audit-poc`, `audit-final` | agents | The state after each phase |
| `poc-scripts` | agents | The proof-of-concept scripts |
| `poc-scripts-sandbox` | sandbox | The same scripts, for the sandbox |
| `poc-run-records` | agents | One sealed file per script run, `poc-run-<n>-<a or b>.age` |
| `failed-trace-<job>-<step>` | agents | An agent step's trace, kept when its run check failed |
| `canary-trace-source`, `canary-trace-poc-write` | agents | The canary agent's trace |
| `audit-report` | agents | The rendered body of a run that did not publish |
| `audit-state` | agents | `findings.json`, `coverage-ledger.json`, `disputed.json`, `audit-history.json` |

Open one with the repository's own `seal.sh`, which checks the sha256 before decrypting and hands the key to `age` through a file descriptor. Run it from the root of a clone, with every file outside the clone:

```bash
d=$(mktemp -d)
gh run download <run-id> -n audit-state -D "$d/sealed"
mkdir "$d/opened"
read -rs AUDIT_AGENTS_AGE_KEY && export AUDIT_AGENTS_AGE_KEY
bash .github/security-audit/seal.sh open AUDIT_AGENTS_AGE_KEY <sha256> "$d/sealed/audit-state.age" "$d/opened"
unset AUDIT_AGENTS_AGE_KEY
```

`read -rs` takes the `AGE-SECRET-KEY-` line pasted from the password manager without showing it. For `audit-state`, `<sha256>` is the one in the issue's state marker. For the sandbox's artifact, use `AUDIT_SANDBOX_AGE_KEY`. Delete `"$d"` when done.

#### Retracting a wrong issue edit

When a run publishes something that should not be public:

1.  Edit the issue body to remove it. Keep the `<!-- security-audit-state ... -->` line exactly as it is: the next run finds its prior state through it.
2.  Delete the earlier revision from the issue's edit history, or the text stays readable there.
3.  Rotate any secret it showed. For the token, follow "Rotating the token" in the maintainer runbook, including its re-run that confirms the new token works. For the agents' key, rotate it and reset the state.

#### A published High or Critical finding

When the issue shows a confirmed High or Critical finding, or a lead that touches `.github/workflows` or names a secret, the attack path is already public. Open the fix pull request the same day. If the review cannot run, the owner merges it with "The bypass merge" in the maintainer runbook, and says why on the pull request. The bypass is the owner's alone: `AGENTS.md` forbids the agent to use it.

#### Reviewing the model choice

The source and proof-of-concept agents run on `claude-opus-5-5`, the cross-check on `claude-fable-5-1`, and the tie-break on `claude-sonnet-5-5`. Each issue header records the dispute rate and the side each tie-break took. After three runs, the owner reads those figures and decides whether to keep the three models.

### First audit run

Three runs dispatched on `main` by the owner, all with `publish=false`. All three concluded success and every job's run check passed.

| Run | Commit | Total | source | poc-write | poc-run | poc-decide | cross-check |
|---|---|---|---|---|---|---|---|
| 41933116212 | `25a4e328` | 2h24m | 1h36m | 37m | 1m | 4m | 5m |
| 42088385640 | `d10fd3c0` | 2h30m | 1h41m | 38m | 1m | 3m | 6m |
| 42131892831 | `5763a678` | 1h41m | 1h18m | 14m | 1m | 4m | 3m |

The second run's validators failed after the source agent, so a repair pass ran; it started no subagent.

Subagent invocations used against each job's cap:

| Run | source | poc-write | poc-decide | cross-check |
|---|---|---|---|---|
| 41933116212 | 40 of 60 | 8 of 12 | 4 of 6 | 4 of 30 |
| 42088385640 | 40 of 60 | 6 of 12 | 3 of 6 | 3 of 30 |
| 42131892831 | 35 of 60 | 4 of 12 | 2 of 6 | 2 of 30 |

*   **Models.** Source and poc-decide ran on `claude-opus-5-5`, and cross-check step 1 on `claude-fable-5-1`. Poc-write ran on the refusal fallback `claude-opus-4-8` in all three runs; that model is on the allowlist and the report header names it. The cross-check and tie-break run with the refusal fallback turned off. No tie-break was needed, so `claude-sonnet-5-5` never ran.
*   **Results.** No finding was confirmed. The runs reported 4, 3 and 2 leads, and rejected 3, 3 and 2 candidates.
*   **Disputes.** The cross-check disputed none of the records: 0 of 4, 0 of 3 and 0 of 2. With no tie-break, there are no tie-break sides to review.
*   **Refusals.** The safety classifier stopped no subagent.
*   **Before these runs.** The first ten runs failed or stopped when the run check refused the search patterns agents used. Pull requests #54, #58, #59 and #60 fixed the check; it now warns on the patterns it keeps whole, 2, 9 and 4 times in these runs.
*   **What the leads changed.** Leads from the runs were fixed in pull requests #47, #48, #49, #50, #52, #53, #55, #56, #57, #62, #63, #64, #65 and #66. Three were accepted instead: deleted finding comments and the shared `github-actions` identity, both of which need a collaborator with write access, and the yes or no answer anonymous sign-up gives on a duplicate registration.
*   **Caps.** The caps stay as they are: source 60, poc-write 12, poc-decide 6, cross-check 30, tie-breaks 3. The highest use was 40, 8, 4 and 4.
