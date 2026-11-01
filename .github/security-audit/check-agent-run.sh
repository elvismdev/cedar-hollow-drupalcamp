#!/usr/bin/env bash
# Checks what an audit agent step actually did, from its execution trace and
# from the state of the runner before and after it. It runs after every agent
# step, and a failure stops the job before anything is handed off.
#
# The deny rules refuse most misuse before it happens; this reads the trace and
# the machine afterwards, so a rule that stopped reaching the agent fails the
# job instead of passing silently.
#
# The tool names, each tool's closed input fields, the character allowlist and
# the read and write roots are checked by the review practice's
# check-trace-tools.sh, given the allowed tools, the output root (read and
# write), $AUDIT_INPUT_DIR (read, when set), the job folder that holds the
# output root (read, only when it holds nothing but in/ and out/ on disk) and
# --grep-any-glob-in-subfolders,
# so a Grep rooted in a folder below the checkout's top level may use negated
# globs and brace lists of folders. The rules below are the audit's own:
#
#   - Every call of the subagent tool (named Agent in calls and Task in the
#     session's tool list, so both names are treated alike) must
#     declare exactly one agent id in its description as "agent-id: <id>", the
#     skill's canonical form ^[a-z0-9][a-z0-9_-]{0,63}$, unique in the trace.
#     A message whose parent_tool_use_id is that call's id belongs to that
#     subagent. A call in a message whose parent matches no subagent call
#     cannot be attributed and fails.
#   - A subagent ran in the foreground, judged by what happened rather than
#     by the run_in_background value its call asked for (any value is
#     accepted, since CLAUDE_CODE_DISABLE_BACKGROUND_TASKS keeps every
#     subagent in the foreground): no task_started event marked
#     is_backgrounded, no background count in the result's subagent_stats,
#     no subagent call whose result is an async launch rather than the
#     subagent's report, and its calls in the trace (below). A launch result
#     is a plain string or a single text block that starts with the text in
#     async-launch.txt, as every background launch in Claude Code 2.1.316
#     does; a report that quotes the phrase elsewhere is not one. This
#     catches a subagent that backgrounds after some calls; judge-canary.sh
#     reads the same file. Its refusal names the call's position and the
#     declared agent id, which has the canonical form below.
#   - Every subagent call has a tool_result in the trace: a call with none
#     cannot be shown to have finished in the foreground.
#   - A subagent's Write or Edit lands under
#     <output-root>/agents/<its-id>/scratch/, and never on a file whose name is
#     one of the shared or combined files that only the top-level agent or the
#     trusted scripts write (SHARED below), wherever it is.
#   - No agent, the top-level one included, writes a file named as one of
#     merge-records.py's trusted outputs (TRUSTED below), wherever it is.
#   - Outside the source job (whose source and repair agents are the skill's
#     parent), no agent, the top-level one included, writes a file named as
#     one of the run's state files (STATE below), wherever it is: after the
#     source job only merge-records.py changes them.
#   - In poc-write the top-level agent writes nothing under agents/, so each
#     proof-of-concept script can only come from the subagent whose scratch
#     holds it.
#   - In poc-write, a subagent's Read, Glob or Grep may not reach another
#     agent's agents/<id>/: a target inside one fails, and so does a Glob or Grep
#     rooted at agents/ or above it, which would search them all. In poc-decide
#     and cross-check the same holds for the agents/<id>/ of every other
#     subagent declared in the same trace, so no verifier sees another's
#     entry; other directories under agents/ (the source job's agents, the
#     decider's promoted artifacts) stay readable, and a Glob or Grep rooted
#     at agents/ or above fails only when another subagent is declared. The
#     scripts and run records the deciders read sit under the input
#     directory, outside the output root's agents/. Every brace
#     group in the path, the Glob pattern and the Grep glob is expanded first
#     and each expansion is judged, so {.,}./x is judged as ../x and ./x. A
#     Glob pattern with a .. segment at or after its first wildcard, or a Grep
#     glob with any .. segment, fails, because where it lands cannot be judged
#     without matching it on disk; so do braces that cannot be expanded with
#     confidence (a backslash, an unbalanced brace, or more than 256
#     expansions). The expander is check-trace-tools.sh's own,
#     expand-braces.cjs, so both checks judge the same expansions.
#   - Every model in a result's modelUsage, and on every assistant message
#     except Claude Code's own <synthetic> ones, is the pinned model or the
#     allowlisted helper.
#   - A foreground subagent hands its report back with SubagentHandback, which
#     check-trace-tools.sh accepts only with exactly a string message and only
#     when the allowed tools name it; it counts as a call attributed to that
#     subagent like any other.
#   - Every subagent call must have at least one tool call attributed to it,
#     and if subagents were used at all (a subagent call, a task_started event
#     or a spawned count) the trace must hold their tool calls.
#   - The checkout (git status and HEAD), ~/.claude/settings.json apart from
#     enableAllProjectMcpServers, ~/.claude/CLAUDE.md and the ~/.claude agents,
#     commands and hooks trees match the fingerprint taken before the step.
#
# The fingerprint holds only hashes and HEAD, and a refusal names the tool, the
# call's position and a fixed label, never a path, an id or a model: the job
# log is public and those are agent-written or attacker-reachable text.
#
# Fails closed: a missing or unreadable trace or fingerprint fails the check.
#
# Usage:
#   check-agent-run.sh --fingerprint <out-file>
#   check-agent-run.sh <job> <execution-file> <allowed-tools> <output-root> \
#                      <fingerprint-file> <model> [helper-model]
#     <job>            source, poc-write, poc-decide or cross-check
#     <allowed-tools>  comma-separated, as check-trace-tools.sh --tools takes
#   GITHUB_WORKSPACE (the checkout), HOME, and optionally AUDIT_INPUT_DIR.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CTT="$HERE/../claude-review/tools/review/check-trace-tools.sh"

