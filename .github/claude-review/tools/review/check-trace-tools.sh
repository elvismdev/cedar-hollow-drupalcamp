#!/usr/bin/env bash
# Fail when an agent's execution trace shows a tool other than Read, Glob or
# Grep, one of those three given an input field outside its schema, or one
# given a path outside the allowed roots.
#
# The review and verification agents are allowed those three tools and every
# other tool is denied by name, because an allow-list alone did not stop an
# agent using other tools. This reads what the agent actually called, so a deny
# list that missed a name, or a flag that stopped reaching the agent, fails the
# job instead of passing silently.
#
# Every object in the trace whose type is "tool_use" is a call, wherever it is
# nested. A call with no name is reported as <unnamed> and fails: a call that
# cannot be identified cannot be shown to be allowed.
#
# The paths those three tools were given are checked too:
# the workspace's .git stays in place because claude-code-action runs git
# against it, and the action writes its token into .git/config. This path check
# is what keeps the agents away from .git/config and from the process
# environment (/proc/self/environ), where the token also sits; the review
# action additionally replaces the head's symlinks with plain files.
#
# Input fields are a closed set per tool, taken from the input schemas of
# Claude Code 2.1.309, the version claude-code-action ae68417 installs. An
# input that is not an object, or that holds any other key, is refused,
# because Claude Code reads some other keys as aliases (Grep reads file_path
# as path when path is absent) and this check does not mirror them:
#
#   - Read: file_path, offset, limit, pages, allow_large.
#   - Glob: pattern, path.
#   - Grep: pattern, path, glob, type, output_mode, -B, -A, -C, context, -n,
#     -i, -o, head_limit, offset, multiline.
#
# The fields among these that name a file or directory are Read's file_path,
# Glob's pattern and path, and Grep's path, with Grep's glob as a filter on
# them. Grep's pattern is a regular expression and type a ripgrep type name;
# the rest are numbers, flags and a mode.
#
# Brace groups are expanded before the paths are judged, by expand-braces.cjs
# (shared with the security audit's run check): every expansion of a Read
# file_path, a Glob or Grep path, a Glob pattern and a Grep glob must pass the
# rules below on its own, so {.,}./x is judged as both ../x and ./x. Nested
# groups expand as in bash and minimatch, and a group with no comma, such as
# {..}, is judged both as written and without its braces. A value whose braces
# cannot be expanded with confidence (a backslash, an unbalanced or stray
# brace, or more than 256 expansions) is refused with the label "braces cannot
# be expanded". The raw value is still held to every rule.
#
# Nothing is normalised. Claude Code trims a path (with JavaScript's trim, which
# removes characters such as U+FEFF that other trims keep) and expands a
# leading ~ before reading it, so any reimplementation of that could disagree
# with it. Instead each raw value must consist only of allowlisted ASCII:
#
#   - Read's file_path, and Glob's and Grep's path: [A-Za-z0-9._/@+-], present
#     and non-empty. Then they are resolved against the workspace when
#     relative and normalised for .., and must land in $GITHUB_WORKSPACE but not
#     its .git, in $REVIEW_HEAD_DIR or in $REVIEW_INPUT_DIR (each when set).
#   - A Glob pattern: the same set plus * { } and comma. A relative one is
#     resolved against its path, normalised for .. (a brace group's ..
#     included, as segments), and held to the same roots; a relative brace
#     expansion that starts with / is refused. An absolute one is judged like
#     a path, because Claude Code 2.1.316 ignores the path for it: it lists,
#     with ripgrep --files --hidden --no-ignore and no exclusion of .git, the
#     directory before the last / ahead of the pattern's first * or { (its
#     dirname when it has none), with the rest as the glob, and a glob with
#     no / matches names at any depth. So every brace expansion must be an
#     absolute path in normal form (no empty, . or .. segment, no trailing /);
#     that directory, the same directory of each expansion and each
#     expansion whole must be inside the roots and not under .git in both
#     views and must not pass through a symlink below their root; and where
#     .git lies below that directory (the workspace's top level, or a root
#     above it) no expansion's glob may be able to match .git or any path
#     below it, so with no / it is refused there (*.php, README.md), and with
#     a / it is refused when it can (*/config, **, .g*/config, */.git/config
#     from above). The run's /mnt/audit/poc-write/in/*.json, a root of its
#     own, passes. An absolute pattern not in normal form, or through a
#     symlink to a folder inside the roots, keeps the label "Glob pattern is
#     absolute"; one outside the roots, a symlink leading outside them
#     included (its real path is judged first), gets "path outside the
#     allowed roots", and one under .git or able to reach it "path under
#     .git".
#   - A Grep glob: the same set as a Glob pattern, plus ! as the first
#     character of a part (and, in a glob kept whole, anywhere: there
#     ripgrep reads a later ! as a literal character, and so does this
#     check), with no .. segment. Claude
#     Code passes it to ripgrep after its own !.git exclusion, where it
#     overrides that exclusion, which matters only where the search can reach
#     the workspace's .git/config. So the rule below applies when the Grep has
#     no path (it then searches the working directory, the workspace) or a path
#     inside $GITHUB_WORKSPACE. When the path is inside $REVIEW_HEAD_DIR or
#     $REVIEW_INPUT_DIR, whose .git is a pointer file with no token and which
#     holds only a diff, any glob that passes the character allowlist is
#     accepted. The rule: ripgrep's last matching glob wins, so a glob
#     reopens .git when it can match the .git directory itself. After Claude
#     Code's split on commas (a part holding a brace group is kept whole), a
#     part that starts with ! is an exclusion to ripgrep and only removes
#     files, so it passes from any path (!web/**, !{a,b}); a ! anywhere else
#     is a literal character to ripgrep, measured with rg 13.0.0 and Claude
#     Code's rg 14.1.1, and is refused in a part split off (a/!b, x,a/!b),
#     while a glob kept whole that holds one ({a/**,!b/**}) is judged with
#     each brace expansion a positive glob naming that literal ! (unless the
#     glob itself starts with !) and only warned about. Every other part and brace expansion
#     must have no .. segment and is judged whole, as ripgrep matches it: with
#     no / (a trailing / aside) against the name .git, and with a / against .git's
#     path, which is .git from the workspace and, from a root above it, also
#     its path from there (repo/.git). A glob with a / that names .git on the
#     way to a path inside it (.git/config, **/.git/**) is refused as well.
#     Matching ignores letter case. So *gitignore*, {.gitignore,composer.json},
#     {scripts/*,web/modules/custom/**}, */x.php and src/** pass, and *, **,
#     **/*, .g*, */ and **/.git do not; from above the workspace repo/* and
#     */* do not either; !web/**,* does not, for its * part.
#     A part kept whole that also has a comma outside its braces
#     ({a,b}/**,c/**) reaches ripgrep as one glob in which that comma is a
#     literal character, so it may match nothing the agent meant. It is not
#     refused for that: it is judged by these rules as ripgrep reads it, its
#     brace expansions with the comma in place, and when it passes the check
#     prints a warning line naming the call (on stderr, like every other line)
#     and does not fail. A glob kept whole with a ! after its first character
#     gets its own warning line, for a ! ripgrep reads as a literal character.
#
# One Read outside the roots is reported instead of refused: a denied read of
# the tool result Claude Code saved for an earlier call. Claude Code saves a
# result over its size limit (20,000 characters for Grep) to
# <config home>/projects/<project>/<session>/tool-results/<tool_use id>.txt,
# where the config home is $CLAUDE_CONFIG_DIR when set and $HOME/.claude
# otherwise, and tells the agent "Full output saved to: <path>"; the deny
# rules on $HOME's dot-folders then refuse the agent's Read of it before
# anything is read. It is reported only when the file_path has exactly that shape (path
# allowlist, no ..), the id is an earlier tool_use in the trace whose
# top-level tool_result has a line ending "Full output saved to: <this path>",
# and this Read's own top-level tool_result is an error whose text is exactly
# Claude Code 2.1.309's "<tool_use_error>File is in a directory that is
# denied by your permission settings.</tool_use_error>". It is printed by
# call number; Glob and Grep get no such exception.
#
# A Glob or Grep with no path searches the working directory and is allowed. A
# Read with no file_path, and any of these fields present but empty, is
# refused. Nothing is resolved on disk, so a symlink is not followed here; the
# head's are replaced before any agent runs, and the workspace is the trusted
# checkout of main. A refusal names the tool, the call's position, the
# rule that refused it as a fixed label and, when the field is one of the
# tool's own, its name; never a value, path, glob or pattern, and never an
# unknown key's name: the job log is public and those are agent-written text.
# A call that breaks several rules gets the first label in the order checked:
# input shape, field set, Grep glob, path, Glob pattern.
#
# Fails closed: a missing, empty or unreadable trace, or no workspace to compare
# against, exits non-zero. The caller decides whether an absent trace means
# there is nothing to check.
#
# With no options it checks the review agents exactly as described above. The
# security audit's agents also write and delegate, so three options widen it
# for them, each still a closed set:
#
#   --tools <names>      comma-separated allowed tools, replacing Read,Glob,Grep.
#                        Only tools whose input fields are listed here may be
#                        named: Read, Glob, Grep, Write, Edit, the subagent
#                        tool under both of its names, Agent and Task, and
#                        SubagentHandback, the tool a foreground subagent
#                        hands its report back with.
#   --root <dir>         an absolute directory added to the read roots
#                        (repeatable). A Grep whose path lies in one outside the
#                        workspace is treated as the head and input directory
#                        are: its glob only has to pass the character allowlist.
#   --write-root <dir>   an absolute directory Write and Edit may write under
#                        (repeatable). With none, every Write and Edit is refused.
#   --grep-any-glob-in-subfolders
#                        a Grep whose path is a valid path inside the allowed
#                        roots, neither the workspace's top level nor a
#                        directory above it (an added root can be), takes any
#                        glob: the character allowlist takes ! anywhere,
#                        brace lists of folders pass, and the
#                        .git rule above is skipped. A glob with a ..
#                        segment is still refused. With no path, or with the
#                        workspace's top level or a directory above it as the
#                        path, the search reaches .git/config and the .git
#                        rule applies.
#                        A path under .git is refused by the path rule first.
#
# Their input fields, from the same schemas:
#
#   - Write: file_path, content.
#   - Edit: file_path, old_string, new_string, replace_all.
#   - Agent and Task: description, prompt, subagent_type, run_in_background.
#     A model field is refused with the rest, so a subagent cannot be given
#     another model through its call.
#   - SubagentHandback: exactly message, a non-empty string, and nothing else.
#     It names no file, so no path rule applies.
#
# A Write or Edit file_path passes the same character allowlist, must be
# absolute, must hold no .. segment even when it would normalise back inside,
# and must land under a write root and outside the workspace's .git. Content
# and the subagent tool's text fields are not paths and are not checked.
#
# Usage: check-trace-tools.sh <trace.json> [--tools <names>] [--root <dir>]...
#                             [--write-root <dir>]... [--grep-any-glob-in-subfolders]
#        GITHUB_WORKSPACE, REVIEW_HEAD_DIR, REVIEW_INPUT_DIR  the allowed roots
set -uo pipefail

