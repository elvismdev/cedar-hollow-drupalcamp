#!/usr/bin/env bash
# Fail when a claude-code-action step does not set show_full_output and
# display_report to the string "false" in its own with: block. Both inputs
# publish Claude-authored content and tool results to the public step summary
# and log; pinning them keeps that off even if the action's defaults change.
# Reads jobs.*.steps of workflows and runs.steps of composite actions. A step
# counts when its uses: is anthropics/claude-code-action followed by @ or /
# (so /base-action@ is covered), compared case-insensitively.
#
# Exit status: 0 clean, 1 a step breaks the rule or no step was found, 2 a
# file could not be read as a workflow or action (named in the message).
#
# Usage: check-agent-output.sh [file.yml ...]
#   default: every tracked workflow and action.yml/action.yaml under .github
set -euo pipefail
args=()
for a in "$@"; do args+=("$(realpath -- "$a")"); done
cd "$(git rev-parse --show-toplevel)"
if [ "${#args[@]}" -eq 0 ]; then
  mapfile -t args < <(git ls-files .github | grep -E '^\.github/workflows/[^/]+\.ya?ml$|(^|/)action\.ya?ml$' | sort -u)
fi
[ "${#args[@]}" -gt 0 ] || { echo "check-agent-output: no workflow or action found" >&2; exit 1; }

python3 -I - "${args[@]}" <<'PY'
import re, sys, yaml

INPUTS = ("show_full_output", "display_report")
AGENT = re.compile(r"^anthropics/claude-code-action[@/]", re.I)

class Unreadable(Exception):
    pass

def mapping(value, path, what):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise Unreadable(f"{path}: {what} is not a mapping")
    return value

def step_lists(path, doc):
    doc = mapping(doc, path, "the document")
    for name, job in mapping(doc.get("jobs"), path, "jobs").items():
        job = mapping(job, path, f"job {name}")
        if "uses" in job:
            continue  # reusable workflow call: no steps of its own
        yield f"job {name}", job.get("steps")
    runs = mapping(doc.get("runs"), path, "runs")
    yield "action", runs.get("steps")

def main(paths):
    checked = 0
    failed = False
    for path in paths:
        try:
            with open(path) as f:
                doc = yaml.safe_load(f)
        except (yaml.YAMLError, OSError) as e:
            raise Unreadable(f"{path}: cannot be parsed: {str(e).splitlines()[0] if str(e) else type(e).__name__}")
        for label, steps in step_lists(path, doc):
            if steps is None:
                continue
            if not isinstance(steps, list):
                raise Unreadable(f"{path}: {label} steps is not a list")
            for i, step in enumerate(steps):
                if not isinstance(step, dict):
                    raise Unreadable(f"{path}: {label} step {i} is not a mapping")
                if not AGENT.match(str(step.get("uses", ""))):
                    continue
                checked += 1
                with_ = mapping(step.get("with"), path, f"{label} step {i} with")
                for key in INPUTS:
                    if with_.get(key) != "false":
                        print(f"check-agent-output: {path} {label} step {i} ({step.get('name', step.get('id', '?'))}): {key} must be the string 'false', found {with_.get(key)!r}")
                        failed = True
    if checked == 0:
        print("check-agent-output: found no claude-code-action step, which means this check read nothing", file=sys.stderr)
        return 1
    if failed:
        return 1
    print(f"check-agent-output: {checked} claude-code-action step(s) pin both inputs off")
    return 0

try:
    sys.exit(main(sys.argv[1:]))
except Unreadable as e:
    print(f"check-agent-output: {e}", file=sys.stderr)
    sys.exit(2)
PY
