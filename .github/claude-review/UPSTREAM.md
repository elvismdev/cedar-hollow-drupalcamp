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

- `tools/agent/compose-agent-args.sh`: review phase only, read-only tool list, extended deny list, optional `--add-dir` for the head and input directories.
- `tools/agent/compose-agent-args.test.sh`: rewritten for the review-only builder.
- `tools/agent/emit-block.sh`: wording about the error tracker removed.
- `tools/agent/emit-block.test.sh`: `ROOT` points at `.github/claude-review`.
- `tools/check-actions.sh`: default action search is rooted at `.github/claude-review/`.
- `tools/check-actions.test.sh`: `ROOT` points at `.github/claude-review`.
- `tools/check-cli-version.sh`: action paths rooted at `.github/claude-review/`.

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
