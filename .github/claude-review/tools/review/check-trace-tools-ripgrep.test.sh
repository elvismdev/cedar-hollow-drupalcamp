#!/usr/bin/env bash
# Runs real ripgrep, in Claude Code's argument order, for every Grep glob the
# trace check accepts, against a scratch checkout whose .git holds a random
# token. Each accepted call is searched twice: as Claude Code 2.1.309 spawns
# ripgrep (in the folder the path opens, with '.' as the target) and by its raw
# path (in the checkout, with the path as written as the target), for these
# paths: none, the checkout, a subfolder, src/.., <checkout>/.. and the parent
# as an added root, folders linked to the checkout and to its parent, the
# parent as an added root by its real path and spelled through a link, links
# from the head and the input directory to the checkout and its parent, and
# paths not in normal form (.//src, ///<checkout>, <checkout>/.,
# <checkout>//src) beside ./src and src/, in two layouts: plain, and with the
# checkout's parent reached through a symlink. It fails if any accepted call
# returns the token either way, if a glob ripgrep cannot parse holds no nested
# brace group, if no refused glob returns the token in either spawn mode,
# which would mean the search could not have found it, and if the check does
# not refuse a call that leaked by its raw path with the label that names why.
# ripgrep is required: without it the test fails.
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
# has an extension, and ordinary files that hold another token. In the
# "linked" layout the checkout's parent folder is reached through a symlink,
# as on a runner whose workspace sits behind one.
layout () { # plain|linked
  local dir="$tmp/$1" up ws token plain
  mkdir -p "$dir"
  if [ "$1" = linked ]; then
    mkdir -p "$dir/realup"; ln -s "$dir/realup" "$dir/up"
  else
    mkdir -p "$dir/up"
  fi
  up="$dir/up"
  ws="$up/repo"
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
  echo "layout: $1"
  GITHUB_WORKSPACE="$ws" python3 -I "$tmp/canary.py" "$C" "$SUITE" "$ws" "$token" "$plain" "$dir" "$up"
}

cat > "$tmp/canary.py" <<'PY'
import itertools, json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

check, suite, ws, token, plain, tmp, up = sys.argv[1:]

def model_parts(glob):
    """The canary's own model of how Claude Code turns a Grep glob into
    ripgrep --glob arguments, kept apart from the check's: split on
    whitespace, then split each piece on commas unless it holds both braces,
    and drop empty pieces."""
    out = []
    for piece in glob.split():
        out.extend([piece] if '{' in piece and '}' in piece else [t for t in piece.split(',') if t])
    return out

# The model and the check's grep_glob_parts.py must agree on a fixed corpus,
# so a change to either shows here.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(check))
from grep_glob_parts import parts as check_parts
CORPUS = ['*.php', 'a,b', 'a,,b', ',a,', '{a,b}', 'a,{b,c}', '!x,{y,z}/**', 'a b', 'a,b c,{d,e} f',
          '{', '}', 'a{b,c', 'a}b,c', '', ' ', '!web/**,*', '{a,b},c', 'src/**/*.php,!vendor/**',
          '!{vendor,node_modules}/**', '{a,{b,c}}', 'x}{,y']
drift = [g for g in CORPUS if model_parts(g) != check_parts(g)]
if drift:
    sys.exit('FAIL: the canary\'s split model and the check\'s disagree on: %s' % ' | '.join(repr(g) for g in drift))
print('split model agrees with the check on %d corpus globs' % len(CORPUS))
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
# Negated shapes: a part starting with ! alone, beside every folder shape in
# either order, two together, and a ! inside a brace group or after a /,
# which ripgrep reads as a literal character.
NEGATED = ['!*', '!**', '!.git', '!.git/**', '!**/.git', '!src/**', '!*/x.php', '!{a,*}', '!{.git,src}',
           '!' + os.path.basename(ws) + '/**', '!**/*']
for n in NEGATED:
    globs.add(n)
    for f in FOLDER:
        globs.add('%s,%s' % (n, f))
        globs.add('%s,%s' % (f, n))
