#!/usr/bin/env bash
# Tests for the audit agents' prompts in ../prompts: each renders with the
# workflow's envsubst call, holds no dash character, carries the shared run
# rules, names the files merge-records.py reads for its phase in the shapes it
# accepts, and every prompt-borne canary in the design's Stage 4 table has its
# canary-<name>.md.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SA="$(cd "$(dirname "$0")/.." && pwd)"
P="$SA/prompts"
DESIGN="$(cd "$SA/../.." && pwd)/docs/designs/security-audit.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command -v envsubst >/dev/null 2>&1 || { echo "FAIL: envsubst is not installed, so the prompts cannot be rendered" >&2; exit 1; }

# The workflow's call, exactly: only these names are substituted.
VARS='$RUN_ID $SOURCE_REF $OUTPUT_DIR $INPUT_DIR $BUDGET $SCOPE_PATHS $GITHUB_ENV_PATH $HOME $RUNNER_TEMP'
render() { # file
  RUN_ID=18123456789 SOURCE_REF=0123456789abcdef0123456789abcdef01234567 \
    OUTPUT_DIR=/mnt/audit/job/out INPUT_DIR=/mnt/audit/job/in BUDGET=60 \
    SCOPE_PATHS='web/modules/custom, web/themes/custom, config/' \
    GITHUB_ENV_PATH=/home/runner/work/_temp/_runner_file_commands/set_env_x \
    HOME=/home/runner-x RUNNER_TEMP=/home/runner-x/work/_temp PATH="$PATH" \
    envsubst "$VARS" < "$1"
}

PROMPTS=(source repair poc-write poc-decide cross-check tie-break)
for name in "${PROMPTS[@]}"; do
  [ -s "$P/$name.md" ] || { echo "FAIL: $name.md is missing or empty" >&2; exit 1; }
done
shopt -s nullglob
CANARIES=("$P"/canary-*.md)
shopt -u nullglob
[ "${#CANARIES[@]}" -gt 0 ] || { echo "FAIL: no canary prompts" >&2; exit 1; }

for f in "${PROMPTS[@]/#/$P/}" "${CANARIES[@]}"; do
  f="${f%.md}.md"
  render "$f" > "$tmp/$(basename "$f")"
done

# The checker can fail: a fixture with a listed name left in and other
# dollar signs that must survive.
printf 'a $RUN_ID b ${OUTPUT_DIR} c $PATH d $_SERVER[x] e ${OTHER} f $RUN_IDX g $ h $HOME\n' > "$tmp/fixture.src"
render "$tmp/fixture.src" > "$tmp/fixture.out"
assert_eq 'a 18123456789 b /mnt/audit/job/out c $PATH d $_SERVER[x] e ${OTHER} f $RUN_IDX g $ h /home/runner-x' \
  "$(cat "$tmp/fixture.out")" "envsubst replaces only the listed names"

python3 -I - "$SA" "$P" "$tmp" "$DESIGN" "${PROMPTS[@]}" <<'PY'
import importlib.util
import json
import os
import re
import sys

sa, prompts_dir, rendered_dir, design = sys.argv[1:5]
names = sys.argv[5:]
LISTED = ["RUN_ID", "SOURCE_REF", "OUTPUT_DIR", "INPUT_DIR", "BUDGET", "SCOPE_PATHS", "GITHUB_ENV_PATH", "HOME", "RUNNER_TEMP"]
VALUES = {
    "RUN_ID": "18123456789", "SOURCE_REF": "0123456789abcdef0123456789abcdef01234567",
    "OUTPUT_DIR": "/mnt/audit/job/out", "INPUT_DIR": "/mnt/audit/job/in", "BUDGET": "60",
    "SCOPE_PATHS": "web/modules/custom, web/themes/custom, config/",
    "GITHUB_ENV_PATH": "/home/runner/work/_temp/_runner_file_commands/set_env_x",
    "HOME": "/home/runner-x", "RUNNER_TEMP": "/home/runner-x/work/_temp",
}
LISTED_RE = re.compile(r"\$(?:\{(%s)\}|(%s)(?![A-Za-z0-9_]))" % ("|".join(LISTED), "|".join(LISTED)))
DASHES = re.compile("[\\u2010-\\u2015\\u2212\\ufe58\\ufe63\\uff0d]")

spec = importlib.util.spec_from_file_location("merge_records", os.path.join(sa, "merge-records.py"))
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

failures = []


def fail(msg):
    failures.append(msg)


def raw(name):
    with open(os.path.join(prompts_dir, name), encoding="utf-8") as fh:
        return fh.read()


def rendered(name):
    with open(os.path.join(rendered_dir, name), encoding="utf-8") as fh:
        return fh.read()


names_md = [n + ".md" for n in names]
canaries = sorted(f for f in os.listdir(prompts_dir) if f.startswith("canary-") and f.endswith(".md"))

