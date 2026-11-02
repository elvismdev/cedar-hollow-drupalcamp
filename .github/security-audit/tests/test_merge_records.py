# Tests for merge-records.py, one or more per rule in its design item. Each
# test builds a small synthetic state directory, runs the script through
# subprocess with python3 -I, and reads the files it rewrote. Where a test
# says the merged files are valid, it runs the vendored skill's own Node
# validators on them.
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SA = os.path.dirname(HERE)
SCRIPT = os.path.join(SA, "merge-records.py")
SKILL = os.path.join(SA, "skill")
NODE = shutil.which("node")
RUN_ID = 9001
SOURCE_BLOCKER = "no sandbox in the source job"
ENTRY_FILE = "web/modules/custom/demo/src/Controller/DemoController.php"
SINK_FILE = "web/modules/custom/demo/src/DemoStorage.php"


def encode_ref(value):
    out = ""
    for byte in value.encode("utf-8"):
        ch = chr(byte)
        out += ch if (ch.isascii() and (ch.isalnum() or ch in "-._~")) else "%%%02X" % byte
    return out


def trace(scope="DemoController::view"):
    return [
        {"kind": "entrypoint", "file": ENTRY_FILE, "line": 10, "scope": scope, "description": "Route handler."},
        {"kind": "sink", "file": SINK_FILE, "line": 20, "scope": "DemoStorage::load", "description": "Loads the row."},
    ]


def evidence():
    return [{"file": SINK_FILE, "line": 20, "description": "No access check before the load."}]


def lead(fp, blockers=None, local=True, title=None):
    plan = {"local": "Request the route as the anonymous test account."} if local else {
        "deployment": "Observe the route on a deployed site."}
    return {
        "verdict": "needs_validation", "fingerprint": fp, "title": title or "Lead " + fp,
        "description": "The route may return rows without an access check.",
        "claimed_root_cause": "Missing access check", "trace": trace(), "evidence": evidence(),
        "blockers": list(blockers if blockers is not None else [SOURCE_BLOCKER]),
        "validation_plan": plan,
    }


def confirmed(fp, overall="medium", impact="medium", observed="HTTP 200 with another user's row.",
              payloads=None, root_cause="Missing access check"):
    return {
        "verdict": "confirmed", "fingerprint": fp, "title": "Finding " + fp,
        "description": "The route returns rows without an access check.",
        "root_cause": root_cause, "intended_behavior": "Only the owner can read a row.",
        "trace": trace(), "evidence": evidence(), "conditions": [],
        "execution": {
            "attacker_perspective": "The anonymous test account.",
            "payloads": payloads or ["GET /demo/1"],
            "instructions": ["Request /demo/1 without logging in."],
            "observed_result": observed,
        },
        "remediation": {"strategy": "Check access before loading the row."},
        "severity": {
            "likelihood": {"score": "medium", "reason": "Reachable anonymously."},
            "impact": {"score": impact, "reason": "Reads another user's row."},
            "overall_severity": overall,
        },
        "confidence": {"score": "high", "reason": "Two scripts showed it."},
    }


def rejected(fp):
    return {
        "verdict": "rejected", "fingerprint": fp, "title": "Rejected " + fp,
        "description": "The route looked unprotected.", "claimed_root_cause": "Missing access check",
        "trace": trace(), "evidence": evidence(), "reason": "The route requires a permission.",
    }


def unit(name, status="candidate", fps=(), unresolved=None):
    refs = {"surface": "demo#" + name, "boundary": "anonymous to owner", "subsystem": "demo",
            "attack_class": "ATTACK-CLASSES.md#Access control"}
    reviewed = status in ("candidate", "covered", "blocked")
    return {
        "coverage_id": "::".join(encode_ref(refs[k]) for k in ("surface", "boundary", "subsystem", "attack_class")),
        "canonical_refs": refs, "surface": "Demo " + name, "boundary": "Anonymous to owner",
        "subsystem": "Demo", "attack_class": "Access control", "starting_paths": [ENTRY_FILE],
        "ordinary_attack_class_block": "ATTACK-CLASSES.md#Access control", "selected_companion_blocks": [],
        "excluded_blocks": [], "prior_status": "new", "attempts": [], "wave": 1, "status": status,
        "agent_id": ("hunter-" + name) if reviewed else None,
        "reviewed_paths": [SINK_FILE] if reviewed else [],
        "local_checks": [{"agent_id": "hunter-" + name, "reviewed_paths": [SINK_FILE],
                          "invariant": "Access is checked before the load.", "method": "source",
                          "result": "No check found.", "artifact": None}] if reviewed else [],
        "result_fingerprints": list(fps),
        "unresolved": list(unresolved if unresolved is not None else ([SOURCE_BLOCKER] if fps else
                                                                       (["budget"] if status == "deferred" else []))),
    }


def metadata(**extra):
    meta = {
        "run_id": str(RUN_ID), "repo": "example/demo", "target": "main", "source_ref": "0" * 40,
        "profile": "standard", "scope_paths": ["web/modules/custom"], "budget": 60,
        "execution_policy": "sandboxed-source-and-local-only", "companions": [], "prior_run_paths": [],
        "shared_file_owners": {}, "usage": {}, "run_status": "complete",
    }
    meta.update(extra)
    return meta


class MergeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state")
        self.out = os.path.join(self.tmp, "out")
        self.records = os.path.join(self.tmp, "records")
        self.scripts = os.path.join(self.tmp, "scripts")
        for d in (self.state, self.out, self.records, self.scripts):
            os.makedirs(d)
        self.messages = []
        self.calls = 0

    def tearDown(self):
        shutil.rmtree(self.tmp)

    # -- fixtures

    def write(self, path, value):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(value if isinstance(value, str) else json.dumps(value))

    def seed(self, findings, ledger, meta=None, history=None, trusted=None):
        trusted_path = os.path.join(self.state, "trusted-meta.json")
        if os.path.exists(trusted_path):
            os.remove(trusted_path)
        if trusted is not None:
            self.write(trusted_path, trusted)
        self.write(os.path.join(self.state, "findings.json"), findings)
        self.write(os.path.join(self.state, "coverage-ledger.json"), ledger)
        self.write(os.path.join(self.state, "run-metadata.json"), meta or metadata())
        if history is not None:
            self.write(os.path.join(self.state, "audit-history.json"), history)

    def load(self, name):
        with open(os.path.join(self.state, name), encoding="utf-8") as handle:
            return json.load(handle)

    def record(self, fp):
        return next((r for r in self.load("findings.json") if r["fingerprint"] == fp), None)

    def unit_for(self, name):
        return next(u for u in self.load("coverage-ledger.json") if u["surface"] == "Demo " + name)

    def subagent(self, agent_id, entry, write_by_subagent=True, description=None):
        """Adds a subagent call to the trace and writes its entry.json; the
        trace shows the subagent writing it unless told otherwise."""
        self.calls += 1
        call_id = "toolu_%d" % self.calls
        path = os.path.join(self.out, "agents", agent_id, "scratch", "entry.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        text = entry if isinstance(entry, str) else json.dumps(entry)
        self.write(path, text)
        self.messages.append({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": call_id, "name": "Agent",
             "input": {"description": description or "agent-id: %s check" % agent_id, "prompt": "p"}}]}})
        writer = {"type": "tool_use", "id": call_id + "w", "name": "Write",
                  "input": {"file_path": path, "content": text}}
        if write_by_subagent:
            self.messages.append({"type": "assistant", "parent_tool_use_id": call_id,
                                  "message": {"content": [writer]}})
        else:
            self.messages.append({"type": "assistant", "message": {"content": [writer]}})
            self.messages.append({"type": "assistant", "parent_tool_use_id": call_id, "message": {"content": [
                {"type": "tool_use", "id": call_id + "r", "name": "Read", "input": {"file_path": path}}]}})

    def trace_file(self):
        path = os.path.join(self.tmp, "trace-%d.json" % len(self.messages))
        self.write(path, self.messages + [{"type": "result", "subtype": "success"}])
        self.messages = []
        return path

    def run_merge(self, *args, ok=True):
        result = subprocess.run([sys.executable, "-I", SCRIPT, "--state", self.state] + list(args),
                                capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def script(self, relative, fp, slot):
        """Writes a script into the scripts hand-off; returns its sha256."""
        content = "<?php\n// %s %s\n" % (fp, slot)
        path = os.path.join(self.scripts, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.write(path, content)
        return hashlib.sha256(content.encode("utf-8")).hexdigest()

    def run_record(self, fp, slot, index, mode="http", name=None, sha="a" * 64):
        record = {"fingerprint": fp, "slot": slot, "mode": mode, "script_sha256": sha,
                  "limits": {"timeout_seconds": 120}, "exit_code": 0, "stdout": "HTTP 200\n",
                  "stderr": "", "timed_out": False}
        path = os.path.join(self.records, name or "poc-run-%d-%s.json" % (index, slot))
        self.write(path, record)
        return path

    def manifest(self, fps):
        items = [{"fingerprint": fp, "scripts": [
            {"slot": s, "agent_id": "writer-%d%s" % (i, s), "mode": "http",
             "script": "agents/writer-%d%s/scratch/poc.php" % (i, s), "fixture": None} for s in "ab"]}
            for i, fp in enumerate(fps)]
        path = os.path.join(self.tmp, "poc-manifest.json")
        self.write(path, {"items": items})
        for i, fp in enumerate(fps):
            for slot in "ab":
                sha = self.script("agents/writer-%d%s/scratch/poc.php" % (i, slot), fp, slot)
                self.run_record(fp, slot, i, sha=sha)
        return path

    def select(self):
        prior = [arg for path in getattr(self, "prior_paths", []) for arg in ("--prior", path)]
        return self.run_merge("select-poc", "--out", os.path.join(self.tmp, "select.json"), *prior)

    def decide(self, manifest):
        return self.run_merge("apply-decide", "--manifest", manifest, "--records", self.records,
                              "--scripts", self.scripts, "--entries", self.out, "--trace", self.trace_file())

    def cross_check(self):
        inputs = os.path.join(self.tmp, "tie-break-inputs.json")
        self.run_merge("select-cross-check", "--out", os.path.join(self.tmp, "list.json"))
        self.run_merge("apply-cross-check", "--entries", self.out, "--trace", self.trace_file(), "--out", inputs)
        with open(inputs, encoding="utf-8") as handle:
            return json.load(handle)["disputes"]

    def tie_break(self):
        return self.run_merge("apply-tie-break", "--inputs", os.path.join(self.tmp, "tie-break-inputs.json"),
                              "--entries", self.out, "--trace", self.trace_file())

    def discarded(self):
        return [d["reason"] for d in self.load("trusted-meta.json").get("merge_discarded", [])]

    def assert_validators_pass(self):
        if NODE is None:
            self.fail("node is required to run the skill's validators")
        for validator, name in (("validate-findings.cjs", "findings.json"),
                                ("validate-coverage-ledger.cjs", "coverage-ledger.json")):
            result = subprocess.run([NODE, os.path.join(SKILL, validator), os.path.join(self.state, name)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, "%s: %s%s" % (validator, result.stdout, result.stderr))

    def decided(self, fp, decision, record, a="demonstrated", b="demonstrated"):
        return {"fingerprint": fp, "script_a": a, "script_b": b, "decision": decision, "record": record}

    def prior(self, findings):
        path = os.path.join(self.tmp, "in", "findings.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.write(path, findings)
        self.prior_paths = [path]
        return metadata()


class SelectionTest(MergeTest):
    def test_carried_confirmed_first_then_eligible_leads_least_recently_tried(self):
        findings = [
            lead("c-carried-2"), lead("c-carried-1"), rejected("c-carried-rejected"),
            lead("l-old"), lead("l-new"), lead("l-never-b"), lead("l-never-a"),
            lead("x-other-blocker", blockers=["needs a deployment"]),
            lead("x-near-blocker", blockers=[SOURCE_BLOCKER + "."]),
            lead("x-deployment-plan", local=False),
        ]
        prior = [confirmed("c-carried-1"), confirmed("c-carried-2"), confirmed("c-carried-rejected")]
        history = {"fingerprints": {"l-old": {"last_poc_run": 10, "last_cross_checked_run": 0, "poc_tries": 1},
                                    "l-new": {"last_poc_run": 20, "last_cross_checked_run": 0, "poc_tries": 1}},
                   "units": {}}
        self.seed(findings, [], self.prior(prior), history)
        self.select()
        with open(os.path.join(self.tmp, "select.json"), encoding="utf-8") as handle:
            items = json.load(handle)["items"]
        self.assertEqual([(i["fingerprint"], i["kind"]) for i in items], [
            ("c-carried-1", "carried_confirmed"), ("c-carried-2", "carried_confirmed"),
            ("l-never-a", "lead"), ("l-never-b", "lead"), ("l-old", "lead"), ("l-new", "lead")])
        poc = self.load("trusted-meta.json")["poc"]
        self.assertEqual(poc["not_tried"], [])
        self.assertEqual(poc["not_rechecked"], [])

    def test_items_beyond_six_are_not_tried_or_not_rechecked(self):
        carried = ["c%d" % i for i in range(5)]
        leads = ["l%d" % i for i in range(3)]
        self.seed([lead(fp) for fp in carried + leads] + [lead("c9")], [],
                  self.prior([confirmed(fp) for fp in carried + ["c9"]]))
        self.select()
        poc = self.load("trusted-meta.json")["poc"]
        self.assertEqual(poc["selected"], ["c0", "c1", "c2", "c3", "c4", "c9"])
        self.assertEqual(poc["not_rechecked"], [])
        self.assertEqual(poc["not_tried"], leads)

    def test_select_poc_runs_once_per_state(self):
        self.seed([lead("a")], [])
        self.select()
        self.assertEqual(self.select_again().returncode, 1)

    def select_again(self):
        return self.run_merge("select-poc", "--out", os.path.join(self.tmp, "select.json"), ok=False)


class DecideTest(MergeTest):
    def setup_items(self, fps):
        self.seed([lead(fp) for fp in fps], [unit(fp, fps=[fp]) for fp in fps])
        self.select()
        return self.manifest(fps)

    def test_confirmed_only_when_both_scripts_demonstrate(self):
        manifest = self.setup_items(["f-both", "f-one"])
        self.subagent("decider-1", self.decided("f-both", "confirmed", confirmed("f-both")))
        self.subagent("decider-2", self.decided("f-one", "confirmed", confirmed("f-one"), b="not_demonstrated"))
        self.decide(manifest)
        self.assertEqual(self.record("f-both")["verdict"], "confirmed")
        one = self.record("f-one")
        self.assertEqual(one["verdict"], "needs_validation")
        self.assertIn("poc decision discarded", one["blockers"])
        self.assertEqual(self.load("trusted-meta.json")["poc"]["confirmed"], ["f-both"])
        self.assertIn("entry does not match the poc-decide shape", self.discarded())
        self.assert_validators_pass()

    def test_each_ledger_transition_records_the_decider_checks(self):
        fps = ["t-confirmed", "t-lead", "t-rejected"]
        manifest = self.setup_items(fps)
        new_lead = lead("t-lead", blockers=["the fixture cannot create a second site"])
        self.subagent("decider-c", self.decided("t-confirmed", "confirmed", confirmed("t-confirmed")))
        self.subagent("decider-l", self.decided("t-lead", "needs_validation", new_lead, b="not_demonstrated"))
        self.subagent("decider-r", self.decided("t-rejected", "rejected", rejected("t-rejected"),
                                                a="not_demonstrated", b="not_demonstrated"))
        self.decide(manifest)
        for fp, decider, unresolved in (("t-confirmed", "decider-c", []),
                                        ("t-lead", "decider-l", ["the fixture cannot create a second site"]),
                                        ("t-rejected", "decider-r", [])):
            u = self.unit_for(fp)
            self.assertEqual(u["status"], "candidate")
            self.assertEqual(u["wave"], 1)
            self.assertEqual(u["agent_id"], "hunter-" + fp)
            self.assertEqual(u["attempts"], [])
            self.assertEqual(u["result_fingerprints"], [fp])
            self.assertEqual(u["unresolved"], unresolved)
            self.assertEqual([c["agent_id"] for c in u["local_checks"]], ["hunter-" + fp, decider, decider])
            self.assertEqual([c["artifact"] for c in u["local_checks"]],
                             [None, "agents/%s/artifacts/a.json" % decider, "agents/%s/artifacts/b.json" % decider])
            demonstrated = {"t-confirmed": ("demonstrated", "demonstrated"),
                            "t-lead": ("demonstrated", "not_demonstrated"),
                            "t-rejected": ("not_demonstrated", "not_demonstrated")}[fp]
            invariant = "Only the owner can read a row." if fp == "t-confirmed" else self.record(fp)["title"]
            for slot, check, state in zip("ab", u["local_checks"][1:], demonstrated):
                self.assertEqual(check["reviewed_paths"], [ENTRY_FILE, SINK_FILE])
                self.assertEqual(check["method"], "local")
                self.assertEqual(check["invariant"], invariant)
                self.assertEqual(check["result"], "script %s: %s; decision: %s" % (
                    slot, state, self.record(fp)["verdict"]))
            self.assertEqual(u["reviewed_paths"], [ENTRY_FILE, SINK_FILE])
            self.assertTrue(os.path.isfile(os.path.join(self.out, "agents", decider, "artifacts", "a.json")))
        self.assertEqual(self.record("t-rejected")["verdict"], "rejected")
        self.assertEqual(self.record("t-lead")["blockers"], ["the fixture cannot create a second site"])
        self.assert_validators_pass()

    def test_a_decision_without_promoted_records_still_updates_the_unit(self):
        manifest = self.setup_items(["n-1"])
        for name in os.listdir(self.records):
            os.remove(os.path.join(self.records, name))
        new_lead = lead("n-1", blockers=["the scripts produced no run record"])
        self.subagent("decider-n", self.decided("n-1", "needs_validation", new_lead,
                                                a="not_demonstrated", b="not_demonstrated"))
        self.decide(manifest)
        self.assertEqual(self.record("n-1")["blockers"], ["the scripts produced no run record"])
        u = self.unit_for("n-1")
        self.assertEqual(u["unresolved"], ["the scripts produced no run record"])
        self.assertEqual([c["agent_id"] for c in u["local_checks"]], ["hunter-n-1"])
        self.assert_validators_pass()

    def test_poc_failed_adds_the_blocker_to_record_and_unit(self):
        self.seed([lead("p-1"), lead("p-2")], [unit("p-1", fps=["p-1"]), unit("p-2", fps=["p-2"])])
        self.select()
        self.run_merge("fail-poc", "--select", os.path.join(self.tmp, "select.json"), "--job", "poc-run")
        for fp in ("p-1", "p-2"):
            self.assertEqual(self.record(fp)["blockers"], [SOURCE_BLOCKER, "poc phase failed: poc-run"])
            self.assertEqual(self.unit_for(fp)["unresolved"], [SOURCE_BLOCKER, "poc phase failed: poc-run"])
            self.assertEqual(self.unit_for(fp)["wave"], 1)
        history = self.load("audit-history.json")["fingerprints"]
        self.assertNotIn("p-1", history)
        self.assert_validators_pass()

    def promotion_case(self, prepare):
        manifest = self.setup_items(["g-1"])
        prepare(os.path.join(self.records, "poc-run-0-b.json"))
        self.subagent("decider-g", self.decided("g-1", "confirmed", confirmed("g-1")))
        self.decide(manifest)
        record = self.record("g-1")
        self.assertEqual(record["verdict"], "needs_validation")
        self.assertIn("poc evidence promotion failed", record["blockers"])
        self.assertFalse(os.path.exists(os.path.join(self.out, "agents", "decider-g", "artifacts", "b.json")))
        self.assert_validators_pass()
        return self.discarded()

    def test_promotion_refuses_a_symlink(self):
        def link(path):
            target = os.path.join(self.tmp, "elsewhere.json")
            os.replace(path, target)
            os.symlink(target, path)
        self.assertIn("run record refused: symlink", self.promotion_case(link))

    def test_promotion_refuses_a_hardlink(self):
        def hardlink(path):
            os.link(path, os.path.join(self.tmp, "second-name.json"))
        self.assertIn("run record refused: hardlinked", self.promotion_case(hardlink))

    def sized(self, path, total):
        """Pads a run record's stdout so the file is exactly total bytes."""
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
        record["stdout"] = ""
        record["stdout"] = "x" * (total - len(json.dumps(record)))
        self.write(path, record)
        self.assertEqual(os.path.getsize(path), total)

    def test_promotion_refuses_a_file_over_one_mebibyte(self):
        self.assertIn("run record refused: oversized",
                      self.promotion_case(lambda path: self.sized(path, 1024 * 1024 + 1)))

    def test_promotion_accepts_a_file_just_under_one_mebibyte(self):
        manifest = self.setup_items(["g-1"])
        self.sized(os.path.join(self.records, "poc-run-0-b.json"), 1024 * 1024 - 1)
        self.subagent("decider-g", self.decided("g-1", "confirmed", confirmed("g-1")))
        self.decide(manifest)
        self.assertEqual(self.record("g-1")["verdict"], "confirmed")
        promoted = os.path.join(self.out, "agents", "decider-g", "artifacts", "b.json")
        self.assertEqual(os.path.getsize(promoted), 1024 * 1024 - 1)
        self.assert_validators_pass()

    def script_case(self, change):
        """Decides g-1 as confirmed after change() edits slot b's manifest entry
        or its script, and returns the discard reasons; the decision must be
        refused."""
        manifest = self.setup_items(["g-1"])
        with open(manifest, encoding="utf-8") as handle:
            data = json.load(handle)
        change(data["items"][0]["scripts"][1])
        self.write(manifest, data)
        self.subagent("decider-g", self.decided("g-1", "confirmed", confirmed("g-1")))
        self.decide(manifest)
        record = self.record("g-1")
        self.assertEqual(record["verdict"], "needs_validation")
        self.assertIn("poc evidence promotion failed", record["blockers"])
        self.assertFalse(os.path.exists(os.path.join(self.out, "agents", "decider-g", "artifacts", "b.json")))
        self.assertEqual([c["agent_id"] for c in self.unit_for("g-1")["local_checks"]], ["hunter-g-1"])
        self.assert_validators_pass()
        return self.discarded()

    def test_a_script_hash_mismatch_refuses_the_record(self):
        def edit(script):
            with open(os.path.join(self.scripts, script["script"]), "a", encoding="utf-8") as handle:
                handle.write("// changed after the run\n")
            script["sha256"] = "a" * 64
        self.assertIn("run record refused: script sha256 mismatch", self.script_case(edit))

    def test_a_missing_script_refuses_the_record(self):
        self.assertIn("run record refused: script missing",
                      self.script_case(lambda script: os.remove(os.path.join(self.scripts, script["script"]))))

    def test_a_script_path_outside_the_scripts_dir_is_refused(self):
        outside = os.path.join(self.tmp, "outside.php")
        for path in (outside, "../outside.php", "agents/../../outside.php"):
            with self.subTest(path=path):
                self.tearDown()
                self.setUp()
                def move(script):
                    target = os.path.join(self.tmp, "outside.php")
                    os.replace(os.path.join(self.scripts, script["script"]), target)
                    script["script"] = path if path != outside else target
                self.assertIn("run record refused: script path not allowed", self.script_case(move))

    def test_a_symlinked_script_is_refused(self):
        def link(script):
            real = os.path.join(self.scripts, script["script"])
            target = os.path.join(self.tmp, "real.php")
            os.replace(real, target)
            os.symlink(target, real)
        self.assertIn("run record refused: symlink", self.script_case(link))

    def test_malformed_entries_are_discarded(self):
        fps = ["m-prose", "m-dupkey", "m-shape", "m-unattributed", "m-fp"]
        manifest = self.setup_items(fps)
        good = json.dumps(self.decided("m-prose", "confirmed", confirmed("m-prose")))
        self.subagent("decider-1", "Here is my entry:\n" + good)
        self.subagent("decider-2", '{"fingerprint": "m-dupkey", "fingerprint": "m-dupkey"}')
        shape = self.decided("m-shape", "confirmed", confirmed("m-shape"))
        shape["extra"] = True
        self.subagent("decider-3", shape)
        self.subagent("decider-4", self.decided("m-unattributed", "confirmed", confirmed("m-unattributed")),
                      write_by_subagent=False)
        self.subagent("decider-5", self.decided("m-fp", "confirmed", confirmed("m-other")))
        self.decide(manifest)
        for fp in fps:
            self.assertEqual(self.record(fp)["verdict"], "needs_validation", fp)
            self.assertEqual(self.unit_for(fp)["wave"], 1, fp)
        reasons = self.discarded()
        self.assertEqual(reasons.count("entry unreadable or not strict JSON"), 2)
        self.assertEqual(reasons.count("entry does not match the poc-decide shape"), 2)
        self.assertIn("entry written by another agent", reasons)
        self.assert_validators_pass()

    def test_two_entries_for_one_fingerprint_keep_neither(self):
        manifest = self.setup_items(["d-1"])
        self.subagent("decider-1", self.decided("d-1", "confirmed", confirmed("d-1")))
        self.subagent("decider-2", self.decided("d-1", "rejected", rejected("d-1")))
        self.decide(manifest)
        self.assertEqual(self.record("d-1")["verdict"], "needs_validation")
        self.assertEqual(self.discarded().count("another entry names the same fingerprint"), 2)

    def test_history_records_the_poc_attempt(self):
        manifest = self.setup_items(["h-1"])
        self.subagent("decider-h", self.decided("h-1", "rejected", rejected("h-1"), a="not_demonstrated",
                                                b="not_demonstrated"))
        self.decide(manifest)
        self.assertEqual(self.load("audit-history.json")["fingerprints"]["h-1"],
                         {"last_poc_run": RUN_ID, "last_cross_checked_run": 0, "poc_tries": 1})


class CountTest(MergeTest):
    def count(self, job, cap, n):
        for i in range(n):
            self.subagent("%s-%d" % (job.replace("_", "-"), i), "{}")
        return self.run_merge("count", "--job", job, "--cap", str(cap), "--trace", self.trace_file())

    def test_cap_exceeded_and_repair_outside_the_source_cap(self):
        self.seed([], [])
        self.count("source", 3, 3)
        self.count("source_repair", 0, 0)
        meta = self.load("trusted-meta.json")
        self.assertEqual(meta["usage"]["source"], {"invocations": 3, "cap": 3})
        self.assertEqual(meta["usage"]["source_repair"], {"invocations": 0, "cap": 0})
        self.assertEqual(meta["run_status"], "complete")
        self.count("source_repair", 0, 1)
        self.count("poc-write", 2, 3)
        meta = self.load("trusted-meta.json")
        self.assertEqual(meta["usage"]["source"]["invocations"], 3)
        self.assertEqual(meta["run_status"], "incomplete")
        self.assertEqual(meta["incomplete_reasons"], ["cap_exceeded:source_repair", "cap_exceeded:poc-write"])

    def test_the_source_agents_own_reason_is_kept(self):
        self.seed([], [], metadata(run_status="incomplete", incomplete_reason="validation_budget_exhausted"))
        self.count("source", 1, 2)
        meta = self.load("trusted-meta.json")
        self.assertEqual(meta["incomplete_reasons"], ["validation_budget_exhausted", "cap_exceeded:source"])

    def test_an_unreadable_trace_fails(self):
        self.seed([], [])
        result = self.run_merge("count", "--job", "source", "--cap", "1", "--trace",
                                os.path.join(self.tmp, "missing.json"), ok=False)
        self.assertEqual(result.returncode, 1)


INTERRUPTION = open(os.path.join(os.path.dirname(SCRIPT), "classifier-interruption.txt"), encoding="utf-8").read().strip()


class InterruptionTest(MergeTest):
    """A subagent the safety classifier stopped is recorded by count, keyed by
    job, agent id and call id, and nothing it left is used: its entry, though
    written by it and on disk, is never merged, and a manifest item naming it
    or a script under its directory is dropped with any decision on it."""

    def result(self, blocks, call=None, parent=None):
        """A tool_result for the last subagent added (or call), as blocks."""
        message = {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": call or "toolu_%d" % self.calls, "content": blocks}]}}
        if parent is not None:
            message["parent_tool_use_id"] = parent
        self.messages.append(message)

    def text(self, value):
        return [{"type": "text", "text": value}]

    def decide_once(self, blocks, subagent_type=None, parent=None):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        self.select()
        manifest = self.manifest(["fp-1"])
        self.subagent("decider-1", self.decided("fp-1", "needs_validation", lead("fp-1"),
                                                a="not_demonstrated", b="not_demonstrated"))
        if subagent_type is not None:
            self.messages[-2]["message"]["content"][0]["input"]["subagent_type"] = subagent_type
        self.result(blocks, parent=parent)
        messages = list(self.messages)
        self.run_merge("count", "--job", "poc-decide", "--cap", "6", "--trace", self.trace_file())
        self.messages = messages
        self.decide(manifest)
        return self.load("trusted-meta.json")

    def assert_merged(self, meta):
        self.assertEqual(meta.get("interrupted"), [])
        self.assertNotIn("subagent interrupted by the safety classifier", self.discarded())
        self.assertEqual(meta["poc"]["decided"], ["fp-1"])

    def test_an_interrupted_subagents_entry_is_not_merged(self):
        meta = self.decide_once(self.text("  " + INTERRUPTION + "\n"))
        self.assertEqual(meta["interrupted"], [{"job": "poc-decide", "agent_id": "decider-1", "tool_use_id": "toolu_1"}])
        self.assertIn("subagent interrupted by the safety classifier", self.discarded())
        self.assertEqual(meta["poc"]["decided"], [])

    def test_a_report_is_merged_and_records_no_interruption(self):
        self.assert_merged(self.decide_once(self.text("Judged both scripts; neither showed the claim.")))

    def test_a_report_quoting_the_interruption_is_not_one(self):
        self.assert_merged(self.decide_once(self.text("Done. A log line read: " + INTERRUPTION)))

    def test_a_report_starting_with_the_sentence_is_not_one(self):
        self.assert_merged(self.decide_once(self.text(INTERRUPTION + " Then I judged both scripts.")))

    def test_the_sentence_in_a_second_block_is_not_one(self):
        self.assert_merged(self.decide_once(self.text("Report.") + self.text(INTERRUPTION)))

    def test_the_sentence_as_a_plain_string_is_not_one(self):
        self.assert_merged(self.decide_once(INTERRUPTION))

    def test_the_sentence_for_an_explore_type_call_is_not_one(self):
        self.assert_merged(self.decide_once(self.text(INTERRUPTION), subagent_type="Explore"))

    def test_the_sentence_in_a_subagents_own_message_is_not_one(self):
        self.assert_merged(self.decide_once(self.text(INTERRUPTION), parent="toolu_9"))

    def test_status_copies_the_interruptions_into_run_metadata(self):
        self.decide_once(self.text(INTERRUPTION))
        self.run_merge("status")
        self.assertEqual(self.load("run-metadata.json")["interrupted"],
                         [{"job": "poc-decide", "agent_id": "decider-1", "tool_use_id": "toolu_1"}])

    def test_a_reused_agent_id_in_a_second_trace_counts_twice(self):
        self.seed([], [])
        for _ in range(2):
            self.subagent("h01", "{}")
            self.result(self.text(INTERRUPTION))
            self.run_merge("count", "--job", "source", "--cap", "60", "--trace", self.trace_file())
        recorded = self.load("trusted-meta.json")["interrupted"]
        self.assertEqual([(r["agent_id"], r["tool_use_id"]) for r in recorded], [("h01", "toolu_1"), ("h01", "toolu_2")])

    def poc_write_count(self, interrupt):
        """count for poc-write, whose writer-0a subagent was or was not
        interrupted."""
        self.subagent("writer-0a", "{}")
        self.result(self.text(INTERRUPTION if interrupt else "Wrote poc.php."))
        self.run_merge("count", "--job", "poc-write", "--cap", "12", "--trace", self.trace_file())

    def test_a_manifest_item_from_an_interrupted_writer_is_dropped(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        self.select()
        self.poc_write_count(interrupt=True)
        manifest = self.manifest(["fp-1"])
        self.subagent("decider-1", self.decided("fp-1", "needs_validation", lead("fp-1"),
                                                a="not_demonstrated", b="not_demonstrated"))
        self.decide(manifest)
        meta = self.load("trusted-meta.json")
        self.assertIn("manifest item from an interrupted subagent", self.discarded())
        self.assertIn("decision on scripts from an interrupted subagent", self.discarded())
        self.assertEqual(meta["poc"]["decided"], [])
        self.assertFalse(os.path.exists(os.path.join(self.out, "agents", "decider-1", "artifacts")))

    def test_a_script_under_an_interrupted_writers_folder_is_dropped_whatever_id_it_names(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        self.select()
        self.poc_write_count(interrupt=True)
        manifest = self.manifest(["fp-1"])
        with open(manifest, encoding="utf-8") as handle:
            data = json.load(handle)
        data["items"][0]["scripts"][0]["agent_id"] = "someone-else"
        self.write(manifest, data)
        self.subagent("decider-1", self.decided("fp-1", "needs_validation", lead("fp-1"),
                                                a="not_demonstrated", b="not_demonstrated"))
        self.decide(manifest)
        self.assertIn("manifest item from an interrupted subagent", self.discarded())
        self.assertEqual(self.load("trusted-meta.json")["poc"]["decided"], [])

    def test_a_manifest_agent_id_that_is_not_a_string_does_not_crash_the_check(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        self.select()
        self.poc_write_count(interrupt=True)
        manifest = self.manifest(["fp-1"])
        with open(manifest, encoding="utf-8") as handle:
            data = json.load(handle)
        data["items"][0]["scripts"][0]["agent_id"] = ["writer-0a"]
        self.write(manifest, data)
        self.subagent("decider-1", self.decided("fp-1", "needs_validation", lead("fp-1"),
                                                a="not_demonstrated", b="not_demonstrated"))
        self.decide(manifest)

    def test_a_manifest_item_from_a_writer_that_finished_is_used(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        self.select()
        self.poc_write_count(interrupt=False)
        manifest = self.manifest(["fp-1"])
        self.subagent("decider-1", self.decided("fp-1", "needs_validation", lead("fp-1"),
                                                a="not_demonstrated", b="not_demonstrated"))
        self.decide(manifest)
        self.assertEqual(self.load("trusted-meta.json")["poc"]["decided"], ["fp-1"])
        self.assertNotIn("manifest item from an interrupted subagent", self.discarded())


class HostileEntryTest(MergeTest):
    """Agent-written input shaped to crash the merge, override a decision or
    skew a count; each case comes from a review probe."""

    def base(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        self.select()
        return self.manifest(["fp-1"])

    def entry_file(self, agent_id):
        return os.path.join(self.out, "agents", agent_id, "scratch", "entry.json")

    def test_an_entry_overwritten_by_the_top_level_agent_is_discarded(self):
        manifest = self.base()
        self.subagent("decider-1", self.decided("fp-1", "needs_validation", lead("fp-1"),
                                                a="not_demonstrated", b="not_demonstrated"))
        forged = json.dumps(self.decided("fp-1", "confirmed", confirmed("fp-1", overall="high", impact="high")))
        self.write(self.entry_file("decider-1"), forged)
        self.messages.append({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "toolu_top", "name": "Write",
             "input": {"file_path": self.entry_file("decider-1"), "content": forged}}]}})
        self.decide(manifest)
        self.assertEqual(self.record("fp-1")["verdict"], "needs_validation")
        self.assertEqual(self.load("trusted-meta.json")["poc"]["confirmed"], [])
        self.assertIn("entry written by another agent", self.discarded())

    def test_an_entry_changed_on_disk_after_its_write_is_discarded(self):
        manifest = self.base()
        self.subagent("decider-1", self.decided("fp-1", "needs_validation", lead("fp-1"),
                                                a="not_demonstrated", b="not_demonstrated"))
        self.write(self.entry_file("decider-1"), self.decided("fp-1", "confirmed", confirmed("fp-1")))
        self.decide(manifest)
        self.assertEqual(self.record("fp-1")["verdict"], "needs_validation")
        self.assertIn("entry on disk differs from the subagent's write", self.discarded())

    def test_an_entry_its_subagent_edited_is_discarded(self):
        manifest = self.base()
        self.subagent("decider-1", self.decided("fp-1", "confirmed", confirmed("fp-1")))
        self.messages.append({"type": "assistant", "parent_tool_use_id": "toolu_%d" % self.calls,
                              "message": {"content": [{"type": "tool_use", "id": "toolu_edit", "name": "Edit",
                                                       "input": {"file_path": self.entry_file("decider-1"),
                                                                 "old_string": "a", "new_string": "a"}}]}})
        self.decide(manifest)
        self.assertEqual(self.record("fp-1")["verdict"], "needs_validation")
        self.assertIn("entry edited after it was written", self.discarded())

    def test_an_agent_id_two_subagents_claim_is_discarded_and_recorded(self):
        manifest = self.base()
        entry = self.decided("fp-1", "confirmed", confirmed("fp-1"))
        self.subagent("decider-1", entry)
        self.subagent("decider-1", entry)
        self.decide(manifest)
        self.assertEqual(self.record("fp-1")["verdict"], "needs_validation")
        self.assertEqual(self.discarded().count("agent id declared by more than one subagent call"), 1)

    def test_the_agent_id_token_is_ascii_and_exact(self):
        for name, description in (("no-break space", "agent-id:\u00a0decider-1 check"),
                                  ("zero-width space", "agent-id:\u200bdecider-1"),
                                  ("format character after", "agent-id: decider-1\ufeff"),
                                  ("no-break space before", "check\u00a0agent-id: decider-1")):
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                manifest = self.base()
                self.subagent("decider-1", self.decided("fp-1", "confirmed", confirmed("fp-1")),
                              description=description)
                self.decide(manifest)
                self.assertEqual(self.record("fp-1")["verdict"], "needs_validation")
                self.assertIn("poc decision discarded", self.record("fp-1")["blockers"])
        self.tearDown()
        self.setUp()
        manifest = self.base()
        self.subagent("decider-1", self.decided("fp-1", "confirmed", confirmed("fp-1")),
                      description="check\tagent-id:\tdecider-1\nmore")
        self.decide(manifest)
        self.assertEqual(self.record("fp-1")["verdict"], "confirmed")

    def test_malformed_decide_entries_are_discarded_not_fatal(self):
        listed = self.decided("fp-1", "needs_validation", lead("fp-1"))
        listed["fingerprint"] = ["fp-1"]
        huge = lead("fp-1")
        huge["trace"][0]["line"] = 10 ** 400
        for name, entry, reason in (
                ("list fingerprint", listed, "entry does not match the poc-decide shape"),
                ("deep nesting", "[" * 200000 + "]" * 200000, "entry unreadable or not strict JSON"),
                ("400-digit integer", self.decided("fp-1", "needs_validation", huge,
                                                   a="not_demonstrated", b="not_demonstrated"),
                 "entry does not match the poc-decide shape")):
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                manifest = self.base()
                self.subagent("decider-1", entry)
                self.decide(manifest)
                self.assertEqual(self.discarded().count(reason), 1)
                self.assertIn("poc decision discarded", self.record("fp-1")["blockers"])

    def test_malformed_cross_check_and_tie_break_entries_are_discarded_not_fatal(self):
        self.seed([confirmed("fp-1")], [unit("u1", fps=["fp-1"], unresolved=[])])
        self.subagent("cc-1", {"decision": "verified", "fingerprint": {"a": 1}})
        self.cross_check()
        self.assertIn("entry does not match the cross-check shape", self.discarded())
        self.tearDown()
        self.setUp()
        self.seed([confirmed("fp-1")], [unit("u1", fps=["fp-1"], unresolved=[])])
        self.subagent("cc-1", {"decision": "replace", "fingerprint": "fp-1", "reason": "Other cause.",
                               "record": confirmed("fp-1", root_cause="Another cause")})
        self.assertEqual(len(self.cross_check()), 1)
        self.subagent("tie-1", {"fingerprint": ["fp-1"], "answer": "original", "reason": "Read it."})
        self.tie_break()
        self.assertIn("entry does not match the tie-break shape", self.discarded())
        self.assertIsNone(self.record("fp-1"))

    def test_agent_written_bookkeeping_in_run_metadata_is_ignored(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])],
                  meta=metadata(usage={"source": {"invocations": -1000, "cap": 999}},
                                poc={"confirmed": ["fp-1"]}, cross_check={"settled": ["fp-1"]},
                                merge_discarded="x", incomplete_reasons=[]))
        for i in range(5):
            self.subagent("h-%d" % i, {})
        self.run_merge("count", "--job", "source", "--cap", "3", "--trace", self.trace_file())
        meta = self.load("trusted-meta.json")
        self.assertEqual(meta["usage"], {"source": {"invocations": 5, "cap": 3}})
        self.assertEqual(meta["incomplete_reasons"], ["cap_exceeded:source"])
        for key in ("poc", "cross_check", "merge_discarded"):
            self.assertNotIn(key, meta)
        self.select()
        self.assertEqual(self.load("trusted-meta.json")["poc"]["confirmed"], [])

    def test_later_subcommands_refuse_a_malformed_usage_entry(self):
        for bad in ({"invocations": "x", "cap": 3}, {"invocations": -1, "cap": 3}, {"invocations": 1}):
            with self.subTest(bad=bad):
                self.seed([], [], trusted={"run_id": RUN_ID, "usage": {"source": bad},
                                           "incomplete_reasons": [], "run_status": "complete"})
                result = self.run_merge("count", "--job", "poc-write", "--cap", "3", "--trace",
                                        self.trace_file(), ok=False)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("Traceback", result.stderr)

    def independence_case(self, slots, contents):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        self.select()
        items = [{"fingerprint": "fp-1", "scripts": [
            {"slot": s, "agent_id": slots[s][0], "mode": "http", "script": slots[s][1], "fixture": None}
            for s in "ab"]}]
        manifest = os.path.join(self.tmp, "m.json")
        self.write(manifest, {"items": items})
        for i, s in enumerate("ab"):
            path = os.path.join(self.scripts, slots[s][1])
            os.makedirs(os.path.dirname(path), exist_ok=True)
            self.write(path, contents[s])
            self.run_record("fp-1", s, 0, sha=hashlib.sha256(contents[s].encode()).hexdigest())
        self.subagent("decider-1", self.decided("fp-1", "confirmed", confirmed("fp-1")))
        self.decide(manifest)
        return self.record("fp-1")

    def test_confirmation_needs_two_independent_scripts(self):
        same = {"a": ("w-a", "agents/w-a/scratch/poc.php"), "b": ("w-a", "agents/w-a/scratch/poc.php")}
        one_agent = {"a": ("w-a", "agents/w-a/scratch/poc.php"), "b": ("w-a", "agents/w-a/scratch/poc2.php")}
        one_path = {"a": ("w-a", "agents/w-a/scratch/poc.php"), "b": ("w-b", "agents/w-a/scratch/poc.php")}
        apart = {"a": ("w-a", "agents/w-a/scratch/poc.php"), "b": ("w-b", "agents/w-b/scratch/poc.php")}
        for name, slots, contents, verdict in (
                ("same script and agent", same, {"a": "<?php 1", "b": "<?php 1"}, "needs_validation"),
                ("same agent id", one_agent, {"a": "<?php 1", "b": "<?php 2"}, "needs_validation"),
                ("same script path", one_path, {"a": "<?php 1", "b": "<?php 1"}, "needs_validation"),
                ("same sha256", apart, {"a": "<?php 1", "b": "<?php 1"}, "needs_validation"),
                ("independent", apart, {"a": "<?php 1", "b": "<?php 2"}, "confirmed")):
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                record = self.independence_case(slots, contents)
                self.assertEqual(record["verdict"], verdict)
                if verdict != "confirmed":
                    self.assertIn("poc scripts not independent", record["blockers"])


class TrustedMetaTest(MergeTest):
    """Bookkeeping an agent writes into run-metadata.json has no effect; only
    trusted-meta.json, which merge-records.py alone writes, is read."""

    def run_metadata(self):
        with open(os.path.join(self.state, "run-metadata.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def rewrite_run_metadata(self, **changes):
        meta = self.run_metadata()
        meta.update(changes)
        for key, value in changes.items():
            if value is None:
                meta.pop(key)
        self.write(os.path.join(self.state, "run-metadata.json"), meta)

    def test_prior_run_paths_come_only_from_the_prior_argument(self):
        planted = os.path.join(self.tmp, "planted", "findings.json")
        os.makedirs(os.path.dirname(planted))
        self.write(planted, [confirmed("a-lead")])
        self.seed([lead("a-lead")], [unit("u1", fps=["a-lead"])], meta=metadata(prior_run_paths=[planted]))
        self.select()
        with open(os.path.join(self.tmp, "select.json"), encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["items"], [{"fingerprint": "a-lead", "kind": "lead"}])
        self.assertEqual(self.load("trusted-meta.json")["prior_run_paths"], [])

    def test_a_repair_step_rewrite_of_reasons_and_usage_has_no_effect(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])])
        for i in range(5):
            self.subagent("h-%d" % i, {})
        self.run_merge("count", "--job", "source", "--cap", "3", "--trace", self.trace_file())
        self.rewrite_run_metadata(incomplete_reasons=[], usage={}, run_status="complete", incomplete_reason=None)
        self.run_merge("count", "--job", "source_repair", "--cap", "0", "--trace", self.trace_file())
        self.run_merge("status")
        trusted = self.load("trusted-meta.json")
        self.assertEqual(trusted["usage"]["source"], {"invocations": 5, "cap": 3})
        self.assertEqual(trusted["incomplete_reasons"], ["cap_exceeded:source", "cross_check_not_run"])
        meta = self.run_metadata()
        self.assertEqual(meta["usage"], trusted["usage"])
        self.assertEqual(meta["run_status"], "incomplete")
        self.assertEqual(meta["incomplete_reason"], "cap_exceeded:source; cross_check_not_run")
        self.assertEqual(meta["source_ref"], "0" * 40)

    def test_an_agent_written_dispute_rate_without_a_cross_check_is_removed(self):
        self.seed([lead("fp-1")], [unit("u1", fps=["fp-1"])],
                  meta=metadata(dispute_rate={"disputes": 0, "cross_checked": 9, "rate": 0.0},
                                cross_check={"settled": ["fp-1"], "tie_breaks": [{"side": "original"}]}))
        self.run_merge("status")
        self.assertNotIn("dispute_rate", self.load("trusted-meta.json"))
        meta = self.run_metadata()
        self.assertNotIn("dispute_rate", meta)
        self.assertNotIn("cross_check", meta)
        self.assertIn("cross_check_not_run", meta["incomplete_reasons"])


class HistoryTest(MergeTest):
    def test_runs_deferred_and_last_covered_run(self):
        deferred, covered = unit("d-1", status="deferred"), unit("v-1", status="covered")
        candidate = unit("k-1", fps=["k-1"])
        history = {"fingerprints": {}, "units": {
            deferred["coverage_id"]: {"last_covered_run": 5, "runs_deferred": 2},
            covered["coverage_id"]: {"last_covered_run": 5, "runs_deferred": 4}}}
        self.seed([lead("k-1")], [deferred, covered, candidate], history=history)
        self.select()
        units = self.load("audit-history.json")["units"]
        self.assertEqual(units[deferred["coverage_id"]], {"last_covered_run": 5, "runs_deferred": 3})
        self.assertEqual(units[covered["coverage_id"]], {"last_covered_run": RUN_ID, "runs_deferred": 0})
        self.assertEqual(units[candidate["coverage_id"]], {"last_covered_run": RUN_ID, "runs_deferred": 0})


class CrossCheckTest(MergeTest):
    def seed_records(self, records, history=None):
        fps = [r["fingerprint"] for r in records]
        self.seed(records, [unit(fp, fps=[fp], unresolved=[]) for fp in fps], history=history)

    def replace(self, agent_id, record, reason="The source differs."):
        self.subagent(agent_id, {"decision": "replace", "fingerprint": record["fingerprint"],
                                 "reason": reason, "record": record})

    def test_material_fields_and_rule_order(self):
        base = confirmed("r-lines")
        lines = confirmed("r-lines")
        lines["trace"][0]["line"] = 11
        lines["description"] = "Reworded description."
        root_case = confirmed("r-root-case", root_cause="  missing   ACCESS check ")
        scope = confirmed("r-scope")
        scope["trace"][0]["scope"] = "DemoController::other"
        root = confirmed("r-root", root_cause="SQL injection in the filter")
        lowered_and_root = confirmed("r-order", overall="low", root_cause="Another cause")
        raised_and_root = confirmed("r-raise", overall="high", impact="high", root_cause="Another cause")
        demoted = lead("r-verdict")
        records = [base, confirmed("r-root-case"), confirmed("r-scope"), confirmed("r-root"),
                   confirmed("r-order"), confirmed("r-raise"), confirmed("r-verdict")]
        self.seed_records(records)
        for i, rec in enumerate([lines, root_case, scope, root, lowered_and_root, raised_and_root, demoted]):
            self.replace("checker-%d" % i, rec)
        disputes = self.cross_check()
        self.assertEqual([(d["fingerprint"], d["rule"]) for d in disputes],
                         [("r-order", "severity_lowered"), ("r-root", "material"),
                          ("r-scope", "material"), ("r-verdict", "verdict")])
        self.assertEqual(self.record("r-lines")["trace"][0]["line"], 11)
        self.assertEqual(self.record("r-lines")["description"], "Reworded description.")
        self.assertEqual(self.record("r-root-case")["root_cause"], "  missing   ACCESS check ")
        cc = self.load("trusted-meta.json")["cross_check"]
        self.assertEqual(cc["refused"], [{"fingerprint": "r-raise", "rule": "severity_raise"}])
        self.assertEqual(self.record("r-raise")["severity"]["overall_severity"], "medium")

    def test_refusals_and_an_allowed_demotion_that_removes_execution(self):
        promoted = confirmed("s-promote")
        raised = confirmed("s-raise", overall="high", impact="high")
        execution = confirmed("s-exec", observed="HTTP 403.")
        demoted = lead("s-demote")
        self.seed_records([lead("s-promote"), confirmed("s-raise"), confirmed("s-exec"), confirmed("s-demote")])
        for i, rec in enumerate([promoted, raised, execution, demoted]):
            self.replace("checker-%d" % i, rec)
        disputes = self.cross_check()
        self.assertEqual([d["fingerprint"] for d in disputes], ["s-demote"])
        cc = self.load("trusted-meta.json")["cross_check"]
        self.assertEqual(sorted((r["fingerprint"], r["rule"]) for r in cc["refused"]),
                         [("s-exec", "execution"), ("s-promote", "promotion"), ("s-raise", "severity_raise")])
        self.assertEqual(self.record("s-promote")["verdict"], "needs_validation")
        self.assertEqual(self.record("s-raise")["severity"]["overall_severity"], "medium")
        self.assertEqual(self.record("s-exec")["execution"]["observed_result"], "HTTP 200 with another user's row.")
        self.subagent("tie-1", {"fingerprint": "s-demote", "answer": "replacement", "reason": "The check exists."})
        self.tie_break()
        record = self.record("s-demote")
        self.assertEqual(record["verdict"], "needs_validation")
        self.assertNotIn("execution", record)
        self.assertEqual(self.load("trusted-meta.json")["cross_check"]["tie_breaks"],
                         [{"fingerprint": "s-demote", "side": "replacement"}])
        self.run_merge("status")
        self.assert_validators_pass()

    def test_a_lowered_severity_cannot_carry_a_changed_execution(self):
        self.seed_records([confirmed("e-1", overall="high", impact="high")])
        smuggled = confirmed("e-1", overall="medium", impact="high", observed="FABRICATED result.",
                             payloads=["GET /evil"])
        self.replace("checker-1", smuggled)
        self.assertEqual(self.cross_check(), [])
        self.subagent("tie-1", {"fingerprint": "e-1", "answer": "replacement", "reason": "Agree."})
        self.tie_break()
        record = self.record("e-1")
        self.assertEqual(record["execution"]["observed_result"], "HTTP 200 with another user's row.")
        self.assertEqual(record["execution"]["payloads"], ["GET /demo/1"])
        self.assertEqual(record["severity"]["overall_severity"], "high")
        cc = self.load("trusted-meta.json")["cross_check"]
        self.assertEqual(cc["refused"], [{"fingerprint": "e-1", "rule": "execution"}])
        self.assertEqual(cc["settled"], ["e-1"])

    def test_tie_break_outcomes_order_and_limit_of_three(self):
        fps = ["t-1", "t-2", "t-3", "t-4"]
        self.seed_records([confirmed(fp) for fp in fps])
        for i, fp in enumerate(reversed(fps)):
            self.replace("checker-%d" % i, confirmed(fp, root_cause="A different cause " + fp))
        disputes = self.cross_check()
        self.assertEqual([d["fingerprint"] for d in disputes], fps)
        replacement = {"t-1": "original", "t-2": "replacement", "t-3": "neither", "t-4": "original"}
        for i, fp in enumerate(fps):
            self.subagent("tie-%d" % i, {"fingerprint": fp, "answer": replacement[fp], "reason": "Read the source."})
        self.tie_break()
        self.assertEqual(self.record("t-1")["root_cause"], "Missing access check")
        self.assertEqual(self.record("t-2")["root_cause"], "A different cause t-2")
        self.assertIsNone(self.record("t-3"))
        self.assertIsNone(self.record("t-4"))
        disputed = self.load("disputed.json")
        self.assertEqual([(d["fingerprint"], d["removed_because"]) for d in disputed],
                         [("t-3", "neither"), ("t-4", "tie_break_cap")])
        self.assertIn("cross-check dispute unresolved", self.unit_for("t-4")["unresolved"])
        meta = self.load("trusted-meta.json")
        self.assertEqual([t["side"] for t in meta["cross_check"]["tie_breaks"]], ["original", "replacement", "neither"])
        self.assertIn("cross_check_dispute", meta["incomplete_reasons"])
        self.run_merge("status")
        meta = self.load("trusted-meta.json")
        self.assertEqual(meta["dispute_rate"], {"disputes": 4, "cross_checked": 4, "rate": 1.0})
        self.assertEqual(meta["run_status"], "incomplete")
        self.assert_validators_pass()

    def tie_break_with_inputs(self, edit, rehash):
        """Runs a dispute to the tie-break after edit() changes the inputs file;
        with rehash, trusted-meta.json is made to carry the edited file's hash,
        so the shape checks are reached."""
        self.seed_records([confirmed("i-1")])
        self.replace("checker-1", confirmed("i-1", root_cause="Another cause"))
        self.assertEqual(len(self.cross_check()), 1)
        inputs = os.path.join(self.tmp, "tie-break-inputs.json")
        with open(inputs, encoding="utf-8") as handle:
            data = json.load(handle)
        edit(data)
        self.write(inputs, data)
        if rehash:
            trusted = self.load("trusted-meta.json")
            with open(inputs, "rb") as handle:
                trusted["cross_check"]["inputs_sha256"] = hashlib.sha256(handle.read()).hexdigest()
            self.write(os.path.join(self.state, "trusted-meta.json"), trusted)
        self.subagent("tie-1", {"fingerprint": "i-1", "answer": "replacement", "reason": "Agree."})
        result = self.run_merge("apply-tie-break", "--inputs", inputs, "--entries", self.out,
                                "--trace", self.trace_file(), ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.record("i-1")["root_cause"], "Missing access check")
        return result.stderr

    def test_tie_break_inputs_changed_after_the_cross_check_are_refused(self):
        def fabricate(data):
            data["disputes"][0]["replacement"]["execution"]["observed_result"] = "FABRICATED."
        self.assertIn("not the ones apply-cross-check wrote", self.tie_break_with_inputs(fabricate, False))

    def test_malformed_tie_break_inputs_are_refused(self):
        def other_fingerprint(data):
            data["disputes"][0]["replacement"]["fingerprint"] = "i-2"
        def not_a_dict(data):
            data["disputes"] = ["i-1"]
        for name, edit in (("replacement fingerprint", other_fingerprint), ("non-dict dispute", not_a_dict)):
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                self.assertIn("the tie-break inputs are malformed", self.tie_break_with_inputs(edit, True))

    def test_cap_of_thirty_overflow(self):
        fps = ["o-%02d" % i for i in range(32)]
        history = {"fingerprints": {"o-00": {"last_poc_run": 0, "last_cross_checked_run": 50, "poc_tries": 0},
                                    "o-01": {"last_poc_run": 0, "last_cross_checked_run": 40, "poc_tries": 0}},
                   "units": {}}
        self.seed_records([lead(fp) for fp in fps], history)
        for i, fp in enumerate(fps):
            self.subagent("checker-%d" % i, {"decision": "verified", "fingerprint": fp})
        self.cross_check()
        cc = self.load("trusted-meta.json")["cross_check"]
        self.assertEqual(cc["selected"], fps[2:])
        self.assertEqual(cc["not_cross_checked"], ["o-01", "o-00"])
        self.assertEqual(len(cc["settled"]), 30)
        meta = self.load("trusted-meta.json")
        self.assertIn("cross_check_cap", meta["incomplete_reasons"])
        self.assertEqual(self.load("audit-history.json")["fingerprints"]["o-05"]["last_cross_checked_run"], RUN_ID)
        self.assertEqual(self.load("audit-history.json")["fingerprints"]["o-00"]["last_cross_checked_run"], 50)

    def test_a_missing_or_malformed_cross_check_entry_leaves_the_record_unchecked(self):
        self.seed_records([confirmed("u-1"), lead("u-2")])
        self.subagent("checker-1", {"decision": "verified", "fingerprint": "u-1", "note": "extra"})
        self.cross_check()
        self.run_merge("status")
        meta = self.load("trusted-meta.json")
        self.assertEqual(meta["cross_check"]["settled"], [])
        self.assertEqual(meta["cross_check"]["not_cross_checked"], ["u-1", "u-2"])
        self.assertIn("cross_check_missing", meta["incomplete_reasons"])
        self.assertIn("entry does not match the cross-check shape", self.discarded())

    def test_status_complete_only_when_nothing_is_open(self):
        self.seed_records([confirmed("w-1")])
        self.subagent("checker-1", {"decision": "verified", "fingerprint": "w-1"})
        self.cross_check()
        self.run_merge("status")
        meta = self.load("trusted-meta.json")
        self.assertEqual(meta["run_status"], "complete")
        self.assertNotIn("incomplete_reason", meta)
        self.assertEqual(meta["dispute_rate"], {"disputes": 0, "cross_checked": 1, "rate": 0.0})


class PipelineTest(MergeTest):
    def test_validators_pass_on_the_merged_fixtures(self):
        fps = ["z-confirm", "z-lead", "z-reject"]
        findings = [lead(fp) for fp in fps] + [rejected("z-old"), lead("z-unselected", local=False)]
        ledger = [unit(fp, fps=[fp]) for fp in fps] + [unit("z-old", fps=["z-old"], unresolved=[]),
                                                       unit("z-unselected", fps=["z-unselected"]),
                                                       unit("z-deferred", status="deferred"),
                                                       unit("z-covered", status="covered")]
        self.seed(findings, ledger)
        self.select()
        manifest = self.manifest(fps)
        self.subagent("decider-1", self.decided("z-confirm", "confirmed", confirmed("z-confirm")))
        self.subagent("decider-2", self.decided("z-lead", "needs_validation", lead("z-lead"), b="not_demonstrated"))
        self.subagent("decider-3", self.decided("z-reject", "rejected", rejected("z-reject"),
                                                a="not_demonstrated", b="not_demonstrated"))
        self.decide(manifest)
        self.assert_validators_pass()
        self.subagent("checker-1", {"decision": "verified", "fingerprint": "z-confirm"})
        self.replace_lead()
        self.cross_check()
        self.subagent("tie-1", {"fingerprint": "z-lead", "answer": "neither", "reason": "Both are wrong."})
        self.tie_break()
        self.run_merge("status")
        self.assert_validators_pass()
        self.assertIsNone(self.record("z-lead"))
        self.assertEqual(self.record("z-confirm")["verdict"], "confirmed")

    def replace_lead(self):
        changed = lead("z-lead")
        changed["claimed_root_cause"] = "A different cause"
        self.subagent("checker-2", {"decision": "replace", "fingerprint": "z-lead", "reason": "Wrong cause.",
                                    "record": changed})


if __name__ == "__main__":
    unittest.main()
