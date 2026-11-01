#!/usr/bin/env bash
# Structural assertions on .github/workflows/security-audit.yml, read with
# PyYAML (which reads the bare key "on" as True): the trigger and its inputs,
# each job's needs, if:, environment, permissions and secrets, pinned actions,
# persist-credentials: false on every checkout, no ${{ }} inside a run:, the
# agent steps' settings, the trusted steps after each agent step and how they
# are gated, every call of an audit or review script with the argument count
# its usage line allows, artifact retention and the audit-state upload, the
# prompt variables, and the key canaries. A mutation self-test proves the
# check fails on each kind of break it looks for.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SA="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$SA/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/security-audit.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 -I -c 'import yaml' 2>/dev/null || { echo "FAIL: PyYAML is not installed, so the workflow cannot be read" >&2; exit 1; }

# check <workflow file>: prints each failed assertion, exits 1 if any failed.
check() {
  python3 -I - "$1" "$ROOT" <<'PY'
import json, re, shlex, sys, yaml

path, root = sys.argv[1], sys.argv[2]
wf = yaml.safe_load(open(path))
errors = []
def err(msg):
    errors.append(msg)
def read(rel):
    with open(root + "/" + rel) as f:
        return f.read()

SA = ".github/security-audit"
CR = ".github/claude-review"
prepare_src = read(SA + "/prepare.sh")

# ---------------------------------------------------------------- trigger
trigger = wf.get(True, wf.get("on"))
if not isinstance(trigger, dict) or list(trigger) != ["workflow_dispatch"]:
    err("the trigger must be workflow_dispatch only, got %r" % (list(trigger) if isinstance(trigger, dict) else trigger,))
    trigger = {"workflow_dispatch": {}}
inputs = (trigger.get("workflow_dispatch") or {}).get("inputs") or {}
if set(inputs) != {"publish", "canary"}:
    err("the dispatch inputs must be publish and canary, got %r" % sorted(inputs))
pub = inputs.get("publish") or {}
if pub.get("type") != "boolean" or pub.get("default") is not True:
    err("publish must be a boolean defaulting to true")
can = inputs.get("canary") or {}
case = re.search(r'case "\$canary" in(.*?)esac', prepare_src, re.S)
canaries = set()
for pattern in re.findall(r"^\s*([a-z|-]+)\)", case.group(1) if case else "", re.M):
    canaries.update(pattern.split("|"))
if can.get("type") != "choice" or can.get("default") != "none" or set(can.get("options") or []) != canaries \
        or len(can.get("options") or []) != len(canaries):
    err("canary must be a choice defaulting to none whose options are prepare.sh's, %s" % sorted(canaries))

if wf.get("permissions") != {}:
    err("the workflow's top-level permissions must be {}")
conc = wf.get("concurrency") or {}
if conc.get("group") != "security-audit" or conc.get("cancel-in-progress") is not False:
    err("concurrency must be group security-audit with cancel-in-progress false")

# ---------------------------------------------------------------- jobs
jobs = wf.get("jobs") or {}
all_jobs = re.search(r"ALL_JOBS='(\[.*?\])'", prepare_src)
expected_jobs = json.loads(all_jobs.group(1)) if all_jobs else []
if list(jobs) != expected_jobs:
    err("the job ids must be prepare.sh's run_jobs names in order, %s, got %s" % (expected_jobs, list(jobs)))
if "name" in (jobs.get("report") or {}) and jobs["report"]["name"] != "report":
    err("the publishing job's display name must be report")

NEEDS = {
    "source": {"prepare"}, "build-site": {"prepare"},
    "poc-write": {"prepare", "source", "build-site"},
    "poc-run": {"prepare", "poc-write", "build-site"},
    "poc-decide": {"prepare", "source", "poc-write", "poc-run"},
    "cross-check": {"prepare", "source", "poc-write", "poc-run", "poc-decide"},
    "report": {"prepare", "source", "build-site", "poc-write", "poc-run", "poc-decide", "cross-check"},
}
ENVIRONMENT = {"prepare": None, "source": "claude-agents", "build-site": None, "poc-write": "claude-agents",
               "poc-run": "audit-sandbox", "poc-decide": "claude-agents", "cross-check": "claude-agents",
               "report": "claude-agents"}
PERMISSIONS = {
    "prepare": {"contents": "read"},
    "source": {"contents": "read", "actions": "read", "issues": "read"},
    "build-site": {"contents": "read"}, "poc-write": {"contents": "read"}, "poc-run": {"contents": "read"},
    "poc-decide": {"contents": "read"}, "cross-check": {"contents": "read"},
    "report": {"contents": "read", "issues": "write", "actions": "read"},
}
SECRETS = {
    "prepare": set(), "build-site": set(), "poc-run": {"AUDIT_SANDBOX_AGE_KEY"},
    "source": {"CLAUDE_CODE_OAUTH_TOKEN", "AUDIT_AGENTS_AGE_KEY"},
    "poc-write": {"CLAUDE_CODE_OAUTH_TOKEN", "AUDIT_AGENTS_AGE_KEY"},
    "poc-decide": {"CLAUDE_CODE_OAUTH_TOKEN", "AUDIT_AGENTS_AGE_KEY"},
    "cross-check": {"CLAUDE_CODE_OAUTH_TOKEN", "AUDIT_AGENTS_AGE_KEY"},
    "report": {"CLAUDE_CODE_OAUTH_TOKEN", "AUDIT_AGENTS_AGE_KEY"},
}
AGENT_STEPS = {"source": ["source", "repair"], "poc-write": ["poc_write"], "poc-decide": ["poc_decide"],
               "cross-check": ["cross_check", "tie_break"]}
ACTION = "anthropics/claude-code-action@ae68417a745a5df4b2124873632bd73a2255e6f6"
MODEL_VARS = {"ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"}

def norm(text):
    return re.sub(r"\s+", " ", str(text or "")).strip()

def runs(step):
    """The run block as logical lines, with backslash continuations joined."""
    return re.sub(r"\\\n\s*", " ", step.get("run") or "").splitlines()

for name, job in jobs.items():
    if not isinstance(job, dict):
        err("job %s is not a mapping" % name)
        continue
    steps = job.get("steps") or []
    text = json.dumps(job)
    needs = job.get("needs") or []
    needs = {needs} if isinstance(needs, str) else set(needs)
    cond = norm(job.get("if"))

    if name != "prepare":
        if needs != NEEDS.get(name):
            err("%s needs must be %s, got %s" % (name, sorted(NEEDS.get(name, [])), sorted(needs)))
        for part in ("needs.prepare.outputs.go == 'true'", "github.ref == 'refs/heads/main'",
                     "contains(fromJSON(needs.prepare.outputs.run_jobs), '%s')" % name):
            if part not in cond:
                err("%s if: must contain %s" % (name, part))
        if name in ("cross-check", "report"):
            if not cond.startswith("always() && "):
                err("%s if: must start with always()" % name)
        elif "always()" in cond:
            err("%s if: must not use always()" % name)
        if name == "cross-check" and "needs.source.result == 'success'" not in cond:
            err("cross-check if: must require needs.source.result == 'success'")
    for used in set(re.findall(r"needs\.([A-Za-z0-9_-]+)\.", text)):
        if used not in needs:
            err("%s uses needs.%s without listing %s in needs" % (name, used, used))

    if job.get("environment") != ENVIRONMENT.get(name):
        err("%s environment must be %r, got %r" % (name, ENVIRONMENT.get(name), job.get("environment")))
    if job.get("permissions") != PERMISSIONS.get(name):
        err("%s permissions must be %r, got %r" % (name, PERMISSIONS.get(name), job.get("permissions")))
    held = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", text))
    if held != SECRETS.get(name):
        err("%s secrets must be %s, got %s" % (name, sorted(SECRETS.get(name, [])), sorted(held)))
    if "secrets." in json.dumps(job.get("env") or {}):
        err("%s holds a secret in its job-level env" % name)
    if name in ("source", "poc-write", "poc-decide", "cross-check"):
        for key, leaf in (("AUDIT_INPUT_DIR", "in"), ("AUDIT_OUTPUT_DIR", "out")):
            if (job.get("env") or {}).get(key) != "/mnt/audit/%s/%s" % (name, leaf):
                err("%s %s must be /mnt/audit/%s/%s" % (name, key, name, leaf))

    agent_ids = []
    for i, st in enumerate(steps):
        uses = str(st.get("uses", ""))
        if uses and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}", uses):
            err("%s step %d uses %s, not pinned to a full commit sha" % (name, i, uses))
        if uses.startswith("actions/checkout@"):
            pc = (st.get("with") or {}).get("persist-credentials")
            if pc is not False and str(pc).lower() != "false":
                err("%s step %d: checkout must set persist-credentials: false" % (name, i))
        if "${{" in str(st.get("run", "")):
            err("%s step %d: ${{ }} inside run:; pass it through env:" % (name, i))
        if uses.startswith("anthropics/claude-code-action@"):
            agent_ids.append(i)
            w = st.get("with") or {}
            if uses != ACTION:
                err("%s step %d: claude-code-action must be pinned to ae68417" % (name, i))
            if st.get("continue-on-error") is not True:
                err("%s step %d: an agent step needs continue-on-error: true" % (name, i))
            if not isinstance(st.get("timeout-minutes"), int):
                err("%s step %d: an agent step needs its own timeout-minutes" % (name, i))
            if str(w.get("show_full_output")) != "false" or str(w.get("display_report")) != "false":
                err("%s step %d: show_full_output and display_report must be 'false'" % (name, i))
            if norm(w.get("claude_code_oauth_token")) != "${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}":
                err("%s step %d: the agent's token must be secrets.CLAUDE_CODE_OAUTH_TOKEN" % (name, i))
            if set(st.get("env") or {}) != MODEL_VARS:
                err("%s step %d: the agent step's env must set exactly %s" % (name, i, sorted(MODEL_VARS)))
            if not re.fullmatch(r"\$\{\{ steps\.args-[a-z-]+\.outputs\.claude_args \}\}", norm(w.get("claude_args"))):
                err("%s step %d: claude_args must come from a compose step" % (name, i))
    if len(agent_ids) != len(AGENT_STEPS.get(name, [])):
        err("%s must have %d agent step(s), has %d" % (name, len(AGENT_STEPS.get(name, [])), len(agent_ids)))

    # The trusted steps after each agent step, up to the next agent step.
    for k, ai in enumerate(agent_ids):
        agent = steps[ai]
        aid = agent.get("id")
        end = agent_ids[k + 1] if k + 1 < len(agent_ids) else len(steps)
        window = steps[ai + 1:end]
        check = [s for s in window if any("check-agent-run.sh" in l and "--fingerprint" not in l for l in runs(s))]
        outcome = [s for s in window if any("agent-outcome.sh" in l for l in runs(s))]
        if len(check) != 1 or len(outcome) != 1:
            err("%s agent step %s needs exactly one run check and one outcome step after it" % (name, aid))
            continue
        check, outcome = check[0], outcome[0]
        for label, st in (("run check", check), ("outcome", outcome)):
            if "always()" not in norm(st.get("if")):
                err("%s %s after %s must have if: always()" % (name, label, aid))
            if norm((st.get("env") or {}).get("TRACE")) != "${{ steps.%s.outputs.execution_file }}" % aid:
                err("%s %s after %s must read that step's execution_file" % (name, label, aid))
        call = [l for l in runs(outcome) if "agent-outcome.sh" in l][0]
        args = shlex.split(call.split("agent-outcome.sh", 1)[1].split(")", 1)[0])
        if len(args) < 5 or args[4] != str(agent.get("timeout-minutes")):
            err("%s outcome after %s must pass the agent step's timeout-minutes" % (name, aid))
        check_id = check.get("id")
        for st in window:
            body = st.get("run") or ""
            gated = "merge-records.py" in body or "validate-findings.cjs" in body
            if gated and "always()" in norm(st.get("if")) \
                    and "steps.%s.outcome == 'success'" % check_id not in norm(st.get("if")):
                err("%s step %r after %s runs with always() without requiring the run check %s" % (name, st.get("name"), aid, check_id))
            canary_only = "needs.prepare.outputs.canary != 'none'" in norm(st.get("if")) \
                or "steps.canary-trace.outcome" in norm(st.get("if"))
            if ("seal.sh seal" in body or str(st.get("uses", "")).startswith("actions/upload-artifact@")) \
                    and "always()" in norm(st.get("if")) and not canary_only:
                err("%s hand-off step %r must not run with always()" % (name, st.get("name")))

    # On a canary run the source and poc-write jobs merge nothing.
    if name in ("source", "poc-write"):
        for st in steps:
            if "merge-records.py" in (st.get("run") or "") or "validate-findings.cjs" in (st.get("run") or ""):
                c = norm(st.get("if"))
                if "steps.plan.outputs.merge == 'true'" not in c and "steps.check-repair.outcome" not in c:
                    err("%s step %r must be skipped on a canary run (steps.plan.outputs.merge)" % (name, st.get("name")))

