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
*   **Answered**: an important finding is answered when a comment by the owner follows the reviewer's first comment in its thread. Resolving a thread, or the thread going outdated, does not answer it.
*   **Acknowledgement**: one owner comment on the pull request starting "Accepted at <short sha>:" followed by a reason. It clears the High tier and the round cap for that commit, or for a later commit that only merges `main` into it.
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
| "Round cap reached for <angle>." | Read the commits pushed since the last reviewed round. If they are right, post "Accepted at <short head sha>: <reason>" and re-run the gate. |
| "Review threads could not be read." | Usually a GitHub API failure. Re-run the gate. |
| "100 or more review threads; the gate cannot decide." | Split the pull request. |
| "<N> important findings unanswered." | Reply in each thread the gate lists: "Fixed in <sha>" after pushing the fix, or the reason the finding stands. A push starts a new round; a reply alone needs only a re-run of the gate. |
| "High risk: waiting for 'Accepted at <sha>:'." | Read the change, then post "Accepted at <short sha>: <reason>" and re-run the gate. |

Causes for "Review did not run":

*   `token_or_quota`: the token expired or the subscription's usage is exhausted. Rotate the token (below), or wait for usage to return, or use the bypass for an urgent change.
*   `no_agent_ran`: the agent step produced nothing. Re-run the job, then read its log. If the log shows claude-code-action failing on a git command before the agent starts, the checkout of `main` is missing or broken: the action restores `.claude`, `CLAUDE.md` and similar files from `main` with git before every review.
*   `tool_violation`: an agent used a tool other than Read, Glob or Grep, passed a tool input field outside that tool's schema, or read a path outside the workspace (`.git` excluded), the pull request head or the diff input folder. Read the job log before anything else; treat it as possible prompt injection through the pull request's content.
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

Filled in after the first gate canary, with its measured durations and agent sessions.
