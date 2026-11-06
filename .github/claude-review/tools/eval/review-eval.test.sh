#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
E="$ROOT/tools/eval/review-eval.mjs"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A fake reviewer: the findings it reports come from REVIEW_JSON, and as a
# verifier (its prompt says VERIFYING) it answers VERDICT_JSON. FAKE_FAIL makes
# it exit non-zero, the way a CLI that could not start does.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'SH'
#!/usr/bin/env bash
prompt=$(cat)
# FAKE_STDERR is written to stderr before a FAKE_FAIL exit.
[ -n "${FAKE_FAIL:-}" ] && { printf '%s' "${FAKE_STDERR:-}" >&2; exit 3; }
# Record each --add-dir the agent was given, and whether the review diff was in
# that directory when the agent started.
if [ -n "${ARGS_LOG:-}" ]; then
  while [ "$#" -gt 0 ]; do
    [ "$1" = "--disallowedTools" ] && printf 'deny %s\n' "$2" >> "$ARGS_LOG"
    if [ "$1" = "--add-dir" ]; then
      if [ -f "$2/review-diff.patch" ]; then has=patch; else has=nopatch; fi
      printf 'add-dir %s %s\n' "$2" "$has" >> "$ARGS_LOG"
      case "$prompt" in *"$2/review-diff.patch"*|*"$2/verify-diff.patch"*) printf 'prompt-names %s\n' "$2" >> "$ARGS_LOG" ;; esac
    fi
    shift
  done
fi
# Record what the case tree's "leak" path is when the agent starts: a link, a
# file (with its content) or nothing.
if [ -n "${LINK_LOG:-}" ]; then
  if [ -L leak ]; then echo "link"; elif [ -f leak ]; then echo "file $(cat leak)"; else echo "none"; fi >> "$LINK_LOG"
fi
# Record the commit the agent's working directory holds.
[ -n "${TREE_LOG:-}" ] && git rev-parse HEAD >> "$TREE_LOG"
if printf '%s' "$prompt" | grep -q VERIFYING; then body="${VERDICT_JSON:-[]}"; call="${VERIFY_READ:-}"; else body="${REVIEW_JSON:-[]}"; call="${REVIEW_READ:-}"; fi
# REVIEW_READ and VERIFY_READ put a Read of that path in the reviewer's or a
# verifier's trace.
# READ_DIFF reads the review diff from the --add-dir directory; READ_CWD reads
# gate.sh by the physical path of the working directory.
if [ -n "${READ_DIFF:-}" ]; then
  prev=""; for a in "$@"; do [ "$prev" = "--add-dir" ] && call="$a/review-diff.patch"; prev="$a"; done
fi
[ -n "${READ_CWD:-}" ] && call="$(pwd -P)/gate.sh"
[ -n "$call" ] && python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":sys.argv[1]}}]}}))' "$call"
python3 -c 'import json,sys; print(json.dumps({"type":"system","subtype":"init"})); print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"```json\n"+sys.argv[1]+"\n```"}]}}))' "$body"
SH
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

r="$tmp/repo"; mkdir -p "$r/cases"
(cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
 printf '# standard\n' > REVIEW.md && printf 'ok\n' > gate.sh
 # The repository's own angle prompt, read from the base: there is no default.
 mkdir -p .github/claude-review && printf 'You are reviewing for CORRECTNESS.\n' > .github/claude-review/bugs.md
 git add -A && git commit -q -m base
 printf 'exit 0 # fails open\n' > gate.sh && git commit -q -am "introduce the bug"
 printf 'docs\n' > README && git add README && git commit -q -m "a clean change")
bug=$(git -C "$r" rev-parse HEAD~1); clean=$(git -C "$r" rev-parse HEAD)
printf '{"name":"gate-fails-open","control":"review","introduced":"%s","fix":"x","angle":"bugs","expect_file":"gate.sh","expect_any":["fails open"]}' "$bug" > "$r/cases/001.json"
printf '{"name":"docs-only","kind":"clean","commit":"%s","angle":"bugs","why":"a README line"}' "$clean" > "$r/cases/002.json"
printf '{"name":"deterministic","control":"bash lint.sh {file}","fix":"x","file":"a"}' > "$r/cases/003.json"

# run <env assignments...> -- <args...>: the eval's exit code, output kept in $tmp/out.
# The eval screens its output against the token it holds, so every run holds a
# dummy one unless the assignments replace it.
run() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  (cd "$r" && env CLAUDE_CODE_OAUTH_TOKEN=dummy-oauth-token-for-tests "${envs[@]}" node "$E" "$@" >"$tmp/out" 2>&1); echo $?
}