# ---------------------------------------------------------------- artifacts
for name, job in jobs.items():
    for st in (job or {}).get("steps") or []:
        if not str(st.get("uses", "")).startswith("actions/upload-artifact@"):
            continue
        w = st.get("with") or {}
        if w.get("name") == "audit-state":
            if name != "report":
                err("only the report job uploads audit-state")
            if w.get("retention-days") != 90:
                err("audit-state must be kept 90 days")
            if not str(w.get("path", "")).endswith("/audit-state/audit-state.age"):
                err("audit-state must hold exactly the file audit-state.age")
            if norm(st.get("if")) != "steps.publish.outputs.marker == 'true'":
                err("audit-state must be uploaded only when the published body carries its marker")
        elif w.get("retention-days") != 1:
            err("%s artifact %s must be kept one day" % (name, w.get("name")))
report_steps = {s.get("id"): s for s in (jobs.get("report") or {}).get("steps") or []}
publish = report_steps.get("publish") or {}
if "security-audit-state" not in (publish.get("run") or "") or "find-audit-issue.sh" not in (publish.get("run") or ""):
    err("the report's publish step must use find-audit-issue.sh and set marker from the published body")
if norm(publish.get("if")) != "needs.prepare.outputs.publish == 'true' && needs.prepare.outputs.canary == 'none'":
    err("the report publishes only when publish is true and no canary runs")
