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
# It also lists, as Claude Code's Glob does, every absolute Glob pattern the
# check accepts, and fails if one lists a file under .git or outside the
# roots, or if no refused one lists the file planted under .git.
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
# Kept-whole shapes: a brace group with a comma outside it, which ripgrep
# reads as one glob with that comma, and any later !, as literal characters.
for f in FOLDER:
    globs.add('{%s,x.php},src/**' % f)
    globs.add('src/**,{%s,x.php}' % f)
    globs.add('{%s,x.php},%s' % (f, f))
    for n in NEGATED:
        globs.add('{%s,x.php},%s' % (f, n))
        globs.add('%s,{%s,a}' % (n, f))
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

# Kept-whole globs searched from above checkouts named re,po and !re,po,
# where the literal comma and ! can match .git's path: every accepted glob
# must return no token in either spawn mode, and some refused glob must.
for name in ('re,po', '!re,po'):
    cws = os.path.join(up, name)
    ctoken = 'Ct' + os.urandom(12).hex()
    subprocess.run(['git', 'init', '-q', cws], check=True)
    subprocess.run(['git', '-C', cws, 'config', 'canary.token', ctoken], check=True)
    with open(os.path.join(cws, 'x.php'), 'w') as fh:
        fh.write(plain + '\n')
    cglobs = ['{re,x},po/**', '{!re,x},po/**', '{*,x},po/**', '!{re,x},po/**', '{re,x},po/*.php',
              '{x,y},po/**', '{!re,x},po/*.php', '{re,*},po/.git/config', '{*,x},po/*', 'x,{*,y},po/**']
    env = dict(os.environ, GITHUB_WORKSPACE=cws)
    calls = [{'type': 'tool_use', 'id': 'k%d' % i, 'name': 'Grep', 'input': {'pattern': 'x', 'path': up, 'glob': g}}
             for i, g in enumerate(cglobs)]
    trace = os.path.join(tmp, 'kept.json')
    json.dump(calls, open(trace, 'w'))
    for options in (['--root', up], AUDIT + ['--root', up]):
        r = subprocess.run(['bash', check, trace] + options, capture_output=True, text=True, env=env)
        refused = {int(m.group(1)) for m in (re.match(r'check-trace-tools: Grep call (\d+): ', l) for l in r.stderr.splitlines())
                   if m and not m.string.endswith(' (warning)')}
        # Exit 1 with no refused call is the check failing to run, not a verdict.
        if r.returncode not in (0, 1) or (r.returncode == 1 and not refused):
            sys.exit('FAIL: the trace check did not run for the kept-whole globs from above %s: %s'
                     % (name, r.stderr[-400:]))
        reached, bad = [], []
        for i, g in enumerate(cglobs, 1):
            for mode in MODES:
                args = ['rg', '--hidden'] + [x for d in ('.git', '.svn', '.hg', '.bzr', '.jj', '.sl') for x in ('--glob', '!' + d)]
                args += ['--max-columns', '500', '-l', '--null', ctoken]
                for p in model_parts(g):
                    args += ['--glob', p]
                cwd, target = (os.path.realpath(up), '.') if mode == 'fd' else (cws, up)
                out = subprocess.run(args + [target], capture_output=True, cwd=cwd).stdout
                if out:
                    (reached if i in refused else bad).append('%s (%s)' % (g, mode))
        print('kept-whole from above %s %s: accepted %d, refused %d, leaked %d, refused that returned the token %d'
              % (name, 'audit' if len(options) > 2 else 'none', len(cglobs) - len(refused), len(refused), len(bad), len(reached)))
        if bad:
            sys.exit('FAIL: accepted kept-whole glob(s) returned the .git token from above %s: %s' % (name, ' '.join(bad)))
        if not reached:
            sys.exit('FAIL: no refused kept-whole glob returned the .git token from above %s, so the check proves nothing' % name)

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

