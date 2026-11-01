#!/usr/bin/env python3
# Applies each audit phase's results to the run's records. After the source
# agent finishes, this is the only component that changes findings.json,
# coverage-ledger.json, run-metadata.json, disputed.json and audit-history.json,
# so every rule that decides what a record becomes (confirmed only with two
# demonstrated scripts, no promotion or raise by the cross-check, tie-break
# outcomes) is enforced here in code and not by an agent.
#
# Usage: merge-records.py --state <dir> <subcommand> [options]
#   count --job <job> --cap <n> --trace <execution-file>
#   select-poc --out <select.json>
#   apply-decide --manifest <poc-manifest.json> --records <dir> --scripts <dir> --entries <out-dir> --trace <execution-file>
#   fail-poc --select <select.json> --job <job>
#   select-cross-check --out <list.json>
#   apply-cross-check --entries <out-dir> --trace <execution-file> --out <tie-break-inputs.json>
#   apply-tie-break --inputs <tie-break-inputs.json> --entries <out-dir> --trace <execution-file>
#   status
#
# Agent entries are read only from <entries>/agents/<id>/scratch/entry.json for
# an id declared by a subagent call in the trace ("agent-id: <id>"), and only
# when the trace shows that subagent itself writing that file. An entry that is
# missing, unattributed, not one strict JSON object, or not the exact shape its
# phase expects is discarded without repair, and the discard is recorded in
# run-metadata.json under merge_discarded with a fixed label, never entry text.
#
# Run records in <records> are files named poc-run-<n>-<slot>.json; each is
# matched to its item by the fingerprint and slot inside it, and its mode must
# be the manifest's mode for that slot. A record is used only if it opens
# without following links, is a regular file with one link and at most 1 MiB,
# and does not change while it is read, and only if its script_sha256 equals
# the sha256 computed here of the script the manifest names for that slot,
# read from <scripts> (the opened poc-scripts hand-off). The script path must
# be relative with no .. segment and is opened one component at a time without
# following links, so it cannot leave <scripts>; any hash in the manifest is
# ignored. A record that fails any of this is not promoted, and its script
# counts as not demonstrated, so its item cannot be confirmed. A used record is
# copied, never moved, to agents/<decider-id>/artifacts/<slot>.json under
# <entries>.
#
# Ledger: a decision adds one local check per promoted run record to every
# unit linked to the fingerprint (result_fingerprints), beside the unit's
# existing checks. The unit keeps its owner, wave and status (candidate, for a
# confirmed, lead or rejected decision alike, since only a candidate unit may
# hold result fingerprints), and its reviewed_paths become the union of all its
# checks' paths. Each check has the decider as agent_id, the files in the
# decision record's trace as reviewed_paths, method "local", the promoted
# artifact, the record's intended_behavior (confirmed) or title (otherwise) as
# the invariant, and "script <slot>: <demonstrated|not_demonstrated>;
# decision: <decision>" as the result. The unit's unresolved list drops the
# previous record's blockers and gains the new lead's blockers. A failed poc
# phase (fail-poc) adds "poc phase failed: <job>" to the lead and its units.
#
# run-metadata.json keys this script adds:
#   usage.<job>          {"invocations", "cap"}, summed over the job's steps
#   incomplete_reasons   every reason in order, the source agent's own first;
#                        incomplete_reason is them joined with "; "
#   poc                  {selected, not_tried, not_rechecked, confirmed,
#                        decided, failed}
#   cross_check          {selected, not_cross_checked, settled, refused,
#                        disputes, cross_checked, tie_breaks, removed,
#                        applied, pending}
#   merge_discarded      [{job, agent_id, reason}] with fixed reason labels
#   dispute_rate         {disputes, cross_checked, rate}
# Incomplete reasons it sets: cap_exceeded:<job>, cross_check_cap,
# cross_check_missing (a selected record with no valid cross-check entry, or
# a cross-check that never applied), cross_check_dispute, cross_check_not_run
# and source_run_not_finished (status found run_status still in_progress).
#
# Run ids are the GitHub run id from run-metadata.json, stored as numbers.
# Fails closed: a state file that cannot be read safely stops the subcommand
# with exit status 1 before anything is written.
import argparse
import errno
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(HERE, "skill", "report-schema.json")

FINDINGS = "findings.json"
LEDGER = "coverage-ledger.json"
METADATA = "run-metadata.json"
DISPUTED = "disputed.json"
HISTORY = "audit-history.json"

MAX_STATE_BYTES = 5 * 1024 * 1024
MAX_ENTRY_BYTES = 1024 * 1024
MAX_ARTIFACT_BYTES = 1024 * 1024
MAX_SCRIPT_BYTES = 1024 * 1024
MAX_TEXT = 4096
POC_SLOTS = 6
CROSS_CHECK_SLOTS = 30
TIE_BREAK_SLOTS = 3

SOURCE_BLOCKER = "no sandbox in the source job"
DECISION_DISCARDED = "poc decision discarded"
PROMOTION_FAILED = "poc evidence promotion failed"
DISPUTE_UNRESOLVED = "cross-check dispute unresolved"

FINGERPRINT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$")
AGENT_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
WINDOWS_AGENT_ID = re.compile(r"^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$")
WINDOWS_COMPONENT = re.compile(
    "^(?:con|prn|aux|nul|clock\\$|conin\\$|conout\\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\\.|$)",
    re.IGNORECASE,
)
JOB = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
RECORD_NAME = re.compile(r"^poc-run-[0-9]{1,4}-[ab]\.json$")
AGENT_DECLARATION = re.compile(r"(?:^|\s)agent-id:\s*(\S+)")
SUBAGENT_TOOLS = ("Agent", "Task")
SEVERITY_RANK = {"informational": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}

# Unicode Default_Ignorable_Code_Point, which the skill's validators treat as
# invisible and forbid in paths; Python's unicodedata has no such property.
DEFAULT_IGNORABLE = (
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160),
    (0x17B4, 0x17B5), (0x180B, 0x180F), (0x200B, 0x200F), (0x202A, 0x202E),
    (0x2060, 0x206F), (0x3164, 0x3164), (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF),
    (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A),
    (0xE0000, 0xE0FFF),
)