if not any((s.get("env") or {}).get("GH_TOKEN") == "${{ github.token }}" for s in [publish]):
    err("the report posts with GITHUB_TOKEN")

# ---------------------------------------------------------------- prompts
vars_line = re.search(r"^VARS='([^']*)'", read(SA + "/tests/prompts.test.sh"), re.M)
if (wf.get("env") or {}).get("PROMPT_VARS") != (vars_line.group(1) if vars_line else None):
    err("PROMPT_VARS must equal the variable list prompts.test.sh renders with")
renders = 0
for name, job in jobs.items():
    for st in (job or {}).get("steps") or []:
        for l in runs(st):
            if re.match(r"\s*envsubst\b", l):
                renders += 1
                if 'envsubst "$PROMPT_VARS"' not in l:
                    err("%s: every envsubst call must take exactly \"$PROMPT_VARS\"" % name)
        if str(st.get("id", "")).startswith("prompt-") and "emit-block.sh prompt" not in (st.get("run") or ""):
            err("%s %s must pass the prompt with emit-block.sh" % (name, st.get("id")))
for name, pid in (("source", "prompt-source"), ("poc-write", "prompt-poc-write")):
    st = {s.get("id"): s for s in jobs.get(name, {}).get("steps") or []}.get(pid) or {}
    if 'prompts/canary-$CANARY.md' not in (st.get("run") or ""):
        err("%s must append canary-<value>.md to its prompt on a canary run" % name)