usage () {
  echo "usage: check-trace-tools.sh <trace.json> [--tools <names>] [--root <dir>]... [--write-root <dir>]... [--grep-any-glob-in-subfolders]" >&2
  exit 2
}

TRACE="${1:-}"
[ -n "$TRACE" ] || usage
shift
# The tools whose input fields the path check below knows.
SUPPORTED=(Read Glob Grep Write Edit Agent Task SubagentHandback)
allowed_names=(Read Glob Grep)
extra_roots=()
write_roots=()
any_glob_in_subfolders=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tools)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      IFS=, read -r -a allowed_names <<<"$2"
      shift 2 ;;
    --root|--write-root)
      [ "$#" -ge 2 ] || usage
      case "$2" in /*) ;; *) echo "check-trace-tools: $1 must be an absolute directory" >&2; exit 2 ;; esac
      if [ "$1" = "--root" ]; then extra_roots+=("$2"); else write_roots+=("$2"); fi
      shift 2 ;;
    --grep-any-glob-in-subfolders)
      any_glob_in_subfolders=1
      shift ;;
    *) usage ;;
  esac
done
# Each name must equal a supported name as a whole.
for n in "${allowed_names[@]}"; do
  known=0
  for k in "${SUPPORTED[@]}"; do
    if [ "$n" = "$k" ]; then known=1; fi
  done
  if [ "$known" -eq 0 ]; then
    echo "check-trace-tools: --tools names a tool whose input fields are not checked here" >&2
    exit 2
  fi
done

# "Read, Glob and Grep" for the default list: the names joined for a message.
join_names () { # conjunction name...
  local conj="$1"; shift
  local out="" i
  for ((i = 1; i <= $#; i++)); do
    if [ "$i" -eq 1 ]; then out="${!i}"
    elif [ "$i" -eq $# ]; then out="$out $conj ${!i}"
    else out="$out, ${!i}"; fi
  done
  printf '%s' "$out"
}
ALLOWED_AND=$(join_names and "${allowed_names[@]}")
ALLOWED_OR=$(join_names or "${allowed_names[@]}")
ALLOWED=$(printf '%s\n' "${allowed_names[@]}" | jq -R . | jq -sc .)
ROOT_ARGS=$(jq -nc '$ARGS.positional' --args "${extra_roots[@]}")
WRITE_ROOT_ARGS=$(jq -nc '$ARGS.positional' --args "${write_roots[@]}")
# Claude Code's real tool names. The name in a trace is agent-written text, so
# only one of these (or the fixed <unnamed>) is ever printed.
KNOWN='["Read","Glob","Grep","Bash","Edit","Write","MultiEdit","NotebookEdit","WebFetch","WebSearch","Skill","Agent","Task","TodoWrite","ListAgents","ScheduleWakeup","Monitor","SendMessage","CronCreate","TaskCreate","AskUserQuestion","EnterPlanMode","ExitPlanMode","EnterWorktree","ToolSearch","<unnamed>"]'

[ -s "$TRACE" ] || {
  echo "check-trace-tools: no trace at '$TRACE', so the tools the agent used cannot be checked" >&2
  exit 1
}

calls=$(jq -r --argjson allowed "$ALLOWED" --argjson known "$KNOWN" '
  [.. | objects | select(.type? == "tool_use") | (.name // "<unnamed>") | tostring]
  | {total: length, outside: (map(select(. as $n | $allowed | index($n) | not)
      | if . as $n | $known | index($n) then . else "(unlisted name)" end) | unique)}
  | "\(.total) \(.outside | join(","))"' "$TRACE") || {
  echo "check-trace-tools: '$TRACE' is not readable JSON, so the tools the agent used cannot be checked" >&2
  exit 1
}

read -r total outside <<<"$calls"
if [ -n "${outside:-}" ]; then
  jq -r --argjson allowed "$ALLOWED" --argjson known "$KNOWN" '
    [.. | objects | select(.type? == "tool_use") | (.name // "<unnamed>") | tostring]
    | to_entries[] | select(.value as $n | $allowed | index($n) | not)
    | if .value as $n | $known | index($n)
      then "check-trace-tools: \(.value) call \(.key + 1): tool not allowed"
      else "check-trace-tools: call \(.key + 1): tool not allowed (unlisted name)" end' "$TRACE" >&2
  echo "check-trace-tools: the agent used a tool outside ${ALLOWED_AND}: ${outside}" >&2
  exit 1
fi

[ -n "${GITHUB_WORKSPACE:-}" ] || {
  echo "check-trace-tools: GITHUB_WORKSPACE is not set, so the paths the agent read cannot be checked" >&2
  exit 1
}

# Every path-bearing string in the trace, mapped to its brace expansions.
HERE="$(cd "$(dirname "$0")" && pwd)"
EXPANSIONS=$(mktemp)
trap 'rm -f "$EXPANSIONS"' EXIT
if ! jq -c '[.. | objects | select(.type? == "tool_use") | .input? | objects
      | (.file_path?, .path?, .pattern?, .glob?) | strings] | unique' "$TRACE" \
    | node "$HERE/expand-braces.cjs" > "$EXPANSIONS"; then
  echo "check-trace-tools: the brace groups in '$TRACE' could not be expanded" >&2
  exit 1
fi

outside_roots=$(python3 -I - "$TRACE" "$ROOT_ARGS" "$WRITE_ROOT_ARGS" "$any_glob_in_subfolders" "$EXPANSIONS" "$HERE" <<'PY'
import json, os, posixpath, re, sys

ws = posixpath.normpath(os.environ['GITHUB_WORKSPACE'])
git_dir = posixpath.join(ws, '.git')
extra_roots = [posixpath.normpath(r) for r in json.loads(sys.argv[2])]
write_roots = [posixpath.normpath(r) for r in json.loads(sys.argv[3])]
any_glob_in_subfolders = sys.argv[4] == '1'
EXPANDED = json.load(open(sys.argv[5]))
# Claude Code's own split of a Grep glob, shared with the ripgrep canary.
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[6])
from grep_glob_parts import parts as grep_parts
from glob_search_split import split as glob_search_split

def expansions(value):
    """The brace expansions of a path-bearing value, or None when they could
    not be computed with confidence (or the value was never expanded)."""
    e = EXPANDED.get(value) if isinstance(value, str) else None
    return e if isinstance(e, list) and all(isinstance(x, str) for x in e) else None
away_roots = [posixpath.normpath(os.environ[v])
              for v in ('REVIEW_HEAD_DIR', 'REVIEW_INPUT_DIR') if os.environ.get(v)]
roots = [ws] + away_roots + extra_roots

# Every containment decision is made twice: on the paths as spelled, and on
# their real paths on disk now (os.path.realpath), for the path, the
# workspace and every root. A link can put the checkout under a root spelled
# away from it, or a root spelled above it away from it, so a call passes
# only when it passes under both views.
class View:
    def __init__(self, f):
        self.f = f
        self.ws = f(ws)
        self.git_dir = posixpath.join(self.ws, '.git')
        self.roots = [f(r) for r in roots]
        self.away_roots = [f(r) for r in away_roots]
        self.extra_roots = [f(r) for r in extra_roots]
        self.write_roots = [f(r) for r in write_roots]
VIEWS = (View(lambda p: p), View(os.path.realpath))

# The input fields of each tool's schema in Claude Code 2.1.309, the version
# claude-code-action ae68417 installs. Anything else is refused, aliases
# included: Grep reads file_path as path, Read reads length as limit, and
# _host (an attached machine) exists only when remote tools are forwarded.
FIELDS = {
    'Read': {'file_path', 'offset', 'limit', 'pages', 'allow_large'},
    'Glob': {'pattern', 'path'},
    'Grep': {'pattern', 'path', 'glob', 'type', 'output_mode', '-B', '-A', '-C',
             'context', '-n', '-i', '-o', 'head_limit', 'offset', 'multiline'},
    'Write': {'file_path', 'content'},
    'Edit': {'file_path', 'old_string', 'new_string', 'replace_all'},
    'Agent': {'description', 'prompt', 'subagent_type', 'run_in_background'},
    'Task': {'description', 'prompt', 'subagent_type', 'run_in_background'},
    'SubagentHandback': {'message'},
}

def under(p, root):
    return p == root or p.startswith(root.rstrip('/') + '/')

# Matched against the raw value, before anything else, with fullmatch so a
# trailing newline cannot slip past $. ASCII only, no whitespace, no ~.
PATH_CHARS = re.compile(r'[A-Za-z0-9._/@+-]+')
GLOB_CHARS = re.compile(r'[A-Za-z0-9._/@+*{},-]+')
GLOB_BANG_CHARS = re.compile(r'[A-Za-z0-9._/@+*{},!-]+')

def path_ok(value):
    return isinstance(value, str) and PATH_CHARS.fullmatch(value) is not None

def glob_ok(value):
    return isinstance(value, str) and GLOB_CHARS.fullmatch(value) is not None

def resolve(p, base):
    """The path the tool would read, or None when it cannot be judged."""
    if p.startswith('~'):
        return None
    return posixpath.normpath(p if p.startswith('/') else posixpath.join(base, p))

# ripgrep's last matching glob wins, so a Grep glob overrides Claude Code's
# own !.git exclusion when it matches the .git directory itself. ripgrep
# matches an override glob as a gitignore line: a trailing / limits it to
# directories, a glob with no other / is matched against the file name at any
# depth, and a glob with a / (a leading one only anchors it) is matched against
# the path relative to ripgrep's working directory, the workspace, where * and
# a ** inside a segment stay within one segment and a whole ** segment spans
# any number of them. For a path outside the working directory, such as a
# search root above the workspace, it is matched against the file name. So
# each part and expansion is refused when it can match the name .git, or when
# it holds a / and can match .git's path: .git, and searched from above the
# workspace also its path from that root (repo/.git). A glob that matches only
# paths inside .git cannot reopen it, since ripgrep never enters an excluded
# directory, but one that names .git on the way (.git/config, **/.git/**) is
# refused too; a segment of only * characters names every directory and is
# judged by what follows it (*/x.php passes). Matching ignores letter case,
# which is stricter than ripgrep.
def _segment_matches(glob_seg, name):
    pattern = ''.join('[^/]*' if c == '*' else re.escape(c) for c in re.sub(r'\*+', '*', glob_seg))
    return re.fullmatch(pattern, name, re.IGNORECASE) is not None

