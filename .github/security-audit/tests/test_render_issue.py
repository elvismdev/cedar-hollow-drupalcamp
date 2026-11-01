# Tests for render-issue.py. Each test writes a small synthetic final state,
# runs the renderer through subprocess with python3 -I, and reads the body it
# wrote. The record fixtures are shared with test_merge_records.py.
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_merge_records import SA, confirmed, lead, metadata, rejected, unit

SCRIPT = os.path.join(SA, "render-issue.py")
SHA = "b" * 64
SCREEN_FAILED = "Output failed or could not run the secret screen"
OK_JOBS = {"publish": True, "canary": "none", "source": {"result": "success", "cause": "ok"},
           "cross_check": {"result": "success", "cause": "ok", "validators": "pass"}}


def final_meta(confirmed_fps=(), settled=(), **extra):
    meta = metadata(
        scope_paths=["web/modules/custom", "config/"],
        usage={"source": {"invocations": 12, "cap": 60}, "tie-break": {"invocations": 1, "cap": 3}},
        poc={"selected": list(confirmed_fps), "not_tried": [], "not_rechecked": [], "confirmed": list(confirmed_fps)},
        cross_check={"selected": list(settled), "not_cross_checked": [], "settled": list(settled), "refused": [],
                     "disputes": 1, "cross_checked": 4, "tie_breaks": [{"fingerprint": "q", "side": "original"}],
                     "removed": 0, "applied": True, "pending": []},
        dispute_rate={"disputes": 1, "cross_checked": 4, "rate": 0.25},
        incomplete_reasons=[],
    )
    meta.update(extra)
    return meta


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write(self, path, value):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(value if isinstance(value, str) else json.dumps(value))

    def seed(self, findings, meta, ledger=(), disputed=(), history=None):
        self.write(os.path.join(self.state, "findings.json"), sorted(findings, key=lambda r: r["fingerprint"]))
        self.write(os.path.join(self.state, "run-metadata.json"), meta)
        self.write(os.path.join(self.state, "coverage-ledger.json"), list(ledger))
        self.write(os.path.join(self.state, "disputed.json"), list(disputed))
        self.write(os.path.join(self.state, "audit-history.json"), history or {"fingerprints": {}, "units": {}})

    def artifacts(self, fp, decider, stdout="HTTP 200\n"):
        u = unit(fp, fps=[fp], unresolved=[])
        u["agent_id"] = decider
        u["local_checks"] = []
        for slot in "ab":
            path = "agents/%s/artifacts/%s.json" % (decider, slot)
            self.write(os.path.join(self.state, path), {
                "fingerprint": fp, "slot": slot, "mode": "http", "script_sha256": "a" * 64, "limits": {},
                "exit_code": 0, "stdout": stdout, "stderr": "", "timed_out": False})
            u["local_checks"].append({"agent_id": decider, "reviewed_paths": u["reviewed_paths"],
                                      "invariant": "Only the owner can read a row.", "method": "local",
                                      "result": "script %s: demonstrated" % slot, "artifact": path})
        return u

    def render(self, jobs=None, marker=None, state=True, extra=()):
        jobs_path = os.path.join(self.tmp, "jobs.json")
        self.write(jobs_path, jobs if jobs is not None else OK_JOBS)
        marker_path = os.path.join(self.tmp, "marker.json")
        self.write(marker_path, marker if marker is not None else "")
        out = os.path.join(self.tmp, "body.md")
        args = [sys.executable, "-I", SCRIPT, "--state-sha256", SHA, "--run-id", "9001", "--jobs", jobs_path,
                "--previous-marker", marker_path, "--out", out] + list(extra)
        if state:
            args += ["--state", self.state]
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(out, encoding="utf-8") as handle:
            return handle.read()

    def marker(self, body):
        found = re.findall(r"<!-- security-audit-state (\{.*\}) -->", body)
        self.assertEqual(len(found), 1)
        return json.loads(found[0])

    def line(self, body, prefix):
        return next(l for l in body.splitlines() if l.startswith(prefix))