# Absolute Glob patterns. Claude Code 2.1.316 ignores a Glob's path when its
# pattern is absolute: it searches the directory before the last / ahead of
# the first *, ?, [ or { (the dirname when there is none), with the rest as
# the glob, running ripgrep --files --null --glob <rest> --sort=modified
# --no-ignore --hidden, and nothing excludes .git. That was read from the
# binary and measured with a real Glob call, which listed a file planted
# under .git for <checkout>/*.json and <checkout>/*/cn*, and from the
# parent for <parent>/*/.git/cn*. Every absolute pattern the check accepts is
# listed both ways (in the folder the directory resolves to, with '.' as the
# target, and from the checkout with the directory as written as the target)
# and must list nothing under .git, where a file named with a random token
# sits, and nothing outside the roots it was accepted with.
gname = 'Gn' + os.urandom(12).hex() + '.php'
with open(os.path.join(ws, '.git', gname), 'w') as fh:
    fh.write('x\n')
with open(os.path.join(inp, 'x.json'), 'w') as fh:
    fh.write(plain + '\n')

def glob_split(pattern):
    """The canary's own model of Claude Code's split of an absolute Glob
    pattern into the directory searched and the glob, kept apart from the
    check's."""
    m = re.search(r'[*?\[{]', pattern)
    if m is None:
        # Node's dirname and basename, which ignore trailing slashes.
        trimmed = pattern.rstrip('/') or '/'
        return os.path.dirname(trimmed), os.path.basename(trimmed)
    cut = pattern.rfind('/', 0, m.start())
    return pattern[:cut] or '/', pattern[cut + 1:]

# The model and the check's glob_search_split.py must both reproduce every
# split measured from the Claude Code 2.1.316 binary.
from glob_search_split import split as check_split
SPLITS = json.load(open(os.path.join(os.path.dirname(check), 'glob-split-corpus.json')))['splits']
split_drift = [r[0] for r in SPLITS if list(glob_split(r[0])) != r[1:] or list(check_split(r[0])) != r[1:]]
if len(SPLITS) < 8 or split_drift:
    sys.exit('FAIL: the absolute Glob split corpus (%d rows) disagrees with the canary or the check on: %s'
             % (len(SPLITS), ' '.join(split_drift)))
print('absolute Glob split: the canary and the check agree with %d measured splits' % len(SPLITS))

def glob_list(pattern, mode, strict=False):
    """The files ripgrep lists for an absolute Glob pattern, as real paths.
    strict, for an accepted pattern: a missing folder or a ripgrep error
    fails the canary, since it would hide what the pattern lists."""
    base, g = glob_split(pattern)
    if not os.path.isdir(base):
        if strict:
            sys.exit('FAIL: the folder of the accepted absolute Glob pattern %s does not exist' % pattern)
        return []
    cwd, target = (os.path.realpath(base), '.') if mode == 'fd' else (ws, base)
    r = subprocess.run(['rg', '--files', '--null', '--glob', g, '--sort=modified', '--no-ignore', '--hidden', target],
                       capture_output=True, cwd=cwd)
    if r.returncode not in (0, 1):
        if strict:
            sys.exit('FAIL: ripgrep exited %d on the accepted absolute Glob pattern %s (%s): %s'
                     % (r.returncode, pattern, mode, r.stderr.decode('utf-8', 'replace').strip()[:300]))
        if not r.stdout:
            return []
    return [os.path.realpath(os.path.join(cwd, f)) for f in r.stdout.decode('utf-8', 'replace').split('\0') if f]

RELS = set(FOLDER) | {'/'.join(c) for d in (1, 2) for c in itertools.product(SEGS, repeat=d)}
RELS |= {'*.json', 'x.php', '*.php', 'README.md', '.git/config', '{.git,x}/**', '{src,.gi*}/*', '.g*/' + gname, '*/' + gname}
RELS = sorted(r for r in RELS if not r.endswith('/'))
BASES = [ws, ws + '/src', ws + '/src/a', ws + '/a', up, real_up, link_up, link_up + '/repo', head, inp,
         os.path.join(head, 'wslink'), os.path.join(inp, 'wslink'), ws + '/src/link']
