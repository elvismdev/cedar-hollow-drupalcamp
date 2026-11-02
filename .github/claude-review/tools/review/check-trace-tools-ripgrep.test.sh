#!/usr/bin/env bash
# Runs real ripgrep, in Claude Code's argument order, for every Grep glob the
# trace check accepts, against a scratch checkout whose .git holds a random
# token. Each accepted call is searched twice: as Claude Code 2.1.309 spawns
# ripgrep (in the folder the path opens, with '.' as the target) and by its raw
# path (in the checkout, with the path as written as the target), for these
# paths: none, the checkout, a subfolder, src/.., <checkout>/.. and the parent
# as an added root, and folders linked to the checkout and to its parent. It
# fails if any accepted call returns the token either way, if no refused glob
# returns the token in either spawn mode, which would mean the search could
# not have found it, and if the check accepts a call that leaked by its raw
# path. ripgrep is required: without it the test fails.
#
# The spawn and the argument order were read from the Claude Code 2.1.309
# binary, the version claude-code-action ae68417 installs, and match 2.1.316.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
C="$ROOT/tools/review/check-trace-tools.sh"
SUITE="$ROOT/tools/review/check-trace-tools.test.sh"
if ! command -v rg >/dev/null 2>&1; then
  echo "FAIL: ripgrep (rg) is not installed; the canary cannot run" >&2
  exit 1