class ContentTest(RenderTest):
    def test_rejected_and_disputed_records_are_counts_only(self):
        hidden = rejected("rej-hidden-fp")
        hidden["title"] = "REJECTED TITLE TEXT"
        disputed = {"fingerprint": "dis-hidden-fp", "record": dict(confirmed("dis-hidden-fp"), title="DISPUTED TITLE"),
                    "replacement": None, "cross_check_reason": "DISPUTE REASON", "tie_break": None,
                    "removed_because": "tie_break_cap"}
        self.seed([hidden, confirmed("c-1")], final_meta(["c-1"], ["c-1"]), disputed=[disputed])
        body = self.render()
        for text in ("rej-hidden-fp", "REJECTED TITLE TEXT", "dis-hidden-fp", "DISPUTED TITLE", "DISPUTE REASON",
                     "The route requires a permission."):
            self.assertNotIn(text, body)
        self.assertIn("rejected 1, disputed 1", body)

    def test_leads_have_no_severity(self):
        odd = lead("l-1", title="Lead one")
        odd["severity"] = {"overall_severity": "critical"}
        self.seed([odd], final_meta([], ["l-1"]))
        body = self.render()
        row = self.line(body, "| `l-1`")
        self.assertNotIn("critical", body)
        for word in ("informational", "low", "medium", "high"):
            self.assertNotIn(word, row.lower())
        self.assertIn("Leads carry no severity.", body)

    def test_mentions_and_links_are_stripped_and_comments_escaped(self):
        record = confirmed("c-1", observed="Ping @octocat at https://evil.example/x and HTTP://evil.example/y")
        record["title"] = "Title <!-- hidden --> @someone"
        record["execution"]["payloads"] = ["GET /x <!-- @ops http://evil.example/z"]
        ledger = [self.artifacts("c-1", "decider-1", stdout="<!-- out --> @admin https://evil.example/o\n")]
        self.seed([record], final_meta(["c-1"], ["c-1"]), ledger=ledger)
        body = self.render()
        self.assertNotRegex(body, r"(?<![A-Za-z0-9_])@[A-Za-z0-9_-]")
        self.assertNotRegex(body.lower(), r"https?://")
        self.assertEqual(body.count("<!--"), 1)
        self.assertTrue(body.rstrip().endswith("-->"))
        self.assertIn("octocat", body)
        self.assertIn("Script a (http mode): exit code 0", body)

    def test_scope_excluded_paths_and_owner_statement(self):
        self.seed([], final_meta())
        body = self.render()
        self.assertIn("*   Scope: `web/modules/custom`, `config/`", body)
        self.assertIn(".github/security-audit/", self.line(body, "*   Excluded:"))
        self.assertIn("published here by the repository owner's choice", body)
        self.assertIn("*   Source commit: `%s`" % ("0" * 40), body)
        self.assertIn("*   Profile: standard", body)

    def test_per_job_usage_against_cap(self):
        self.seed([], final_meta())
        body = self.render()
        self.assertIn("*   Subagent invocations against cap: source 12 of 60; tie-break 1 of 3", body)
        self.assertIn("*   Dispute rate: 1 of 4 records cross-checked (25%)", body)
        self.assertIn("*   Tie-breaks: original 1, replacement 0, neither 0", body)

    def test_only_settled_and_poc_confirmed_records_are_published(self):
        records = [confirmed("c-ok"), confirmed("c-no-poc"), confirmed("c-unsettled"), lead("l-ok"), lead("l-unsettled")]
        meta = final_meta(["c-ok", "c-unsettled"], ["c-ok", "c-no-poc", "l-ok"])
        meta["cross_check"]["not_cross_checked"] = ["c-unsettled", "l-unsettled"]
        self.seed(records, meta)
        body = self.render()
        tables = body.split("## Changes since the last run")[0]
        self.assertIn("`c-ok`", tables)
        self.assertIn("`l-ok`", tables)
        for fp in ("c-no-poc", "c-unsettled", "l-unsettled"):
            self.assertNotIn(fp, tables)
        self.assertIn("confirmed 1, leads 1, rejected 0, disputed 0, not cross-checked 2, unvalidated 0, "
                      "confirmed not re-checked this run 1", body)