if renders < 6:
    err("expected a rendered prompt for each of the six agent steps, found %d envsubst call(s)" % renders)

# ---------------------------------------------------------------- source job order and prior state
src = (jobs.get("source") or {}).get("steps") or []
def first(pred):
    return next((i for i, s in enumerate(src) if pred(s.get("run") or "")), None)
i_count, i_select = first(lambda r: "count --job source " in r), first(lambda r: "select-poc" in r)
if i_count is None or i_select is None or i_count > i_select:
    err("source: count --job source must run before select-poc")
elif "--prior \"$PRIOR_FINDINGS\"" not in src[i_select].get("run", ""):
    err("source: select-poc must be given the opened prior findings.json with --prior")
i_open = first(lambda r: ".prior_run_paths = " in r)
i_agent = next((i for i, s in enumerate(src) if str(s.get("uses", "")).startswith("anthropics/")), None)
if i_open is None or i_agent is None or i_open > i_agent:
    err("source: prior_run_paths must be written into run-metadata.json before the agent step")

# ---------------------------------------------------------------- canary judging
# After the targeted agent step: judge-canary.sh on that step's trace, run
# only on a canary run, and the trace sealed to the agents key and kept one
# day, on a canary run only.
for name, cond in (("source", "needs.prepare.outputs.canary != 'none'"),
                   ("poc-write", "needs.prepare.outputs.canary == 'script-isolation'")):
    steps = (jobs.get(name) or {}).get("steps") or []
    ids = [i for i, s in enumerate(steps) if s.get("id") == "agent-" + name]
    judges = [i for i, s in enumerate(steps) if "judge-canary.sh" in (s.get("run") or "")]
    if len(ids) != 1 or len(judges) != 1 or judges[0] < ids[0]:
        err("%s must judge its canary once, after its agent step" % name)
        continue
    j = steps[judges[0]]
    c, e = norm(j.get("if")), j.get("env") or {}
    if not c.startswith("always() && ") or cond not in c:
        err("%s canary judge must run with always() and only when %s" % (name, cond))
    if norm(e.get("TRACE")) != "${{ steps.agent-%s.outputs.execution_file }}" % name \
            or norm(e.get("RUN_CHECK_OUTCOME")) != "${{ steps.check-%s.outcome }}" % name:
        err("%s canary judge must read its agent step's trace and run check outcome" % name)
    if 'judge-canary.sh "$CANARY" "$TRACE"' not in (j.get("run") or ""):
        err("%s canary judge must be called as judge-canary.sh \"$CANARY\" \"$TRACE\"" % name)
    seal = [s for s in steps if s.get("id") == "canary-trace"]
    upload = [s for s in steps if (s.get("with") or {}).get("name") == "canary-trace-" + name]
    if len(seal) != 1 or "needs.prepare.outputs.canary != 'none'" not in norm(seal[0].get("if")) \
            or "keys/agents.pub" not in (seal[0].get("run") or ""):
        err("%s must seal its agent's trace to agents.pub on canary runs only" % name)
    if len(upload) != 1 or norm(upload[0].get("if")) != "always() && steps.canary-trace.outcome == 'success'" \
            or upload[0]["with"].get("retention-days") != 1:
        err("%s must upload the sealed trace for one day, only when it was sealed" % name)
