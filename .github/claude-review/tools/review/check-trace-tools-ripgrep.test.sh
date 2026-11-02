#!/usr/bin/env bash
# Runs real ripgrep, in Claude Code's argument order, for every Grep glob the
# trace check accepts from the checkout's top level, against a scratch checkout
# whose .git holds a random token. It fails if any accepted glob returns the
# token, and also if no refused glob does, which would mean the search could
# not have found it. ripgrep is required: without it the test fails.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
C="$ROOT/tools/review/check-trace-tools.sh"
SUITE="$ROOT/tools/review/check-trace-tools.test.sh"
if ! command -v rg >/dev/null 2>&1; then
  echo "FAIL: ripgrep (rg) is not installed; the canary cannot run" >&2
  exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The scratch checkout: a token in .git/config and in a file under .git that
# has an extension, and ordinary files that hold another token.
ws="$tmp/repo"
git init -q "$ws"
token="Gt$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
plain="Pt$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
git -C "$ws" config canary.token "$token"
mkdir -p "$ws/.git/info" "$ws/src/a" "$ws/a"
printf '%s\n' "$token" > "$ws/.git/info/x.php"
printf '%s\n' "$token" > "$ws/.git/info/a"
for f in x.php .gitignore composer.json README.md src/x.php src/a/x.php a/x.php a/b.yml; do
  printf '%s\n' "$plain" > "$ws/$f"
done

GITHUB_WORKSPACE="$ws" python3 -I - "$C" "$SUITE" "$ws" "$token" "$plain" "$tmp" <<'PY'
import itertools, json, os, re, subprocess, sys

check, suite, ws, token, plain, tmp = sys.argv[1:]
AUDIT = ['--tools', 'Read,Glob,Grep,Write,Edit,Agent,Task,SubagentHandback',
         '--root', '/mnt/audit/source/in', '--root', '/mnt/audit/source/out',
         '--write-root', '/mnt/audit/source/out', '--grep-any-glob-in-subfolders']

# Every glob the trace check's suite names, so whatever it accepts is
# searched for real; the check decides below which of them are accepted.
text = open(suite, encoding='utf-8').read()
globs = set(re.findall(r'\\?"glob\\?":\\?"([^"\\]*)', text))
for block in re.findall(r"for g in (.*?); do", text, re.S):
    globs.update(re.findall(r"'([^']*)'", block))
globs |= {'*gitignore*', '{.gitignore,composer.json}'}
# A generated set: every glob of up to three segments from a small alphabet.
SEGS = ['*', '**', 'a', 'x.php', '.gitignore', '.git', '.gi*', '{a,.git}', '*.{php,git}', '{x.php,**}']
for depth in (1, 2, 3):
    for combo in itertools.product(SEGS, repeat=depth):
        globs.add('/'.join(combo))
globs = sorted(g for g in globs if g)

def accepted(path, options):
    """The globs the trace check accepts for a Grep with that path."""
    calls = []
    for g in globs:
        inp = {'pattern': 'x', 'glob': g}
        if path:
            inp['path'] = path
        calls.append({'type': 'assistant', 'message': {'content': [
            {'type': 'tool_use', 'id': 't%d' % len(calls), 'name': 'Grep', 'input': inp}]}})
    trace = os.path.join(tmp, 'trace.json')
    json.dump(calls, open(trace, 'w'))
    r = subprocess.run(['bash', check, trace] + options, capture_output=True, text=True)
    refused = {int(n) for n in re.findall(r'Grep call (\d+):', r.stderr)}
    if r.returncode not in (0, 1) or (r.returncode == 1 and not refused):
        sys.exit('FAIL: the trace check did not run: %s' % r.stderr[-400:])
    return {g for i, g in enumerate(globs, 1) if i not in refused}

def search(glob):
    """ripgrep as Claude Code 2.1.316 runs it: --hidden, its own exclusions,
    --max-columns, the mode flags, the pattern, then the agent's glob split on
    whitespace and on commas unless a part holds a brace group."""
    args = ['rg', '--hidden']
    for d in ('.git', '.svn', '.hg', '.bzr', '.jj', '.sl'):
        args += ['--glob', '!' + d]
    args += ['--max-columns', '500', '-l', '--null', token + '|' + plain]
    for part in glob.split():
        for p in ([part] if '{' in part and '}' in part else [t for t in part.split(',') if t]):
            args += ['--glob', p]
    r = subprocess.run(args + [ws], capture_output=True, cwd=ws)
    return r.returncode, r.stdout.decode('utf-8', 'replace')

def leaks(glob):
    code, out = search(glob)
    files = [f for f in out.split('\0') if f]
    return code, [f for f in files if '/.git/' in f], files

ok = set()
for path in ('', ws):
    for options in ([], AUDIT):
        ok |= accepted(path, options)
refused = [g for g in globs if g not in ok]
print('globs %d, accepted %d, refused %d' % (len(globs), len(ok), len(refused)))

bad, searched, errors = [], 0, 0
for g in sorted(ok):
    code, leaked, files = leaks(g)
    if code == 2:
        errors += 1
        continue
    searched += 1
    if leaked:
        bad.append(g)
if bad:
    sys.exit('FAIL: %d accepted glob(s) returned the .git token: %s' % (len(bad), ' '.join(bad[:20])))
# The search must find ordinary files through an accepted glob, and the token
# through a refused one, or a clean result proves nothing.
if '/x.php' not in ''.join(leaks('*.php')[2]) or '*.php' not in ok:
    sys.exit('FAIL: the accepted glob *.php found no ordinary file')
reached = [g for g in refused if leaks(g)[1]]
if not reached:
    sys.exit('FAIL: no refused glob returned the .git token, so the canary cannot fail')
print('searched %d accepted glob(s) (%d ripgrep errors), none reached .git; %d refused glob(s) did, e.g. %s'
      % (searched, errors, len(reached), ' '.join(reached[:5])))
PY
status=$?
[ "$status" -eq 0 ] && echo "ok: check-trace-tools-ripgrep.test.sh"
exit "$status"
