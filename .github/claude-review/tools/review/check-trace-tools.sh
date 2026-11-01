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
#   - A Glob pattern: the same set plus * { } and comma. It must be relative,
#     with no leading /, because Claude Code searches an absolute pattern from
#     its static prefix rather than from its path. It is then resolved against
#     its path, normalised for .. (a brace group's .. included, as segments),
#     and held to the same roots.
#   - A Grep glob: the same set as a Glob pattern, with no .. segment. Claude
#     Code passes it to ripgrep after its own !.git exclusion, where it
#     overrides that exclusion, which matters only where the search can reach
#     the workspace's .git/config. So the rule below applies when the Grep has
#     no path (it then searches the working directory, the workspace) or a path
#     inside $GITHUB_WORKSPACE. When the path is inside $REVIEW_HEAD_DIR or
#     $REVIEW_INPUT_DIR, whose .git is a pointer file with no token and which
#     holds only a diff, any glob that passes the character allowlist is
#     accepted. The rule: after Claude Code's split on commas (a part holding
#     a brace group is kept whole) each part must end in a literal file
#     extension or a brace group of extensions (*.php, *.{php,module},
#     src/**/*.ts). Its last segment may instead be a brace group of plain
#     names before that extension (**/{a,b}.php); a brace group anywhere
#     else, or one holding a wildcard, is refused. Every brace expansion must
#     pass the same rule, so each ends in a file extension. No part or
#     expansion may hold .git as a
#     whole path segment (.git, .git/..., .../.git, .../.git/..., in any
#     letter case); a name that only starts with .git, such as *.gitignore,
#     is not one.
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
#                        glob: the character allowlist gains !, so negated
#                        globs and brace lists of folders pass, and the
#                        extension-shaped rule is skipped. A glob with a ..
#                        segment is still refused. With no path, or with the
#                        workspace's top level as the path, the search reaches
#                        .git/config and the extension-shaped rule applies.
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

