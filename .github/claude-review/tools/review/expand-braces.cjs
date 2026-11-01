// Brace expansion for the paths, Glob patterns and Grep globs an agent gave
// its tools, shared by check-trace-tools.sh and the security audit's
// check-agent-run.sh so both judge the same expansions.
//
// A brace group such as {.,}. spells .. without a literal .. segment, so a
// check that judges the raw string can be walked past. Each group is expanded
// and every expansion is judged instead. Groups are expanded left to right as
// a cartesian product, splitting each group's body on commas.
//
// When the braces cannot be expanded with confidence the result is null, and
// callers refuse the value: a backslash (an escape this does not interpret),
// a nested group, an unbalanced or stray brace, or more than MAX_EXPANSIONS
// results.
//
// As a module: require(...).expandBraces(string) -> string[] | null.
// As a command: reads a JSON array of strings on stdin and prints a JSON
// object mapping each string to its expansions or null.
'use strict';

const MAX_EXPANSIONS = 1024;

function expandBraces(s) {
  if (s.includes('\\')) return null;
  let results = [''];
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === '}') return null;
    if (ch === '{') {
      const end = s.indexOf('}', i + 1);
      if (end === -1) return null;
      const body = s.slice(i + 1, end);
      if (body.includes('{')) return null;
      const next = [];
      for (const r of results) for (const alt of body.split(',')) next.push(r + alt);
      if (next.length > MAX_EXPANSIONS) return null;
      results = next;
      i = end + 1;
    } else {
      results = results.map((r) => r + ch);
      i += 1;
    }
  }
  return results;
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
