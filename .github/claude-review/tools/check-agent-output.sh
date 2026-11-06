#!/usr/bin/env bash
# Fail when a claude-code-action step does not set show_full_output and
# display_report to the string "false" in its own with: block. Both inputs
# publish Claude-authored content and tool results to the public step summary
# and log; pinning them keeps that off even if the action's defaults change.
# Reads jobs.*.steps of workflows and runs.steps of composite actions.
#
# Usage: check-agent-output.sh [file.yml ...]   (default: every workflow and action under .github)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ "$#" -eq 0 ]; then
  mapfile -t files < <(git ls-files --cached --others --exclude-standard '.github/workflows/*.yml' '.github/workflows/*.yaml' '.github/**/action.yml' | sort -u)
else
  files=("$@")
fi
[ "${#files[@]}" -gt 0 ] || { echo "check-agent-output: no workflow or action found" >&2; exit 1; }

python3 - "${files[@]}" <<'PY'
import sys, yaml

INPUTS = ("show_full_output", "display_report")
checked = 0
failed = False
for path in sys.argv[1:]:
    doc = yaml.safe_load(open(path)) or {}
    groups = [(f"job {name}", job.get("steps") or []) for name, job in (doc.get("jobs") or {}).items()]
    groups.append(("action", (doc.get("runs") or {}).get("steps") or []))
    for label, steps in groups:
        for i, step in enumerate(steps):
            if not str(step.get("uses", "")).startswith("anthropics/claude-code-action@"):
                continue
            checked += 1
            with_ = step.get("with") or {}
            for key in INPUTS:
                if with_.get(key) != "false":
                    print(f"check-agent-output: {path} {label} step {i} ({step.get('name', step.get('id', '?'))}): {key} must be the string 'false', found {with_.get(key)!r}")
                    failed = True
if checked == 0:
    print("check-agent-output: found no claude-code-action step, which means this check read nothing", file=sys.stderr)
    sys.exit(1)
if failed:
    sys.exit(1)
print(f"check-agent-output: {checked} claude-code-action step(s) pin both inputs off")
PY