outside_roots=$(python3 -I - "$TRACE" "$ROOT_ARGS" "$WRITE_ROOT_ARGS" "$any_glob_in_subfolders" "$EXPANSIONS" <<'PY'
import json, os, posixpath, re, sys

ws = posixpath.normpath(os.environ['GITHUB_WORKSPACE'])
git_dir = posixpath.join(ws, '.git')
extra_roots = [posixpath.normpath(r) for r in json.loads(sys.argv[2])]
write_roots = [posixpath.normpath(r) for r in json.loads(sys.argv[3])]
any_glob_in_subfolders = sys.argv[4] == '1'
EXPANDED = json.load(open(sys.argv[5]))

def expansions(value):
    """The brace expansions of a path-bearing value, or None when they could
    not be computed with confidence (or the value was never expanded)."""
    e = EXPANDED.get(value) if isinstance(value, str) else None
    return e if isinstance(e, list) and all(isinstance(x, str) for x in e) else None
roots = [ws] + [posixpath.normpath(os.environ[v])
                for v in ('REVIEW_HEAD_DIR', 'REVIEW_INPUT_DIR') if os.environ.get(v)] + extra_roots

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
SUBFOLDER_GLOB_CHARS = re.compile(r'[A-Za-z0-9._/@+*{},!-]+')

def path_ok(value):
    return isinstance(value, str) and PATH_CHARS.fullmatch(value) is not None

def glob_ok(value):
    return isinstance(value, str) and GLOB_CHARS.fullmatch(value) is not None

def resolve(p, base):
    """The path the tool would read, or None when it cannot be judged."""
    if p.startswith('~'):
        return None
    return posixpath.normpath(p if p.startswith('/') else posixpath.join(base, p))

# A part ends in a file extension or a brace group of extensions. Its last
# segment may instead be a brace group of plain names before that extension
# (**/{a,b}.php); a brace group anywhere else is refused.
_EXT = r'\.([A-Za-z0-9]+|\{[A-Za-z0-9]+(,[A-Za-z0-9]+)*\})'
EXTENSION_GLOB = re.compile(r'[^{},]*' + _EXT
                            + r'|([^{},]*/)?\{[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*\}' + _EXT)

def grep_glob_allowed(value):
    if not glob_ok(value):
        return False
    # Claude Code splits on whitespace, which glob_ok has already refused, then
    # on commas unless a part holds a brace group.
    parts = [value] if '{' in value and '}' in value else [t for t in value.split(',') if t]
    return bool(parts) and all(EXTENSION_GLOB.fullmatch(t) and not git_segment(t) for t in parts)


def git_segment(value):
    """True when .git is a whole path segment of value, in any letter case:
    .git, .git/..., .../.git or .../.git/.... A name that only starts with
    .git, such as .gitignore, is not one."""
    return any(seg.lower() == '.git' for seg in value.split('/'))

def inside(p):
    return p is not None and not under(p, git_dir) and any(under(p, r) for r in roots)

def away_from_workspace(path):
    """True when a Grep path is a valid path inside the head or the input
    directory, so its search cannot reach the workspace's .git."""
    if not isinstance(path, str) or path_refusal('path', path, ws):
        return False
    away = [posixpath.normpath(os.environ[v])
            for v in ('REVIEW_HEAD_DIR', 'REVIEW_INPUT_DIR') if os.environ.get(v)]
    # An added root counts only where it cannot reach the workspace.
    away += [r for r in extra_roots if not under(r, ws) and not under(ws, r)]
    # Every brace expansion of the path must lie in one of them.
    exps = expansions(path)
    return bool(exps) and all(any(under(resolve(e, ws), r) for r in away) for e in exps)

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
        if resolved is not None and under(resolved, git_dir):
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
    if under(resolved, git_dir):
        return ('path under .git', field)
    if not any(under(resolved, r) for r in write_roots):
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
    # Every brace expansion of the path must be such a folder.
    exps = expansions(path)
    return bool(exps) and all(not under(ws, resolve(e, ws)) for e in exps)

def refusal(call):
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
        if subfolder_search(args.get('path')):
            if SUBFOLDER_GLOB_CHARS.fullmatch(g) is None:
                return ('character outside the allowlist', 'glob')
            if '..' in re.split(r'[/{},!]', g):
                return ('Grep glob is not extension-shaped', 'glob')
            exps = expansions(g)
            if exps is None:
                return ('braces cannot be expanded', 'glob')
            if any('..' in re.split(r'[/{},!]', e) for e in exps):
                return ('Grep glob is not extension-shaped', 'glob')
        else:
            if not glob_ok(g):
                return ('character outside the allowlist', 'glob')
            if '..' in re.split(r'[/{},]', g):
                return ('Grep glob is not extension-shaped', 'glob')
            exps = expansions(g)
            if exps is None:
                return ('braces cannot be expanded', 'glob')
            if any('..' in re.split(r'[/{},]', e) for e in exps):
                return ('Grep glob is not extension-shaped', 'glob')
            if not away_from_workspace(args.get('path')) and not (
                    grep_glob_allowed(g) and all(grep_glob_allowed(e) for e in exps)):
                return ('Grep glob is not extension-shaped', 'glob')
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
        # Relative only: Claude Code searches an absolute pattern from its
        # static prefix, which a brace group holding .. moves away from the
        # directory this check would compute.
        if pattern.startswith('/'):
            return ('Glob pattern is absolute', 'pattern')
        exps = expansions(pattern)
        if exps is None:
            return ('braces cannot be expanded', 'pattern')
        for e in exps:
            if e.startswith('/'):
                return ('Glob pattern is absolute', 'pattern')
            resolved = resolve(e, base)
            if resolved is not None and under(resolved, git_dir):
                return ('path under .git', 'pattern')
            if not inside(resolved):
                return ('path outside the allowed roots', 'pattern')
    return None

trace = json.load(open(sys.argv[1]))
refused = []
for i, c in enumerate(calls(trace), 1):
    r = refusal(c)
    if r:
        refused.append(f"{c.get('name')} call {i}")
        label, field = r
        print(f"check-trace-tools: {c.get('name')} call {i}: {label}"
              + (f" (field {field})" if field else ''), file=sys.stderr)
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