poc_run = {s.get("name"): s for s in (jobs.get("poc-run") or {}).get("steps") or []}
run_step = next((s for s in poc_run.values() if s.get("id") == "run"), {})
if "judge-canary.sh sandbox-secrets -" not in (run_step.get("run") or ""):
    err("poc-run must judge the sandbox-secrets canary on each plaintext record before sealing it")
verdict = poc_run.get("Canary verdict (sandbox-secrets)") or {}
if "needs.prepare.outputs.canary == 'sandbox-secrets'" not in norm(verdict.get("if")):
    err("poc-run must fail the sandbox-secrets canary in its own step when a record fails")
reopen = poc_run.get("Canary, the sandbox key opens no sealed record") or {}
if "judge-canary.sh reopen-records -" not in (reopen.get("run") or "") \
        or "needs.prepare.outputs.canary == 'reopen-records'" not in norm(reopen.get("if")):
    err("poc-run must judge reopen-records with judge-canary.sh on a reopen-records run only")

# ---------------------------------------------------------------- key canaries
for name, own, other, key in (("source", "agents", "sandbox", "AUDIT_AGENTS_AGE_KEY"),
                              ("poc-run", "sandbox", "agents", "AUDIT_SANDBOX_AGE_KEY")):
    ok = False
    for st in (jobs.get(name) or {}).get("steps") or []:
        r = st.get("run") or ""
        if (key in (st.get("env") or {}) and "/dev/urandom" in r and "keys/%s.pub" % own in r
                and "keys/%s.pub" % other in r and "seal.sh open %s" % key in r):
            ok = True
    if not ok:
        err("%s must seal a random token to %s.pub and %s.pub and open it with %s" % (name, own, other, key))

# ---------------------------------------------------------------- script calls
check_usage = ("usage: check-agent-run.sh --fingerprint <out-file>",
               "check-agent-run.sh <job> <execution-file> <allowed-tools> <output-root> <fingerprint-file> <model> [helper-model]")