def _path_matches(gsegs, psegs):
    """True when the glob segments can match exactly the path segments."""
    if not gsegs:
        return not psegs
    if gsegs[0] == '**':
        return (_path_matches(gsegs[1:], psegs)
                or (bool(psegs) and _path_matches(gsegs, psegs[1:])))
    return (bool(psegs) and _segment_matches(gsegs[0], psegs[0])
            and _path_matches(gsegs[1:], psegs[1:]))

def _names_below(gsegs, psegs, named=False):
    """True when the glob segments can match a path below the path segments
    (whose last is .git) with that last segment matched by a glob segment
    that names it: one that is not only * characters, so .git/config and
    **/.git/** count and */x.php does not."""
    if not psegs:
        return named and bool(gsegs)
    if not gsegs:
        return False
    last = len(psegs) == 1
    if gsegs[0] == '**':
        return (_names_below(gsegs[1:], psegs, named)
                or _names_below(gsegs, psegs[1:], False if last else named))
    if not _segment_matches(gsegs[0], psegs[0]):
        return False
    return _names_below(gsegs[1:], psegs[1:], set(gsegs[0]) != {'*'} if last else named)

def _matches_below(gsegs, psegs):
    """True when the glob segments can match some path strictly below the
    path segments."""
    if not psegs:
        return bool(gsegs)
    if not gsegs:
        return False
    if gsegs[0] == '**':
        return _matches_below(gsegs[1:], psegs) or _matches_below(gsegs, psegs[1:])
    return _segment_matches(gsegs[0], psegs[0]) and _matches_below(gsegs[1:], psegs[1:])