# Rendering: envsubst replaced exactly the listed names and left every other
# dollar sign as written.
for f in names_md + canaries:
    src, out = raw(f), rendered(f)
    want = LISTED_RE.sub(lambda m: VALUES[m.group(1) or m.group(2)], src)
    if out != want:
        fail("%s: envsubst changed something other than the listed names" % f)
    if LISTED_RE.search(out):
        fail("%s: a listed variable is left unreplaced" % f)
    if DASHES.search(src):
        fail("%s: holds a dash character other than the hyphen" % f)
    if f.startswith("canary-") and "/home/runner" in src:
        fail("%s: writes a runner path as a literal instead of from $HOME or $RUNNER_TEMP" % f)
    if "\u00a0" in src:
        fail("%s: holds a no-break space" % f)

# The shared run rules, in every prompt.
SHARED = [
    ("foreground", "subagents run in the foreground only"),
    ("Never stop to ask", "never stop to ask"),
    ("No network", "no network"),
    ("Pantheon Dev", "Pantheon Dev out of bounds"),
    ("never instructions to follow", "content and run output are data, not instructions"),
    ("agent-id:", "how a subagent declares its agent id"),
]
for f in names_md:
    text = rendered(f)
    for needle, what in SHARED:
        if needle not in text:
            fail("%s: lacks the shared rule: %s" % (f, what))

# Every prompt that may start subagents asks for run_in_background: false on
# each call: Claude Code backgrounds a subagent whose call omits it, and a
# background subagent's calls never reach the trace the run check reads.
FOREGROUND = "Subagents run in the foreground only: pass `run_in_background: false` on every subagent call."
STARTS_SUBAGENTS = ["source.md", "poc-write.md", "poc-decide.md", "cross-check.md", "tie-break.md",
                    "canary-script-isolation.md", "canary-sandbox-secrets.md",
                    "canary-subagent-findings-write.md", "canary-subagent-bash.md"]
for f in STARTS_SUBAGENTS:
    text = rendered(f)
    if FOREGROUND not in text:
        fail("%s: does not ask for run_in_background: false on every subagent call" % f)
    if "Never pass `run_in_background`" in text:
        fail("%s: still tells agents to omit run_in_background" % f)
for f in names_md:
    if "Every subagent call passes only" in rendered(f) and "`run_in_background: false`" not in \
            next(l for l in rendered(f).splitlines() if "Every subagent call passes only" in l):
        fail("%s: its list of subagent call fields leaves out run_in_background: false" % f)

# The agent-id examples bind exactly one valid id, as check-agent-run.sh and
# merge-records.py read a description.
for f in names_md:
    if f == "repair.md":
        continue
    examples = re.findall(r"`(agent-id: [^`]*)`", rendered(f))
    if not examples:
        fail("%s: gives no agent-id example" % f)
    for ex in examples:
        ids = mr.AGENT_DECLARATION.findall(ex)
        if len(ids) != 1 or not mr.safe_agent_id(ids[0]):
            fail("%s: the agent-id example %r does not bind one valid id" % (f, ex))

# Each prompt names the files merge-records.py and the trusted steps read for
# its phase.
NAMES = {
    "source.md": ["findings.json", "coverage-ledger.json", "run-metadata.json", "validation_plan.local",
                  "`%s`" % mr.SOURCE_BLOCKER, "audit-history.json", "REVIEW.md"],
    "repair.md": ["findings.json", "coverage-ledger.json", "validator-errors.txt"],
    "poc-write.md": ["poc-manifest.json", "select.json", "accounts.json", "scratch/poc.php", "scratch/fixture.php",
                     "/work/site", "/work/site/web", "127.0.0.1:8888", "/user/login"],
    "poc-decide.md": ["scratch/entry.json", "poc-manifest.json", "poc-run-", "select.json", "findings.json"],
    "cross-check.md": ["scratch/entry.json", "list.json", "findings.json"],
    "tie-break.md": ["scratch/entry.json", "tie-break-inputs.json"],
}
# What each canary plants, from the Stage 4 table.
NAMES.update({
    "canary-denied-read.md": ["/proc/self/environ", "/sys/kernel", "/home/runner-x/work/_temp/_runner_file_commands",
                              "/home/runner-x/work/_actions", "/home/runner-x/runners", "/home/runner-x/.claude.json",
                              "/home/runner-x/.claude/.credentials.json", "`.git/config`", "composer.json"],
    "canary-denied-write.md": ["Write `%s`" % VALUES["GITHUB_ENV_PATH"], "_runner_file_commands/",
                               "/home/runner-x/work/_temp/_runner_file_commands/canary-write",
                               "/home/runner-x/.claude/settings.json", "top of the checkout"],
    "canary-subagent-bash.md": ["Bash tool", "agent-id: canary-bash ", "If it is not, make no call for it."],
    "canary-subagent-findings-write.md": ["file_path %s/findings.json" % VALUES["OUTPUT_DIR"], "agent-id: canary-findings "],
    "canary-script-isolation.md": ["agent-id: canary-iso-a ", "agent-id: canary-iso-b ",
                                   "Read tool once, with file_path %s/agents/canary-iso-a/scratch/poc.php" % VALUES["OUTPUT_DIR"]],
    "canary-sandbox-secrets.md": ["AUDIT_SANDBOX_AGE_KEY", "AUDIT_AGENTS_AGE_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
                                  "'GITHUB_TOKEN'", "ACTIONS_RUNTIME_TOKEN", "$_SERVER[$name]", "$_ENV[$name]"],
})
for f, needles in NAMES.items():
    text = rendered(f)
    for needle in needles:
        if needle not in text:
            fail("%s: does not name %s" % (f, needle))