hit='[{"severity":"important","file":"gate.sh","line":1,"title":"the gate fails open"}]'
nit='[{"severity":"nit","file":"gate.sh","line":1,"title":"the gate fails open"}]'
assert_eq "0" "$(run REVIEW_JSON="$hit" -- cases --base main --no-verify --only gate-fails-open)" "a caught incident passes"
assert_eq "1" "$(run REVIEW_JSON='[]' -- cases --base main --no-verify --only gate-fails-open)" "a missed incident fails"
assert_eq "1" "$(run REVIEW_JSON="$nit" -- cases --base main --no-verify --only gate-fails-open)" "an incident reported only as a nit fails"
assert_eq "1" "$(run REVIEW_JSON="$hit" -- cases --base main --no-verify --only docs-only)" "an important finding on a clean change fails"
assert_eq "0" "$(run REVIEW_JSON="$nit" -- cases --base main --no-verify --only docs-only)" "a nit on a clean change passes"
assert_contains "$(cat "$tmp/out")" "clean cases flagged 0 of 1" "the summary counts clean cases flagged"

# With verification on, a finding two of three verifiers refute is not counted,
# and one they keep still is.
refute='[{"index":0,"verdict":"false","reason":"README only"}]'
keep='[{"index":0,"verdict":"real"}]'
assert_eq "0" "$(run REVIEW_JSON="$hit" VERDICT_JSON="$refute" -- cases --base main --only docs-only)" "a refuted finding on a clean change is dropped by the vote"
assert_eq "0" "$(run REVIEW_JSON="$hit" VERDICT_JSON="$refute" -- cases --base main --only docs-only)" "a refuted finding again"
assert_contains "$(cat "$tmp/out")" "reviewer reported 1, the vote dropped 1, 0 kept" "the log tells a refuted finding from one never reported"
assert_eq "1" "$(run REVIEW_JSON="$hit" VERDICT_JSON="$keep" -- cases --base main --only docs-only)" "and one the verifiers keep still fails it"

# The deterministic case is skipped: only the incident and the clean case run.
run REVIEW_JSON="$hit" -- cases --base main --no-verify >/dev/null
assert_contains "$(cat "$tmp/out")" "2 case(s)" "only incident and clean cases are run"

# Against a baseline, only a case that passed before and fails now regresses.
printf '{"cases":{"gate-fails-open":"fail","docs-only":"pass"}}' > "$r/baseline.json"
assert_eq "0" "$(run REVIEW_JSON='[]' -- cases --base main --no-verify --baseline baseline.json)" "a miss already in the baseline does not fail"
assert_contains "$(cat "$tmp/out")" "known     gate-fails-open" "but it is reported as known"
assert_eq "1" "$(run REVIEW_JSON="$hit" -- cases --base main --no-verify --baseline baseline.json)" "a clean case that passed before and now flags regresses"
assert_contains "$(cat "$tmp/out")" "REGRESSED docs-only" "and names the case"
assert_contains "$(cat "$tmp/out")" "improved  gate-fails-open" "while the newly caught incident is reported as improved"
printf '{"cases":{"docs-only":"pass"}}' > "$r/partial.json"
run REVIEW_JSON='[]' -- cases --base main --no-verify --baseline partial.json >/dev/null
assert_contains "$(cat "$tmp/out")" "new       gate-fails-open" "a case with no baseline entry is reported as new"
# The repository's own incident, with its expect_any read from the real case
# file, replayed against a fixture commit to deploy-dev.yml.
real_case="$ROOT/evals/cases/deploy-dev-config-status.json"
(cd "$r" && mkdir -p .github/workflows \
 && printf 'run: config=$(terminus drush "$SITE.dev" -- config:status --format=json)\n' > .github/workflows/deploy-dev.yml \
 && git add .github/workflows/deploy-dev.yml && git commit -q -m "compare drush output as json")
deploy=$(git -C "$r" rev-parse HEAD)
mkdir -p "$r/deploy-cases"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["introduced"]=sys.argv[2]; print(json.dumps(c))' \
  "$real_case" "$deploy" > "$r/deploy-cases/deploy-dev-config-status.json"