patterns = {b + '/' + r for b in BASES for r in RELS}
patterns |= {'%s/{%s,x}/%s' % (up, os.path.basename(ws), r) for r in RELS}
patterns |= {'%s/{src,a}/%s' % (ws, r) for r in RELS} | {'%s/{src,.git}/%s' % (ws, r) for r in ('x.php', '*')}
patterns |= {ws + '/src/../' + r for r in ('*', '.git/config')} | {ws + '/./' + r for r in ('*', 'x.php')}
patterns |= {inp + '/*.json', ws + '/src/x.php', ws + '/' + gname}
patterns = sorted(patterns)
# Every folder a pattern in normal form names exists (head/.git, src/a/.git),
# so an accepted pattern whose folder is missing is a fault in the canary. A
# pattern whose folder is an existing file (x.php/*) lists nothing in Claude
# Code and is left out.
not_folders = set()
for p in patterns:
    d = glob_split(p)[0]
    if all(s not in ('', '.', '..') for s in d[1:].split('/')):
        try:
            os.makedirs(d, exist_ok=True)
        except (FileExistsError, NotADirectoryError):
            not_folders.add(p)
patterns = [p for p in patterns if p not in not_folders]
print('absolute Glob patterns left out because their folder is a file: %d' % len(not_folders))
GOPTS =[('none', []), ('audit', AUDIT), ('parent root', ['--root', up]), ('audit, parent root', AUDIT + ['--root', up]),
         ('real parent root', ['--root', real_up]), ('linked parent root', ['--root', link_up])]
print('absolute Glob patterns %d' % len(patterns))

def glob_accepted(options):
    calls = [{'type': 'tool_use', 'id': 'g%d' % i, 'name': 'Glob', 'input': {'pattern': p}} for i, p in enumerate(patterns)]
    trace = os.path.join(tmp, 'glob.json')
    json.dump(calls, open(trace, 'w'))
    r = subprocess.run(['bash', check, trace] + options, capture_output=True, text=True)
    refused = {int(m.group(1)) for m in (re.match(r'check-trace-tools: Glob call (\d+): ', l) for l in r.stderr.splitlines()) if m}
    if r.returncode not in (0, 1) or (r.returncode == 1 and not refused):
        sys.exit('FAIL: the trace check did not run on the absolute Glob patterns: %s' % r.stderr[-400:])
    return [p for i, p in enumerate(patterns, 1) if i not in refused]

real_git = os.path.realpath(os.path.join(ws, '.git'))
inside_git = lambda f: f == real_git or f.startswith(real_git + '/')
found_plain = False
accepted_by = {}
for label, options in GOPTS:
    roots = [os.path.realpath(r) for r in [ws, head, inp] + [options[i + 1] for i, o in enumerate(options) if o == '--root']]
    ok_patterns = accepted_by[label] = glob_accepted(options)
    jobs = [(p, mode) for p in ok_patterns for mode in MODES]
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        listed = list(pool.map(lambda j: (j, glob_list(*j, strict=True)), jobs))
    git_leaks = sorted({'%s (%s)' % j for j, files in listed if any(inside_git(f) or gname in f for f in files)})
    root_leaks = sorted({'%s (%s)' % j for j, files in listed
                         if any(not any(f == r or f.startswith(r + '/') for r in roots) for f in files)})
    found_plain = found_plain or any(j[0] == inp + '/*.json' and os.path.join(os.path.realpath(inp), 'x.json') in files
                                     for j, files in listed)
    print('absolute Glob, %-18s: accepted %4d, listed under .git %d, listed outside the roots %d'
          % (label, len(ok_patterns), len(git_leaks), len(root_leaks)))
    if git_leaks:
        sys.exit('FAIL: accepted absolute Glob pattern(s) listed a file under .git: %s' % ' '.join(git_leaks[:20]))
    if root_leaks:
        sys.exit('FAIL: accepted absolute Glob pattern(s) listed a file outside the roots: %s' % ' '.join(root_leaks[:20]))
if not found_plain:
    sys.exit('FAIL: the accepted absolute Glob <input>/*.json listed no ordinary file, so a clean result proves nothing')
# Some refused pattern must list the planted file, in both modes, or the
# listing could not have found it.
refused = sorted(set(patterns) - set(accepted_by['none']))
for mode in MODES:
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        reached = [p for p, files in pool.map(lambda p: (p, glob_list(p, mode)), refused) if any(gname in f for f in files)]
    if not reached:
        sys.exit('FAIL: no refused absolute Glob pattern listed the planted .git file (%s), so the canary cannot fail' % mode)
    print('absolute Glob refused (%s): %d listed the planted .git file' % (mode, len(reached)))
PY
status=0
for l in plain linked; do
  layout "$l" || status=1
done
[ "$status" -eq 0 ] && echo "ok: check-trace-tools-ripgrep.test.sh"
exit "$status"