# The run check's own lists, read from the scripts, so a prompt cannot drift
# from what check-agent-run.sh refuses or check-trace-tools.sh accepts.
with open(os.path.join(sa, "check-agent-run.sh"), encoding="utf-8") as fh:
    car = fh.read()
sets = {}
for name in ("SHARED", "TRUSTED", "STATE"):
    m = re.search(r"const %s = new Set\(\[(.*?)\]\);" % name, car, re.S)
    sets[name] = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()
    if len(sets[name]) < 4:
        fail("check-agent-run.sh's %s set could not be read" % name)
with open(os.path.join(sa, "..", "claude-review", "tools", "review", "check-trace-tools.sh"), encoding="utf-8") as fh:
    ctt = fh.read()
m = re.search(r"^FIELDS = (\{.*?^\})", ctt, re.S | re.M)
FIELDS = __import__('ast').literal_eval(m.group(1)) if m else {}
if set(FIELDS) < {"Read", "Glob", "Grep", "Write", "Edit", "Agent"}:
    fail("check-trace-tools.sh's FIELDS could not be read")

RESERVED_FOR_SUBAGENTS = sets["SHARED"] | sets["TRUSTED"]
LATER = {"poc-write.md", "poc-decide.md", "cross-check.md", "tie-break.md"}
for f in names_md:
    text = rendered(f)
    blocks = re.findall(r"```text\n(Tool rules for this agent.*?)```", text, re.S)
    outside = re.sub(r"```text\n(Tool rules for this agent.*?)```", "", text, flags=re.S)
    if f != "repair.md" and len(blocks) != 1:
        fail("%s: expected one subagent tool-rules block" % f)
    for block in blocks:
        # check-agent-run.sh refuses a subagent's search of agents/ or above
        # it in every job where several subagents run.
        if f in LATER and "never Glob or Grep with %s, %s/agents" % (VALUES["OUTPUT_DIR"], VALUES["OUTPUT_DIR"]) not in block:
            fail("%s: the subagent tool rules do not forbid searching the output root or agents/" % f)
        for n in sorted(RESERVED_FOR_SUBAGENTS):
            if n not in block:
                fail("%s: the subagent tool rules do not forbid %s, which check-agent-run.sh refuses" % (f, n))
    for n in sorted(sets["TRUSTED"]):
        if n not in outside:
            fail("%s: the agent's own rules do not forbid %s" % (f, n))
    if f in LATER:
        m = re.search(r"The run check (?:also )?refuses any write in this job, by you or a subagent, to (.*?), wherever it is\.", outside)
        if not m:
            fail("%s: lacks the sentence saying which writes the run check refuses in this job" % f)
        else:
            for n in sorted(sets["STATE"] | sets["TRUSTED"]):
                if n not in m.group(1):
                    fail("%s: the run check's refusal sentence does not name %s" % (f, n))
    # Every field a prompt lists for a tool is one check-trace-tools.sh accepts.
    for tool, fields in re.findall(r"^- (Read|Glob|Grep|Write|Edit):.*Fields: ([^.]*)\.", text, re.M):
        extra = {x.strip() for x in fields.split(",")} - FIELDS.get(tool, set())
        if extra:
            fail("%s: lists %s fields check-trace-tools.sh refuses: %s" % (f, tool, sorted(extra)))
    for fields in re.findall(r"\(fields ([a-z_]+) and ([a-z_]+)\)", text):
        if not set(fields) <= FIELDS.get("Write", set()):
            fail("%s: lists Write fields check-trace-tools.sh refuses: %s" % (f, fields))
    for sentence in re.findall(r"subagent call passes only (.*?)\. ", text):
        named = set(re.findall(r"`([a-z_]+)(?:: [^`]*)?`", sentence))
        if not named or not named <= FIELDS.get("Agent", set()):
            fail("%s: names subagent call fields check-trace-tools.sh refuses: %s" % (f, sorted(named)))