def can_reach_git(glob, targets, listed=False):
    """True when one ripgrep glob can match the checkout's .git: its name, or,
    for a glob holding a /, any of targets (paths of .git), or a path below
    one with .git itself named. With listed, nothing excludes .git from the
    walk (Claude Code's Glob), so a glob reaches it when it can match any
    path below a target, and a glob with no / matches names at any depth, so
    it reaches .git whenever there is a target at all."""
    g = glob.rstrip('/')
    if '/' not in g:
        if listed:
            return bool(targets)
        return g == '' or _segment_matches(g, '.git')
    segs = [x for x in g.split('/') if x]
    below = _matches_below if listed else _names_below
    return not segs or any(_path_matches(segs, t.split('/')) or below(segs, t.split('/'))
                           for t in targets)

def git_targets(path):
    """The paths of the workspace's .git that ripgrep may match a glob
    against for a Grep with this path: .git, and from a root above the
    workspace also .git's path from that root."""
    targets = {'.git'}
    # With the workspace behind a symlink, ripgrep's working directory (its
    # real path) differs from the target as spelled, so a glob is matched
    # against the target's absolute path: .git's absolute paths, spelled and
    # real, are targets too.
    # The same holds for a search root spelled through a symlink, whose
    # spelling of .git is a target too. From a root above the workspace,
    # .git's path from that root is judged in both views.
    real_ws = os.path.realpath(ws)
    absolute = {posixpath.join(w, '.git') for w in (ws, real_ws)}
    linked = real_ws != ws
    exps = expansions(path) if isinstance(path, str) else None
    for e in exps or []:
        spelled = resolve(e, ws)
        if spelled is None:
            continue
        real_root = os.path.realpath(spelled)
        if real_root != spelled:
            linked = True
            if under(real_ws, real_root):
                absolute.add(posixpath.normpath(posixpath.join(
                    spelled, posixpath.relpath(real_ws, real_root), '.git')))
        for v in VIEWS:
            root = v.f(spelled)
            if root != v.ws and under(v.ws, root):
                targets.add(posixpath.join(posixpath.relpath(v.ws, root), '.git'))
    if linked:
        targets |= {a.lstrip('/') for a in absolute}
    return targets

