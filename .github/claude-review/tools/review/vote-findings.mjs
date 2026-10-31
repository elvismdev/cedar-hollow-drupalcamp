// Keep the findings that independent verifiers could not refute.
//
// The reviewer's findings are candidates. Several verifier agents each open
// every candidate's file and line and try to refute it, answering "real",
// "false" or "style" per finding, and a finding is posted only when fewer than
// a majority of the configured verifiers refuted it. Style counts as a
// refutation: a finding that is only about style, naming or cleanup is noise,
// and noise costs a round when the author is an agent.
//
// Every doubt resolves towards keeping a finding. A verifier that did not run,
// answered nothing readable, named an index that is not a candidate or gave a
// verdict outside the three words casts no refutation, so a broken verifier can
// never hide a real bug; at worst it lets a false one through, which the
// author can answer.
//
// Usage: vote-findings.mjs <candidates.json> <kept.json> <dropped.json> <verifiers> [verdicts.json ...]
//   verifiers  how many were configured, so a missing vote still counts in the
//              denominator. 0 turns verification off and keeps every candidate.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const [candidatesPath, keptPath, droppedPath, verifiersArg, ...verdictPaths] = process.argv.slice(2);
if (!candidatesPath || !keptPath || !droppedPath || verifiersArg === undefined) {
  console.error('usage: vote-findings.mjs <candidates.json> <kept.json> <dropped.json> <verifiers> [verdicts.json ...]');
  process.exit(2);
}
const verifiers = Number(verifiersArg);
if (!Number.isInteger(verifiers) || verifiers < 0) {
  console.error(`vote-findings: '${verifiersArg}' is not a number of verifiers`);
  process.exit(2);
}

let candidates;
try {
  candidates = JSON.parse(readFileSync(candidatesPath, 'utf8'));
  if (!Array.isArray(candidates)) throw new Error('not a list');
} catch (err) {
  console.error(`vote-findings: the candidates at ${candidatesPath} are not readable (${err.name}); refusing to post a review built on nothing`);
  process.exit(1);
}

const REFUTES = new Set(['false', 'style']);
const refutations = candidates.map(() => []);

for (const path of verdictPaths) {
  if (!existsSync(path)) {
    console.log(`vote-findings: no verdicts at ${path}, counted as keeping every finding`);
    continue;
  }
  let verdicts;
  try {
    verdicts = JSON.parse(readFileSync(path, 'utf8'));
    if (!Array.isArray(verdicts)) throw new Error('not a list');
  } catch (err) {
    // The parse error is not printed: it quotes the text it failed on.
    console.log(`vote-findings: verdicts at ${path} are not readable (${err.name}), counted as keeping every finding`);
    continue;
  }
  // One vote per verifier per finding, even if it answered the same index twice.
  const seen = new Set();
  for (const v of verdicts) {
    const i = Number(v?.index);
    if (!Number.isInteger(i) || i < 0 || i >= candidates.length || seen.has(i)) continue;
    const verdict = String(v?.verdict || '').toLowerCase();
    if (!REFUTES.has(verdict)) continue;
    seen.add(i);
    refutations[i].push({ verdict, reason: String(v?.reason || '') });
  }
}

const needed = Math.floor(verifiers / 2) + 1;
const kept = [];
const dropped = [];
candidates.forEach((finding, i) => {
  if (verifiers > 0 && refutations[i].length >= needed) {
    dropped.push({ ...finding, refuted_by: refutations[i] });
  } else {
    kept.push(finding);
  }
});

writeFileSync(keptPath, JSON.stringify(kept, null, 2));
writeFileSync(droppedPath, JSON.stringify(dropped, null, 2));
console.log(`vote-findings: ${candidates.length} candidate(s), ${kept.length} kept, ${dropped.length} dropped `
  + (verifiers > 0
    ? `(a finding is dropped when ${needed} of ${verifiers} verifier(s) refute it)`
    : '(not verified: every candidate is posted)'));
// Counts only. The job log is public and is written before the secret screen,
// so no title, file or reason an agent wrote is printed here; they reach the
// pull request and the job summary only after the screen.
if (dropped.length > 0) {
  const byVerdict = {};
  for (const d of dropped) for (const r of d.refuted_by) byVerdict[r.verdict] = (byVerdict[r.verdict] || 0) + 1;
  const reasons = Object.keys(byVerdict).sort().map((v) => `${byVerdict[v]} ${v}`).join(', ');
  console.log(`vote-findings: refutations behind the dropped: ${reasons}`);
}