printf '{"cases":{"deploy-dev-config-status":"pass"}}' > "$r/deploy-baseline.json"
assert_eq "1" "$(run REVIEW_JSON='[]' -- deploy-cases --base main --no-verify --baseline deploy-baseline.json)" "a reviewer that reports nothing regresses an incident the baseline records as passing"
assert_contains "$(cat "$tmp/out")" "REGRESSED deploy-dev-config-status" "and names the incident"
other='[{"severity":"important","file":".github/workflows/deploy-dev.yml","line":1,"title":"drush deploy runs before the database backup, so a failed update cannot be rolled back"}]'
assert_eq "1" "$(run REVIEW_JSON="$other" -- deploy-cases --base main --no-verify)" "an important finding about a different Drush issue in deploy-dev.yml does not catch the incident"
assert_contains "$(cat "$tmp/out")" "none naming the incident" "and the reason says the finding does not name it"
caught='[{"severity":"important","file":".github/workflows/deploy-dev.yml","line":1,"title":"Drush log lines on stdout make the config:status output not valid JSON"}]'
assert_eq "0" "$(run REVIEW_JSON="$caught" -- deploy-cases --base main --no-verify)" "while a finding naming the log lines on stdout catches it"

printf 'nope' > "$r/bad-baseline.json"
assert_eq "2" "$(run REVIEW_JSON='[]' -- cases --base main --no-verify --baseline bad-baseline.json)" "an unreadable baseline is refused, not ignored"

# A case that could not run is never a pass.
assert_eq "2" "$(run FAKE_FAIL=1 -- cases --base main --no-verify)" "an agent that could not run is exit 2"
assert_contains "$(cat "$tmp/out")" "could not run" "and says so"
mkdir -p "$r/empty"
assert_eq "2" "$(run X=1 -- empty --base main)" "a directory with no live cases measured nothing"
printf '{"name":"broken","kind":"clean","angle":"bugs"}' > "$r/cases/004.json"
assert_eq "2" "$(run X=1 -- cases --base main)" "a case missing its fields is refused"

# The diff is a file the agent opens with the Read tool, outside the worktree it
# runs in, so each case gets an input directory that the agent is given with
# --add-dir and that the prompt names.
rm -f "$r/cases/004.json"; : > "$tmp/args.log"
run REVIEW_JSON="$hit" ARGS_LOG="$tmp/args.log" -- cases --base main --no-verify --only gate-fails-open >/dev/null
assert_contains "$(cat "$tmp/args.log")" "add-dir " "the reviewer is given --add-dir"
dir=$(awk '/^add-dir /{print $2; exit}' "$tmp/args.log")
case "$dir" in /*) abs=0;; *) abs=1;; esac
assert_exit 0 "$abs" "for an absolute directory, without quotes ($dir)"
assert_contains "$(cat "$tmp/args.log")" "add-dir $dir patch" "which holds the review diff when the agent starts"
assert_contains "$(cat "$tmp/args.log")" "prompt-names $dir" "and the prompt names the diff there"

# The reviewer gets the review job's path rules, written from the repository
# under review and the input directory's parent, as one argument without the
# quotes that keep it whole in claude_args.
deny=$(awk '/^deny /{print $2; exit}' "$tmp/args.log")
top=$(git -C "$r" rev-parse --show-toplevel)
for rule in 'Read(//proc/**)' "Grep(/$top/.git)" "Read(/$top/.git/**)" "Read(/$HOME/.*/**)"; do
  assert_contains ",$deny," ",$rule," "the reviewer's deny list holds $rule"
done
case "$deny" in *"'"*) echo "FAIL: the deny list reached the agent with its quotes" >&2; exit 1 ;; esac

# When the argument script refuses a runner path, the case cannot run and the
# eval says which variable was refused, from the script's own reason.
assert_eq "2" "$(run REVIEW_JSON="$hit" RUNNER_TEMP='/bad path' -- cases --base main --no-verify --only gate-fails-open)" "a refused runner path stops the case"
assert_contains "$(cat "$tmp/out")" "compose-agent-args.sh refused the reviewer's arguments" "the eval says the argument script refused"
assert_contains "$(cat "$tmp/out")" "RUNNER_TEMP must be an absolute path" "and passes on its reason, naming the variable"