def grep_glob_chars_ok(value):
    """The Grep glob allowlist: the Glob pattern characters, and ! only as
    the first character of a part. ripgrep reads a glob that starts with ! as
    an exclusion, which can only remove files from the search; a ! anywhere
    else (inside a brace group, after a /) is a literal character to it, so a
    glob holding one would be judged as a positive glob naming a !, and is
    refused instead. The exception is a glob kept whole, which is warned
    about rather than refused: there a later ! is accepted as the literal
    character ripgrep reads it as, and grep_glob_allowed judges it so."""
    if not isinstance(value, str) or re.search(r'\s', value):
        return False
    parts = grep_parts(value)
    return bool(parts) and all(
        (GLOB_BANG_CHARS if kept_whole(t) else GLOB_CHARS).fullmatch(
            t[1:] if t.startswith('!') else t) is not None
        for t in parts)

def kept_whole(value):
    """True for a Grep glob Claude Code passes to ripgrep as one glob: it
    holds a brace group, so Claude Code does not split it on commas."""
    return grep_parts(value) == [value] and '{' in value and '}' in value

def bang_in_kept_whole(value):
    """True for a glob Claude Code keeps whole that holds a ! after its first
    character: ripgrep reads that ! as a literal character, so it excludes
    nothing. Such a glob is reported as a warning, not refused; the rules
    below judge it as ripgrep reads it."""
    return kept_whole(value) and '!' in value[1:]

def comma_outside_kept_braces(value):
    """True for a glob Claude Code keeps whole because it holds a brace group
    that also has a comma outside its braces (src/**/*.php,{web,docs}/**,
    !web/**,{a/**,z.php}): ripgrep reads that comma as a literal character,
    so the glob may match nothing the agent meant. Such a glob is reported
    as a warning, not refused; the rules below judge it as ripgrep reads it.
    A } before its { counts too."""
    if not kept_whole(value):
        return False
    depth = 0
    for ch in value:
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth < 0:
                return True
        elif ch == ',' and depth == 0:
            return True
    return False

def grep_glob_allowed(value, exps, path):
    """True when no part or expansion of a Grep glob can reopen the
    workspace's .git for a Grep with this path. A part that starts with !
    only excludes, so it passes, and so do its expansions, which all start
    with ! too; every other part is judged. A part kept whole is one glob to
    ripgrep, so an expansion of it that starts with ! ({!a,b},c gives !a,c)
    is a positive glob naming a literal !, and is judged unless the part
    itself starts with !."""
    if not grep_glob_chars_ok(value):
        return False
    targets = git_targets(path)
    kept = kept_whole(value)
    for t in grep_parts(value) + exps:
        if t.startswith('!') and (value.startswith('!') or not kept):
            continue
        if '..' in t.split('/') or can_reach_git(t, targets):
            return False
    return True