for a, b in itertools.combinations(NEGATED, 2):
    globs.add('%s,%s' % (a, b))
globs |= {'{!a,*}', '{!.git,src/*}', '{src/*,!*}', 'src/!a', '*/!*', '!!*'}
# The globs of the three calls that leaked by their raw path: src/.. with
# src/**, <checkout>/.. with */repo/** from the parent as a root, and a
# folder linked to the checkout with src/**.
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
    # A line ending (warning) names a call the check accepted; every other
    # line naming a Grep call is a refusal.
    refused, warned = set(), set()
    for line in r.stderr.splitlines():
        m = re.match(r'check-trace-tools: Grep call (\d+): ', line)
        if m:
            (warned if line.endswith(' (warning)') else refused).add(int(m.group(1)))
    if r.returncode not in (0, 1) or (r.returncode == 1 and not refused):
        sys.exit('FAIL: the trace check did not run: %s' % r.stderr[-400:])
    if refused & warned:
        sys.exit('FAIL: the trace check both refused and warned on call(s) %s' % sorted(refused & warned))
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
    for p in model_parts(glob):
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

def nested_braces(glob):
    """True when a brace group opens inside another."""
    depth = 0
    for c in glob:
        if c == '{':
            if depth:
                return True
            depth += 1
        elif c == '}' and depth:
            depth -= 1
    return False
if nested_braces('{a,b}/{c,d}') or not nested_braces('{a,{b,c}}'):
    sys.exit('FAIL: the nested brace test misjudges its own examples')

# The path variants: no path, the checkout, a subfolder, a .. that resolves to
# the checkout, the parent reached with .. and as itself (an added root),
# folders linked to the checkout and to its parent, the parent as a root by its
# real path and spelled through a link, links from the head and the input
# directory to the checkout and its parent, and paths not in normal form.
os.symlink('..', os.path.join(ws, 'src', 'link'))
os.symlink('../..', os.path.join(ws, 'src', 'uplink'))
real_up = os.path.realpath(up)
link_up = os.path.join(tmp, 'link-up')
os.symlink(up, link_up)
head, inp = os.path.join(tmp, 'head'), os.path.join(tmp, 'input')
os.makedirs(head)
os.makedirs(inp)
os.symlink(ws, os.path.join(head, 'wslink'))
os.symlink(ws, os.path.join(inp, 'wslink'))
os.symlink(up, os.path.join(head, 'uplink'))
os.environ['REVIEW_HEAD_DIR'] = head
os.environ['REVIEW_INPUT_DIR'] = inp
TOP = [[], AUDIT]
UP = [['--root', up], AUDIT + ['--root', up]]
def rooted(r):
    return [['--root', r], AUDIT + ['--root', r]]
VARIANTS = [('no path', '', TOP), ('workspace', ws, TOP), ('subfolder', 'src', TOP),
            ('src/..', 'src/..', TOP), ('<ws>/..', ws + '/..', UP), ('parent', up, UP),
            ('link to checkout', 'src/link', TOP), ('link to parent', 'src/uplink', TOP),
            ('real parent root', real_up, rooted(real_up)), ('linked parent root', link_up, rooted(link_up)),
            ('head link to ws', os.path.join(head, 'wslink'), TOP),
            ('input link to ws', os.path.join(inp, 'wslink'), TOP),
            ('head link to up', os.path.join(head, 'uplink'), TOP),
            ('.//src', './/src', TOP), ('///<ws>', '//' + ws, TOP), ('<ws>/.', ws + '/.', TOP),
            ('<ws>//src', ws + '//src', TOP), ('./src', './src', TOP), ('src/', 'src/', TOP)]
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
            # ripgrep refuses a glob it cannot parse before searching anything,
            # which Claude Code reports as an error; the only such glob measured
            # is one with a nested brace group, so any other fails the canary,
            # as does any other error, which can hide a match.
            if code == 2 and not files and re.sub(r'^rg: ', '', err).startswith('error parsing glob'):
                unparsed.append(g)
            elif code == 2:
                errors.append((g, err))
        odd = [g for g in unparsed if not nested_braces(g)]
        print('%-17s %-3s: accepted %4d, unparsed %3d, leaked %d' % (name, mode, len(ok[name]), len(unparsed), len(bad)))
        if bad:
            failures.append('%d accepted glob(s) with path %s (%s) returned the .git token: %s'
                            % (len(bad), name, mode, ' '.join(bad[:20])))
        if errors:
            failures.append('ripgrep failed with path %s (%s) on %d accepted glob(s), e.g. %s: %s'
                            % (name, mode, len(errors), errors[0][0], errors[0][1]))
        if odd:
            failures.append('%d glob(s) ripgrep could not parse with path %s (%s) hold no nested brace group: %s'
                            % (len(odd), name, mode, ' '.join(odd[:20])))