SCRIPTS = {
    SA + "/prepare.sh": (["usage: prepare.sh <date YYYY-MM-DD> <event> <publish> <canary> <out-dir>"],
                         lambda a: len(a) == 5),
    SA + "/fetch-prior-state.sh": (["usage: fetch-prior-state.sh <owner/repo> <out-dir>"], lambda a: len(a) == 2),
    SA + "/find-audit-issue.sh": (["usage: find-audit-issue.sh <owner/repo>"], lambda a: len(a) == 1),
    SA + "/seal.sh": (["seal.sh seal <recipient-file> <in-dir> <out>",
                       "seal.sh open <identity-env-name> <expected-sha256> <in> <out-dir>"],
                      lambda a: (a[:1] == ["seal"] and len(a) == 4) or (a[:1] == ["open"] and len(a) == 5)),
    SA + "/sqlite-config.sh": (["usage: sqlite-config.sh <out-dir>"], lambda a: len(a) == 1),
    SA + "/check-agent-run.sh": (list(check_usage),
                                 lambda a: (a[:1] == ["--fingerprint"] and len(a) == 2)
                                 or (len(a) in (6, 7) and a[0] in ("source", "poc-write", "poc-decide", "cross-check"))),
    SA + "/agent-outcome.sh": (["usage: agent-outcome.sh <execution-file> <step-outcome> <started-epoch> <ended-epoch> <timeout-minutes> <expected-file>..."],
                               lambda a: len(a) >= 5),
    SA + "/judge-canary.sh": (["usage: judge-canary.sh <canary> <execution-file> [run-record]"],
                              lambda a: len(a) in (2, 3)),
    SA + "/run-in-sandbox.sh": (["usage: run-in-sandbox.sh <fingerprint> <slot> <mode> <site-dir> <script> [fixture]"],
                                lambda a: len(a) in (5, 6)),
    SA + "/create-test-accounts.php": (["Usage: drush php:script create-test-accounts.php <output-path>"],
                                       lambda a: len(a) == 1),
    SA + "/skill/validate-findings.cjs": (["Usage: node validate-findings.cjs <path-to-findings.json>"], lambda a: len(a) == 1),
    SA + "/skill/validate-coverage-ledger.cjs": (["Usage: node validate-coverage-ledger.cjs <path-to-coverage-ledger.json>"],
                                                 lambda a: len(a) == 1),
    SA + "/merge-records.py": (["Usage: merge-records.py --state <dir> <subcommand> [options]"], None),
    SA + "/render-issue.py": (["render-issue.py --state <dir> --state-sha256 <hex> --run-id <id>",
                               "render-issue.py --screen-failed --out <body.md>"], None),
    CR + "/tools/agent/emit-block.sh": (["usage: emit-block.sh <output-name> <file>"], lambda a: len(a) == 2),
    CR + "/tools/agent/compose-agent-args.sh": (["usage: compose-agent-args.sh --audit", "usage: compose-agent-args.sh --audit-models <step>"],
                                                lambda a: a == ["--audit"] or (len(a) == 2 and a[0] == "--audit-models"
                                                and a[1] in ("source", "repair", "poc_write", "poc_decide", "cross_check", "tie_break"))),
    CR + "/tools/review/keep-trace.sh": (["REVIEW_SCREEN_ONLY=1 keep-trace.sh <out-dir> <angle> <head-sha> <trace> [file...]"],
                                         lambda a: len(a) >= 4 and a[1] == "audit"),
    "scripts/rebuild.sh": ([], lambda a: len(a) == 0),
}
for script, (usages, _) in SCRIPTS.items():
    source_text = read(script)
    for usage in usages:
        if usage not in source_text:
            err("%s no longer has the usage line this test checks calls against: %s" % (script, usage))

MERGE = {"count": ({"--job", "--cap", "--trace"}, set()), "select-poc": ({"--out"}, {"--prior"}),
         "apply-decide": ({"--manifest", "--records", "--scripts", "--entries", "--trace"}, set()),
         "fail-poc": ({"--select", "--job"}, set()), "select-cross-check": ({"--out"}, set()),
         "apply-cross-check": ({"--entries", "--trace", "--out"}, set()),
         "apply-tie-break": ({"--inputs", "--entries", "--trace"}, set()), "status": (set(), set())}
merge_src = read(SA + "/merge-records.py")
for sub, (req, opt) in MERGE.items():
    if '"%s"' % sub not in merge_src:
        err("merge-records.py has no subcommand %s" % sub)
    for flag in req | opt:
        if flag not in merge_src:
            err("merge-records.py no longer takes %s" % flag)

def flags_of(args):
    """Flag names, and False when a flag lacks its value."""
    out, i = [], 0
    while i < len(args):
        if not args[i].startswith("--") or i + 1 >= len(args) or args[i + 1].startswith("--"):
            return None
        out.append(args[i]); i += 2
    return out

def check_merge(args):
    if args[:1] != ["--state"] or len(args) < 3 or args[2] not in MERGE:
        return False
    req, opt = MERGE[args[2]]
    flags = flags_of(args[3:])
    return flags is not None and req <= set(flags) <= (req | opt) and all(flags.count(f) == 1 for f in req)

