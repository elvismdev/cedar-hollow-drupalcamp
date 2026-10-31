// Score the reviewer against a repository's own record: incidents it must
// catch, and changes known to be clean that it must leave alone.
//
// Every case replays one commit's own diff, in a worktree at that commit, so
// the stimulus and the tree are what a reviewer faced at the time. The prompt,
// the tool set, the extractor and the verification vote are this repository's
// own scripts, the ones the review action runs, because an eval that assembles
// its own prompt or grants its own tools measures something the pipeline does
// not run.
//
// Two kinds of case, in one directory of *.json files:
//   incident  "control": "review", with "introduced" (the commit that brought
//             the defect in), "angle", "expect_file" and "expect_any" (phrases
//             any one of which names the defect). Passes when the reviewer
//             reports it as important against that file.
//   clean     "kind": "clean", with "commit", "angle" and "why" (the evidence
//             that it was fine). Passes when the reviewer reports nothing
//             important: a false important finding is what leads an author,
//             above all an agent author, to make a harmful change.
// Any other case in the directory belongs to a deterministic control and is
// skipped here.
//
// Exit 0 when every case passed, 1 when one failed, 2 when a case could not be
// run at all. A case that did not run is never counted as passing.
//
// With --baseline, the eval judges a change to the reviewer the way it should
// be judged, against the reviewer it replaces: exit 1 only when a case the
// baseline records as passing now fails. A miss that was already a miss is
// reported and does not fail, because a check that stays red until the
// reviewer is perfect blocks every change and so measures nothing. Compared
// case by case rather than by totals, which hide one incident newly caught
// while another is newly missed. A case that newly passes, and a case with no
// baseline entry, are reported so the baseline can be brought up to date.
//
// Usage: review-eval.mjs <cases-dir> [--base <ref>] [--only <name>] [--no-verify]
//                        [--out <results.json>] [--baseline <baseline.json>]
//   baseline  {"cases": {"<case name>": "pass" | "fail"}}, the last measured result
//   Run from the root of the repository whose history the cases name. The
//   reviewer is the `claude` CLI on PATH, authenticated the usual way.
import { readFileSync, writeFileSync, readdirSync, mkdtempSync, appendFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const TOOLS = join(dirname(fileURLToPath(import.meta.url)), '..');
const VERIFIERS = 3;

export function caseKind(c) {
  if (c?.control === 'review') return 'incident';
  if (c?.kind === 'clean') return 'clean';
  return null;
}

export function validate(c, kind) {
  const need = kind === 'incident'
    ? ['name', 'introduced', 'angle', 'expect_file', 'expect_any']
    : ['name', 'commit', 'angle', 'why'];
  for (const field of need) {
    if (!c[field]) return `has no ${field}`;
  }
  if (kind === 'incident' && (!Array.isArray(c.expect_any) || c.expect_any.length === 0)) {
    return 'has an empty expect_any';
  }
  return null;
}

/** An incident passes when one important finding against its file names it. */
export function scoreIncident(c, findings) {
  const inFile = findings.filter((f) => String(f?.file || '') === c.expect_file);
  if (inFile.length === 0) {
    return { ok: false, why: `no finding against ${c.expect_file}; ${findings.length} finding(s) elsewhere` };
  }
  const hit = inFile.find((f) => {
    const text = `${f?.title || ''} ${f?.detail || ''} ${f?.class || ''}`.toLowerCase();
    return c.expect_any.some((p) => text.includes(String(p).toLowerCase()));
  });
  if (!hit) {
    return { ok: false, why: `${inFile.length} finding(s) against ${c.expect_file}, none naming the incident` };
  }
  const severity = String(hit.severity || '').toLowerCase();
  if (severity !== 'important') {
    return { ok: false, why: `reported as "${severity || 'untagged'}", which does not block a merge` };
  }
  return { ok: true, why: `reported as important: ${String(hit.title || '').slice(0, 100)}` };
}

/** A clean case passes when nothing important was reported against it. */
export function scoreClean(findings) {
  const important = findings.filter((f) => String(f?.severity || '').toLowerCase() === 'important');
  if (important.length > 0) {
    return { ok: false, why: `${important.length} important finding(s) on a clean change: ${String(important[0].title || '').slice(0, 100)}` };
  }
  return { ok: true, why: `nothing important (${findings.length} other finding(s))` };
}

/** The review's own arguments, split for argv. They carry no quoted values. */
export function reviewArgs(line) {
  const value = String(line || '').replace(/^AGENT_ARGS_REVIEW=/, '').trim();
  if (!value || /["'\\]/.test(value)) throw new Error(`unusable reviewer arguments: ${value}`);
  return value.split(/\s+/);
}

/** Each case against its last measured result. Only a pass turning into a fail regresses. */
export function compareToBaseline(results, baseline) {
  const lines = [];
  let regressed = false;
  for (const r of results) {
    const was = baseline[r.name];
    if (was === undefined) lines.push(`  new       ${r.name}: ${r.status}, not in the baseline yet; add it`);
    else if (was === 'pass' && r.status === 'fail') { regressed = true; lines.push(`  REGRESSED ${r.name}: passed in the baseline, fails now`); }
    else if (was === 'fail' && r.status === 'pass') lines.push(`  improved  ${r.name}: failed in the baseline, passes now; update the baseline`);
    else if (r.status === 'fail') lines.push(`  known     ${r.name}: still fails, as in the baseline`);
  }
  for (const name of Object.keys(baseline)) {
    if (!results.some((r) => r.name === name)) lines.push(`  missing   ${name}: in the baseline but no case ran`);
  }
  lines.unshift(regressed
    ? 'review-eval: REGRESSION against the baseline, so this change makes the reviewer worse'
    : 'review-eval: no regression against the baseline');
  return { regressed, lines };
}

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', ...opts });
}

function resolveBase(repo, given) {
  const tried = given ? [given] : [];
  if (!given) {
    const head = sh('git', ['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD'], { cwd: repo }).stdout.trim();
    if (head) tried.push(head.replace('refs/remotes/', ''));
    tried.push('origin/main', 'origin/master', 'main', 'master');
  }
  for (const ref of tried) {
    if (sh('git', ['cat-file', '-e', `${ref}:REVIEW.md`], { cwd: repo }).status === 0) return ref;
  }
  return null;
}

/** One agent run, prompt on stdin, the stream converted to the array the extractor reads. */
function runAgent(promptFile, cwd, args, work, label) {
  const stream = join(work, `${label}.jsonl`);
  const r = sh('bash', ['-c', 'claude -p --output-format stream-json --verbose "${@:3}" < "$1" > "$2"', '_', promptFile, stream, ...args], { cwd });
  if (r.status !== 0) return { ok: false, error: `claude exited ${r.status}: ${(r.stderr || '').trim().slice(0, 300)}` };
  const messages = [];
  for (const line of readFileSync(stream, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { messages.push(JSON.parse(line)); } catch { /* a partial line is not a message */ }
  }
  const trace = join(work, `${label}.json`);
  writeFileSync(trace, JSON.stringify(messages));
  return { ok: true, trace };
}

function extract(trace, out) {
  const r = sh('node', [join(TOOLS, 'review/findings-from-trace.mjs'), trace, out]);
  return r.status === 0 && existsSync(out);
}

function runCase(repo, c, kind, base, args, verify) {
  const commit = kind === 'incident' ? c.introduced : c.commit;
  const angle = c.angle;
  const work = mkdtempSync(join(tmpdir(), `review-eval-${c.name}-`));
  const tree = join(work, 'tree');
  const add = sh('git', ['worktree', 'add', '--detach', tree, commit], { cwd: repo });
  if (add.status !== 0) return { error: `could not check out ${commit}: ${add.stderr.trim()}` };
  try {
    const prompt = join(work, 'prompt.txt');
    const a = sh('bash', [join(TOOLS, 'review/assemble-review-prompt.sh'), angle, base, commit, prompt, `${commit}^`], { cwd: repo });
    if (a.status !== 0) return { error: `could not assemble the prompt: ${(a.stderr || a.stdout).trim()}` };
    console.log(`    ${(a.stdout || '').trim()}`);

    const review = runAgent(prompt, tree, args, work, 'review');
    if (!review.ok) return { error: review.error };
    const candidates = join(work, 'candidates.json');
    if (!extract(review.trace, candidates)) return { error: 'the reviewer ran but reported nothing machine-readable' };

    let findingsFile = candidates;
    let dropped = [];
    const count = JSON.parse(readFileSync(candidates, 'utf8')).length;
    if (verify && count > 0) {
      const vprompt = join(work, 'verify-prompt.txt');
      const v = sh('bash', [join(TOOLS, 'review/assemble-verify-prompt.sh'), base, commit, candidates, vprompt], { cwd: repo });
      if (v.status !== 0) return { error: `could not assemble the verification prompt: ${(v.stderr || v.stdout).trim()}` };
      const votes = [];
      for (let i = 1; i <= VERIFIERS; i += 1) {
        const out = join(work, `verdicts-${i}.json`);
        votes.push(out);
        const run = runAgent(vprompt, tree, args, work, `verify-${i}`);
        // A verifier that fails is a vote to keep, exactly as in the review action.
        if (run.ok) extract(run.trace, out);
      }
      findingsFile = join(work, 'findings.json');
      const vote = sh('node', [join(TOOLS, 'review/vote-findings.mjs'), candidates, findingsFile, join(work, 'dropped.json'), String(VERIFIERS), ...votes]);
      if (vote.status !== 0) return { error: `the vote failed: ${vote.stderr.trim()}` };
      dropped = JSON.parse(readFileSync(join(work, 'dropped.json'), 'utf8'));
    }
    const findings = JSON.parse(readFileSync(findingsFile, 'utf8'));
    // What the reviewer said and what the vote removed, so a miss can be told
    // apart: a reviewer that said nothing, or verifiers that refuted it.
    console.log(`    reviewer reported ${count}, the vote dropped ${dropped.length}, ${findings.length} kept`);
    for (const d of dropped) console.log(`      dropped: ${d.file}:${d.line} ${String(d.title || '').slice(0, 100)}`);
    return { findings, candidates: count, dropped, work };
  } finally {
    sh('git', ['worktree', 'remove', '--force', tree], { cwd: repo });
  }
}

function main(argv) {
  const opts = { verify: true };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--base') opts.base = argv[++i];
    else if (argv[i] === '--only') opts.only = argv[++i];
    else if (argv[i] === '--out') opts.out = argv[++i];
    else if (argv[i] === '--no-verify') opts.verify = false;
    else if (argv[i] === '--baseline') opts.baseline = argv[++i];
    else rest.push(argv[i]);
  }
  const [dir] = rest;
  if (!dir) { console.error('usage: review-eval.mjs <cases-dir> [--base <ref>] [--only <name>] [--no-verify] [--out <file>] [--baseline <file>]'); return 2; }
  let baseline = null;
  if (opts.baseline) {
    try {
      baseline = JSON.parse(readFileSync(opts.baseline, 'utf8')).cases;
      if (!baseline || typeof baseline !== 'object') throw new Error('no "cases" object');
    } catch (e) {
      // A baseline that cannot be read must not quietly turn the comparison off.
      console.error(`review-eval: the baseline at ${opts.baseline} is not readable (${e.message})`); return 2;
    }
  }

  const repo = sh('git', ['rev-parse', '--show-toplevel']).stdout.trim();
  if (!repo) { console.error('review-eval: not inside a git repository'); return 2; }
  if (!existsSync(dir)) { console.error(`review-eval: no case directory at ${dir}`); return 2; }

  const cases = [];
  for (const f of readdirSync(dir).filter((n) => n.endsWith('.json')).sort()) {
    let c;
    try { c = JSON.parse(readFileSync(join(dir, f), 'utf8')); } catch (e) {
      console.error(`review-eval: ${f} is not readable JSON (${e.message})`); return 2;
    }
    const kind = caseKind(c);
    if (!kind) continue;
    const bad = validate(c, kind);
    if (bad) { console.error(`review-eval: ${f} ${bad}`); return 2; }
    if (!opts.only || c.name === opts.only) cases.push({ c, kind });
  }
  if (cases.length === 0) { console.error(`review-eval: no incident or clean cases in ${dir}, so nothing was measured`); return 2; }

  const base = resolveBase(repo, opts.base);
  if (!base) { console.error('review-eval: no base ref with a REVIEW.md, so there is no standard to judge against'); return 2; }

  const compose = sh('bash', [join(TOOLS, 'agent/compose-agent-args.sh')], { cwd: repo }).stdout || '';
  const args = reviewArgs(compose.split('\n').find((l) => l.startsWith('AGENT_ARGS_REVIEW=')));

  const self = process.env.CLAUDE_REVIEW_REF
    || sh('git', ['-C', TOOLS, 'rev-parse', '--short', 'HEAD']).stdout.trim() || 'unknown';
  console.log(`review-eval: ${cases.length} case(s) from ${dir}, standard from ${base}, reviewer scripts at ${self}, `
    + `${opts.verify ? `${VERIFIERS} verifiers` : 'no verification'}. Each case runs ${opts.verify ? `up to ${VERIFIERS + 1} agents` : 'one agent'} and spends tokens.`);

  const results = [];
  for (const { c, kind } of cases) {
    const r = runCase(repo, c, kind, base, args, opts.verify);
    let row;
    if (r.error) row = { name: c.name, kind, status: 'error', why: r.error };
    else {
      const s = kind === 'incident' ? scoreIncident(c, r.findings) : scoreClean(r.findings);
      row = {
        name: c.name, kind, status: s.ok ? 'pass' : 'fail', why: s.why,
        candidates: r.candidates, kept: r.findings, dropped: r.dropped,
      };
    }
    results.push(row);
    console.log(`  ${row.status.padEnd(5)} ${kind.padEnd(8)} ${c.name}: ${row.why}`);
  }

  const inc = results.filter((r) => r.kind === 'incident');
  const cln = results.filter((r) => r.kind === 'clean');
  const errors = results.filter((r) => r.status === 'error').length;
  const summary = `incidents caught ${inc.filter((r) => r.status === 'pass').length} of ${inc.length}; `
    + `clean cases flagged ${cln.filter((r) => r.status === 'fail').length} of ${cln.length}; `
    + `${errors} case(s) could not run`;
  console.log(`review-eval: ${summary}`);
  if (opts.out) writeFileSync(opts.out, JSON.stringify({ summary, base, scripts: self, results }, null, 2));
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, [
      '## Reviewer eval', '', summary, '', '| case | kind | result | why |', '|---|---|---|---|',
      ...results.map((r) => `| ${r.name} | ${r.kind} | ${r.status} | ${String(r.why).replace(/\|/g, '\\|')} |`), '',
    ].join('\n'));
  }
  if (errors > 0) return 2;
  if (!baseline) return results.every((r) => r.status === 'pass') ? 0 : 1;
  const verdict = compareToBaseline(results, baseline);
  for (const line of verdict.lines) console.log(line);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, ['', ...verdict.lines, ''].join('\n'));
  return verdict.regressed ? 1 : 0;
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