def grep_path_refusal(path):
    """The label for a Grep path the glob rule cannot judge, else None.
    ripgrep matches a glob against the path as written, so web/.. with
    web/** matches web/../.git/..., and it follows a symlinked folder, so a
    link to the checkout or above it puts .git under a path the rule judges
    as a subfolder. A raw .. segment is refused, and so is a path any
    existing component of which, below the allowed root that holds it, is a
    symlink on disk now. The root itself and its ancestors are not judged,
    so a runner whose workspace sits behind a symlink still works; a path
    in no root is judged whole."""
    if not isinstance(path, str):
        return None
    if '..' in path.split('/'):
        return ('Grep path holds a .. segment', 'path')
    # ripgrep matches a glob against the target as written, so the raw path
    # must be in normal form: no //, no . segment after the first, no
    # trailing /. (a leading ./ and a trailing / match as the plain path).
    if '//' in path or '/./' in path or path.endswith('/.'):
        return ('Grep path is not in normal form', 'path')
    for e in expansions(path) or [path]:
        p = resolve(e, ws)
        if p is not None and through_symlink(p):
            return ('Grep path passes through a symlink', 'path')
    return None

def through_symlink(p):
    """True when an existing component of the absolute path p, below the
    allowed root that holds it (the longest), is a symlink on disk now. The
    root itself and its ancestors are not judged; a path in no root is
    judged whole."""
    holders = [r for r in roots if under(p, r)]
    root = max(holders, key=len) if holders else '/'
    return os.path.realpath(p) != posixpath.normpath(
        posixpath.join(os.path.realpath(root), posixpath.relpath(p, root)))

# Claude Code 2.1.316 searches an absolute Glob pattern from its own split of
# it (glob_search_split.py) and ignores the call's path. It runs ripgrep
# --files --hidden --no-ignore in that folder with the rest as the glob and no
# exclusion of .git, so hidden files and .git are listed, and a glob with no
# / matches names at any depth.

def normal_absolute(p):
    """True for an absolute path in normal form: no empty, . or .. segment
    and no trailing /."""
    return p.startswith('/') and all(s not in ('', '.', '..') for s in p[1:].split('/'))

def listed_git_targets(base):
    """The paths of the workspace's .git that ripgrep may match a glob
    against when it lists base: none when .git is not below base in either
    view; otherwise .git's path from base in each view where base holds the
    workspace, .git itself (ripgrep run in the workspace strips it from a
    path) and .git's absolute paths, spelled and real (ripgrep matches a
    path outside its working directory whole)."""
    targets = set()
    for v in VIEWS:
        root = v.f(base)
        if under(v.ws, root):
            targets.add(posixpath.normpath(posixpath.join(posixpath.relpath(v.ws, root), '.git')))
    if targets:
        targets.add('.git')
        absolute = {posixpath.join(w, '.git') for w in (ws, os.path.realpath(ws))}
        real_ws, real_base = os.path.realpath(ws), os.path.realpath(base)
        if under(real_ws, real_base):
            # .git spelled through base, when a link makes base hold it.
            absolute.add(posixpath.normpath(posixpath.join(base, posixpath.relpath(real_ws, real_base), '.git')))
        targets |= {a.lstrip('/') for a in absolute}
    return targets

def absolute_glob_refusal(pattern, exps):
    """The label for an absolute Glob pattern the check refuses, else None.
    Every brace expansion must be a normal absolute path; the directory
    Claude Code searches, the same directory of each expansion and each
    expansion whole must be inside the roots and not under .git, in both
    views, and not pass through a symlink below their root; and the glob,
    expansion by expansion, must not be able to match .git or a path below
    it."""
    field = 'pattern'
    if not all(normal_absolute(e) for e in exps):
        return ('Glob pattern is absolute', field)
    base = glob_search_split(pattern)[0]
    dirs = [base] + [glob_search_split(e)[0] for e in exps]
    for p in dirs + exps:
        if under_git(p):
            return ('path under .git', field)
        if not inside(p):
            return ('path outside the allowed roots', field)
    if any(through_symlink(d) for d in dirs):
        return ('Glob pattern is absolute', field)
    targets = listed_git_targets(base)
    prefix = base.rstrip('/') + '/'
    if targets and any(can_reach_git(e[len(prefix):], targets, listed=True) for e in exps):
        return ('path under .git', field)
    return None

def inside(p):
    return p is not None and all(
        not under(v.f(p), v.git_dir) and any(under(v.f(p), r) for r in v.roots) for v in VIEWS)

def under_git(p):
    return p is not None and any(under(v.f(p), v.git_dir) for v in VIEWS)

def away_from_workspace(path):
    """True when a Grep path is a valid path inside the head or the input
    directory, so its search cannot reach the workspace's .git."""
    if not isinstance(path, str) or path_refusal('path', path, ws):
        return False
    exps = expansions(path)
    if not exps:
        return False
    for v in VIEWS:
        # The head, the input directory and an added root count only where
        # they cannot reach the workspace, which a link can make them do.
        away = [r for r in v.away_roots + v.extra_roots if not under(r, v.ws) and not under(v.ws, r)]
        # Every brace expansion of the path must lie in one of them.
        if not all(any(under(v.f(resolve(e, ws)), r) for r in away) for e in exps):
            return False
    return True

def calls(node):
    if isinstance(node, dict):
        if node.get('type') == 'tool_use':
            yield node
        for v in node.values():
            yield from calls(v)
    elif isinstance(node, list):
        for v in node:
            yield from calls(v)