def check_render(args):
    if args == ["--screen-failed", "--out", args[-1]] and len(args) == 3:
        return True
    flags = flags_of(args)
    return flags is not None and {"--jobs", "--out"} <= set(flags) <= {
        "--state", "--state-sha256", "--run-id", "--jobs", "--previous-marker", "--out"}

CALL = re.compile(r'(?:\bbash|\bpython3 -I|\bnode|php:script)\s+"?(?:\$GITHUB_WORKSPACE/)?([A-Za-z0-9_./-]+\.(?:sh|py|cjs|php))"?')
calls = 0
for name, job in jobs.items():
    for st in (job or {}).get("steps") or []:
        for line in runs(st):
            for m in CALL.finditer(line):
                script = m.group(1)
                if script not in SCRIPTS:
                    err("%s calls %s, which this test has no usage line for" % (name, script))
                    continue
                lex = shlex.shlex(line[m.end():], posix=True, punctuation_chars=True)
                lex.whitespace_split = True
                args = []
                try:
                    for tok in lex:
                        if re.fullmatch(r"[;&|<>()]+", tok):
                            break
                        args.append(tok)
                except ValueError:
                    err("%s: could not parse the call of %s" % (name, script))
                    continue
                calls += 1
                ok = {SA + "/merge-records.py": check_merge, SA + "/render-issue.py": check_render}.get(
                    script, SCRIPTS[script][1])(args)
                if script.endswith("keep-trace.sh") and "REVIEW_SCREEN_ONLY=1 bash" not in line:
                    ok = False
                if not ok:
                    err("%s calls %s with arguments its usage does not allow: %r" % (name, script, args))
if calls < 40:
    err("found only %d script calls, which means the call pattern read too little" % calls)

for e in errors:
    print("FAIL: " + e)
sys.exit(1 if errors else 0)
PY
}

# The workflow passes.
out=$(check "$WORKFLOW" 2>&1) || { printf '%s\n' "$out" >&2; echo "FAIL: security-audit.yml fails its structure checks" >&2; exit 1; }

