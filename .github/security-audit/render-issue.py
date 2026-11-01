#!/usr/bin/env python3
# Renders the body of the public security-audit issue from the run's final
# records. Everything it writes is public, so it publishes only what the
# merge step settled: a confirmed record only when two scripts demonstrated it
# this run (run-metadata.json poc.confirmed) and the cross-check settled it
# (cross_check.settled), and a lead only when the cross-check settled it.
# Rejected, disputed, unvalidated and unchecked records appear only as counts,
# and leads never carry a severity. Every piece of record or agent text is
# NFKC-normalised, has control and format characters removed, and has
# http(s)://, www. and protocol-relative //host links, Markdown link and
# image targets and reference definitions, word@word addresses and @ mentions
# removed, repeated until it stops changing; < and > are then escaped. So it
# can neither ping anyone, link anywhere, nor open an HTML comment.
#
# A confirmed finding's section shows the record's one execution.instructions
# list (the decider's reproduction steps), its payloads and observed result,
# and for each script a and b the mode, exit code, timeout and an excerpt of
# stdout from the run record promoted for that slot; a run record is used only
# when the ledger check pointing at it names the same agent id as the
# artifact's agents/<id>/ directory. The scripts themselves are not shown.
#
# The body never exceeds 60,000 characters: finding sections are cut first,
# then table rows, then changes-section entries (fingerprints, then deferred
# units), each cut stated with its count and issue_size added to the status.
#
# Usage:
#   render-issue.py --state <dir> --state-sha256 <hex> --run-id <id> \
#                   --jobs <job-results.json> --previous-marker <marker.json> --out <body.md>
#   render-issue.py --screen-failed --out <body.md>
#
# <job-results.json> holds what the report job knows about the run:
#   {"publish": true, "canary": "none",
#    "source": {"result": "success", "cause": "ok"},
#    "cross_check": {"result": "success", "cause": "ok", "validators": "pass"}}
# where result is a job result (success, failure, cancelled, skipped) and
# cause is agent-outcome.sh's cause or another fixed label. <marker.json> is
# the previous issue's state marker, {"run_id", "sha256", "fingerprints"}; a
# missing, empty or malformed file means there is no previous marker.
#
# The header form follows the report job's table, checked in order: a run
# that is not published (publish false or a canary) says so first and is
# otherwise rendered as below; a completed cross-check renders the records; a
# successful source with no completed cross-check renders
# "Incomplete: cross-check <cause>" and counts; otherwise
# "Incomplete: source <cause>" and counts from the state, if any. The state
# marker is written only when the state was read and its sha256 is given; the
# screen-failure body has none.
import argparse
import errno
import functools
import json
import os
import re
import stat
import sys
import unicodedata

FINDINGS = "findings.json"
LEDGER = "coverage-ledger.json"
METADATA = "run-metadata.json"
DISPUTED = "disputed.json"
HISTORY = "audit-history.json"

MAX_STATE_BYTES = 5 * 1024 * 1024
MAX_ARTIFACT_BYTES = 1024 * 1024
MAX_BODY = 60000
EXCERPT = 1500

SCREEN_FAILED = "Output failed or could not run the secret screen"
BODY_LEFT_OUT = ("# Security audit\n\n**Status: incomplete (issue_size).** The body was left out because even "
                 "its header would exceed 60,000 characters.")
OWNER_CHOICE = ("Attack paths, including those of High and Critical findings and of leads, "
                "are published here by the repository owner's choice.")
EXCLUDED_PATHS = [
    ".github/security-audit/ (the vendored skill and the audit's own scripts)",
    "web/core/, web/modules/contrib/, web/themes/contrib/ and vendor/ (Drupal core, contributed and vendor code)",
    "every other path outside the scope",
]

FINGERPRINT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{7,64}$")
RUN_ID = re.compile(r"^[1-9][0-9]{0,19}$")
LABEL = re.compile(r"^[a-z0-9_:. -]{1,80}$")
ARTIFACT = re.compile(r"^agents/([a-z0-9][a-z0-9_-]{0,63})/artifacts/([ab])\.json$")
# Applied in this order on every pass of clean(). Each removes a form GitHub
# would turn into a link or a notification.
STRIPS = (
    (re.compile(r"\]\([^)\s]*\)?"), "]"),
    (re.compile(r"\[[^\]\n]*\]:\s*\S+"), "[link removed]"),
    (re.compile(r"(?i)https?://\S*"), "[link removed]"),
    (re.compile(r"(?i)www\.\S*"), "[link removed]"),
    (re.compile(r"//[^\s/]\S*"), "[link removed]"),
    (re.compile(r"[^\s@]*[A-Za-z0-9_]@[A-Za-z0-9_]\S*"), "[address removed]"),
    (re.compile(r"@(?=[A-Za-z0-9_-])"), ""),
)
MAX_CLEAN_PASSES = 20