class HeaderTest(RenderTest):
    def jobs(self, **changes):
        jobs = json.loads(json.dumps(OK_JOBS))
        for key, value in changes.items():
            jobs[key] = value
        return jobs

    def first_lines(self, body):
        return [l for l in body.splitlines() if l.startswith("**")][:2]

    def test_each_header_form_in_the_tables_order(self):
        self.seed([confirmed("c-1")], final_meta(["c-1"], ["c-1"]))
        cases = [
            (self.jobs(publish=False), ["**Not published: the run was dispatched with publish false.**",
                                        "**Status: complete.**"]),
            (self.jobs(canary="denied-read", publish=False), ["**Not published: canary run denied-read.**",
                                                               "**Status: complete.**"]),
            (self.jobs(), ["**Status: complete.**"]),
            (self.jobs(cross_check={"result": "failure", "cause": "time_limit", "validators": "fail"}),
             ["**Incomplete: cross-check time_limit.**"]),
            (self.jobs(cross_check={"result": "success", "cause": "ok", "validators": "fail"}),
             ["**Incomplete: cross-check validators_failed.**"]),
            (self.jobs(source={"result": "failure", "cause": "max_turns"},
                       cross_check={"result": "skipped", "cause": "no_agent_ran"}),
             ["**Incomplete: source max_turns.**"]),
        ]
        for jobs, expected in cases:
            body = self.render(jobs)
            lines = self.first_lines(body)
            self.assertEqual([l.split(" This body")[0] for l in lines[:len(expected)]], expected, jobs)
            if not expected[-1].startswith("**Status"):
                self.assertNotIn("## Confirmed", body)
                self.assertNotIn("## Leads", body)
                self.assertIn("*   Counts: confirmed 1,", body)

    def test_incomplete_status_names_the_reasons(self):
        meta = final_meta(["c-1"], ["c-1"], run_status="incomplete",
                          incomplete_reasons=["cap_exceeded:poc-write", "cross_check_dispute"])
        self.seed([confirmed("c-1")], meta)
        body = self.render()
        self.assertIn("**Status: incomplete (cap_exceeded:poc-write; cross_check_dispute).**", body)

    def test_a_failed_source_with_no_state_has_no_counts_and_no_marker(self):
        jobs = self.jobs(source={"result": "failure", "cause": "usage_limit"})
        body = self.render(jobs, marker={"run_id": "1", "sha256": SHA, "fingerprints": ["old-1"]}, state=False)
        self.assertIn("**Incomplete: source usage_limit.**", body)
        self.assertIn("*   Counts: none (no state from this run)", body)
        self.assertNotIn("<!--", body)

    def test_the_screen_failure_header_has_no_state_marker(self):
        out = os.path.join(self.tmp, "screen.md")
        result = subprocess.run([sys.executable, "-I", SCRIPT, "--screen-failed", "--out", out],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(out, encoding="utf-8") as handle:
            body = handle.read()
        self.assertEqual(body, SCREEN_FAILED + "\n")
        self.assertNotIn("security-audit-state", body)


class ChangesTest(RenderTest):
    def test_the_four_change_states_and_runs_waited(self):
        deferred = unit("waiting", status="deferred")
        history = {"fingerprints": {}, "units": {deferred["coverage_id"]: {"last_covered_run": 0, "runs_deferred": 3}}}
        records = [confirmed("k-new"), lead("k-still"), lead("k-unchecked"), rejected("k-gone")]
        meta = final_meta(["k-new"], ["k-new", "k-still"])
        meta["cross_check"]["not_cross_checked"] = ["k-unchecked"]
        self.seed(records, meta, ledger=[deferred], history=history)
        prior = {"run_id": "8000", "sha256": SHA, "fingerprints": ["k-still", "k-unchecked", "k-gone", "k-vanished"]}
        body = self.render(marker=prior)
        self.assertIn("*   New: `k-new` Finding k-new", body)
        self.assertIn("*   Still open: `k-still` Lead k-still", body)
        self.assertIn("*   Not re-checked this run: `k-unchecked`", body)
        self.assertIn("*   No longer found: `k-gone`, `k-vanished`", body)
        self.assertIn("*   Demo waiting, Anonymous to owner, Access control: 3 run(s)", body)
        self.assertIn("not cross-checked 1", body)
        self.assertEqual(self.marker(body), {"run_id": "9001", "sha256": SHA,
                                             "fingerprints": ["k-new", "k-still", "k-unchecked"]})

    def test_missing_state_falls_back_to_the_previous_markers_fingerprints(self):
        prior = {"run_id": "8000", "sha256": SHA, "fingerprints": ["m-2", "m-1", "not valid!"]}
        body = self.render(marker=prior, state=False)
        self.assertIn("*   Not re-checked this run: `m-1`, `m-2`", body)
        self.assertIn("*   No longer found: none", body)
        self.assertNotIn("not valid!", body)


class HostileTextTest(RenderTest):
    """Text shaped to slip a live mention or link past the cleaner, from the
    review probe."""

    EVIL = ("A @\u200bowner B http\u200b://evil.example/x C _https://evil.example/y_ D www.evil.example "
            "E [click](//evil.example) F <\u200b!-- G user@evil.example H \uff20fullwidth "
            "I ![img](/evil.png) J [ref][r] K [r]: /evil-ref L //evil.example/z M a@\u2060b")

    def test_hidden_mentions_and_links_are_removed(self):
        record = lead("fp-1", title=self.EVIL)
        record["description"] = self.EVIL
        self.seed([record], final_meta(settled=["fp-1"]))
        body = self.render()
        published = body.split("<!-- security-audit-state")[0]
        self.assertNotRegex(published, r"@[A-Za-z0-9_-]")
        self.assertNotIn("evil", published)
        self.assertNotRegex(published.lower(), r"https?:|www\.|//[^\s/]|\]\(|\]:")
        self.assertNotIn("<!--", published)
        self.assertIn("A owner B [link removed]", published)
        self.assertIn("fullwidth", published)


class SizeTest(RenderTest):
    def test_the_issue_size_cut_keeps_header_tables_and_marker(self):
        records, ledger = [], []
        for i in range(40):
            fp = "big-%02d" % i
            records.append(confirmed(fp))
            ledger.append(self.artifacts(fp, "decider-%02d" % i, stdout="x" * 3000))
        self.seed(records, final_meta([r["fingerprint"] for r in records], [r["fingerprint"] for r in records]),
                  ledger=ledger)
        body = self.render()
        self.assertLessEqual(len(body.encode("utf-8")), 60000)
        self.assertIn("issue_size", self.line(body, "**Status:"))
        match = re.search(r"(\d+) finding section\(s\) left out because the issue would exceed 60,000 bytes",
                          body)
        self.assertIsNotNone(match)
        kept = body.count("\n### ")
        self.assertEqual(kept + int(match.group(1)), 40)
        self.assertGreater(kept, 0)
        self.assertEqual(body.count("| `big-"), 40)
        self.assertEqual(len(self.marker(body)["fingerprints"]), 40)


class EntityTest(RenderTest):
    """Character references GitHub decodes before it finds mentions, addresses
    and links, from the re-review probe."""

    CASES = ["&#64;octocat", "&#x40;octocat", "&commat;octocat", "user&#64;example.com", "&amp;#64;octocat",
             "https&#58;//x", "www&#46;x", "&amp;amp;#x40;deep"]

    def test_entity_encoded_mentions_and_links_are_removed(self):
        text = " ".join("X %s Y" % case for case in self.CASES)
        record = lead("fp-1", title=text)
        record["description"] = text
        self.seed([record], final_meta(settled=["fp-1"]))
        body = self.render()
        published = body.split("<!-- security-audit-state")[0]
        self.assertNotRegex(published, r"@[A-Za-z0-9_]")
        self.assertNotIn("://", published)
        self.assertNotIn("www.", published.lower())
        self.assertNotRegex(published, r"&(?!amp;|lt;|gt;)")
        self.assertIn("X octocat Y", published)


class ReferenceTest(RenderTest):
    def test_cross_repository_references_are_removed_and_plain_numbers_kept(self):
        text = "A owner/repo#12 B owner/repo!7 C owner/repo@0123abc D GH-42 E gh-43 F see #12"
        record = lead("fp-1", title=text)
        self.seed([record], final_meta(settled=["fp-1"]))
        row = self.line(self.render(), "| `fp-1`")
        for ref in ("owner/repo", "GH-42", "gh-43", "0123abc"):
            self.assertNotIn(ref, row)
        self.assertIn("A [reference removed] B [reference removed] C [reference removed] D [reference removed] "
                      "E [reference removed] F see #12", row)


class BoundTest(RenderTest):
    def test_the_body_never_exceeds_the_limit(self):
        units = [unit("d%04d" % i, status="deferred") for i in range(2000)]
        for u in units:
            u["surface"] = "S" * 50
        prior = {"run_id": "8000", "sha256": SHA, "fingerprints": ["gone-%04d" % i for i in range(2000)]}
        self.seed([], final_meta(), ledger=units)
        body = self.render(marker=prior)
        self.assertLessEqual(len(body.encode("utf-8")), 60000)
        self.assertIn("issue_size", self.line(body, "**Status:"))
        match = re.search(r"(\d+) line\(s\) of the changes section left out because the issue would exceed "
                          r"60,000 bytes", body)
        self.assertIsNotNone(match)
        self.assertGreater(int(match.group(1)), 0)
        self.assertTrue(body.rstrip().endswith("-->"))

    def test_the_bound_counts_utf8_bytes(self):
        records = [lead("l-%04d" % i, title="\U0001F600" * 400) for i in range(400)]
        self.seed(records, final_meta(settled=[r["fingerprint"] for r in records]))
        body = self.render()
        self.assertLessEqual(len(body.encode("utf-8")), 60000)
        self.assertIn("issue_size", self.line(body, "**Status:"))
        self.assertIn("table row(s) left out because the issue would exceed 60,000 bytes", body)

    def test_a_check_must_name_the_artifacts_agent(self):
        u = self.artifacts("c-1", "decider-1")
        for check in u["local_checks"]:
            check["agent_id"] = "decider-2"
        self.seed([confirmed("c-1")], final_meta(["c-1"], ["c-1"]), ledger=[u])
        body = self.render()
        self.assertIn("Script a: run record not available.", body)
        self.assertIn("Script b: run record not available.", body)


if __name__ == "__main__":
    unittest.main()