# Each mutation breaks one requirement, and the check must fail on it.
mutate() { # label python-replacement-source
  local label="$1" f="$tmp/mutant.yml"
  python3 -I - "$WORKFLOW" "$f" "$2" <<'PY'
import sys
src, dst, code = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
old, new, count = eval(code)
if s.count(old) < 1:
    sys.exit("mutation anchor not found: %r" % old)
open(dst, "w").write(s.replace(old, new, count))
PY
  if check "$f" > "$tmp/out" 2>&1; then
    echo "FAIL: the check passed a workflow with this break: $label" >&2
    exit 1
  fi
}
mutate "a schedule trigger" '("on:\n  workflow_dispatch:", "on:\n  schedule:\n    - cron: \"0 6 * * 6\"\n  workflow_dispatch:", 1)'
mutate "a checkout keeping credentials" '("persist-credentials: false", "persist-credentials: true", 1)'
mutate "an expression inside run:" '("run: bash .github/security-audit/sqlite-config.sh", "run: echo ${{ github.event_name }} && bash .github/security-audit/sqlite-config.sh", 1)'
mutate "audit-state kept 30 days" '("retention-days: 90", "retention-days: 30", 1)'
mutate "a hand-off kept two days" '("retention-days: 1\n", "retention-days: 2\n", 1)'
mutate "poc-run in claude-agents" '("environment: audit-sandbox", "environment: claude-agents", 1)'
mutate "issues: write outside report" '("      actions: read\n      issues: read\n", "      actions: read\n      issues: write\n", 1)'
mutate "the publishing job renamed" '("  report:\n    needs:", "  report:\n    name: Publish\n    needs:", 1)'
mutate "full agent output in the log" "(\"show_full_output: 'false'\", \"show_full_output: 'true'\", 1)"
mutate "an agent step without continue-on-error" '("continue-on-error: true\n        timeout-minutes: 280", "timeout-minutes: 280", 1)'
mutate "an outcome timeout unlike its agent step" '("\"$ENDED\" 280 ", "\"$ENDED\" 281 ", 1)'
mutate "a count that ignores the run check" "(\" && steps.check-source.outcome == 'success' && steps.plan.outputs.merge\", \" && steps.plan.outputs.merge\", 1)"
mutate "a merge step run on a canary" "(\"steps.check-source.outcome == 'success' && steps.plan.outputs.merge == 'true'\", \"steps.check-source.outcome == 'success'\", 1)"
mutate "prepare.sh with a missing argument" '("\"$PUBLISH\" \"$CANARY\" \"$RUNNER_TEMP/meta\"", "\"$PUBLISH\" \"$RUNNER_TEMP/meta\"", 1)'
mutate "seal.sh open with an extra argument" '("seal.sh open AUDIT_SANDBOX_AGE_KEY \"$SCRIPTS_SHA256\"", "seal.sh open AUDIT_SANDBOX_AGE_KEY x \"$SCRIPTS_SHA256\"", 1)'
mutate "apply-decide without --scripts" '("--scripts \"$AUDIT_INPUT_DIR/scripts\" ", "", 1)'
mutate "select-poc without --prior" '(" --prior \"$PRIOR_FINDINGS\"", "", 1)'
mutate "a job missing the main ref check" "(\"if: needs.prepare.outputs.go == 'true' && github.ref == 'refs/heads/main' && contains(fromJSON(needs.prepare.outputs.run_jobs), 'build-site')\", \"if: needs.prepare.outputs.go == 'true' && contains(fromJSON(needs.prepare.outputs.run_jobs), 'build-site')\", 1)"
mutate "an undeclared needs reference" '("SOURCE_SHA256: ${{ needs.source.outputs.sha256 }}\n          RECORDS", "SOURCE_SHA256: ${{ needs.report.outputs.sha256 }}\n          RECORDS", 1)'
mutate "the sandbox key in an agent job" '("AUDIT_AGENTS_AGE_KEY: ${{ secrets.AUDIT_AGENTS_AGE_KEY }}\n          STATE_SHA256", "AUDIT_AGENTS_AGE_KEY: ${{ secrets.AUDIT_SANDBOX_AGE_KEY }}\n          STATE_SHA256", 1)'
mutate "an unpinned action" '("actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9", "actions/upload-artifact@v7", 1)'
mutate "audit-state uploaded unconditionally" "(\"if: steps.publish.outputs.marker == 'true'\", \"if: always()\", 1)"
mutate "a prompt rendered without the variable list" '("envsubst \"$PROMPT_VARS\" < .github/security-audit/prompts/tie-break.md", "envsubst < .github/security-audit/prompts/tie-break.md", 1)'
mutate "no canary prompt in poc-write" '("envsubst \"$PROMPT_VARS\" < \".github/security-audit/prompts/canary-$CANARY.md\" >> \"$RUNNER_TEMP/prompt-poc-write.md\"", "true", 1)'
mutate "the sandbox key canary removed" '("Check the sandbox key against both public keys\n        env:\n          AUDIT_SANDBOX_AGE_KEY", "Check the sandbox key against both public keys\n        env:\n          UNUSED", 1)'
mutate "a hand-off sealed with always()" "(\"      - name: Seal audit-final to the agents key\n        id: handoff\n\", \"      - name: Seal audit-final to the agents key\n        id: handoff\n        if: always()\n\", 1)"

mutate "the source canary judge on every run" "(\"Judge the canary (source agent)\n        if: always() && steps.plan.outputs.agent == 'true' && needs.prepare.outputs.canary != 'none'\", \"Judge the canary (source agent)\n        if: always() && steps.plan.outputs.agent == 'true'\", 1)"
mutate "the canary trace sealed on every run" "(\"id: canary-trace\n        if: always() && steps.plan.outputs.agent == 'true' && needs.prepare.outputs.canary != 'none'\", \"id: canary-trace\n        if: always() && steps.plan.outputs.agent == 'true'\", 1)"
mutate "the canary trace kept two days" '("name: canary-trace-poc-write\n          path: ${{ runner.temp }}/canary-trace/canary-trace-poc-write.age\n          retention-days: 1", "name: canary-trace-poc-write\n          path: ${{ runner.temp }}/canary-trace/canary-trace-poc-write.age\n          retention-days: 2", 1)'
mutate "the judge reading the wrong run check" '("RUN_CHECK_OUTCOME: ${{ steps.check-poc-write.outcome }}", "RUN_CHECK_OUTCOME: ${{ steps.outcome-poc-write.outcome }}", 1)'
mutate "sandbox-secrets not judged" '("bash .github/security-audit/judge-canary.sh sandbox-secrets -", "true", 1)'
mutate "the judge with a missing argument" '("judge-canary.sh reopen-records - \"$f\"", "judge-canary.sh reopen-records", 1)'

pass "security-audit workflow structure"