class Refused(Exception):
    """A state file or argument that cannot be used safely; nothing is written."""


# ---------------------------------------------------------------- reading


def _reject_constant(name):
    raise ValueError("non-finite number")


def _unique_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate key")
        out[key] = value
    return out


def parse_strict(data):
    """One JSON value from UTF-8 bytes: no duplicate keys, NaN or Infinity."""
    text = data.decode("utf-8")
    return json.loads(text, object_pairs_hook=_unique_pairs, parse_constant=_reject_constant)


def read_fd(fd, limit):
    """Reads a regular file with one link and at most limit bytes from an open
    descriptor, refusing one that changes while it is read. Returns the bytes."""
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode):
        raise Refused("not a regular file")
    if before.st_nlink != 1:
        raise Refused("hardlinked")
    if before.st_size > limit:
        raise Refused("oversized")
    chunks, total = [], 0
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise Refused("oversized")
        chunks.append(chunk)
    after = os.fstat(fd)
    if (after.st_dev, after.st_ino, after.st_nlink, after.st_size, stat.S_IFMT(after.st_mode)) != (
        before.st_dev, before.st_ino, before.st_nlink, before.st_size, stat.S_IFMT(before.st_mode)
    ) or total != before.st_size:
        raise Refused("changed while read")
    return b"".join(chunks)


def open_nofollow(path, dir_fd=None):
    try:
        return os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except OSError as err:
        if err.errno in (errno.ELOOP, errno.EMLINK):
            raise Refused("symlink")
        raise


def read_bytes(path, limit, dir_fd=None):
    fd = open_nofollow(path, dir_fd)
    try:
        return read_fd(fd, limit)
    finally:
        os.close(fd)


def read_json(path, limit):
    return parse_strict(read_bytes(path, limit))


def write_json(path, value):
    data = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(data)
    os.replace(tmp, path)


def js_order(text):
    """The order JavaScript's < uses for strings (UTF-16 code units), which is
    the order the skill's validators require."""
    return text.encode("utf-16-be")


# ---------------------------------------------------------------- text rules


def is_default_ignorable(ch):
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in DEFAULT_IGNORABLE)


def valid_scalars(text):
    return not any(0xD800 <= ord(ch) <= 0xDFFF for ch in text)


def visible(text):
    if not isinstance(text, str) or not valid_scalars(text):
        return False
    for ch in text:
        if ch.isspace() or unicodedata.category(ch) in ("Cc", "Cf") or is_default_ignorable(ch):
            continue
        return True
    return False


def visible_text(value, limit=MAX_TEXT):
    return isinstance(value, str) and 0 < len(value) <= limit and value.strip() == value and visible(value)


def forbidden_path_char(ch):
    return unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp") or is_default_ignorable(ch)


def safe_relative_path(value):
    if not isinstance(value, str) or value == "" or not valid_scalars(value) or value.strip() != value:
        return False
    if any(forbidden_path_char(ch) for ch in value) or "\\" in value or ":" in value:
        return False
    if value.startswith("/") or value.startswith("~") or re.match(r"^[A-Za-z]:", value):
        return False
    for segment in value.split("/"):
        if segment in ("", ".", "..") or re.search(r"[ .]$", segment) or WINDOWS_COMPONENT.match(segment):
            return False
    return True


def safe_agent_id(value):
    return isinstance(value, str) and bool(AGENT_ID.match(value)) and not WINDOWS_AGENT_ID.match(value)


def clip(text):
    text = text.strip()
    if len(text) > MAX_TEXT:
        text = text[:MAX_TEXT].rstrip()
    return text


# ---------------------------------------------------------------- record schema


_SCHEMA = None


def schema():
    global _SCHEMA
    if _SCHEMA is None:
        _SCHEMA = read_json(SCHEMA_PATH, MAX_STATE_BYTES)
    return _SCHEMA


def json_type(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return "unknown"


def canonical(value):
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k) + ":" + canonical(value[k]) for k in sorted(value)) + "}"
    if isinstance(value, list):
        return "[" + ",".join(canonical(v) for v in value) + "]"
    return json_type(value) + ":" + json.dumps(value)


def schema_errors(value, node):
    """The JSON Schema keywords report-schema.json uses, as the skill's
    validate-findings.cjs interprets them."""
    errors = []
    if "oneOf" in node:
        passing = [b for b in node["oneOf"] if not schema_errors(value, b)]
        if len(passing) != 1:
            errors.append("oneOf")
    if "const" in node and canonical(value) != canonical(node["const"]):
        errors.append("const")
    if "enum" in node and canonical(value) not in [canonical(v) for v in node["enum"]]:
        errors.append("enum")
    if "type" in node:
        want, got = node["type"], json_type(value)
        ok = got == want or (want == "integer" and got == "number" and float(value).is_integer())
        if not ok:
            return errors + ["type"]
    if isinstance(value, dict):
        for key in node.get("required", []):
            if key not in value:
                errors.append("required")
        props = node.get("properties", {})
        for key, item in value.items():
            if key in props:
                errors += schema_errors(item, props[key])
            elif node.get("additionalProperties") is False:
                errors.append("additional")
    if isinstance(value, list):
        if len(value) < node.get("minItems", 0):
            errors.append("minItems")
        if node.get("uniqueItems") is True and len({canonical(v) for v in value}) != len(value):
            errors.append("uniqueItems")
        if "items" in node:
            for item in value:
                errors += schema_errors(item, node["items"])
    if isinstance(value, str):
        if len(value) < node.get("minLength", 0):
            errors.append("minLength")
        if node.get("visibleContent") is True and not visible(value):
            errors.append("visible")
        if "pattern" in node and not re.search(node["pattern"], value):
            errors.append("pattern")
    if json_type(value) == "number" and "minimum" in node and value < node["minimum"]:
        errors.append("minimum")
    return errors


