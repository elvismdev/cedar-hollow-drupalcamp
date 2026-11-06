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
# The run blocks and the review scripts are also refused any bare origin/
# revision, such as origin/main. Git resolves that name through refs/tags
# before refs/remotes, so a tag named origin/main would stand in for main;
# refs/remotes/origin/<branch> names the remote-tracking ref alone. Comment
# lines are skipped, and a name after a slash, as in a refspec, is not bare.
#
# Usage: check-actions.sh [action.yml | script ...]
#   default: every .github/claude-review/*/action.yml, and every .sh, .mjs,
#   .cjs, .js and .py file under .github/claude-review except the *.test.sh
#   suites, which plant such names on purpose.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
files=(); scripts=()
if [ "$#" -eq 0 ]; then
  mapfile -t files < <(git ls-files --cached --others --exclude-standard '.github/claude-review/*/action.yml' | sort -u)
  mapfile -t scripts < <(git ls-files --cached --others --exclude-standard '.github/claude-review' \
    | grep -E '\.(sh|mjs|cjs|js|py)$' | grep -vE '\.test\.sh$' | sort -u)
else
  for a in "$@"; do
    case "$a" in *action.yml) files+=("$a") ;; *) scripts+=("$a") ;; esac
  done
fi
[ "${#files[@]}" -gt 0 ] || [ "${#scripts[@]}" -gt 0 ] || { echo "check-actions: no action.yml found" >&2; exit 1; }

# bare_origin <label> <file>: prints each non-comment line naming a bare
# origin/ revision, and exits 1 if there is one.
bare_origin() {
  python3 - "$1" "$2" <<'PY'
import re, sys
label, path = sys.argv[1], sys.argv[2]
bare = re.compile(r"(?<![A-Za-z0-9_./-])origin[/]")
hit = False
for n, line in enumerate(open(path, encoding="utf-8"), 1):
    if line.lstrip().startswith(("#", "//")):
        continue
    if bare.search(line):
        # Built from parts, so this line does not name the revision it reports.
        print(f"check-actions: {label}:{n} names a bare {'origin' + '/'} revision; "
              f"use refs/remotes/origin/<branch>: {line.strip()}")
        hit = True
sys.exit(1 if hit else 0)
PY
}

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
  bare_origin "$name" "$s" || fail=1
done
for s in "${scripts[@]}"; do
  bare_origin "$s" "$s" || fail=1
done
if [ "${#files[@]}" -gt 0 ] && [ "$blocks" -eq 0 ]; then
  echo "check-actions: found no run blocks, which means this check read nothing" >&2; exit 1
fi
echo "check-actions: ${#files[@]} action(s), $blocks run block(s), ${#scripts[@]} script(s)"
exit "$fail"