def path_refusal(field, value, base):
    """The label for a path-valued field the check refuses, else None."""
    if value is None or value == '':
        return ('empty field', field)
    if not isinstance(value, str):
        return ('field not a string', field)
    if value.startswith('~'):
        return ('path starts with ~', field)
    if not path_ok(value):
        return ('character outside the allowlist', field)
    exps = expansions(value)
    if exps is None:
        return ('braces cannot be expanded', field)
    for e in exps:
        if e.startswith('~'):
            return ('path starts with ~', field)
        resolved = resolve(e, base)
        if under_git(resolved):
            return ('path under .git', field)
        if not inside(resolved):
            return ('path outside the allowed roots', field)
    return None

def write_refusal(value):
    """The label for a Write or Edit file_path the check refuses, else None."""
    field = 'file_path'
    if value is None or value == '':
        return ('empty field', field)
    if not isinstance(value, str):
        return ('field not a string', field)
    if value.startswith('~'):
        return ('path starts with ~', field)
    if not path_ok(value):
        return ('character outside the allowlist', field)
    if not value.startswith('/'):
        return ('write path is relative', field)
    if '..' in value.split('/'):
        return ('write path contains ..', field)
    resolved = posixpath.normpath(value)
    if under_git(resolved):
        return ('path under .git', field)
    if not all(any(under(v.f(resolved), r) for r in v.write_roots) for v in VIEWS):
        return ('path outside the write roots', field)
    return None

def subfolder_search(path):
    """True when --grep-any-glob-in-subfolders is on and a Grep path is a
    valid path inside the roots that neither is nor contains the workspace's
    top level, whose search could reach .git/config."""
    if not any_glob_in_subfolders or not isinstance(path, str):
        return False
    if path_refusal('path', path, ws):
        return False
    # A path through a symlink can open the checkout's top level or above it,
    # so it is judged by the glob rule, which refuses it.
    if grep_path_refusal(path):
        return False
    # Every brace expansion of the path must be such a folder.
    exps = expansions(path)
    return bool(exps) and all(not under(v.ws, v.f(resolve(e, ws))) for e in exps for v in VIEWS)

# The warnings for a Grep glob kept whole with a comma outside its braces,
# and for one kept whole with a ! after its first character.
KEPT_COMMA_WARNING = ('glob holds a brace group and a comma outside it, so ripgrep reads it as one '
                      'pattern and it may match nothing (warning)')
KEPT_BANG_WARNING = ("glob is kept whole and holds '!' after its first character, which ripgrep reads "
                     'as a literal character, so it excludes nothing (warning)')
# A kept-whole glob that starts with ! is an exclusion, so only its later !
# is called literal.
KEPT_NEGATED_BANG_WARNING = ("glob is kept whole, starts with '!' and holds another '!' after it, which "
                             'ripgrep reads as a literal character (warning)')

def refusal(call):
    """(refusal, warnings): the refusal is (label, field or None) for the
    first rule that refuses the call, else None; the warnings, for a Grep
    that is not refused, are KEPT_COMMA_WARNING when its glob is kept whole
    with a comma outside its braces and KEPT_BANG_WARNING (or, for a glob
    that starts with !, KEPT_NEGATED_BANG_WARNING) when it is kept whole
    with a ! after its first character, in that order."""
    r = first_refusal(call)
    args = call.get('input')
    g = args.get('glob') if call.get('name') == 'Grep' and isinstance(args, dict) else None
    if r is not None or not isinstance(g, str):
        return r, []
    return r, [w for w, on in ((KEPT_COMMA_WARNING, comma_outside_kept_braces(g)),
                               (KEPT_NEGATED_BANG_WARNING if g.startswith('!') else KEPT_BANG_WARNING,
                                bang_in_kept_whole(g))) if on]

def first_refusal(call):
    """(label, field or None) for the first rule that refuses the call, else None.
    A field name is returned only when it is in the tool's own field set."""
    name, args = call.get('name'), call.get('input')
    if name not in FIELDS:
        return None  # any other name was refused by the name check above
    if not isinstance(args, dict):
        return ('input not an object', None)
    if not set(args) <= FIELDS[name]:
        return ('unknown field', None)
    if name == 'Read':
        return path_refusal('file_path', args.get('file_path'), ws)
    if name in ('Write', 'Edit'):
        return write_refusal(args.get('file_path'))
    if name in ('Agent', 'Task'):
        return None
    if name == 'SubagentHandback':
        if args.get('message') is None or args.get('message') == '':
            return ('empty field', 'message')
        if not isinstance(args['message'], str):
            return ('field not a string', 'message')
        return None
    if name == 'Grep' and 'glob' in args and args['glob'] is not None:
        g = args['glob']
        if g == '':
            return ('empty field', 'glob')
        if not isinstance(g, str):
            return ('field not a string', 'glob')
        subfolder = subfolder_search(args.get('path'))
        # The character allowlist depends on the mode; the refusals after it
        # apply in every mode.
        if not (GLOB_BANG_CHARS.fullmatch(g) is not None if subfolder else grep_glob_chars_ok(g)):
            return ('character outside the allowlist', 'glob')
        if '..' in re.split(r'[/{},!]', g):
            return ('Grep glob holds a .. segment', 'glob')
        exps = expansions(g)
        if exps is None:
            return ('braces cannot be expanded', 'glob')
        if any('..' in re.split(r'[/{},!]', e) for e in exps):
            return ('Grep glob holds a .. segment', 'glob')
        if not subfolder:
            if not away_from_workspace(args.get('path')):
                if not grep_glob_allowed(g, exps, args.get('path')):
                    return ('Grep glob can reach .git', 'glob')
                # A path outside every root is refused as such before the
                # .. and symlink checks.
                p = args.get('path')
                r = (path_refusal('path', p, ws) if p is not None else None) or grep_path_refusal(p)
                if r:
                    return r
    path = args.get('path')
    if path is None:
        base = ws
    else:
        r = path_refusal('path', path, ws)
        if r:
            return r
        base = resolve(path, ws)
    if name == 'Glob' and 'pattern' in args:
        pattern = args['pattern']
        if pattern == '':
            return ('empty field', 'pattern')
        if not isinstance(pattern, str):
            return ('field not a string', 'pattern')
        if not glob_ok(pattern):
            return ('character outside the allowlist', 'pattern')
        exps = expansions(pattern)
        if exps is None:
            return ('braces cannot be expanded', 'pattern')
        if pattern.startswith('/'):
            return absolute_glob_refusal(pattern, exps)
        for e in exps:
            if e.startswith('/'):
                return ('Glob pattern is absolute', 'pattern')
            resolved = resolve(e, base)
            if under_git(resolved):
                return ('path under .git', 'pattern')
            if not inside(resolved):
                return ('path outside the allowed roots', 'pattern')
    return None