class Refused(Exception):
    pass


# ---------------------------------------------------------------- reading


def _unique_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate key")
        out[key] = value
    return out


def _reject_constant(name):
    raise ValueError("non-finite number")


def read_fd_json(fd, limit):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise Refused("not a regular file under the limit")
    data = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        data += chunk
        if len(data) > limit:
            raise Refused("oversized")
    return json.loads(data.decode("utf-8"), object_pairs_hook=_unique_pairs, parse_constant=_reject_constant)


def read_json(path, limit=MAX_STATE_BYTES, dir_fd=None):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except OSError as err:
        if err.errno in (errno.ELOOP, errno.EMLINK):
            raise Refused("symlink")
        raise
    try:
        return read_fd_json(fd, limit)
    finally:
        os.close(fd)


def optional_json(path, kind, default):
    if path is None or not os.path.lexists(path):
        return default
    try:
        value = read_json(path)
    except (OSError, ValueError, Refused):
        return default
    return value if isinstance(value, kind) else default


def read_artifact(state_dir, relative):
    """One promoted run record, opened component by component without
    following links; None when it cannot be read that way."""
    match = ARTIFACT.match(relative) if isinstance(relative, str) else None
    if not match:
        return None
    fds = []
    try:
        fds.append(os.open(state_dir, os.O_RDONLY | os.O_DIRECTORY))
        for name in ("agents", match.group(1), "artifacts"):
            fds.append(os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
        record = read_json(match.group(2) + ".json", MAX_ARTIFACT_BYTES, dir_fd=fds[-1])
    except (OSError, ValueError, Refused):
        return None
    finally:
        for fd in reversed(fds):
            os.close(fd)
    return record if isinstance(record, dict) else None


# ---------------------------------------------------------------- text


def clean_pass(text):
    text = unicodedata.normalize("NFKC", text)
    text = "".join(ch for ch in text if ch in "\n\t" or unicodedata.category(ch) not in ("Cc", "Cf", "Cs"))
    for pattern, replacement in STRIPS:
        text = pattern.sub(replacement, text)
    return text


def clean(text):
    """Record or agent text made safe to publish, before any Markdown escaping:
    NFKC normalisation, then every Cc, Cf and Cs character but newline and tab
    removed, then links, addresses and mentions stripped, repeated until the
    text stops changing, so a character removed by one step cannot join the
    pieces of a link or a mention another step already passed over."""
    if not isinstance(text, str):
        text = "" if text is None else str(text)
    return clean_str(text)


@functools.lru_cache(maxsize=None)
def clean_str(text):
    for _ in range(MAX_CLEAN_PASSES):
        cleaned = clean_pass(text)
        if cleaned == text:
            return text
        text = cleaned
    return "[text removed]"


def inline(text):
    text = clean(text).replace("<", "&lt;").replace(">", "&gt;")
    return " ".join(text.split())


def cell(text):
    return inline(text).replace("|", "\\|") or " "


def code_block(text):
    text = clean(text).replace("<!--", "&lt;!--")
    longest = max([len(run) for run in re.findall(r"`+", text)] + [2])
    fence = "`" * (longest + 1)
    return "%s\n%s\n%s" % (fence, text.rstrip("\n"), fence)


def label(value, default="unknown"):
    return value if isinstance(value, str) and LABEL.match(value) else default


def line(value):
    return str(value) if isinstance(value, int) and not isinstance(value, bool) else "?"


def fp_text(fp):
    return "`%s`" % fp if isinstance(fp, str) and FINGERPRINT.match(fp) else "`(invalid fingerprint)`"


# ---------------------------------------------------------------- model


class Run:
    def __init__(self, args):
        self.args = args
        self.jobs = optional_json(args.jobs, dict, {})
        marker = optional_json(args.previous_marker, dict, {})
        prior = marker.get("fingerprints") if isinstance(marker.get("fingerprints"), list) else []
        self.prior = sorted({fp for fp in prior if isinstance(fp, str) and FINGERPRINT.match(fp)})
        self.state_ok = False
        self.findings, self.ledger, self.meta, self.disputed, self.history = [], [], {}, [], {}
        if args.state:
            findings = optional_json(os.path.join(args.state, FINDINGS), list, None)
            meta = optional_json(os.path.join(args.state, METADATA), dict, None)
            if findings is not None and meta is not None:
                self.state_ok = True
                self.findings = [r for r in findings if isinstance(r, dict) and isinstance(r.get("fingerprint"), str)]
                self.meta = meta
                self.ledger = [u for u in optional_json(os.path.join(args.state, LEDGER), list, []) if isinstance(u, dict)]
                self.disputed = optional_json(os.path.join(args.state, DISPUTED), list, [])
                self.history = optional_json(os.path.join(args.state, HISTORY), dict, {})
        poc = self.meta.get("poc") if isinstance(self.meta.get("poc"), dict) else {}
        cc = self.meta.get("cross_check") if isinstance(self.meta.get("cross_check"), dict) else {}
        self.poc_confirmed = set(self.list_of(poc, "confirmed"))
        self.settled = set(self.list_of(cc, "settled"))
        self.not_cross_checked = self.list_of(cc, "not_cross_checked")
        self.cc = cc

        source = self.jobs.get("source") if isinstance(self.jobs.get("source"), dict) else {}
        cross = self.jobs.get("cross_check") if isinstance(self.jobs.get("cross_check"), dict) else {}
        self.complete_form = (self.state_ok and cross.get("result") == "success" and cross.get("validators") == "pass")
        if self.complete_form:
            self.form = "records"
        elif source.get("result") == "success":
            cause = label(cross.get("cause"))
            if cross.get("result") == "success":
                cause = "validators_failed"
            self.form = "Incomplete: cross-check " + cause
        else:
            self.form = "Incomplete: source " + label(source.get("cause"))

        fps = {r["fingerprint"] for r in self.findings}
        self.confirmed = [r for r in self.findings if r.get("verdict") == "confirmed"
                          and r["fingerprint"] in self.poc_confirmed
                          and (r["fingerprint"] in self.settled or not self.complete_form)]
        self.leads = [r for r in self.findings if r.get("verdict") == "needs_validation"
                      and (r["fingerprint"] in self.settled or not self.complete_form)]
        self.unchecked_confirmed = [r for r in self.findings if r.get("verdict") == "confirmed"
                                    and r["fingerprint"] not in self.poc_confirmed]
        disputed_fps = {d.get("fingerprint") for d in self.disputed if isinstance(d, dict)}
        linked = set()
        for unit in self.ledger:
            if unit.get("status") == "candidate":
                linked.update(fp for fp in unit.get("result_fingerprints") or [] if isinstance(fp, str))
        self.unvalidated = sorted(linked - fps - disputed_fps)
        self.open_elsewhere = (fps - {r["fingerprint"] for r in self.findings if r.get("verdict") == "rejected"}) \
            | disputed_fps | linked

    @staticmethod
    def list_of(obj, key):
        value = obj.get(key)
        return [v for v in value if isinstance(v, str)] if isinstance(value, list) else []

    def published(self):
        if not self.complete_form:
            return []
        return [r["fingerprint"] for r in self.confirmed + self.leads]

    def changes(self):
        published = set(self.published())
        prior = set(self.prior)
        new = sorted(published - prior)
        still = sorted(published & prior)
        if not self.complete_form:
            return new, still, sorted(prior), []
        rest = prior - published
        not_rechecked = sorted(fp for fp in rest if fp in self.open_elsewhere)
        gone = sorted(rest - set(not_rechecked))
        return new, still, not_rechecked, gone

    def marker_fingerprints(self):
        new, still, not_rechecked, _ = self.changes()
        return sorted(set(new) | set(still) | set(not_rechecked))


# ---------------------------------------------------------------- rendering


def header(run, cut_note):
    lines = []
    jobs = run.jobs
    canary = jobs.get("canary")
    if isinstance(canary, str) and canary not in ("", "none"):
        lines.append("**Not published: canary run %s.** This body is kept as a sealed artifact." % label(canary))
    elif jobs.get("publish") is False:
        lines.append("**Not published: the run was dispatched with publish false.** This body is kept as a sealed artifact.")
    if run.form == "records":
        status = run.meta.get("run_status")
        reasons = [label(r) for r in Run.list_of(run.meta, "incomplete_reasons")]
        if not reasons and isinstance(run.meta.get("incomplete_reason"), str) and status == "incomplete":
            reasons = [label(run.meta["incomplete_reason"])]
        if cut_note:
            reasons.append("issue_size")
        if status == "complete" and not reasons:
            lines.append("**Status: complete.**")
        else:
            lines.append("**Status: incomplete (%s).**" % ("; ".join(reasons) or "unknown"))
    else:
        lines.append("**%s.**" % run.form)
    lines.append("")
    meta = run.meta
    ref = meta.get("source_ref")
    lines.append("*   Source commit: %s" % ("`%s`" % ref if isinstance(ref, str) and COMMIT.match(ref) else "unknown"))
    lines.append("*   Profile: %s" % label(meta.get("profile")))
    scope = [inline(p).replace("`", "") for p in Run.list_of(meta, "scope_paths")]
    lines.append("*   Scope: %s" % (", ".join("`%s`" % p for p in scope) if scope else "unknown"))
    lines.append("*   Excluded: %s" % "; ".join(EXCLUDED_PATHS))
    usage = meta.get("usage") if isinstance(meta.get("usage"), dict) else {}
    parts = []
    for job in sorted(usage):
        entry = usage[job]
        if isinstance(entry, dict) and isinstance(entry.get("invocations"), int) and isinstance(entry.get("cap"), int):
            parts.append("%s %d of %d" % (label(job), entry["invocations"], entry["cap"]))
    lines.append("*   Subagent invocations against cap: %s" % ("; ".join(parts) if parts else "none recorded"))
    rate = meta.get("dispute_rate") if isinstance(meta.get("dispute_rate"), dict) else {}
    if isinstance(rate.get("rate"), (int, float)) and not isinstance(rate.get("rate"), bool):
        lines.append("*   Dispute rate: %d of %d records cross-checked (%.0f%%)" % (
            int(rate.get("disputes", 0)), int(rate.get("cross_checked", 0)), rate["rate"] * 100))
    else:
        lines.append("*   Dispute rate: none recorded")
    sides = {"original": 0, "replacement": 0, "neither": 0}
    for entry in run.cc.get("tie_breaks") or []:
        if isinstance(entry, dict) and entry.get("side") in sides:
            sides[entry["side"]] += 1
    lines.append("*   Tie-breaks: original %d, replacement %d, neither %d" % (
        sides["original"], sides["replacement"], sides["neither"]))
    if run.state_ok:
        rejected = sum(1 for r in run.findings if r.get("verdict") == "rejected")
        lines.append("*   Counts: confirmed %d, leads %d, rejected %d, disputed %d, not cross-checked %d, "
                     "unvalidated %d, confirmed not re-checked this run %d" % (
                         len(run.confirmed), len(run.leads), rejected, len(run.disputed),
                         len(run.not_cross_checked), len(run.unvalidated), len(run.unchecked_confirmed)))
    else:
        lines.append("*   Counts: none (no state from this run)")
    lines.append("")
    lines.append(OWNER_CHOICE)
    return lines


def trace_text(record):
    return "; ".join("%s %s:%s %s" % (label(t.get("kind")), inline(t.get("file")), line(t.get("line")),
                                      inline(t.get("scope")))
                     for t in record.get("trace") or [] if isinstance(t, dict))


def boundary(record):
    trace = [t for t in record.get("trace") or [] if isinstance(t, dict)]
    if not trace:
        return ""
    return "%s to %s" % (inline(trace[0].get("scope")), inline(trace[-1].get("scope")))


def confirmed_table(records):
    lines = ["## Confirmed", "", "| Fingerprint | Title | Severity | Principal | Boundary |", "|---|---|---|---|---|"]
    for r in records:
        sev = r.get("severity", {}).get("overall_severity")
        lines.append("| %s | %s | %s | %s | %s |" % (fp_text(r["fingerprint"]), cell(r.get("title")), label(sev),
                                                   cell(r.get("execution", {}).get("attacker_perspective")),
                                                   cell(boundary(r))))
    return lines


def leads_table(records):
    lines = ["## Leads", "", "Leads carry no severity.", "",
             "| Fingerprint | Title | Trace | Blockers | Plan |", "|---|---|---|---|---|"]
    for r in records:
        plan = r.get("validation_plan") or {}
        plan_text = "; ".join("%s: %s" % (k, inline(plan[k])) for k in ("local", "deployment") if k in plan)
        lines.append("| %s | %s | %s | %s | %s |" % (fp_text(r["fingerprint"]), cell(r.get("title")),
                                                   cell(trace_text(r)),
                                                   cell("; ".join(inline(b) for b in r.get("blockers") or [])),
                                                   cell(plan_text)))
    return lines


def script_results(run, fp):
    results = {}
    for unit in run.ledger:
        if fp not in (unit.get("result_fingerprints") or []):
            continue
        for check in unit.get("local_checks") or []:
            if isinstance(check, dict) and check.get("method") == "local":
                match = ARTIFACT.match(check.get("artifact") or "") if isinstance(check.get("artifact"), str) else None
                if match is None or match.group(1) != check.get("agent_id"):
                    continue
                record = read_artifact(run.args.state, check.get("artifact"))
                if record and record.get("fingerprint") == fp and record.get("slot") in ("a", "b"):
                    results[record["slot"]] = record
    return results


def section(run, record):
    fp = record["fingerprint"]
    sev = record.get("severity") or {}
    ex = record.get("execution") or {}
    lines = ["### %s %s" % (fp_text(fp), inline(record.get("title"))), ""]
    lines.append("*   Severity: %s (likelihood %s, impact %s)" % (
        label(sev.get("overall_severity")), label((sev.get("likelihood") or {}).get("score")),
        label((sev.get("impact") or {}).get("score"))))
    lines.append("*   Principal: %s" % inline(ex.get("attacker_perspective")))
    lines.append("*   Boundary: %s" % boundary(record))
    lines.append("")
    lines.append(inline(record.get("description")))
    lines.append("")
    lines.append("**Trace**")
    lines.append("")
    for t in record.get("trace") or []:
        if isinstance(t, dict):
            lines.append("1.  %s `%s:%s` %s: %s" % (label(t.get("kind")), inline(t.get("file")).replace("`", ""),
                                                  line(t.get("line")),
                                                  inline(t.get("scope")), inline(t.get("description"))))
    lines.append("")
    lines.append("**Reproduction**")
    lines.append("")
    for step in ex.get("instructions") or []:
        lines.append("1.  %s" % inline(step))
    lines.append("")
    lines.append("Payloads:")
    lines.append("")
    lines.append(code_block("\n".join(str(p) for p in ex.get("payloads") or [])))
    lines.append("")
    lines.append("Observed result: %s" % inline(ex.get("observed_result")))
    lines.append("")
    results = script_results(run, fp)
    for slot in ("a", "b"):
        rec = results.get(slot)
        if rec is None:
            lines.append("Script %s: run record not available." % slot)
            lines.append("")
            continue
        lines.append("Script %s (%s mode): exit code %s%s. Output excerpt:" % (
            slot, label(rec.get("mode")), rec.get("exit_code") if isinstance(rec.get("exit_code"), int) else "unknown",
            ", timed out" if rec.get("timed_out") is True else ""))
        lines.append("")
        lines.append(code_block(str(rec.get("stdout", ""))[:EXCERPT]))
        lines.append("")
    fix = record.get("remediation") or {}
    lines.append("**Fix:** %s" % inline(fix.get("strategy")))
    files = [inline(c.get("file_name")).replace("`", "") for c in fix.get("code_changes") or [] if isinstance(c, dict)]
    if files:
        lines.append("")
        lines.append("Files to change: %s" % ", ".join("`%s`" % f for f in files))
    lines.append("")
    return lines


def change_entries(run):
    """The changes section's entries in order: each group's fingerprints, then
    the deferred units."""
    new, still, not_rechecked, gone = run.changes()
    groups = [("New", new, True), ("Still open", still, True),
              ("Not re-checked this run", not_rechecked, False), ("No longer found", gone, False)]
    deferred = sorted([u for u in run.ledger if u.get("status") == "deferred"], key=lambda u: str(u.get("coverage_id")))
    return groups, deferred


def change_count(run):
    groups, deferred = change_entries(run)
    return sum(len(fps) for _, fps, _ in groups) + len(deferred)


def changes_section(run, kept=None):
    """The changes section, keeping only the first kept entries (fingerprints,
    then deferred units) when kept is given."""
    groups, deferred = change_entries(run)
    total = change_count(run)
    budget = total if kept is None else kept
    titles = {r["fingerprint"]: r.get("title") for r in run.confirmed + run.leads}
    lines = ["## Changes since the last run", ""]
    for name, fps, with_titles in groups:
        shown, budget = fps[:budget], budget - len(fps[:budget])
        lines.append("*   %s: %s" % (name, ", ".join(
            "%s%s" % (fp_text(fp), (" " + inline(titles.get(fp))) if with_titles and fp in titles else "")
            for fp in shown) if shown else "none"))
    units = run.history.get("units") if isinstance(run.history.get("units"), dict) else {}
    shown_units = deferred[:budget]
    if shown_units:
        lines.append("")
        lines.append("Deferred coverage units, with the runs each has waited:")
        lines.append("")
        for u in shown_units:
            waited = (units.get(u.get("coverage_id")) or {}).get("runs_deferred", 0)
            lines.append("*   %s, %s, %s: %s run(s)" % (inline(u.get("surface")), inline(u.get("boundary")),
                                                     inline(u.get("attack_class")),
                                                     waited if isinstance(waited, int) else 0))
    if kept is not None and kept < total:
        lines.append("")
        lines.append("%d line(s) of the changes section left out because the issue would exceed 60,000 characters."
                     % (total - kept))
    return lines


def marker(run):
    if not (run.state_ok and SHA256.match(run.args.state_sha256 or "") and RUN_ID.match(run.args.run_id or "")):
        return []
    payload = {"run_id": run.args.run_id, "sha256": run.args.state_sha256,
               "fingerprints": run.marker_fingerprints()}
    return ["", "<!-- security-audit-state %s -->" % json.dumps(payload, separators=(", ", ": "))]


def render(run, sections_kept, rows_kept, changes_kept=None):
    """The body, keeping the first sections_kept finding sections, the first
    rows_kept table rows (confirmed rows first, then leads) and, when
    changes_kept is given, the first changes_kept changes entries."""
    cut_sections = len(run.confirmed) - sections_kept
    cut_rows = len(run.confirmed) + len(run.leads) - rows_kept
    cut = cut_sections > 0 or cut_rows > 0 or changes_kept is not None
    lines = ["# Security audit", ""] + header(run, cut) + [""]
    if run.form == "records":
        confirmed_rows = run.confirmed[:rows_kept]
        lead_rows = run.leads[:max(rows_kept - len(run.confirmed), 0)]
        lines += confirmed_table(confirmed_rows) + [""] + leads_table(lead_rows) + [""]
        if cut_rows > 0:
            lines += ["%d table row(s) left out because the issue would exceed 60,000 characters." % cut_rows, ""]
        if cut_sections > 0:
            lines += ["%d finding section(s) left out because the issue would exceed 60,000 characters." % cut_sections, ""]
        for record in run.confirmed[:sections_kept]:
            lines += section(run, record)
    lines += changes_section(run, changes_kept) + marker(run)
    return "\n".join(lines) + "\n"


def build(run):
    total = len(run.confirmed) + len(run.leads)
    sections = len(run.confirmed)
    body = render(run, sections, total)
    while len(body) > MAX_BODY and sections > 0:
        sections -= 1
        body = render(run, sections, total)
    rows = total
    while len(body) > MAX_BODY and rows > 0:
        rows -= 1
        body = render(run, 0, rows)
    if len(body) > MAX_BODY:
        low, high = 0, change_count(run)
        while low < high:
            mid = (low + high + 1) // 2
            if len(render(run, 0, 0, mid)) <= MAX_BODY:
                low = mid
            else:
                high = mid - 1
        body = render(run, 0, 0, low)
    if len(body) > MAX_BODY:
        body = BODY_LEFT_OUT + "\n"
        tail = "\n".join(marker(run)) + "\n"
        if len(body) + len(tail) <= MAX_BODY:
            body += tail
    return body


def main(argv):
    parser = argparse.ArgumentParser(prog="render-issue.py")
    parser.add_argument("--state")
    parser.add_argument("--state-sha256", default="")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--jobs")
    parser.add_argument("--previous-marker")
    parser.add_argument("--out", required=True)
    parser.add_argument("--screen-failed", action="store_true")
    args = parser.parse_args(argv)
    if args.screen_failed:
        body = SCREEN_FAILED + "\n"
    else:
        if not args.jobs:
            parser.error("--jobs is required unless --screen-failed is given")
        body = build(Run(args))
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
