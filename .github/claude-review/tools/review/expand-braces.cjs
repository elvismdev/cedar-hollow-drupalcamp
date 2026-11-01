// Brace expansion for the paths, Glob patterns and Grep globs an agent gave
// its tools, shared by check-trace-tools.sh and the security audit's
// check-agent-run.sh so both judge the same expansions.
//
// A brace group such as {.,}. spells .. without a literal .. segment, so a
// check that judges the raw string can be walked past. Each group is expanded
// and every expansion is judged instead. Groups are expanded left to right as
// a cartesian product, splitting each group's body on commas.
//
// Expansion follows bash and minimatch: a group whose body holds a comma at
// its own level is a list of alternatives, each of which may hold further
// groups to any depth ({a,{b,c}} gives a, b, c); groups are expanded left to
// right as a cartesian product. A group with no comma at its own level, such
// as {a}, is literal and keeps its braces, though groups inside it still
// expand. Because glob engines differ on such a group, every expansion that
// still holds a brace is also returned with its braces removed, so a caller
// judges {..}/x both as written and as ../x.
//
// When the braces cannot be expanded with confidence the result is null, and
// callers refuse the value: a backslash (an escape this does not interpret),
// an unbalanced or stray brace, or more than MAX_EXPANSIONS expansions.
//
// As a module: require(...).expandBraces(string) -> string[] | null.
// As a command: reads a JSON array of strings on stdin and prints a JSON
// object mapping each string to its expansions or null.
'use strict';

const MAX_EXPANSIONS = 256;

class TooMany extends Error {}

// The index of the brace closing the one at i, or -1.
function closing(s, i) {
  let depth = 0;
  for (let j = i; j < s.length; j += 1) {
    if (s[j] === '{') depth += 1;
    else if (s[j] === '}') {
      depth -= 1;
      if (depth === 0) return j;
    }
  }
  return -1;
}

// The body split on the commas at its own level.
function alternatives(body) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let j = 0; j < body.length; j += 1) {
    if (body[j] === '{') depth += 1;
    else if (body[j] === '}') depth -= 1;
    else if (body[j] === ',' && depth === 0) {
      parts.push(body.slice(start, j));
      start = j + 1;
    }
  }
  parts.push(body.slice(start));
  return parts;
}

function product(heads, tails) {
  if (heads.length * tails.length > MAX_EXPANSIONS) throw new TooMany();
  const out = [];
  for (const h of heads) for (const t of tails) out.push(h + t);
  return out;
}

// Assumes balanced braces.
function expand(s) {
  const i = s.indexOf('{');
  if (i === -1) return [s];
  const j = closing(s, i);
  const prefix = s.slice(0, i);
  const body = s.slice(i + 1, j);
  const rest = expand(s.slice(j + 1));
  const parts = alternatives(body);
  let middle;
  if (parts.length === 1) {
    middle = expand(body).map((x) => `{${x}}`);
  } else {
    middle = [];
    for (const p of parts) {
      middle.push(...expand(p));
      if (middle.length > MAX_EXPANSIONS) throw new TooMany();
    }
  }
  return product(middle.map((m) => prefix + m), rest);
}

function expandBraces(s) {
  if (s.includes('\\')) return null;
  let depth = 0;
  for (const ch of s) {
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth < 0) return null;
    }
  }
  if (depth !== 0) return null;
  let results;
  try {
    results = expand(s);
  } catch (err) {
    if (err instanceof TooMany) return null;
    throw err;
  }
  const out = new Set(results);
  for (const r of results) if (/[{}]/.test(r)) out.add(r.replace(/[{}]/g, ''));
  return [...out];
}

module.exports = { expandBraces, MAX_EXPANSIONS };

if (require.main === module) {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (d) => { input += d; });
  process.stdin.on('end', () => {
    let values;
    try {
      values = JSON.parse(input);
    } catch (err) {
      console.error(`expand-braces: input is not JSON (${err.name})`);
      process.exit(1);
    }
    if (!Array.isArray(values)) {
      console.error('expand-braces: input is not a list');
      process.exit(1);
    }
    const out = Object.create(null);
    for (const v of values) if (typeof v === 'string') out[v] = expandBraces(v);
    process.stdout.write(JSON.stringify(out));
  });
}
