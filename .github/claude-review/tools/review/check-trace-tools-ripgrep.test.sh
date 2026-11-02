#!/usr/bin/env bash
# Runs real ripgrep, in Claude Code's argument order, for every Grep glob the
# trace check accepts from the checkout's top level, and from the directory
# above it given as an added root, against a scratch checkout whose .git holds
# a random token. It fails if any accepted glob returns the
# token, and also if no refused glob does, which would mean the search could
# not have found it. ripgrep is required: without it the test fails.
#
# The argument order below was read from the Claude Code 2.1.316 binary;
# claude-code-action ae68417 installs Claude Code 2.1.309, the version
# check-trace-tools.sh's field lists are taken from.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
C="$ROOT/tools/review/check-trace-tools.sh"
SUITE="$ROOT/tools/review/check-trace-tools.test.sh"
if ! command -v rg >/dev/null 2>&1; then
  echo "FAIL: ripgrep (rg) is not installed; the canary cannot run" >&2
  exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "ripgrep: $(rg --version | head -n 1)"

# The scratch checkout: a token in .git/config and in a file under .git that
# has an extension, and ordinary files that hold another token.
up="$tmp/up"
ws="$up/repo"
mkdir -p "$up"
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

GITHUB_WORKSPACE="$ws" python3 -I - "$C" "$SUITE" "$ws" "$token" "$plain" "$tmp" "$up" <<'PY'
import itertools, json, os, re, subprocess, sys

check, suite, ws, token, plain, tmp, up = sys.argv[1:]
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
        # The same shapes under the checkout's own name, for the search from
        # the directory above it.
        if depth < 3:
            globs.add('/'.join((os.path.basename(ws),) + combo))
# Folder-list shapes: <dir>/*, <dir>/**, */<name>, and brace and comma lists
# of them, for each folder spelling, under the checkout's own name too.
DIRS = ['src', 'a', 'src/a', '.git', '.gi*', '*', '**', '{src,.git}', '{a,*}']
FOLDER = [d + t for d in DIRS for t in ('/*', '/**', '/', '/x.php')] + ['*/x.php', '*/a', '*/*', '**/x.php']
for f in FOLDER:
    globs.add(f)
    globs.add(os.path.basename(ws) + '/' + f)
for a, b in itertools.combinations(FOLDER, 2):
    globs.add('{%s,%s}' % (a, b))
    globs.add('%s,%s' % (a, b))
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

def search(glob, target=None):
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
    # Claude Code runs ripgrep in its working directory, the checkout, and
    # passes the Grep's path as the target, even when it lies outside it.
    r = subprocess.run(args + [target or ws], capture_output=True, cwd=ws)
    return r.returncode, r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace')

def leaks(glob, target=None):
    """ripgrep's exit status, the files under .git it listed, every file it
    listed and its first error line. Files are read even when it exits 2, since
    an error elsewhere does not stop it listing matches."""
    code, out, err = search(glob, target)
    files = [f for f in out.split('\0') if f]
    return code, [f for f in files if '/.git/' in f], files, (err.splitlines() or [''])[0]

ok = set()
for path in ('', ws):
    for options in ([], AUDIT):
        ok |= accepted(path, options)
refused = [g for g in globs if g not in ok]
print('globs %d, accepted %d, refused %d' % (len(globs), len(ok), len(refused)))
# From the directory above the checkout, allowed as an added root.
above = set()
for options in (['--root', up], AUDIT + ['--root', up]):
    above |= accepted(up, options)
print('from above the checkout: accepted %d, refused %d' % (len(above), len(globs) - len(above)))

def run_accepted(names, target):
    bad, errors, unparsed = [], [], []
    for g in sorted(names):
        code, leaked, files, err = leaks(g, target)
        if leaked:
            bad.append(g)
        # ripgrep refuses a glob it cannot parse (nested brace groups) before
        # searching anything, which Claude Code reports as an error; any other
        # error can hide a match.
        if code == 2 and not files and re.sub(r'^rg: ', '', err).startswith('error parsing glob'):
            unparsed.append(g)
        elif code == 2:
            errors.append((g, err))
    where = 'from above the checkout ' if target else ''
    if bad:
        sys.exit('FAIL: %d accepted glob(s) %sreturned the .git token: %s' % (len(bad), where, ' '.join(bad[:20])))
    # An error can hide a match, so any ripgrep error fails the canary.
    if errors:
        sys.exit('FAIL: ripgrep failed %son %d accepted glob(s), e.g. %s: %s'
                 % (where, len(errors), errors[0][0], errors[0][1]))

    return len(unparsed)

unparsed_top = run_accepted(ok, None)
unparsed_above = run_accepted(above, up)
# The search must find ordinary files through an accepted glob, and the token
# through a refused one, or a clean result proves nothing.
if '/x.php' not in ''.join(leaks('*.php')[2]) or '*.php' not in ok:
    sys.exit('FAIL: the accepted glob *.php found no ordinary file')
reached = [g for g in refused if leaks(g)[1]]
if not reached:
    sys.exit('FAIL: no refused glob returned the .git token, so the canary cannot fail')
reached_above = [g for g in globs if g not in above and leaks(g, up)[1]]
if not reached_above:
    sys.exit('FAIL: no glob refused from above the checkout returned the .git token')
print('searched %d accepted glob(s) (%d that ripgrep cannot parse), none reached .git; %d refused glob(s) did, e.g. %s'
      % (len(ok), unparsed_top, len(reached), ' '.join(reached[:5])))
print('from above: searched %d accepted glob(s) (%d that ripgrep cannot parse), none reached .git; %d refused glob(s) did, e.g. %s'
      % (len(above), unparsed_above, len(reached_above), ' '.join(reached_above[:5])))
PY
status=$?
[ "$status" -eq 0 ] && echo "ok: check-trace-tools-ripgrep.test.sh"
exit "$status"
