# Upstream provenance

## Source

A copy of the owner's private review action at 1eeeb4f.

## Kept

Every file below is a copy; the Changed section lists the ones edited.

- `eval/action.yml`
- `gate/action.yml`
- `review/action.yml`
- `tools/agent/compose-agent-args.sh`
- `tools/agent/compose-agent-args.test.sh`
- `tools/agent/emit-block.sh`
- `tools/agent/emit-block.test.sh`
- `tools/agent/test/assert.sh`
- `tools/agent/test/helpers/parse-env-file.py`
- `tools/check-actions.sh`
- `tools/check-actions.test.sh`
- `tools/check-cli-version.sh`
- `tools/eval/review-eval.mjs`
- `tools/eval/review-eval.test.sh`
- `tools/review/assemble-review-prompt.sh`
- `tools/review/assemble-review-prompt.test.sh`
- `tools/review/assemble-verify-prompt.sh`
- `tools/review/assemble-verify-prompt.test.sh`
- `tools/review/diff-addressable-lines.sh`
- `tools/review/findings-from-trace.mjs`
- `tools/review/findings-from-trace.test.sh`
- `tools/review/findings-gate.sh`
- `tools/review/findings-gate.test.sh`
- `tools/review/keep-trace.sh`
- `tools/review/keep-trace.test.sh`
- `tools/review/post-findings.sh`
- `tools/review/post-findings.test.sh`
- `tools/review/prior-findings.sh`
- `tools/review/prior-findings.test.sh`
- `tools/review/reviewed-through.sh`
- `tools/review/reviewed-through.test.sh`
- `tools/review/vote-findings.mjs`
- `tools/review/vote-findings.test.sh`

`tools/review/keep-trace.sh` becomes the screen-only secret check and `tools/review/findings-from-trace.mjs` parses the trace; both are used by the review action although upstream's trace steps are dropped.

## Dropped

- `README.md`: it names the private repository.
- `tools/action.yml`: a composite action for the private fix pipeline, not used by review.
- `tools/review/angles/`: the default angle prompts; the Drupal prompts `bugs.md` and `security.md` replace them, so a missing Drupal prompt fails instead of falling back.
- The steps "Keep the review trace" and "Archive the review trace": traces would be public here.
- The eval's "Keep the scores" artifact step: the artifact would be public here.
- `.github/workflows/test.yml`: its test steps are ported into this repository's own workflow.

## Renamed

- The helper folder is `tools/agent/` (D21).
- Its variables are `AGENT_ARGS_*`, `AGENT_MODEL_*`, `AGENT_TURNS_*` and `AGENT_BLOCK_*` (D21).

## Changed