def record_valid(record):
    """True when one record matches its schema branch and the per-record rules
    of validate-findings.cjs (trace order, safe paths, verdict fields)."""
    if not isinstance(record, dict) or schema_errors(record, schema()["items"]):
        return False
    for field in ("trace", "evidence"):
        for entry in record[field]:
            if not safe_relative_path(entry["file"]):
                return False
    for change in record.get("remediation", {}).get("code_changes", []):
        if not safe_relative_path(change["file_name"]):
            return False
    kinds = [t["kind"] for t in record["trace"]]
    if len(kinds) == 1 and kinds[0] not in ("entrypoint", "sink"):
        return False
    if len(kinds) > 1 and (kinds[0] != "entrypoint" or kinds[-1] != "sink"
                           or any(k != "propagation" for k in kinds[1:-1])):
        return False
    verdict = record["verdict"]
    if verdict == "confirmed":
        severity = record["severity"]
        if SEVERITY_RANK[severity["overall_severity"]] > SEVERITY_RANK[severity["impact"]["score"]]:
            return False
        if not visible(record["execution"]["observed_result"]) or not visible(record["remediation"]["strategy"]):
            return False
    elif verdict == "needs_validation":
        plan = record["validation_plan"]
        if not (visible(plan.get("local", "")) or visible(plan.get("deployment", ""))):
            return False
    return True


# ---------------------------------------------------------------- state


class State:
    def __init__(self, directory):
        self.dir = directory
        self.findings = self._load(FINDINGS, list, None)
        self.ledger = self._load(LEDGER, list, None)
        self.meta = self._load(METADATA, dict, None)
        self.disputed = self._load(DISPUTED, list, [])
        self.history = self._load(HISTORY, dict, {})
        self.history.setdefault("fingerprints", {})
        self.history.setdefault("units", {})
        if not isinstance(self.history["fingerprints"], dict) or not isinstance(self.history["units"], dict):
            raise Refused(HISTORY + " has the wrong shape")
        try:
            self.run_id = int(self.meta.get("run_id"))
        except (TypeError, ValueError):
            raise Refused(METADATA + " has no numeric run_id")
        if self.run_id < 1:
            raise Refused(METADATA + " has no positive run_id")
        if not isinstance(self.meta.get("usage", {}), dict):
            raise Refused(METADATA + " usage is not an object")
        reasons = self.meta.get("incomplete_reasons")
        if reasons is None:
            reasons = []
            if self.meta.get("run_status") == "incomplete" and isinstance(self.meta.get("incomplete_reason"), str):
                reasons.append(self.meta["incomplete_reason"])
            self.meta["incomplete_reasons"] = reasons
        if not isinstance(reasons, list) or not all(isinstance(r, str) for r in reasons):
            raise Refused(METADATA + " incomplete_reasons is not a list of strings")
        fps = [r.get("fingerprint") for r in self.findings if isinstance(r, dict)]
        if len(fps) != len(self.findings) or len(set(fps)) != len(fps):
            raise Refused(FINDINGS + " has a non-object record or a duplicate fingerprint")
        if not all(isinstance(u, dict) and isinstance(u.get("coverage_id"), str) for u in self.ledger):
            raise Refused(LEDGER + " has a unit without a coverage_id")

    def _load(self, name, kind, default):
        path = os.path.join(self.dir, name)
        if default is not None and not os.path.lexists(path):
            return default
        try:
            value = read_json(path, MAX_STATE_BYTES)
        except (OSError, ValueError, Refused) as err:
            raise Refused("%s cannot be read safely (%s)" % (name, type(err).__name__))
        if not isinstance(value, kind):
            raise Refused("%s has the wrong top-level type" % name)
        return value

    def record(self, fp):
        for record in self.findings:
            if record.get("fingerprint") == fp:
                return record
        return None

    def put(self, record):
        self.findings = [r for r in self.findings if r.get("fingerprint") != record["fingerprint"]]
        self.findings.append(record)

    def remove(self, fp):
        self.findings = [r for r in self.findings if r.get("fingerprint") != fp]

    def units_for(self, fp):
        return [u for u in self.ledger if fp in (u.get("result_fingerprints") or [])]

    def fp_history(self, fp):
        entry = self.history["fingerprints"].setdefault(fp, {})
        for key in ("last_poc_run", "last_cross_checked_run", "poc_tries"):
            entry.setdefault(key, 0)
        return entry

    def unit_history(self, coverage_id):
        entry = self.history["units"].setdefault(coverage_id, {})
        for key in ("last_covered_run", "runs_deferred"):
            entry.setdefault(key, 0)
        return entry

    def incomplete(self, reason):
        if reason not in self.meta["incomplete_reasons"]:
            self.meta["incomplete_reasons"].append(reason)
        self.meta["run_status"] = "incomplete"
        self.meta["incomplete_reason"] = "; ".join(self.meta["incomplete_reasons"])

    def discard(self, job, agent_id, label):
        self.meta.setdefault("merge_discarded", []).append(
            {"job": job, "agent_id": agent_id if safe_agent_id(agent_id) else None, "reason": label})

    def save(self):
        self.findings.sort(key=lambda r: js_order(r["fingerprint"]))
        self.ledger.sort(key=lambda u: js_order(u["coverage_id"]))
        write_json(os.path.join(self.dir, FINDINGS), self.findings)
        write_json(os.path.join(self.dir, LEDGER), self.ledger)
        write_json(os.path.join(self.dir, METADATA), self.meta)
        write_json(os.path.join(self.dir, DISPUTED), self.disputed)
        write_json(os.path.join(self.dir, HISTORY), self.history)


def add_unique(items, value):
    if value not in items:
        items.append(value)


# ---------------------------------------------------------------- trace


def read_trace(path):
    try:
        messages = read_json(path, 64 * 1024 * 1024)
    except (OSError, ValueError, Refused) as err:
        raise Refused("the trace cannot be read (%s)" % type(err).__name__)
    if not isinstance(messages, list):
        raise Refused("the trace is not a list of messages")
    return messages


def tool_uses(node):
    """Every tool_use object, depth first in document order, as
    check-agent-run.sh walks them."""
    if isinstance(node, dict):
        if node.get("type") == "tool_use":
            yield node
        for value in node.values():
            yield from tool_uses(value)
    elif isinstance(node, list):
        for value in node:
            yield from tool_uses(value)