usage() {
  echo "usage: check-agent-run.sh --fingerprint <out-file>" >&2
  echo "       check-agent-run.sh <job> <execution-file> <allowed-tools> <output-root> <fingerprint-file> <model> [helper-model]" >&2
  exit 2
}

# One labelled line per watched thing. A path that does not exist is skipped
# by the tree hash. settings.json is hashed whole, apart from
# enableAllProjectMcpServers, the one key claude-code-action writes during the
# agent step (it creates the file holding only that key when none exists), so
# a missing file and one holding only that key hash alike. Any other key
# counts, because hooks, permissions, apiKeyHelper, statusLine, env and others
# change what a later Claude run in the same job executes.
#
# Fails closed: it returns non-zero, naming the part, when the workspace is not
# the top of a git repository, when git, jq or find fails (git's refusal of a
# directory it judges of dubious ownership included), or when settings.json
# exists but does not parse. Each command's status is checked explicitly,
# because callers run this in a context where set -e does not apply.
fingerprint() {
  local ws="${GITHUB_WORKSPACE:-}" claude="$HOME/.claude"
  local top head status settings files paths=() p
  if [ -z "$ws" ]; then echo "check-agent-run: GITHUB_WORKSPACE is not set" >&2; return 1; fi
  top=$(git -C "$ws" rev-parse --show-toplevel 2>/dev/null) \
    && [ "$(cd "$top" && pwd -P)" = "$(cd "$ws" && pwd -P)" ] \
    || { echo "check-agent-run: the workspace is not the top of a git repository git can read" >&2; return 1; }
  head=$(git -C "$ws" rev-parse --verify HEAD 2>/dev/null) \
    || { echo "check-agent-run: git could not read HEAD" >&2; return 1; }
  status=$(git -C "$ws" status --porcelain=v1 -uall 2>/dev/null | sha256sum | cut -d' ' -f1) \
    || { echo "check-agent-run: git status failed" >&2; return 1; }
  if [ -e "$claude/settings.json" ]; then
    settings=$(jq -cS 'del(.enableAllProjectMcpServers)' "$claude/settings.json" 2>/dev/null | sha256sum | cut -d' ' -f1) \
      || { echo "check-agent-run: ~/.claude/settings.json exists but cannot be read as JSON" >&2; return 1; }
  else
    settings=$(jq -ncS '{}' | sha256sum | cut -d' ' -f1) \
      || { echo "check-agent-run: jq failed" >&2; return 1; }
  fi
  for p in CLAUDE.md agents commands hooks; do
    if [ -e "$claude/$p" ]; then paths+=("$claude/$p"); fi
  done
  if [ "${#paths[@]}" -gt 0 ]; then
    files=$(find "${paths[@]}" -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1) \
      || { echo "check-agent-run: the ~/.claude files could not be hashed" >&2; return 1; }
  else
    files=none
  fi
  printf 'head %s\nstatus %s\nsettings %s\nclaude-files %s\n' "$head" "$status" "$settings" "$files"
}