- `eval/action.yml`: no checkout of its own, as the calling workflow checks out with full history; no `CLAUDE_REVIEW_REF`, so `review-eval.mjs` reads its own commit with `git rev-parse`; new output `rc`, the eval's exit status.
- `gate/action.yml`: rewritten as a composite action that passes the guard, draft, review, tier and pull request inputs to `tools/review/gate-decide.sh`.
- `review/action.yml`: no checkout of its own; a step fetches the pull request head into a detached worktree at `$RUNNER_TEMP/head`, asserts its sha against the pulls API (`head_mismatch`) and a non-empty file list when the API reports changed files (`empty_diff`), and exports `REVIEW_HEAD_DIR` and `REVIEW_INPUT_DIR`; the next step replaces the head's symlinks with files naming their targets; the workspace's `.git` stays in place during every claude-code-action step, as the action runs git against it; scripts from `$GITHUB_WORKSPACE/.github/claude-review/tools`; new input `owner_login` for `prior-findings.sh`; `max_turns` has no default; a first step fails when `max_turns` is not a positive whole number or `owner_login` is empty, as the runner does not enforce `required` on composite inputs; the head fetch follows it; `diff_from` passed to both prompt scripts; a tool check after the reviewer and each verifier; posting split into vote, a secret screen of the trace, the findings and a summary, posting, and a job summary append, the last two only after the screen passes; the addressable-line map built from the merge base of base and head; the step proving an agent ran runs after a failed agent step, so a failure with no trace is `no_agent_ran`; a final step setting outputs `state` and `cause`; the round cap counts the bot's reviews with `tools/review/review-rounds.sh`.
- `tools/agent/compose-agent-args.sh`: review phase only, read-only tool list, extended deny list, optional `--add-dir` for the head and input directories.
- `tools/agent/compose-agent-args.test.sh`: rewritten for the review-only builder.
- `tools/agent/emit-block.sh`: wording about the error tracker removed.
- `tools/agent/emit-block.test.sh`: `ROOT` points at `.github/claude-review`.
- `tools/check-actions.sh`: default action search is rooted at `.github/claude-review/`.
- `tools/check-actions.test.sh`: `ROOT` points at `.github/claude-review`.
- `tools/check-cli-version.sh`: action paths rooted at `.github/claude-review/`.
- `tools/eval/review-eval.mjs`: a per-case input directory exported as `REVIEW_INPUT_DIR` to the argument builder and both prompt scripts; quoted `--add-dir` values accepted.
- `tools/eval/review-eval.test.sh`: `ROOT` points at `.github/claude-review`; its repository commits a `bugs` angle prompt, as no default exists; asserts the agent's `--add-dir` holds the review diff.
- `tools/review/assemble-review-prompt.sh`: optional `diff_from` argument; git failures exit non-zero; diff written to `$REVIEW_INPUT_DIR/review-diff.patch` for the Read tool; names `$REVIEW_HEAD_DIR` or the working directory; repository-relative `file` required; no default angle prompt; no merge base fails.
- `tools/review/assemble-review-prompt.test.sh`: `ROOT` points at `.github/claude-review`; angle prompts on the base; cases for the head directory, a git failure and `diff_from`.
- `tools/review/assemble-verify-prompt.sh`: no git instructions; diff written to `$REVIEW_INPUT_DIR/verify-diff.patch` for the Read tool; optional `diff_from`; names `$REVIEW_HEAD_DIR` or the working directory; no merge base fails instead of falling back to the base.
- `tools/review/assemble-verify-prompt.test.sh`: `ROOT` points at `.github/claude-review`; cases for the diff file, the head directory and `diff_from`.
- `tools/review/diff-addressable-lines.sh`: takes the base and head refs and maps the diff from their merge base, failing when there is none, instead of taking a two-dot range.
- `tools/review/diff-addressable-lines.test.sh`: new; a branch whose main has moved past the branch point maps only the branch's lines; no merge base and a missing argument fail.
- `tools/review/check-trace-tools.sh`: new; fails when a trace shows a `tool_use` outside Read, Glob and Grep, a Read, Glob or Grep input that is not an object or holds a key outside that tool's schema in Claude Code 2.1.309 (Read: `file_path`, `offset`, `limit`, `pages`, `allow_large`; Glob: `pattern`, `path`; Grep: `pattern`, `path`, `glob`, `type`, `output_mode`, `-B`, `-A`, `-C`, `context`, `-n`, `-i`, `-o`, `head_limit`, `offset`, `multiline`), or a path outside the workspace (less its `.git`, which holds the token the action writes), `$REVIEW_HEAD_DIR` and `$REVIEW_INPUT_DIR`, with no normalisation: each raw `file_path` and `path` must match `[A-Za-z0-9._/@+-]+` and each Glob `pattern` and Grep `glob` `[A-Za-z0-9._/@+*{},-]+`, present fields must be non-empty, a path starting with `~` and an absolute Glob `pattern` are refused, and a Grep `glob` part must end in a file extension or a brace group of them, optionally after a final brace group of names (`**/{a,b}.php`), and not name `.git`.
- `tools/review/check-trace-tools.test.sh`: new; allowed and disallowed calls, nested and unnamed calls, allowed and refused paths, `~` paths, U+FEFF, whitespace, non-ASCII and empty values, Grep globs, input fields outside each tool's schema (Grep `file_path` among them), absolute Glob patterns, and missing, empty and unreadable traces.
- `tools/review/findings-from-trace.mjs`: strips a leading `$REVIEW_HEAD_DIR/` from each finding's `file`; a trace that is not JSON is reported by error type, without the parse error's quoted text.
- `tools/review/findings-from-trace.test.sh`: `ROOT` points at `.github/claude-review`; cases for the head directory and an unquoted parse error.
- `tools/review/findings-gate.sh`: a thread is answered only by a later comment from `REVIEW_OWNER_LOGIN`; prints `open=<N>` and `thread=<tag> <url>`; refuses an unset owner login; prints `truncated=true` for a feed of 100 threads; the feed reaches python3 in a temporary file, not an environment variable, which Linux caps at 128 KiB.
- `tools/review/findings-gate.test.sh`: `ROOT` points at `.github/claude-review`; rewritten for owner replies and the machine lines; owner fixture `repo-owner`; a case for `truncated=true`; a feed over 128 KiB is read.
- `tools/review/gate-decide.sh`: new; the Review gate's decision order, acknowledgement check, step summary and re-run hint; `findings-gate.sh`'s stderr, which names why the threads could not be read, stays in the log; the comments feed reaches python3 in a temporary file, not an environment variable, which Linux caps at 128 KiB.
- `tools/review/gate-decide.test.sh`: new; every decision step and their order, angles, drafts, missing states and acknowledgements in a real repository; the cause of unreadable threads on stderr; a comments feed over 128 KiB is read.
- `tools/review/keep-trace.sh`: screen-only mode, `REVIEW_SCREEN_ONLY=1`, screening the given files and copying nothing.
- `tools/review/keep-trace.test.sh`: `ROOT` points at `.github/claude-review`; screen-only cases with a planted secret.
- `tools/review/post-findings.test.sh`: `ROOT` points at `.github/claude-review`.
- `tools/review/prior-findings.sh`: a thread is answered only by a reply from `REVIEW_OWNER_LOGIN`; resolved and outdated threads are listed as open; the feed reaches python3 in a temporary file, not an environment variable, which Linux caps at 128 KiB.
- `tools/review/prior-findings.test.sh`: `ROOT` points at `.github/claude-review`; cases for owner replies; owner fixture `repo-owner`; a feed over 128 KiB is read.
- `tools/review/reviewed-through.sh`: outputs `diff_from`; a head equal to the clean merge of the last reviewed commit with its merge base with `origin/main` is `current`; a conflicting merge is a full review; the feed reaches python3 in a temporary file, not an environment variable, which Linux caps at 128 KiB.
- `tools/review/reviewed-through.test.sh`: `ROOT` points at `.github/claude-review`; merge cases; human fixture `repo-owner`; a feed over 128 KiB is read.
- `tools/review/review-action-cause.test.sh`: new; the step proving an agent ran has `always()` and needs an attempted agent step, and the final step names `no_agent_ran` for a failed agent with no trace.
- `tools/review/review-rounds.sh`: new; counts the reviews one angle posted, matching the bot's login exactly; the feed reaches python3 in a temporary file, not an environment variable, which Linux caps at 128 KiB; an unreadable feed exits non-zero.
- `tools/review/review-rounds.test.sh`: new; exact and lookalike logins, other angles, paginated pages, a feed over 128 KiB, and unreadable feeds.
- `tools/review/check-trace-tools.sh`: one log line per refused call naming the tool, the call's position, the refusing rule as a fixed label and, for a field in the tool's own set, its name; no value or unknown key name is printed.
- `tools/review/check-trace-tools.test.sh`: a case per label and a planted-value test that no value reaches the log.
- `tools/review/check-trace-tools.sh`: the extension-shaped rule for a Grep `glob` applies only when the Grep has no `path` or a `path` inside `$GITHUB_WORKSPACE`; with a `path` inside `$REVIEW_HEAD_DIR` or `$REVIEW_INPUT_DIR` any glob passing the character allowlist is accepted; a glob with a `..` segment is refused everywhere.
- `tools/review/check-trace-tools.test.sh`: Grep globs in the head and input directory pass, the same globs with no path or a workspace path are refused, and a `..` glob in the head is refused.
- `tools/review/risk-tier.sh`: new; the High or Normal tier from the changed paths, the path count and the ticked Risk box.
- `tools/review/risk-tier.test.sh`: new; one path per High pattern, renames, declared boxes, HTML comments and 3000 paths.
- `tools/review/replace-symlinks.sh`: new; replaces every symlink under a directory with a file naming its target, unresolved.
- `tools/review/replace-symlinks.test.sh`: new; absolute, relative, directory and dangling links in a real worktree, with a canary outside it.
- `tools/review/vote-findings.mjs`: the log gives counts only, with the refutations behind the dropped findings in aggregate; no finding title, file or parse error text is printed.
- `tools/review/vote-findings.test.sh`: `ROOT` points at `.github/claude-review`; the log repeats no agent-written text.