def subagent_bindings(messages):
    """Maps each subagent call id to the one agent id its description
    declares, dropping calls whose declaration is missing, invalid or reused."""
    calls, seen, reused = {}, set(), set()
    for message in messages:
        for call in tool_uses(message):
            if call.get("name") not in SUBAGENT_TOOLS:
                continue
            args = call.get("input") if isinstance(call.get("input"), dict) else {}
            desc = args.get("description") if isinstance(args.get("description"), str) else ""
            ids = AGENT_DECLARATION.findall(desc)
            call_id = call.get("id")
            if len(ids) != 1 or not safe_agent_id(ids[0]) or not isinstance(call_id, str) or not call_id:
                continue
            if ids[0] in seen:
                reused.add(ids[0])
            seen.add(ids[0])
            calls[call_id] = ids[0]
    return {k: v for k, v in calls.items() if v not in reused}


def subagent_count(messages):
    calls = sum(1 for m in messages for c in tool_uses(m) if c.get("name") in SUBAGENT_TOOLS)
    spawned = 0
    for message in messages:
        if isinstance(message, dict) and message.get("type") == "result":
            stats = message.get("subagent_stats")
            if isinstance(stats, dict) and isinstance(stats.get("spawned"), int) and not isinstance(stats.get("spawned"), bool):
                spawned += max(stats["spawned"], 0)
    return max(calls, spawned)


def entry_path(entries, agent_id):
    return os.path.normpath(os.path.join(os.path.abspath(entries), "agents", agent_id, "scratch", "entry.json"))


def read_entries(state, job, entries, trace_path):
    """Returns {agent_id: entry} for every subagent whose entry.json on disk is
    byte for byte the content of that subagent's last Write to it in the
    trace. An entry that any other agent (the top-level agent included)
    wrote or edited, that its own subagent edited, or that differs from that
    last Write is discarded and recorded."""
    messages = read_trace(trace_path)
    bindings = subagent_bindings(messages)
    paths = {entry_path(entries, agent_id): agent_id for agent_id in set(bindings.values())}
    last, refused = {}, {}
    for message in messages:
        if not isinstance(message, dict):
            continue
        parent = message.get("parent_tool_use_id")
        author = bindings.get(parent) if isinstance(parent, str) else None
        for call in tool_uses(message):
            args = call.get("input") if isinstance(call.get("input"), dict) else {}
            target = args.get("file_path")
            if not isinstance(target, str) or not target.startswith("/"):
                continue
            owner = paths.get(os.path.normpath(target))
            if owner is None or call.get("name") == "Read":
                continue
            if author != owner:
                refused.setdefault(owner, "entry written by another agent")
            elif call.get("name") == "Write" and isinstance(args.get("content"), str):
                last[owner] = args["content"]
            else:
                refused.setdefault(owner, "entry edited after it was written")
    result = {}
    for agent_id in sorted(set(bindings.values())):
        if agent_id in refused:
            state.discard(job, agent_id, refused[agent_id])
            continue
        if agent_id not in last:
            state.discard(job, agent_id, "no entry written by this subagent")
            continue
        try:
            data = read_bytes(entry_path(entries, agent_id), MAX_ENTRY_BYTES)
        except (OSError, Refused):
            state.discard(job, agent_id, "entry unreadable or not strict JSON")
            continue
        if data != last[agent_id].encode("utf-8", "surrogatepass"):
            state.discard(job, agent_id, "entry on disk differs from the subagent's write")
            continue
        try:
            entry = parse_strict(data)
        except ValueError:
            state.discard(job, agent_id, "entry unreadable or not strict JSON")
            continue
        if not isinstance(entry, dict):
            state.discard(job, agent_id, "entry is not one JSON object")
            continue
        result[agent_id] = entry
    return result


def one_per_fingerprint(state, job, entries):
    """Keeps entries whose fingerprint no other entry names; a fingerprint two
    entries claim keeps neither."""
    by_fp = {}
    for agent_id, entry in entries.items():
        by_fp.setdefault(entry["fingerprint"], []).append(agent_id)
    kept = {}
    for fp, ids in by_fp.items():
        if len(ids) > 1:
            for agent_id in ids:
                state.discard(job, agent_id, "another entry names the same fingerprint")
        else:
            kept[fp] = (ids[0], entries[ids[0]])
    return kept


# ---------------------------------------------------------------- count


def cmd_count(state, args):
    if not JOB.match(args.job):
        raise Refused("invalid job name")
    if args.cap < 0:
        raise Refused("the cap must not be negative")
    used = subagent_count(read_trace(args.trace))
    usage = state.meta.setdefault("usage", {})
    entry = usage.get(args.job)
    if not isinstance(entry, dict):
        entry = {"invocations": 0, "cap": args.cap}
    entry["invocations"] = int(entry.get("invocations", 0)) + used
    entry["cap"] = args.cap
    usage[args.job] = entry
    if entry["invocations"] > args.cap:
        state.incomplete("cap_exceeded:" + args.job)
    print("merge-records: %s used %d of %d subagent invocations" % (args.job, entry["invocations"], args.cap))


# ---------------------------------------------------------------- select-poc


def prior_confirmed(state):
    """Fingerprints confirmed in the prior run's findings.json, the one listed
    in run-metadata.json prior_run_paths by the trusted step that opened it."""
    paths = state.meta.get("prior_run_paths") or []
    if not isinstance(paths, list):
        raise Refused("prior_run_paths is not a list")
    confirmed = set()
    for path in paths:
        if not isinstance(path, str) or os.path.basename(path) != FINDINGS:
            continue
        try:
            prior = read_json(path, MAX_STATE_BYTES)
        except (OSError, ValueError, Refused) as err:
            raise Refused("the prior findings.json cannot be read (%s)" % type(err).__name__)
        if not isinstance(prior, list):
            raise Refused("the prior findings.json is not a list")
        for record in prior:
            if isinstance(record, dict) and record.get("verdict") == "confirmed" and isinstance(record.get("fingerprint"), str):
                confirmed.add(record["fingerprint"])
    return confirmed


