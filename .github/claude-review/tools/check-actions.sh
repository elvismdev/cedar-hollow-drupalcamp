#!/usr/bin/env bash
# Check the bash inside every composite action's `run:` steps: bash -n for
# syntax, then shellcheck. The workflow linter this repository came with reads
# jobs.*.steps and never looks at runs.steps, so it passed an action.yml with a
# syntax error in it; this is the check that does look.
#
# ${{ ... }} expressions are replaced with a placeholder first. GitHub expands
# them before bash runs, so bash never sees them, and left in place they read
# as bad substitutions.
#
# Usage: check-actions.sh [action.yml ...]   (default: every .github/claude-review/*/action.yml)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ "$#" -eq 0 ]; then
  mapfile -t files < <(git ls-files --cached --others --exclude-standard '.github/claude-review/*/action.yml' | sort -u)
else
  files=("$@")
fi
[ "${#files[@]}" -gt 0 ] || { echo "check-actions: no action.yml found" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; blocks=0
for f in "${files[@]}"; do
  python3 - "$f" "$tmp" <<'PY' || { echo "check-actions: $f is not a composite action" >&2; fail=1; continue; }
import re, sys, yaml, pathlib
path, out = sys.argv[1], pathlib.Path(sys.argv[2])
doc = yaml.safe_load(open(path))
steps = (doc or {}).get("runs", {}).get("steps")
if not isinstance(steps, list):
    sys.exit(1)
safe = re.sub(r"[^A-Za-z0-9]", "_", path)
for i, step in enumerate(steps):
    run = step.get("run")
    if run is None:
        continue
    body = re.sub(r"\$\{\{.*?\}\}", "EXPR", run, flags=re.S)
    (out / f"{safe}__{i:02d}.sh").write_text("#!/usr/bin/env bash\n" + body)
PY
done
for s in "$tmp"/*.sh; do
  [ -e "$s" ] || continue
  blocks=$((blocks + 1))
  name=$(basename "$s" .sh)
  bash -n "$s" 2>"$tmp/err" || { echo "check-actions: syntax error in ${name}:"; cat "$tmp/err"; fail=1; continue; }
  shellcheck -S warning "$s" || { echo "check-actions: shellcheck failed in ${name}"; fail=1; }
done
[ "$blocks" -gt 0 ] || { echo "check-actions: found no run blocks, which means this check read nothing" >&2; exit 1; }
echo "check-actions: ${#files[@]} action(s), $blocks run block(s)"
exit "$fail"