# reviewArgs splits the composed line as claude-code-action does for the
# shapes it holds: a double-quoted directory and a single-quoted rule list are
# each one word with the quotes removed. A word quoted around a space, an
# unclosed quote or a backslash makes the line unusable.
args_of() { LINE="$1" node --input-type=module -e "import { reviewArgs } from '$E'; try { console.log(JSON.stringify(reviewArgs(process.env.LINE))); } catch { console.log('unusable'); }"; }
assert_eq '["--add-dir","/a","--max-turns","3","--disallowedTools","Bash,Read(//proc/**),Grep(//h/.*)"]' \
  "$(args_of "AGENT_ARGS_REVIEW=--add-dir \"/a\" --max-turns 3 --disallowedTools 'Bash,Read(//proc/**),Grep(//h/.*)'")" \
  "a single-quoted rule list is one word without its quotes"
for bad in "--disallowedTools 'Bash Read'" "--disallowedTools 'Bash" "--disallowedTools Bash'x'" "--add-dir \"/a b\"" "--x a\\b"; do
  assert_eq "unusable" "$(args_of "$bad")" "refused: $bad"
done

# A link the case commit adds is replaced before any agent runs, with the same
# script the review action runs on the head, so the agent's Read cannot follow
# it out of the case tree.
outside="$tmp/outside-secret"; printf 'outside the tree\n' > "$outside"
(cd "$r" && ln -s "$outside" leak && git add leak && git commit -q -m "add a link out of the tree")
linked=$(git -C "$r" rev-parse HEAD)
mkdir -p "$r/link-cases"
printf '{"name":"adds-a-link","kind":"clean","commit":"%s","angle":"bugs","why":"a link"}' "$linked" > "$r/link-cases/001.json"
: > "$tmp/link.log"
assert_eq "0" "$(run REVIEW_JSON='[]' LINK_LOG="$tmp/link.log" -- link-cases --base main --no-verify)" "a case whose tree holds a link still runs"
assert_eq "file symlink to: $outside" "$(cat "$tmp/link.log")" "and the agent finds a file naming the link's target, not the link"
assert_contains "$(cat "$tmp/out")" "replace-symlinks: replaced 1 symlink(s)" "the eval logs the replacement"

# Every agent's trace goes through the review job's tool check, with the case
# tree as the workspace: a refused call fails the case with the check's reason,
# whatever the agent reported.
assert_eq "0" "$(run REVIEW_JSON="$hit" REVIEW_READ=gate.sh -- cases --base main --no-verify --only gate-fails-open)" "a Read inside the case tree passes the tool check"
assert_contains "$(cat "$tmp/out")" "check-trace-tools: 1 tool call(s), all Read, Glob or Grep, all inside the allowed roots" "and the check's verdict is logged"
: > "$tmp/summary.md"
assert_eq "2" "$(run REVIEW_JSON="$hit" REVIEW_READ=.git/config GITHUB_STEP_SUMMARY="$tmp/summary.md" -- cases --base main --no-verify --only gate-fails-open)" "a reviewer Read of the case tree's .git fails the eval"
assert_contains "$(cat "$tmp/out")" "check-trace-tools.sh refused the reviewer's trace" "the eval says the tool check refused"
assert_contains "$(cat "$tmp/out")" "Read call 1: path under .git" "and passes on the check's reason"
assert_contains "$(grep '^| gate-fails-open |' "$tmp/summary.md")" "path under .git (field file_path); check-trace-tools: the agent called" "the job summary row holds the whole reason on one line"
assert_eq "2" "$(run REVIEW_JSON="$hit" REVIEW_READ="$r/.git/config" -- cases --base main --no-verify --only gate-fails-open)" "a Read of the repository's own .git/config fails it too"
assert_contains "$(cat "$tmp/out")" "path outside the allowed roots" "as outside the allowed roots"
assert_eq "2" "$(run REVIEW_JSON="$hit" VERDICT_JSON="$keep" VERIFY_READ=/proc/self/environ -- cases --base main --only gate-fails-open)" "a verifier's refused Read fails the case instead of counting as a vote"
assert_contains "$(cat "$tmp/out")" "check-trace-tools.sh refused verifier 1's trace" "and names the verifier"