fi
tmp=$(realpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
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
from concurrent.futures import ThreadPoolExecutor

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
# The globs of the calls that leaked by their raw path (see REGRESSIONS).
globs |= {'src/**', '*/%s/**' % os.path.basename(ws)}
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

def spawn(path, mode):
    """ripgrep's working directory and target for a Grep with that path.
    fd: as Claude Code 2.1.309 runs it on Linux with ripgrep at an absolute
    path (its embedded one, or a system one found on PATH): it opens the
    path, runs ripgrep in /proc/self/fd/<fd>, the folder the path resolves
    to on disk, and passes '.'. raw: in the checkout, with the path as the
    agent wrote it as the target, so a .. or a link is matched as written."""
    if mode == 'fd':
        return os.path.realpath(os.path.join(ws, path) if path else ws), '.'
    return ws, path or ws

def search(glob, path, mode):
    """ripgrep in Claude Code's argument order (the same in 2.1.309 and
    2.1.316): --hidden, its own exclusions, --max-columns, the mode flags, the
    pattern, then the agent's glob split on whitespace and on commas unless a
    part holds a brace group, then the target."""
    args = ['rg', '--hidden']
    for d in ('.git', '.svn', '.hg', '.bzr', '.jj', '.sl'):
        args += ['--glob', '!' + d]
    args += ['--max-columns', '500', '-l', '--null', token + '|' + plain]
    for part in glob.split():
        for p in ([part] if '{' in part and '}' in part else [t for t in part.split(',') if t]):
            args += ['--glob', p]
    cwd, target = spawn(path, mode)
    r = subprocess.run(args + [target], capture_output=True, cwd=cwd)
    return r.returncode, r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace')

def leaks(glob, path, mode):
    """ripgrep's exit status, the files under .git it listed, every file it
    listed and its first error line. Files are read even when it exits 2, since
    an error elsewhere does not stop it listing matches."""
    code, out, err = search(glob, path, mode)
    files = [f for f in out.split('\0') if f]
    return code, [f for f in files if '/.git/' in f or f.startswith('.git/')], files, (err.splitlines() or [''])[0]

# The path variants: no path, the checkout, a subfolder, a .. that resolves to
# the checkout, the parent reached with .. and as itself (an added root), and
# folders linked to the checkout and to its parent.
os.symlink('..', os.path.join(ws, 'src', 'link'))
os.symlink('../..', os.path.join(ws, 'src', 'uplink'))
TOP = [[], AUDIT]
UP = [['--root', up], AUDIT + ['--root', up]]
VARIANTS = [('no path', '', TOP), ('workspace', ws, TOP), ('subfolder', 'src', TOP),
            ('src/..', 'src/..', TOP), ('<ws>/..', ws + '/..', UP), ('parent', up, UP),
            ('link to checkout', 'src/link', TOP), ('link to parent', 'src/uplink', TOP)]
MODES = ('fd', 'raw')
print('globs %d' % len(globs))

ok = {}
for name, path, optsets in VARIANTS:
    ok[name] = set()
    for options in optsets:
        ok[name] |= accepted(path, options)

def run_all(jobs):
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        return list(pool.map(lambda j: (j, leaks(*j)), jobs))

failures = []
for name, path, _ in VARIANTS:
    for mode in MODES:
        bad, errors, unparsed = [], [], []
        for (g, _p, _m), (code, leaked, files, err) in run_all([(g, path, mode) for g in sorted(ok[name])]):
            if leaked:
                bad.append(g)
            # ripgrep refuses a glob it cannot parse (nested brace groups)
            # before searching anything, which Claude Code reports as an error;
            # any other error can hide a match.
            if code == 2 and not files and re.sub(r'^rg: ', '', err).startswith('error parsing glob'):
                unparsed.append(g)
            elif code == 2:
                errors.append((g, err))
        print('%-17s %-3s: accepted %4d, unparsed %3d, leaked %d' % (name, mode, len(ok[name]), len(unparsed), len(bad)))
        if bad:
            failures.append('%d accepted glob(s) with path %s (%s) returned the .git token: %s'
                            % (len(bad), name, mode, ' '.join(bad[:20])))
        if errors:
            failures.append('ripgrep failed with path %s (%s) on %d accepted glob(s), e.g. %s: %s'
                            % (name, mode, len(errors), errors[0][0], errors[0][1]))
if failures:
    sys.exit('FAIL: ' + '\nFAIL: '.join(failures))

# The search must find ordinary files through an accepted glob, and the token
# through refused ones in both spawn modes, or a clean result proves nothing.
if '*.php' not in ok['no path'] or '/x.php' not in ''.join(leaks('*.php', '', 'raw')[2]):
    sys.exit('FAIL: the accepted glob *.php found no ordinary file')
for name, path, _ in (VARIANTS[0], VARIANTS[5]):
    for mode in MODES:
        refused = [g for g in globs if g not in ok[name]]
        reached = [g for (g, _p, _m), r in run_all([(g, path, mode) for g in refused]) if r[1]]
        if not reached:
            sys.exit('FAIL: no glob refused with path %s (%s) returned the .git token, so the canary cannot fail' % (name, mode))
        print('refused with path %s (%s): %d returned the .git token, e.g. %s' % (name, mode, len(reached), ' '.join(reached[:5])))

# The calls the whole-glob rule accepted that returned the token by their raw
# path: the check must refuse each, and each must still leak raw.
REGRESSIONS = [('src/..', 'src/**', []), (ws + '/..', '*/%s/**' % os.path.basename(ws), ['--root', up]),
               ('src/link', 'src/**', [])]
for path, g, options in REGRESSIONS:
    calls = [{'type': 'tool_use', 'id': 'r', 'name': 'Grep', 'input': {'pattern': 'x', 'path': path, 'glob': g}}]
    trace = os.path.join(tmp, 'regression.json')
    json.dump(calls, open(trace, 'w'))
    r = subprocess.run(['bash', check, trace] + options, capture_output=True, text=True)
    if r.returncode != 1 or 'Grep call 1:' not in r.stderr:
        sys.exit('FAIL: the check accepted the regression call path %s glob %s: %s' % (path, g, r.stderr[-300:]))
    if not leaks(g, path, 'raw')[1]:
        sys.exit('FAIL: the regression call path %s glob %s no longer returns the token raw, so it proves nothing' % (path, g))
    print('regression call path %s glob %s: refused by the check, returns the token raw' % (path, g))
PY
status=$?
[ "$status" -eq 0 ] && echo "ok: check-trace-tools-ripgrep.test.sh"
exit "$status"
