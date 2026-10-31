# Upstream provenance

## Source

A copy of the owner's private review action at 1eeeb4f.

## Kept

- `review/action.yml`, `gate/action.yml`, `eval/action.yml`
- `tools/review/` (prompt assemblers, findings extraction, vote, gate, posting, prior findings, reviewed-through) with their tests
- `tools/eval/` (`review-eval.mjs` and its test)
- `tools/agent/` (`compose-agent-args.sh`, `emit-block.sh`, `test/assert.sh`, `test/helpers/parse-env-file.py`) with their tests
- `tools/check-actions.sh`, `tools/check-actions.test.sh`, `tools/check-cli-version.sh`

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