# What the agents wrote is screened against the token the eval holds, with the
# review job's screen, before any of it reaches the log, the job summary or
# --out. The token is random for this run, so only the agent's output can
# have put it there.
token="sk-ant-oat01-$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
leak="[{\"severity\":\"important\",\"file\":\"gate.sh\",\"line\":1,\"title\":\"the gate fails open, token $token\"}]"
: > "$tmp/summary.md"; rm -f "$tmp/results.json"
assert_eq "2" "$(run CLAUDE_CODE_OAUTH_TOKEN="$token" REVIEW_JSON="$leak" GITHUB_STEP_SUMMARY="$tmp/summary.md" -- cases --base main --no-verify --only gate-fails-open --out "$tmp/results.json")" "a finding holding the token fails the eval"
assert_contains "$(cat "$tmp/out")" "a screened file contains the value of: CLAUDE_CODE_OAUTH_TOKEN" "the log says the screen refused, naming the secret"
for f in "$tmp/out" "$tmp/summary.md" "$tmp/results.json"; do
  [ -s "$f" ] || { echo "FAIL: $f was not written" >&2; exit 1; }
  if grep -qF "$token" "$f"; then echo "FAIL: the token reached $f" >&2; exit 1; fi
done
assert_contains "$(cat "$tmp/summary.md")" "the secret screen refused" "the job summary gives the screen's reason instead"
assert_contains "$(cat "$tmp/results.json")" "the secret screen refused" "and so does --out"
# A finding the verifiers refute is printed as dropped: it is screened as well.
: > "$tmp/summary.md"; rm -f "$tmp/results.json"
assert_eq "2" "$(run CLAUDE_CODE_OAUTH_TOKEN="$token" REVIEW_JSON="$leak" VERDICT_JSON="$refute" GITHUB_STEP_SUMMARY="$tmp/summary.md" -- cases --base main --only docs-only --out "$tmp/results.json")" "a dropped finding holding the token fails the eval too"
for f in "$tmp/out" "$tmp/summary.md" "$tmp/results.json"; do
  [ -s "$f" ] || { echo "FAIL: $f was not written" >&2; exit 1; }
  if grep -qF "$token" "$f"; then echo "FAIL: the dropped title's token reached $f" >&2; exit 1; fi
done
assert_contains "$(cat "$tmp/out")" "CLAUDE_CODE_OAUTH_TOKEN" "and the screen names the secret"
# A clean output passes the screen, and the log shows that it ran.
assert_eq "0" "$(run CLAUDE_CODE_OAUTH_TOKEN="$token" REVIEW_JSON="$hit" -- cases --base main --no-verify --only gate-fails-open)" "output without the token passes the screen"
assert_contains "$(cat "$tmp/out")" "keep-trace: screened" "and the screen's line is logged"
# With no token to compare against the screen cannot run, and fails closed.
assert_eq "2" "$(run CLAUDE_CODE_OAUTH_TOKEN= REVIEW_JSON="$hit" -- cases --base main --no-verify --only gate-fails-open)" "an eval holding no token cannot screen and fails"
assert_contains "$(cat "$tmp/out")" "no secret long enough to compare against" "with the screen's reason"

# ANTHROPIC_API_KEY, when the eval holds one, is screened as well.
apikey="sk-ant-api03-$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
keyleak="[{\"severity\":\"important\",\"file\":\"gate.sh\",\"line\":1,\"title\":\"the gate fails open, key $apikey\"}]"
assert_eq "2" "$(run ANTHROPIC_API_KEY="$apikey" REVIEW_JSON="$keyleak" -- cases --base main --no-verify --only gate-fails-open)" "a finding holding ANTHROPIC_API_KEY fails the eval"
assert_contains "$(cat "$tmp/out")" "a screened file contains the value of: ANTHROPIC_API_KEY" "and the screen names it"
if grep -qF "$apikey" "$tmp/out"; then echo "FAIL: the API key reached the log" >&2; exit 1; fi

# The agent's whole stderr is screened, not only the part kept for the reason.
long=$(printf 'x%.0s' $(seq 1 400))
assert_eq "2" "$(run CLAUDE_CODE_OAUTH_TOKEN="$token" FAKE_FAIL=1 FAKE_STDERR="$long $token" -- cases --base main --no-verify --only gate-fails-open)" "a failed agent's stderr is screened"
assert_contains "$(cat "$tmp/out")" "a screened file contains the value of: CLAUDE_CODE_OAUTH_TOKEN" "including past its first 300 characters"
if grep -qF "$token" "$tmp/out"; then echo "FAIL: the stderr token reached the log" >&2; exit 1; fi