Rename of the private helper folder, its variable prefix and a private-name comment, applied in the copy commit (one line per file touched):

- `review/action.yml`: helper paths and variable names
- `tools/agent/compose-agent-args.sh`: helper paths and variable names
- `tools/agent/compose-agent-args.test.sh`: helper paths and variable names
- `tools/agent/emit-block.sh`: helper paths and variable names
- `tools/agent/emit-block.test.sh`: helper paths and variable names
- `tools/check-actions.test.sh`: helper paths and variable names
- `tools/eval/review-eval.mjs`: helper paths and variable names
- `tools/eval/review-eval.test.sh`: helper paths and variable names
- `tools/review/assemble-review-prompt.test.sh`: helper paths and variable names
- `tools/review/assemble-verify-prompt.test.sh`: helper paths and variable names
- `tools/review/findings-from-trace.mjs`: comment wording only
- `tools/review/findings-from-trace.test.sh`: helper paths and variable names
- `tools/review/findings-gate.test.sh`: helper paths and variable names
- `tools/review/keep-trace.test.sh`: helper paths and variable names
- `tools/review/post-findings.test.sh`: helper paths and variable names
- `tools/review/prior-findings.test.sh`: helper paths and variable names
- `tools/review/reviewed-through.test.sh`: helper paths and variable names
- `tools/review/vote-findings.test.sh`: helper paths and variable names

Test steps, ported from upstream's `test.yml` into `.github/workflows/ci.yml` as job `reviewer-tools` (paths changed to `.github/claude-review/tools` and `.claude/hooks`):

- Full-history checkout and a global git identity, because the suites create commits.
- Every `*.test.sh` runs, the suite count prints, no suites found fails, and every failing suite is listed.
- `shellcheck -S warning` over every `*.sh` in both folders, `check-actions.sh`, and `check-cli-version.sh` with the workflow token.
- `tools/review-workflow.test.sh`: new; asserts the trigger, the review jobs' needs and conditions, the gate's `if: always()`, and that every `actions/checkout` in the guard, classify, review and gate jobs takes main (no other `ref`, no pull request head in any input) with `persist-credentials: false` and, in the review jobs, `fetch-depth: 0`, and that no step takes the pull request body through `env:`, in `review.yml`, with fixture self-tests; skips while `review.yml` is absent.