if [ "${1:-}" = "--fingerprint" ]; then
  [ "$#" -eq 2 ] || usage
  if ! fp=$(fingerprint); then
    rm -f "$2"
    echo "check-agent-run: no fingerprint written" >&2
    exit 1
  fi
  printf '%s\n' "$fp" > "$2"
  echo "check-agent-run: fingerprint written"
  exit 0
fi

[ "$#" -eq 6 ] || [ "$#" -eq 7 ] || usage
job="$1" trace="$2" allowed="$3" out_root="$4" fp_file="$5" model="$6" helper="${7:-}"
case "$job" in
  source|poc-write|poc-decide|cross-check) ;;
  *) echo "check-agent-run: unknown job" >&2; exit 2 ;;
esac
case "$out_root" in /*) ;; *) echo "check-agent-run: the output root must be absolute" >&2; exit 2 ;; esac
[ -n "$model" ] || usage
[ -n "${GITHUB_WORKSPACE:-}" ] || { echo "check-agent-run: GITHUB_WORKSPACE is not set" >&2; exit 1; }

failed=0

roots=(--root "$out_root")
if [ -n "${AUDIT_INPUT_DIR:-}" ]; then roots+=(--root "$AUDIT_INPUT_DIR"); fi
# The job folder holding in/ and out/ (/mnt/audit/<job>) is a read root too,
# but only when, on disk now, it holds nothing else: then a search from it
# reaches only what the two roots already allow.
job_dir="$(dirname "$out_root")"
if [ "$(basename "$out_root")" = out ] && [ -d "$job_dir" ] && [ ! -L "$job_dir" ] \
  && [ "$(find "$job_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | paste -sd' ' -)" = "in out" ] \
  && [ -d "$job_dir/in" ] && [ ! -L "$job_dir/in" ] && [ -d "$job_dir/out" ] && [ ! -L "$job_dir/out" ]; then
  roots+=(--root "$job_dir")
fi
if ! bash "$CTT" "$trace" --tools "$allowed" "${roots[@]}" --write-root "$out_root" \
  --grep-any-glob-in-subfolders; then
  failed=1
fi

if ! node - "$trace" "$job" "$out_root" "$GITHUB_WORKSPACE" "$model" "$helper" \
  "$HERE/../claude-review/tools/review/expand-braces.cjs" "$HERE/async-launch.txt" <<'JS'
const fs = require('fs');
const path = require('path').posix;

const [trace, job, outArg, wsArg, model, helper, expander, launchFile] = process.argv.slice(2);
const say = (line) => console.error(`check-agent-run: ${line}`);

let msgs;
try {
  msgs = JSON.parse(fs.readFileSync(trace, 'utf8'));
} catch (err) {
  say(`the trace is missing or not readable JSON (${err.name}), so the run cannot be checked`);
  process.exit(1);
}
if (!Array.isArray(msgs)) {
  say('the trace is not a list of messages, so the run cannot be checked');
  process.exit(1);
}

const out = path.normalize(outArg);
const ws = path.normalize(wsArg);
const agentsDir = path.join(out, 'agents');
const SUBAGENT_TOOLS = new Set(['Agent', 'Task']);
const ID = /^[a-z0-9][a-z0-9_-]{0,63}$/;
// Files only the top-level agent or the trusted scripts write.
const SHARED = new Set([
  'findings.json', 'coverage-ledger.json', 'run-metadata.json', 'disputed.json',
  'audit-history.json', 'select.json', 'poc-manifest.json', 'cross-check.json',
  'tie-break.json', 'validator-errors.txt',
]);
// merge-records.py's trusted outputs, which no agent writes.
const TRUSTED = new Set(['trusted-meta.json', 'tie-break-inputs.json', 'select.json', 'list.json']);
// The run's state files, which only the source job's agents write.
const STATE = new Set(['findings.json', 'coverage-ledger.json', 'run-metadata.json', 'disputed.json', 'audit-history.json']);
const MODELS = new Set([model, helper].filter(Boolean));

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const under = (p, root) => p === root || p.startsWith(root.replace(/\/+$/, '') + '/');
const resolve = (p, base) => path.normalize(p.startsWith('/') ? p : path.join(base, p));

// Every tool_use object, depth first in document order, numbered across the
// whole trace exactly as check-trace-tools.sh numbers them.
function* toolUses(node) {
  if (isObj(node)) {
    if (node.type === 'tool_use') yield node;
    for (const v of Object.values(node)) yield* toolUses(v);
  } else if (Array.isArray(node)) {
    for (const v of node) yield* toolUses(v);
  }
}

const calls = [];
for (const m of msgs) {
  const parent = isObj(m) && typeof m.parent_tool_use_id === 'string' ? m.parent_tool_use_id : null;
  for (const c of toolUses(m)) calls.push({ n: calls.length + 1, c, parent });
}
const label = ({ n, c }) => `${SUBAGENT_TOOLS.has(c.name) || ['Read', 'Glob', 'Grep', 'Write', 'Edit'].includes(c.name) ? c.name : 'tool'} call ${n}`;

let bad = 0;
const refuse = (call, why) => { bad += 1; say(`${label(call)}: ${why}`); };

// Bind each subagent call to its declared id.
const subagents = new Map();
const seenIds = new Set();
for (const call of calls) {
  const { c } = call;
  if (!SUBAGENT_TOOLS.has(c.name)) continue;
  const input = isObj(c.input) ? c.input : {};
  const desc = typeof input.description === 'string' ? input.description : '';
  // ASCII only: "agent-id:", then spaces or tabs, then the id, which must end
  // at an ASCII blank or the end of the text.
  const ids = [...desc.matchAll(/(?:^|[ \t\r\n])agent-id:[ \t]*([A-Za-z0-9_-]+)(?=$|[ \t\r\n])/g)].map((x) => x[1]);
  let id = null;
  if (ids.length !== 1 || !ID.test(ids[0])) {
    refuse(call, 'does not declare exactly one valid agent id');
  } else if (seenIds.has(ids[0])) {
    refuse(call, 'declares an agent id another subagent call already declared');
  } else {
    id = ids[0];
    seenIds.add(id);
  }
  if (typeof c.id !== 'string' || c.id === '') {
    refuse(call, 'has no call id, so its subagent cannot be attributed');
  } else {
    subagents.set(c.id, id);
  }
}

// Background starts and subagent use as Claude Code itself reports them.
let started = 0;
let spawned = 0;
for (const m of msgs) {
  if (!isObj(m)) continue;
  if (m.type === 'system' && m.subtype === 'task_started') {
    started += 1;
    if (m.is_backgrounded === true) { bad += 1; say('a task_started event is backgrounded: a subagent ran in the background'); }
  }
  if (m.type === 'result' && isObj(m.subagent_stats)) {
    const s = m.subagent_stats;
    spawned += Number(s.spawned) || 0;
    const bg = (Number(s.started_in_background) || 0) + (isObj(s.requested) ? Number(s.requested.background) || 0 : 0);
    if (bg > 0) { bad += 1; say('the result counts a background subagent'); }
  }
}

// A subagent call that returns at once with an async launch, rather than the
// subagent's report, started it in the background, whatever it did before.
const LAUNCH = fs.readFileSync(launchFile, 'utf8').trim();
if (!LAUNCH) { say('the async launch text is empty, so a background launch cannot be detected'); process.exit(1); }
// A launch is one plain string or one text block; a report of several
// blocks, or text that only quotes the phrase, is not.
const launchText = (r) => (typeof r.content === 'string' ? r.content
  : Array.isArray(r.content) && r.content.length === 1 && isObj(r.content[0]) && r.content[0].type === 'text'
    && typeof r.content[0].text === 'string' ? r.content[0].text : null);
function* toolResults(node) {
  if (isObj(node)) {
    if (node.type === 'tool_result') yield node;
    for (const v of Object.values(node)) yield* toolResults(v);
  } else if (Array.isArray(node)) {
    for (const v of node) yield* toolResults(v);
  }
}
const callById = new Map(calls.filter(({ c }) => typeof c.id === 'string').map((call) => [call.c.id, call]));
const answered = new Set();
for (const r of toolResults(msgs)) {
  if (typeof r.tool_use_id !== 'string' || !subagents.has(r.tool_use_id)) continue;
  answered.add(r.tool_use_id);
  const text = launchText(r);
  if (text !== null && text.startsWith(LAUNCH)) {
    const id = subagents.get(r.tool_use_id);
    refuse(callById.get(r.tool_use_id),
      `(agent id ${id === null ? 'not valid' : id}) returned an async launch: the subagent ran in the background`);
  }
}
for (const [callId] of subagents) {
  if (!answered.has(callId)) refuse(callById.get(callId), 'has no result in the trace, so it cannot be shown to have finished in the foreground');
}

// Brace expansion shared with check-trace-tools.sh: an array of expansions,
// or null when the braces cannot be expanded with confidence.
const { expandBraces } = require(expander);

// Every target a read-side call reaches, one per brace expansion, or null
// when any of them cannot be judged.
function readTargets(c) {
  const a = isObj(c.input) ? c.input : {};
  if (c.name === 'Read') {
    if (typeof a.file_path !== 'string') return null;
    const ps = expandBraces(a.file_path);
    return ps && ps.map((p) => resolve(p, ws));
  }
  let bases = [ws];
  if (typeof a.path === 'string' && a.path !== '') {
    const ps = expandBraces(a.path);
    if (!ps) return null;
    bases = ps.map((p) => resolve(p, ws));
  }
  if (c.name === 'Grep') {
    if (typeof a.glob === 'string') {
      const gs = expandBraces(a.glob);
      if (!gs || gs.some((g) => g.split(/[/,!]/).includes('..'))) return null;
    }
    return bases;
  }
  if (typeof a.pattern !== 'string') return bases;
  const pats = expandBraces(a.pattern);
  if (!pats) return null;
  const targets = [];
  for (const p of pats) {
    const segs = p.split('/');
    const w = segs.findIndex((s) => /[*?[\]]/.test(s));
    if (w !== -1 && segs.slice(w).includes('..')) return null;
    const literal = (w === -1 ? segs : segs.slice(0, w)).join('/') || '.';
    for (const b of bases) targets.push(resolve(literal, b));
  }
  return targets;
}

// The label for the first target that reaches another agent, else null.
// blocked(t) says whether a target inside agents/ belongs to an agent this
// subagent may not reach; anyOther whether any such agent exists, which
// decides whether a search of agents/ or above it reaches one.
function isolationRefusal(name, targets, blocked, anyOther) {
  if (targets === null) return 'a subagent search cannot be judged (.. or braces), so its reach is unknown';
  for (const t of targets) {
    if (name !== 'Read' && under(agentsDir, t) && anyOther) return 'a subagent searches agents/ or above it, reaching other agents';
    if (under(t, agentsDir) && t !== agentsDir && blocked(t)) {
      return "a subagent reads another agent's agents/<id>/";
    }
  }
  return null;
}

// The agent directory a target under agents/ lies in, by id.
const agentOf = (t) => path.relative(agentsDir, t).split('/')[0];
const declared = new Set([...subagents.values()].filter((v) => v !== null));

// The absolute, normalised path a Write or Edit names, or null when
// check-trace-tools.sh has refused its path already.
const writePath = (c) => ((c.name === 'Write' || c.name === 'Edit') && isObj(c.input)
  && typeof c.input.file_path === 'string' && c.input.file_path.startsWith('/')
  ? path.normalize(c.input.file_path) : null);

// The refusal for a write by any agent to a reserved file name, else null:
// a trusted output anywhere, or a state file outside the source job.
function reservedRefusal(p) {
  const name = path.basename(p);
  if (TRUSTED.has(name)) return "an agent writes one of merge-records.py's trusted outputs";
  if (job !== 'source' && STATE.has(name)) return 'an agent writes a state file outside the source job';
  return null;
}

// Rules for every agent's writes.
for (const call of calls) {
  const p = writePath(call.c);
  if (p === null) continue;
  const reserved = reservedRefusal(p);
  if (reserved) {
    refuse(call, reserved);
  } else if (job === 'poc-write' && call.parent === null && under(p, agentsDir)) {
    refuse(call, 'the top-level agent writes under agents/, where only each subagent writes its own script');
  }
}

let attributed = 0;
const perSubagent = new Map();
for (const call of calls) {
  const { c, parent } = call;
  if (parent === null) continue;
  if (!subagents.has(parent)) {
    refuse(call, 'is in a message whose parent is no subagent call, so it cannot be attributed');
    continue;
  }
  attributed += 1;
  perSubagent.set(parent, (perSubagent.get(parent) || 0) + 1);
  const id = subagents.get(parent);
  const a = isObj(c.input) ? c.input : {};

  if (c.name === 'Write' || c.name === 'Edit') {
    if (typeof a.file_path !== 'string' || !a.file_path.startsWith('/')) continue; // refused by check-trace-tools
    const p = path.normalize(a.file_path);
    if (reservedRefusal(p)) {
      // refused above
    } else if (SHARED.has(path.basename(p))) {
      refuse(call, 'a subagent writes a shared or combined file');
    } else if (id === null || !under(p, path.join(agentsDir, id, 'scratch')) || p === path.join(agentsDir, id, 'scratch')) {
      refuse(call, 'a subagent writes outside its own agents/<id>/scratch/');
    }
  }

  if (['Read', 'Glob', 'Grep'].includes(c.name)) {
    let why = null;
    if (job === 'poc-write') {
      why = isolationRefusal(c.name, readTargets(c), (t) => id === null || agentOf(t) !== id, true);
    } else if (job === 'poc-decide' || job === 'cross-check') {
      const others = [...declared].filter((d) => d !== id);
      why = isolationRefusal(c.name, readTargets(c),
        (t) => others.includes(agentOf(t)) || (id === null && declared.has(agentOf(t))), others.length > 0 || id === null);
    }
    if (why) refuse(call, why);
  }
}

for (const call of calls) {
  if (SUBAGENT_TOOLS.has(call.c.name) && typeof call.c.id === 'string' && call.c.id !== ''
      && !perSubagent.has(call.c.id)) {
    refuse(call, 'started a subagent with no tool calls in the trace, so what it did cannot be checked');
  }
}

const used = subagents.size > 0 || started > 0 || spawned > 0;
if (used && attributed === 0) {
  bad += 1;
  say('subagents were used but the trace holds none of their tool calls, so what they did cannot be checked');
}

// Models.
let unexpected = 0;
for (const m of msgs) {
  if (!isObj(m)) continue;
  if (m.type === 'result' && isObj(m.modelUsage)) {
    for (const k of Object.keys(m.modelUsage)) if (!MODELS.has(k)) unexpected += 1;
  }
  if (m.type === 'assistant' && isObj(m.message) && typeof m.message.model === 'string'
      && m.message.model !== '<synthetic>' && !MODELS.has(m.message.model)) unexpected += 1;
}
if (unexpected > 0) {
  bad += 1;
  say(`${unexpected} model use(s) other than the pinned model or the allowlisted helper`);
}

if (bad > 0) process.exit(1);
console.log(`check-agent-run: ${subagents.size} subagent call(s), ${attributed} subagent tool call(s), the ${job} rules pass`);
JS
then
  failed=1
fi

if [ ! -s "$fp_file" ]; then
  echo "check-agent-run: no fingerprint from before the step, so changes to the checkout and ~/.claude cannot be checked" >&2
  failed=1
else
  if ! now=$(fingerprint); then
    echo "check-agent-run: the fingerprint could not be taken again" >&2
    now=""
    failed=1
  fi
  changed=$(diff <(printf '%s\n' "$now") "$fp_file" | sed -n 's/^[<>] \([a-z-]*\) .*/\1/p' | sort -u | tr '\n' ' ') || true
  if [ -n "$changed" ]; then
    echo "check-agent-run: changed while the agent ran: ${changed% }" >&2
    failed=1
  elif [ -n "$now" ]; then
    echo "check-agent-run: checkout and ~/.claude unchanged"
  fi
fi

if [ "$failed" -ne 0 ]; then
  echo "check-agent-run: the run check failed; nothing from this step may be handed off" >&2
  exit 1
fi
echo "check-agent-run: the run check passed"