# Claude Code saves a tool result over its size limit to
# <config home>/projects/<project>/<session>/tool-results/<tool_use id>.txt
# and tells the agent "Full output saved to: <path>". The audit's deny rules
# cover $HOME's dot-folders, so an agent's Read of that file is denied before
# anything is read. Such a Read is reported instead of refused, and only when
# the path has exactly that shape under the config home ($CLAUDE_CONFIG_DIR
# when set, else $HOME/.claude), it names a tool_use
# earlier in the trace whose top-level tool_result says "Full output saved
# to: <this path>" on a line, and this Read's own top-level tool_result is
# Claude Code's deny error. Any other Read outside the roots is refused.
# Claude Code's config home: $CLAUDE_CONFIG_DIR when set, else $HOME/.claude.
# A relative CLAUDE_CONFIG_DIR cannot be placed, so no Read is excused.
_config_dir = os.environ.get('CLAUDE_CONFIG_DIR') or ''
CONFIG_HOME = (posixpath.normpath(_config_dir) if _config_dir.startswith('/') else None) if _config_dir \
    else posixpath.normpath(os.environ.get('HOME') or '/nonexistent') + '/.claude'
SAVED = re.compile(r'([^/]+)/([^/]+)/tool-results/(toolu_[A-Za-z0-9_-]+)\.txt')
# Claude Code 2.1.309's Read tool returns this message, wrapped as a
# tool_use_error, when a Read deny rule matches.
DENIED = '<tool_use_error>File is in a directory that is denied by your permission settings.</tool_use_error>'

def top_results(node):
    """{tool_use_id: [tool_result]} from the trace's top-level messages only."""
    found = {}
    for m in node if isinstance(node, list) else []:
        body = m.get('message') if isinstance(m, dict) and m.get('type') == 'user' else None
        content = body.get('content') if isinstance(body, dict) else None
        for r in content if isinstance(content, list) else []:
            if isinstance(r, dict) and r.get('type') == 'tool_result' and isinstance(r.get('tool_use_id'), str):
                found.setdefault(r['tool_use_id'], []).append(r)
    return found

def result_text(r):
    c = r.get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list) and all(isinstance(b, dict) and b.get('type') == 'text' and isinstance(b.get('text'), str)
                                   for b in c):
        return '\n'.join(b['text'] for b in c)
    return None

def denied_saved_output(call, earlier, results):
    """True for a Read refused only for its path that is a denied read of a
    tool result Claude Code saved for an earlier call in this trace."""
    args = call.get('input')
    fp = args.get('file_path') if isinstance(args, dict) else None
    if call.get('name') != 'Read' or not path_ok(fp) or '..' in fp.split('/'):
        return False
    if CONFIG_HOME is None:
        return False
    prefix = CONFIG_HOME + '/projects/'
    m = SAVED.fullmatch(fp[len(prefix):]) if fp.startswith(prefix) else None
    if m is None or {m.group(1), m.group(2)} & {'.', '..'} or m.group(3) not in earlier:
        return False
    marker = 'Full output saved to: ' + fp
    if not any(t is not None and any(line.endswith(marker) for line in t.split('\n'))
               for t in (result_text(r) for r in results.get(m.group(3), []))):
        return False
    own = results.get(call.get('id')) if isinstance(call.get('id'), str) else None
    return bool(own) and all(r.get('is_error') is True and (result_text(r) or '').strip() == DENIED for r in own)

trace = json.load(open(sys.argv[1]))
results = top_results(trace)
earlier = set()
refused = []
for i, c in enumerate(calls(trace), 1):
    r, warnings = refusal(c)
    if r and r[0] == 'path outside the allowed roots' and denied_saved_output(c, earlier, results):
        print(f"check-trace-tools: Read call {i}: a denied read of the tool result Claude Code saved for an "
              "earlier call; reported, not refused", file=sys.stderr)
        r = None
    if isinstance(c.get('id'), str):
        earlier.add(c['id'])
    if r:
        refused.append(f"{c.get('name')} call {i}")
        label, field = r
        print(f"check-trace-tools: {c.get('name')} call {i}: {label}"
              + (f" (field {field})" if field else ''), file=sys.stderr)
    else:
        # On stderr like every other line: stdout carries only the refused calls.
        for warning in warnings:
            print(f"check-trace-tools: Grep call {i}: {warning}", file=sys.stderr)
print(', '.join(refused))
PY
) || {
  echo "check-trace-tools: the paths in '$TRACE' could not be checked" >&2
  exit 1
}
if [ -n "$outside_roots" ]; then
  echo "check-trace-tools: the agent called ${ALLOWED_OR} with a field outside that tool's input fields, a path outside the allowed roots (the workspace except .git, the head, the input directory, any added root), a write outside the write roots, or a character outside the allowlist: ${outside_roots}" >&2
  exit 1
fi
echo "check-trace-tools: ${total} tool call(s), all ${ALLOWED_OR}, all inside the allowed roots"
