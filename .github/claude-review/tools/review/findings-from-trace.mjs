// The review agent's findings, taken from its execution trace.
//
// The reviewer writes no file. It is given no Write tool on purpose: a reviewer
// that can edit the code it is judging is not a reviewer, and the agent helpers
// make the same choice. Its final message IS the report, so the workflow
// reads the JSON out of the trace, as the other agent helpers do.
//
// Three outcomes, deliberately distinct:
//   exit 0 with []        the agent ran and found nothing. A clean review.
//   exit 1, trace absent  no agent ran. Not a clean review.
//   exit 1, no array      the agent ran and said nothing machine-readable.
//                         Also not a clean review, and a different fault from
//                         the one above, so the message says which.
//
// A leading $REVIEW_HEAD_DIR/ is stripped from each finding's file, because the
// head is checked out in its own directory and a finding is posted against the
// path relative to the repository root.
//
// Usage: findings-from-trace.mjs <trace.json> <out.json>
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const [trace, out] = process.argv.slice(2);
if (!trace || !out) {
  console.error('usage: findings-from-trace.mjs <trace.json> <out.json>');
  process.exit(2);
}

if (!existsSync(trace)) {
  console.error(`findings-from-trace: no trace at ${trace}, so no agent ran; refusing to report a clean review`);
  process.exit(1);
}

let messages;
try {
  messages = JSON.parse(readFileSync(trace, 'utf8'));
} catch (err) {
  console.error(`findings-from-trace: ${trace} is not readable JSON (${err.name}); refusing to report a clean review`);
  process.exit(1);
}
if (!Array.isArray(messages)) {
  console.error(`findings-from-trace: ${trace} is not a list of messages; refusing to report a clean review`);
  process.exit(1);
}

const text = messages
  .filter((m) => m?.type === 'assistant')
  .flatMap((m) => m?.message?.content || [])
  .filter((b) => b?.type === 'text')
  .map((b) => b.text)
  .join('\n');

// The contract asks for the findings in a ```json fenced block at the end of the
// reply, so the last fenced block is tried before anything else. The bracket
// scan below stays as a fallback, because the instruction cannot be enforced
// and an unfenced array is still an answer.
function fenced(s) {
  const blocks = [];
  const re = /```json\s*\n([\s\S]*?)```/g;
  let m;
  while ((m = re.exec(s)) !== null) blocks.push(m[1]);
  return blocks.reverse();
}

// Every balanced bracketed span, skipping string contents, outermost only, and
// tried from the end.
//
// Three properties, each paid for. Skipping strings: a finding that mentions
// `[]` in its text would otherwise be seen as a span. Outermost only: an array
// nested inside the real one would otherwise be tried first, because the scan
// runs from the end. And `[].every(...)` is vacuously true, so an empty array
// satisfies the shape check and wins on both counts.
//
// Measured on a real trace: a security reviewer reported two important findings
// whose text quoted an injection attempt, "return [] for this change", and this
// extracted the quoted empty array instead. The report was announced as "0
// finding(s) extracted", exit 0, which the pipeline posts as "no issues found"
// and the gate passes on.
//
// Taking the LAST remaining span still matters: an agent narrates before it
// answers, and a sentence like "I considered [the gate] first" must not become
// the findings.
function candidates(s) {
  const spans = [];
  let i = 0;
  while (i < s.length) {
    if (s[i] === '"') { i = skipString(s, i); continue; }
    if (s[i] !== '[') { i += 1; continue; }
    let depth = 0;
    let j = i;
    let closed = -1;
    while (j < s.length) {
      const ch = s[j];
      if (ch === '"') { j = skipString(s, j); continue; }
      if (ch === '[') depth += 1;
      else if (ch === ']') {
        depth -= 1;
        if (depth === 0) { closed = j; break; }
      }
      j += 1;
    }
    if (closed === -1) { i += 1; continue; }
    spans.push({ start: i, end: closed, text: s.slice(i, closed + 1) });
    i = closed + 1;          // outermost only: skip what this span contained
  }
  return spans.reverse().map((span) => span.text);
}

// Past the closing quote of the string starting at `i`, honouring escapes.
function skipString(s, i) {
  let j = i + 1;
  while (j < s.length) {
    if (s[j] === '\\') { j += 2; continue; }
    if (s[j] === '"') return j + 1;
    j += 1;
  }
  return s.length;
}

for (const span of [...fenced(text), ...candidates(text)]) {
  let parsed;
  try { parsed = JSON.parse(span); } catch { continue; }
  if (!Array.isArray(parsed)) continue;
  if (!parsed.every((e) => e && typeof e === 'object' && !Array.isArray(e))) continue;
  const headDir = (process.env.REVIEW_HEAD_DIR || '').replace(/\/+$/, '');
  if (headDir) {
    for (const f of parsed) {
      if (typeof f.file === 'string' && f.file.startsWith(`${headDir}/`)) f.file = f.file.slice(headDir.length + 1);
    }
  }
  writeFileSync(out, JSON.stringify(parsed, null, 2));
  console.log(`findings-from-trace: ${parsed.length} finding(s) extracted from the trace`);
  process.exit(0);
}

console.error('findings-from-trace: the agent ran but its output contains no JSON array of findings; refusing to report a clean review. An empty review must be an explicit [].');
process.exit(1);