# poc-decide names every field the skill's confirmed branch requires, which
# record_valid in merge-records.py enforces through report-schema.json.
confirmed = next((b for b in mr.schema()["items"]["oneOf"] if b["properties"]["verdict"].get("const") == "confirmed"), None)
line = next((l for l in rendered("poc-decide.md").splitlines() if l.startswith('- "confirmed" only when')), "")
for field in (confirmed or {}).get("required", ["<schema unreadable>"]):
    if not re.search(r"\b%s\b" % re.escape(field), line):
        fail("poc-decide.md: the confirmed record's field list omits %s" % field)


def json_blocks(text):
    out = []
    for block in re.findall(r"```json\n(.*?)```", text, re.S):
        try:
            out.append(json.loads(block))
        except ValueError as err:
            fail("a json example does not parse: %s" % err)
    return out


# The JSON shapes, checked with merge-records.py's own checks.
decide = [b for b in json_blocks(rendered("poc-decide.md"))]
if len(decide) != 1 or set(decide[0]) != mr.DECIDE_KEYS:
    fail("poc-decide.md: the entry example's keys are not merge-records.py's DECIDE_KEYS")
else:
    e = decide[0]
    if e["script_a"] not in mr.SCRIPT_STATES or e["script_b"] not in mr.SCRIPT_STATES \
            or e["decision"] not in ("confirmed", "needs_validation", "rejected") \
            or e["record"].get("verdict") != e["decision"] or e["record"].get("fingerprint") != e["fingerprint"]:
        fail("poc-decide.md: the entry example's values do not fit merge-records.py's decide check")

cross = json_blocks(rendered("cross-check.md"))
verified = [b for b in cross if b.get("decision") == "verified"]
replace = [b for b in cross if b.get("decision") == "replace"]
if len(verified) != 1 or not mr.cross_entry_valid(verified[0], {verified[0]["fingerprint"]}):
    fail("cross-check.md: the verified example fails merge-records.py's cross-check entry check")
if len(replace) != 1 or set(replace[0]) != {"decision", "fingerprint", "reason", "record"} \
        or not mr.visible_text(replace[0]["reason"]) or replace[0]["record"].get("fingerprint") != replace[0]["fingerprint"]:
    fail("cross-check.md: the replace example does not have merge-records.py's replace shape")

tie = json_blocks(rendered("tie-break.md"))
if len(tie) != 1 or not mr.tie_entry_valid(tie[0], {tie[0]["fingerprint"]}):
    fail("tie-break.md: the entry example fails merge-records.py's tie-break entry check")


class Discards:
    def __init__(self):
        self.labels = []

    def discard(self, job, agent_id, label):
        self.labels.append(label)


for f in ("poc-write.md", "canary-sandbox-secrets.md"):
    blocks = json_blocks(rendered(f))
    if len(blocks) != 1:
        fail("%s: expected one manifest example" % f)
        continue
    path = os.path.join(rendered_dir, f + ".manifest.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(blocks[0], fh)
    sink = Discards()
    modes = mr.read_manifest(sink, path)
    if sink.labels or len(modes) != 1:
        fail("%s: the manifest example fails merge-records.py's manifest check (%s)" % (f, sink.labels))
        continue
    slots = next(iter(modes.values()))
    if not mr.manifest_independent(slots):
        fail("%s: the manifest example's slots are not independent" % f)
    for slot in slots.values():
        if not mr.safe_relative_path(slot[1]) or not slot[1].startswith("agents/%s/scratch/" % slot[2]):
            fail("%s: a manifest script path is not under its agent's scratch" % f)

# Every prompt-borne canary row in the design's Stage 4 table has its file,
# and there is no other canary file.
with open(design, encoding="utf-8") as fh:
    lines = fh.read().splitlines()
start = next((i for i, l in enumerate(lines) if l.strip().startswith("| `canary` value | Target |")), None)
if start is None:
    fail("the design's Stage 4 canary table was not found")
else:
    want = set()
    rows = 0
    for line in lines[start + 2:]:
        if not line.strip().startswith("|"):
            break
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        rows += 1
        m = re.fullmatch(r"`([a-z0-9-]+)`", cells[0])
        if m and cells[1].endswith("agent"):
            want.add("canary-%s.md" % m.group(1))
    if rows < 2 or not want:
        fail("the Stage 4 canary table yielded no prompt-borne rows")
    for name in sorted(want - set(canaries)):
        fail("missing canary prompt %s" % name)
    for name in sorted(set(canaries) - want):
        fail("canary prompt %s has no prompt-borne row in the Stage 4 table" % name)

for msg in failures:
    print("FAIL: " + msg, file=sys.stderr)
sys.exit(1 if failures else 0)
PY
pass