if failures:
    sys.exit('FAIL: ' + '\nFAIL: '.join(failures))

# The search must find ordinary files through an accepted glob, and the token
# through refused ones in both spawn modes, or a clean result proves nothing.
if '*.php' not in ok['no path'] or '/x.php' not in ''.join(leaks('*.php', '', 'raw')[2]):
    sys.exit('FAIL: the accepted glob *.php found no ordinary file')
# A kept-whole glob with a comma outside its braces passes with a warning, so
# it must be among the accepted globs searched above.
if 'src/**/*.php,{web,docs}/**' not in ok['no path']:
    sys.exit('FAIL: the warned glob src/**/*.php,{web,docs}/** was not searched as accepted')
for name, path, _ in (VARIANTS[0], VARIANTS[5], VARIANTS[8], VARIANTS[9]):
    for mode in MODES:
        refused = [g for g in globs if g not in ok[name]]
        reached = [g for (g, _p, _m), r in run_all([(g, path, mode) for g in refused]) if r[1]]
        if not reached:
            sys.exit('FAIL: no glob refused with path %s (%s) returned the .git token, so the canary cannot fail' % (name, mode))
        print('refused with path %s (%s): %d returned the .git token, e.g. %s' % (name, mode, len(reached), ' '.join(reached[:5])))

# The calls the whole-glob rule accepted that returned the token by their raw
# path: the check must refuse each, and in the plain layout each must still
# leak raw.
REGRESSIONS = [('src/..', 'src/**', [], 'Grep path holds a .. segment (field path)'),
               (ws + '/..', '*/%s/**' % os.path.basename(ws), ['--root', up], 'Grep path holds a .. segment (field path)'),
               ('src/link', 'src/**', [], 'Grep path passes through a symlink (field path)')]
for path, g, options, label in REGRESSIONS:
    calls = [{'type': 'tool_use', 'id': 'r', 'name': 'Grep', 'input': {'pattern': 'x', 'path': path, 'glob': g}}]
    trace = os.path.join(tmp, 'regression.json')
    json.dump(calls, open(trace, 'w'))
    r = subprocess.run(['bash', check, trace] + options, capture_output=True, text=True)
    if r.returncode != 1 or 'Grep call 1: ' + label not in r.stderr:
        sys.exit('FAIL: the check accepted the regression call path %s glob %s: %s' % (path, g, r.stderr[-300:]))
    # They were measured in the plain layout; behind a symlinked parent
    # ripgrep matches the absolute path and some no longer reach .git.
    if os.path.realpath(ws) != ws:
        print('regression call path %s glob %s: refused by the check' % (path, g))
        continue
    if not leaks(g, path, 'raw')[1]:
        sys.exit('FAIL: the regression call path %s glob %s no longer returns the token raw, so it proves nothing' % (path, g))
    print('regression call path %s glob %s: refused by the check, returns the token raw' % (path, g))
PY
status=0
for l in plain linked; do
  layout "$l" || status=1
done
[ "$status" -eq 0 ] && echo "ok: check-trace-tools-ripgrep.test.sh"
exit "$status"