def cmd_select_poc(state, args):
    if "poc" in state.meta:
        raise Refused("select-poc already ran for this state")
    prior = prior_confirmed(state)
    carried, leads = [], []
    for record in state.findings:
        fp = record["fingerprint"]
        if fp in prior and record.get("verdict") != "rejected":
            carried.append(fp)
        elif (record.get("verdict") == "needs_validation"
              and SOURCE_BLOCKER in (record.get("blockers") or [])
              and visible((record.get("validation_plan") or {}).get("local", ""))):
            leads.append(fp)
    carried.sort(key=js_order)
    leads.sort(key=lambda fp: (int(state.history["fingerprints"].get(fp, {}).get("last_poc_run", 0)), js_order(fp)))
    ordered = [(fp, "carried_confirmed") for fp in carried] + [(fp, "lead") for fp in leads]
    chosen, rest = ordered[:POC_SLOTS], ordered[POC_SLOTS:]
    write_json(args.out, {"items": [{"fingerprint": fp, "kind": kind} for fp, kind in chosen]})
    state.meta["poc"] = {
        "selected": [fp for fp, _ in chosen],
        "not_tried": [fp for fp, kind in rest if kind == "lead"],
        "not_rechecked": [fp for fp, kind in rest if kind == "carried_confirmed"],
        "confirmed": [],
    }
    for unit in state.ledger:
        history = state.unit_history(unit["coverage_id"])
        if unit.get("status") == "deferred":
            history["runs_deferred"] = int(history["runs_deferred"]) + 1
        else:
            history["runs_deferred"] = 0
        if unit.get("status") in ("covered", "candidate", "blocked"):
            history["last_covered_run"] = state.run_id
    print("merge-records: selected %d of %d proof-of-concept items" % (len(chosen), len(ordered)))


# ---------------------------------------------------------------- apply-decide


DECIDE_KEYS = {"fingerprint", "script_a", "script_b", "decision", "record"}
SCRIPT_STATES = ("demonstrated", "not_demonstrated")


def decide_entry_valid(entry, selected):
    if set(entry) != DECIDE_KEYS or entry.get("fingerprint") not in selected:
        return False
    if entry["script_a"] not in SCRIPT_STATES or entry["script_b"] not in SCRIPT_STATES:
        return False
    if entry["decision"] not in ("confirmed", "needs_validation", "rejected"):
        return False
    record = entry["record"]
    if not record_valid(record) or record["verdict"] != entry["decision"] or record["fingerprint"] != entry["fingerprint"]:
        return False
    if entry["decision"] == "confirmed" and (entry["script_a"], entry["script_b"]) != ("demonstrated", "demonstrated"):
        return False
    return True


def read_manifest(state, path):
    try:
        manifest = read_json(path, MAX_ENTRY_BYTES)
    except (OSError, ValueError, Refused):
        state.discard("poc-decide", None, "manifest unreadable or not strict JSON")
        return {}
    items = manifest.get("items") if isinstance(manifest, dict) else None
    if not isinstance(items, list):
        state.discard("poc-decide", None, "manifest has no items list")
        return {}
    modes = {}
    for item in items:
        scripts = item.get("scripts") if isinstance(item, dict) else None
        fp = item.get("fingerprint") if isinstance(item, dict) else None
        if not isinstance(fp, str) or not isinstance(scripts, list) or fp in modes:
            state.discard("poc-decide", None, "manifest item malformed or repeated")
            continue
        slots = {}
        for script in scripts:
            if (isinstance(script, dict) and script.get("slot") in ("a", "b")
                    and script.get("mode") in ("http", "drush") and script["slot"] not in slots):
                slots[script["slot"]] = (script["mode"], script.get("script"))
        if set(slots) != {"a", "b"} or len(scripts) != 2:
            state.discard("poc-decide", None, "manifest item malformed or repeated")
            continue
        modes[fp] = slots
    return modes


def run_record_valid(record):
    return (isinstance(record, dict)
            and set(record) == {"fingerprint", "slot", "mode", "script_sha256", "limits",
                                "exit_code", "stdout", "stderr", "timed_out"}
            and isinstance(record["fingerprint"], str) and record["slot"] in ("a", "b")
            and record["mode"] in ("http", "drush")
            and isinstance(record["script_sha256"], str) and bool(SHA256.match(record["script_sha256"]))
            and isinstance(record["limits"], dict)
            and isinstance(record["exit_code"], int) and not isinstance(record["exit_code"], bool)
            and isinstance(record["stdout"], str) and isinstance(record["stderr"], str)
            and isinstance(record["timed_out"], bool))