# Nothing replay prints reaches the log before the screen has passed it.
run REVIEW_JSON="$hit" -- cases --base main --no-verify --only gate-fails-open >/dev/null
screened=$(grep -n "keep-trace: screened" "$tmp/out" | head -1 | cut -d: -f1)
assembled=$(grep -n "assemble-review-prompt:" "$tmp/out" | head -1 | cut -d: -f1)
checked=$(grep -n "check-trace-tools:" "$tmp/out" | head -1 | cut -d: -f1)
[ -n "$screened" ] && [ -n "$assembled" ] && [ -n "$checked" ] && [ "$screened" -lt "$assembled" ] && [ "$screened" -lt "$checked" ] \
  || { echo "FAIL: replay's lines were printed before the screen (screen $screened, prompt $assembled, check $checked)" >&2; exit 1; }

# Each case's work directory, traces included, is removed once screened,
# whether the screen passed or refused.
mkdir -p "$tmp/tmpdir"
run TMPDIR="$tmp/tmpdir" REVIEW_JSON="$hit" -- cases --base main --no-verify --only gate-fails-open >/dev/null
run TMPDIR="$tmp/tmpdir" CLAUDE_CODE_OAUTH_TOKEN="$token" REVIEW_JSON="$leak" -- cases --base main --no-verify --only gate-fails-open >/dev/null
assert_eq "" "$(ls -A "$tmp/tmpdir")" "no case work directory is left behind"

# A temporary directory reached through a link: the tool check gets real
# paths, so a Read of the tree by its physical path passes.
mkdir -p "$tmp/realtmp"; ln -s "$tmp/realtmp" "$tmp/linktmp"
assert_eq "0" "$(run TMPDIR="$tmp/linktmp" REVIEW_JSON="$hit" READ_CWD=1 -- cases --base main --no-verify --only gate-fails-open)" "a Read by the tree's physical path passes when the temporary directory is a link"

# A case name outside the path allowlist does not make its own paths refused.
mkdir -p "$r/odd-cases"
printf '{"name":"gate: fails open","control":"review","introduced":"%s","fix":"x","angle":"bugs","expect_file":"gate.sh","expect_any":["fails open"]}' "$bug" > "$r/odd-cases/001.json"
assert_eq "0" "$(run REVIEW_JSON="$hit" READ_DIFF=1 -- odd-cases --base main --no-verify)" "a case named with a colon and a space can read its own diff"

# A case commit is a full 40-character sha. Git resolves a short sha through
# refs before objects, so a tag named after a case's short sha would choose the
# tree the agents run in. A short one is refused before any agent runs.
short=${clean:0:8}
git -C "$r" tag "$short" "$bug"
mkdir -p "$r/short-cases" "$r/full-cases"
printf '{"name":"docs-only","kind":"clean","commit":"%s","angle":"bugs","why":"a README line"}' "$short" > "$r/short-cases/001.json"
: > "$tmp/tree.log"
assert_eq "2" "$(run REVIEW_JSON='[]' TREE_LOG="$tmp/tree.log" -- short-cases --base main --no-verify)" "a case with a short commit sha is refused"
assert_contains "$(cat "$tmp/out")" "which is not a full 40-character sha" "and the eval says why"
assert_eq "" "$(cat "$tmp/tree.log")" "before any agent runs in the tree a tag named after it chose"
printf '{"name":"gate-fails-open","control":"review","introduced":"%s","fix":"x","angle":"bugs","expect_file":"gate.sh","expect_any":["fails open"]}' "${bug:0:8}" > "$r/short-cases/001.json"
assert_eq "2" "$(run REVIEW_JSON='[]' -- short-cases --base main --no-verify)" "and so is an incident whose introduced is a short sha"
# With the full sha, the tag named after its short form changes nothing.
printf '{"name":"docs-only","kind":"clean","commit":"%s","angle":"bugs","why":"a README line"}' "$clean" > "$r/full-cases/001.json"
: > "$tmp/tree.log"
assert_eq "0" "$(run REVIEW_JSON='[]' TREE_LOG="$tmp/tree.log" -- full-cases --base main --no-verify)" "a case with a full sha runs beside a tag named after its short form"
assert_eq "$clean" "$(cat "$tmp/tree.log")" "in the tree of the case's own commit"
git -C "$r" tag -d "$short" >/dev/null

# The repository's own cases all name their commits by full sha.
for f in "$ROOT"/evals/cases/*.json; do
  bad=$(F="$f" node --input-type=module -e "import { readFileSync } from 'node:fs'; import { caseKind, validate } from '$E'; const c = JSON.parse(readFileSync(process.env.F, 'utf8')); const k = caseKind(c); console.log(k ? (validate(c, k) || '') : '');")
  assert_eq "" "$bad" "$(basename "$f") is a valid case"
done

pass "review-eval.test.sh"