def script_sha256(scripts, relative):
    """The sha256 of a script under <scripts>, opened one component at a time
    without following links; refuses an absolute path or a .. segment."""
    if not isinstance(relative, str) or relative.startswith("/") or ".." in relative.split("/") \
            or not safe_relative_path(relative):
        raise Refused("script path not allowed")
    parts = relative.split("/")
    fds = []
    try:
        fds.append(os.open(scripts, os.O_RDONLY | os.O_DIRECTORY))
        for name in parts[:-1]:
            fds.append(os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
        data = read_bytes(parts[-1], MAX_SCRIPT_BYTES, dir_fd=fds[-1])
    except FileNotFoundError:
        raise Refused("script missing")
    except OSError as err:
        if err.errno == errno.ELOOP:
            raise Refused("symlink")
        raise Refused("script unreadable")
    finally:
        for fd in reversed(fds):
            os.close(fd)
    return hashlib.sha256(data).hexdigest()


def read_run_records(state, directory, modes, scripts):
    """{(fingerprint, slot): (bytes, record)} for every run record that opens
    safely, matches its manifest item and carries the sha256 of the script the
    manifest names for its slot; refused files are recorded by reason."""
    try:
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        state.discard("poc-decide", None, "run records directory missing")
        return {}
    found, dup = {}, set()
    try:
        for name in sorted(os.listdir(dir_fd)):
            if not RECORD_NAME.match(name):
                continue
            try:
                data = read_bytes(name, MAX_ARTIFACT_BYTES, dir_fd=dir_fd)
                record = parse_strict(data)
            except Refused as err:
                state.discard("poc-decide", None, "run record refused: %s" % err)
                continue
            except (OSError, ValueError):
                state.discard("poc-decide", None, "run record unreadable or not strict JSON")
                continue
            slot = modes.get(record["fingerprint"], {}).get(record["slot"]) if run_record_valid(record) else None
            if slot is None or slot[0] != record["mode"]:
                state.discard("poc-decide", None, "run record malformed or not in the manifest")
                continue
            try:
                digest = script_sha256(scripts, slot[1])
            except Refused as err:
                state.discard("poc-decide", None, "run record refused: %s" % err)
                continue
            if digest != record["script_sha256"]:
                state.discard("poc-decide", None, "run record refused: script sha256 mismatch")
                continue
            key = (record["fingerprint"], record["slot"])
            if key in found:
                dup.add(key)
            found[key] = (data, record)
    finally:
        os.close(dir_fd)
    for key in dup:
        state.discard("poc-decide", None, "two run records for one script")
        del found[key]
    return found


def promote(entries, agent_id, slot, data):
    """Creates agents/<agent_id>/artifacts/<slot>.json under <entries> without
    following links at any component, refusing an existing leaf. Returns the
    output-relative artifact path."""
    fds = []
    try:
        fds.append(os.open(entries, os.O_RDONLY | os.O_DIRECTORY))
        for name in ("agents", agent_id, "artifacts"):
            try:
                os.mkdir(name, 0o755, dir_fd=fds[-1])
            except FileExistsError:
                pass
            fds.append(os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
        leaf = os.open(slot + ".json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=fds[-1])
        try:
            info = os.fstat(leaf)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise Refused("destination is not a new regular file")
            view = memoryview(data)
            while view:
                view = view[os.write(leaf, view):]
        finally:
            os.close(leaf)
    except OSError as err:
        raise Refused("destination refused (%s)" % type(err).__name__)
    finally:
        for fd in reversed(fds):
            os.close(fd)
    return "agents/%s/artifacts/%s.json" % (agent_id, slot)


def unit_agent_ids(unit):
    ids = {unit.get("agent_id")}
    for check in unit.get("local_checks") or []:
        ids.add(check.get("agent_id") if isinstance(check, dict) else None)
    for attempt in unit.get("attempts") or []:
        if isinstance(attempt, dict):
            ids.add(attempt.get("agent_id"))
            for check in attempt.get("local_checks") or []:
                ids.add(check.get("agent_id") if isinstance(check, dict) else None)
    return ids


def add_checks(unit, checks, unresolved):
    """Adds the decision's local checks beside the unit's existing ones; the
    unit keeps its owner, wave and status, and its reviewed_paths become the
    union of all its checks' paths."""
    unit["local_checks"] = list(unit.get("local_checks") or []) + checks
    paths = list(unit.get("reviewed_paths") or [])
    for check in unit["local_checks"]:
        for path in check.get("reviewed_paths") or []:
            add_unique(paths, path)
    unit["reviewed_paths"] = sorted(paths, key=js_order)
    unit["unresolved"] = unresolved


def add_blocker(state, fp, blocker):
    record = state.record(fp)
    if record is not None and record.get("verdict") == "needs_validation":
        add_unique(record["blockers"], blocker)
    for unit in state.units_for(fp):
        add_unique(unit.setdefault("unresolved", []), blocker)


def cmd_apply_decide(state, args):
    poc = state.meta.get("poc")
    if not isinstance(poc, dict) or not isinstance(poc.get("selected"), list):
        raise Refused("no proof-of-concept selection in run-metadata.json")
    selected = set(poc["selected"])
    modes = read_manifest(state, args.manifest)
    records = read_run_records(state, args.records, modes, args.scripts)
    raw = read_entries(state, "poc-decide", args.entries, args.trace)
    valid = {}
    for agent_id, entry in raw.items():
        if decide_entry_valid(entry, selected):
            valid[agent_id] = entry
        else:
            state.discard("poc-decide", agent_id, "entry does not match the poc-decide shape")
    decisions = one_per_fingerprint(state, "poc-decide", valid)

    # Each decision's checks, one per run record promoted to its decider.
    plans = {}
    for fp in sorted(decisions, key=js_order):
        agent_id, entry = decisions[fp]
        units = state.units_for(fp)
        if any(agent_id in unit_agent_ids(u) for u in units):
            state.discard("poc-decide", agent_id, "decider id already owns evidence in the unit")
            continue
        record = entry["record"]
        paths = sorted({t["file"] for t in record["trace"]}, key=js_order)
        invariant = clip(record.get("intended_behavior") or record["title"])
        checks = []
        for slot in ("a", "b"):
            if (fp, slot) not in records:
                continue
            try:
                artifact = promote(args.entries, agent_id, slot, records[(fp, slot)][0])
            except Refused as err:
                state.discard("poc-decide", agent_id, "promotion refused: %s" % err)
                continue
            checks.append({
                "agent_id": agent_id,
                "reviewed_paths": paths,
                "invariant": invariant,
                "method": "local",
                "result": "script %s: %s; decision: %s" % (slot, entry["script_" + slot], entry["decision"]),
                "artifact": artifact,
            })
        if entry["decision"] == "confirmed" and len(checks) != 2:
            add_blocker(state, fp, PROMOTION_FAILED)
            state.discard("poc-decide", agent_id, "confirmed without both run records promoted")
            continue
        plans[fp] = (agent_id, entry, checks)

    for fp in sorted(selected - set(plans), key=js_order):
        add_blocker(state, fp, DECISION_DISCARDED)

    # Apply records, then add the checks to every linked unit.
    old_blockers = {}
    for fp, (agent_id, entry, checks) in plans.items():
        before = state.record(fp)
        old_blockers[fp] = list((before or {}).get("blockers") or [])
        state.put(entry["record"])
        if entry["decision"] == "confirmed":
            add_unique(poc.setdefault("confirmed", []), fp)
        elif fp in poc.get("confirmed", []):
            poc["confirmed"].remove(fp)
    for unit in state.ledger:
        mine = [fp for fp in sorted(plans, key=js_order) if fp in (unit.get("result_fingerprints") or []) and plans[fp][2]]
        if not mine or unit.get("status") != "candidate" or not safe_agent_id(unit.get("agent_id")):
            continue
        checks = [c for fp in mine for c in plans[fp][2]]
        unresolved = [u for u in unit.get("unresolved", []) if not any(u in old_blockers[fp] for fp in mine)]
        for fp in unit.get("result_fingerprints", []):
            record = state.record(fp)
            if record is not None and record.get("verdict") == "needs_validation":
                for blocker in record["blockers"]:
                    if fp in mine or blocker in unit.get("unresolved", []):
                        add_unique(unresolved, blocker)
        add_checks(unit, checks, unresolved)

    for fp in selected:
        history = state.fp_history(fp)
        history["last_poc_run"] = state.run_id
        history["poc_tries"] = int(history["poc_tries"]) + 1
    poc["decided"] = sorted(plans, key=js_order)
    print("merge-records: applied %d of %d proof-of-concept decisions" % (len(plans), len(selected)))


# ---------------------------------------------------------------- fail-poc


def cmd_fail_poc(state, args):
    if not JOB.match(args.job):
        raise Refused("invalid job name")
    try:
        select = read_json(args.select, MAX_ENTRY_BYTES)
        items = select["items"]
        fps = [item["fingerprint"] for item in items]
    except (OSError, ValueError, Refused, KeyError, TypeError):
        raise Refused("select.json cannot be read")
    if not all(isinstance(fp, str) for fp in fps):
        raise Refused("select.json has a non-string fingerprint")
    blocker = "poc phase failed: " + args.job
    for fp in fps:
        add_blocker(state, fp, blocker)
    poc = state.meta.setdefault("poc", {})
    poc["failed"] = args.job
    poc["confirmed"] = []
    print("merge-records: marked %d selected item(s) with the failed poc phase" % len(fps))


# ---------------------------------------------------------------- cross-check


def cmd_select_cross_check(state, args):
    pool = [r["fingerprint"] for r in state.findings if r.get("verdict") in ("confirmed", "needs_validation")]
    pool.sort(key=lambda fp: (int(state.history["fingerprints"].get(fp, {}).get("last_cross_checked_run", 0)), js_order(fp)))
    chosen, rest = pool[:CROSS_CHECK_SLOTS], pool[CROSS_CHECK_SLOTS:]
    write_json(args.out, {"items": [{"fingerprint": fp} for fp in chosen]})
    state.meta["cross_check"] = {
        "selected": chosen, "not_cross_checked": rest, "settled": [], "refused": [],
        "disputes": 0, "cross_checked": 0, "tie_breaks": [], "removed": 0,
    }
    if rest:
        state.incomplete("cross_check_cap")
    print("merge-records: selected %d of %d records for the cross-check" % (len(chosen), len(pool)))


def norm(text):
    return " ".join(text.split()).casefold() if isinstance(text, str) else None


def trace_set(record):
    return {(t["kind"], t["file"], t["scope"]) for t in record["trace"]}


def payloads(record):
    return {canonical(p) for p in record.get("execution", {}).get("payloads", [])}


def cross_check_outcome(original, replacement):
    """Technical Plan section 7's rules in order: 'apply', 'dispute:<rule>' or
    'refuse:<rule>'."""
    old, new = original["verdict"], replacement["verdict"]
    if old != new:
        if new == "confirmed":
            return "refuse:promotion"
        return "dispute:verdict"
    if old == "confirmed":
        before, after = original["severity"], replacement["severity"]
        moves = [SEVERITY_RANK[after["overall_severity"]] - SEVERITY_RANK[before["overall_severity"]],
                 SEVERITY_RANK[after["impact"]["score"]] - SEVERITY_RANK[before["impact"]["score"]]]
        if any(m > 0 for m in moves):
            return "refuse:severity_raise"
        if any(m < 0 for m in moves):
            return "dispute:severity_lowered"
        if (payloads(original) != payloads(replacement)
                or original["execution"]["observed_result"] != replacement["execution"]["observed_result"]):
            return "refuse:execution"
    cause = "root_cause" if old == "confirmed" else "claimed_root_cause"
    if trace_set(original) != trace_set(replacement) or norm(original.get(cause)) != norm(replacement.get(cause)):
        return "dispute:material"
    return "apply"


def cross_entry_valid(entry, selected):
    if entry.get("fingerprint") not in selected:
        return False
    if entry.get("decision") == "verified":
        return set(entry) == {"decision", "fingerprint"}
    if entry.get("decision") == "replace":
        return (set(entry) == {"decision", "fingerprint", "reason", "record"}
                and visible_text(entry["reason"]) and record_valid(entry["record"])
                and entry["record"]["fingerprint"] == entry["fingerprint"])
    return False


def cmd_apply_cross_check(state, args):
    cc = state.meta.get("cross_check")
    if not isinstance(cc, dict) or not isinstance(cc.get("selected"), list):
        raise Refused("no cross-check selection in run-metadata.json")
    selected = set(cc["selected"])
    raw = read_entries(state, "cross-check", args.entries, args.trace)
    valid = {}
    for agent_id, entry in raw.items():
        if cross_entry_valid(entry, selected):
            valid[agent_id] = entry
        else:
            state.discard("cross-check", agent_id, "entry does not match the cross-check shape")
    entries = one_per_fingerprint(state, "cross-check", valid)
    disputes = []
    for fp in sorted(entries, key=js_order):
        _, entry = entries[fp]
        original = state.record(fp)
        if original is None:
            continue
        cc["cross_checked"] += 1
        state.fp_history(fp)["last_cross_checked_run"] = state.run_id
        if entry["decision"] == "verified":
            add_unique(cc["settled"], fp)
            continue
        outcome = cross_check_outcome(original, entry["record"])
        if outcome == "apply":
            state.put(entry["record"])
            add_unique(cc["settled"], fp)
        elif outcome.startswith("refuse:"):
            cc["refused"].append({"fingerprint": fp, "rule": outcome.split(":", 1)[1]})
            add_unique(cc["settled"], fp)
        else:
            disputes.append({"fingerprint": fp, "rule": outcome.split(":", 1)[1], "original": original,
                             "replacement": entry["record"], "cross_check_reason": entry["reason"]})
    for fp in sorted(selected - set(entries), key=js_order):
        add_unique(cc["not_cross_checked"], fp)
        state.incomplete("cross_check_missing")
    cc["disputes"] = len(disputes)
    cc["pending"] = [d["fingerprint"] for d in disputes]
    cc["applied"] = True
    write_json(args.out, {"disputes": disputes})
    print("merge-records: %d record(s) cross-checked, %d dispute(s)" % (cc["cross_checked"], len(disputes)))


def remove_disputed(state, dispute, because, tie_break):
    fp = dispute["fingerprint"]
    state.remove(fp)
    state.disputed.append({
        "fingerprint": fp, "record": dispute["original"], "replacement": dispute["replacement"],
        "cross_check_reason": dispute["cross_check_reason"], "tie_break": tie_break, "removed_because": because,
    })
    for unit in state.units_for(fp):
        add_unique(unit.setdefault("unresolved", []), DISPUTE_UNRESOLVED)
    state.meta["cross_check"]["removed"] += 1
    state.incomplete("cross_check_dispute")


def cmd_apply_tie_break(state, args):
    cc = state.meta.get("cross_check")
    if not isinstance(cc, dict) or not cc.get("applied"):
        raise Refused("apply-cross-check has not run")
    try:
        disputes = read_json(args.inputs, MAX_STATE_BYTES)["disputes"]
    except (OSError, ValueError, Refused, KeyError, TypeError):
        raise Refused("the tie-break inputs cannot be read")
    disputes = sorted([d for d in disputes if d.get("fingerprint") in cc.get("pending", [])],
                      key=lambda d: js_order(d["fingerprint"]))
    eligible = {d["fingerprint"] for d in disputes[:TIE_BREAK_SLOTS]}
    raw = read_entries(state, "tie-break", args.entries, args.trace)
    valid = {}
    for agent_id, entry in raw.items():
        if (set(entry) == {"fingerprint", "answer", "reason"} and entry["fingerprint"] in eligible
                and entry["answer"] in ("original", "replacement", "neither") and visible_text(entry["reason"])):
            valid[agent_id] = entry
        else:
            state.discard("tie-break", agent_id, "entry does not match the tie-break shape")
    answers = one_per_fingerprint(state, "tie-break", valid)
    for index, dispute in enumerate(disputes):
        fp = dispute["fingerprint"]
        if index >= TIE_BREAK_SLOTS:
            remove_disputed(state, dispute, "tie_break_cap", None)
            continue
        if fp not in answers:
            remove_disputed(state, dispute, "no_valid_tie_break", None)
            continue
        _, entry = answers[fp]
        cc["tie_breaks"].append({"fingerprint": fp, "side": entry["answer"]})
        tie_break = {"answer": entry["answer"], "reason": entry["reason"]}
        if entry["answer"] == "original":
            add_unique(cc["settled"], fp)
        elif entry["answer"] == "replacement" and record_valid(dispute["replacement"]):
            state.put(dispute["replacement"])
            add_unique(cc["settled"], fp)
        else:
            remove_disputed(state, dispute, "neither" if entry["answer"] == "neither" else "replacement_invalid", tie_break)
    cc["pending"] = []
    print("merge-records: settled %d dispute(s)" % len(disputes))


# ---------------------------------------------------------------- status


def cmd_status(state, args):
    cc = state.meta.get("cross_check")
    if isinstance(cc, dict):
        if not cc.get("applied"):
            for fp in cc.get("selected", []):
                add_unique(cc["not_cross_checked"], fp)
            if cc.get("selected"):
                state.incomplete("cross_check_missing")
        for fp in list(cc.get("pending") or []):
            original = state.record(fp)
            if original is not None:
                remove_disputed(state, {"fingerprint": fp, "original": original, "replacement": None,
                                        "cross_check_reason": None}, "tie_break_not_run", None)
        cc["pending"] = []
        checked = cc.get("cross_checked", 0)
        state.meta["dispute_rate"] = {
            "disputes": cc.get("disputes", 0), "cross_checked": checked,
            "rate": round(cc.get("disputes", 0) / checked, 4) if checked else None,
        }
    else:
        state.incomplete("cross_check_not_run")
    if state.meta.get("run_status") not in ("complete", "incomplete"):
        state.incomplete("source_run_not_finished")
    if state.meta["incomplete_reasons"]:
        state.meta["run_status"] = "incomplete"
        state.meta["incomplete_reason"] = "; ".join(state.meta["incomplete_reasons"])
    else:
        state.meta["run_status"] = "complete"
        state.meta.pop("incomplete_reason", None)
    print("merge-records: run_status %s" % state.meta["run_status"])


# ---------------------------------------------------------------- main


def main(argv):
    parser = argparse.ArgumentParser(prog="merge-records.py")
    parser.add_argument("--state", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("count")
    p.add_argument("--job", required=True)
    p.add_argument("--cap", required=True, type=int)
    p.add_argument("--trace", required=True)
    p = sub.add_parser("select-poc")
    p.add_argument("--out", required=True)
    p = sub.add_parser("apply-decide")
    for name in ("--manifest", "--records", "--scripts", "--entries", "--trace"):
        p.add_argument(name, required=True)
    p = sub.add_parser("fail-poc")
    p.add_argument("--select", required=True)
    p.add_argument("--job", required=True)
    p = sub.add_parser("select-cross-check")
    p.add_argument("--out", required=True)
    p = sub.add_parser("apply-cross-check")
    for name in ("--entries", "--trace", "--out"):
        p.add_argument(name, required=True)
    p = sub.add_parser("apply-tie-break")
    for name in ("--inputs", "--entries", "--trace"):
        p.add_argument(name, required=True)
    sub.add_parser("status")
    args = parser.parse_args(argv)

    commands = {
        "count": cmd_count, "select-poc": cmd_select_poc, "apply-decide": cmd_apply_decide,
        "fail-poc": cmd_fail_poc, "select-cross-check": cmd_select_cross_check,
        "apply-cross-check": cmd_apply_cross_check, "apply-tie-break": cmd_apply_tie_break,
        "status": cmd_status,
    }
    try:
        state = State(args.state)
        commands[args.command](state, args)
        state.save()
    except Refused as err:
        print("merge-records: %s: %s" % (args.command, err), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
