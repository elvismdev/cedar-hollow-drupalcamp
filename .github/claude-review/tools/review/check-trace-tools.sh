#!/usr/bin/env bash
# Fail when an agent's execution trace shows a tool other than Read, Glob or
# Grep, or one of those three given a path outside the allowed roots.
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
# The paths those three tools were given are checked too, as a second layer:
# the review action keeps the workspace's .git, where claude-code-action would
# write its token, away while the agents run, and replaces the head's symlinks
# with plain files. The token is also in the agent process's environment,
# readable at /proc/self/environ, which only this check stands in front of.
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
#   - A Glob pattern: the same set plus * { } and comma, then resolved against
#     its path and held to the same roots.
#   - A Grep glob: the same set as a Glob pattern. Claude Code passes it to
#     ripgrep after its own !.git exclusion, where it overrides that exclusion,
#     so after Claude Code's split on commas (a part holding a brace group is
#     kept whole) each part must end in a literal file extension (*.php,
#     *.{php,module}, src/**/*.ts) and must not name .git.
#
# A Glob or Grep with no path searches the working directory and is allowed. A
# Read with no file_path, and any of these fields present but empty, is
# refused. Nothing is resolved on disk, so a symlink is not followed here; the
# head's are replaced before any agent runs, and the workspace is the trusted
# checkout of main. A refusal names the tool and the call's position, never the
# path: the job log is public and the path is agent-written text.
#
# Fails closed: a missing, empty or unreadable trace, or no workspace to compare
# against, exits non-zero. The caller decides whether an absent trace means
# there is nothing to check.
#
# Usage: check-trace-tools.sh <trace.json>
#        GITHUB_WORKSPACE, REVIEW_HEAD_DIR, REVIEW_INPUT_DIR  the allowed roots
set -uo pipefail

TRACE="${1:?usage: check-trace-tools.sh <trace.json>}"
ALLOWED='["Read","Glob","Grep"]'

[ -s "$TRACE" ] || {
  echo "check-trace-tools: no trace at '$TRACE', so the tools the agent used cannot be checked" >&2
  exit 1
}

calls=$(jq -r --argjson allowed "$ALLOWED" '
  [.. | objects | select(.type? == "tool_use") | (.name // "<unnamed>") | tostring]
  | {total: length, outside: (unique | map(select(. as $n | $allowed | index($n) | not)))}
  | "\(.total) \(.outside | join(","))"' "$TRACE") || {
  echo "check-trace-tools: '$TRACE' is not readable JSON, so the tools the agent used cannot be checked" >&2
  exit 1
}

read -r total outside <<<"$calls"
if [ -n "${outside:-}" ]; then
  echo "check-trace-tools: the agent used a tool outside Read, Glob and Grep: ${outside}" >&2
  exit 1
fi

[ -n "${GITHUB_WORKSPACE:-}" ] || {
  echo "check-trace-tools: GITHUB_WORKSPACE is not set, so the paths the agent read cannot be checked" >&2
  exit 1
}

outside_roots=$(python3 -I - "$TRACE" <<'PY'
import json, os, posixpath, re, sys

ws = posixpath.normpath(os.environ['GITHUB_WORKSPACE'])
git_dir = posixpath.join(ws, '.git')
roots = [ws] + [posixpath.normpath(os.environ[v])
                for v in ('REVIEW_HEAD_DIR', 'REVIEW_INPUT_DIR') if os.environ.get(v)]

def under(p, root):
    return p == root or p.startswith(root.rstrip('/') + '/')

# Matched against the raw value, before anything else, with fullmatch so a
# trailing newline cannot slip past $. ASCII only, no whitespace, no ~.
PATH_CHARS = re.compile(r'[A-Za-z0-9._/@+-]+')
GLOB_CHARS = re.compile(r'[A-Za-z0-9._/@+*{},-]+')

def path_ok(value):
    return isinstance(value, str) and PATH_CHARS.fullmatch(value) is not None

def glob_ok(value):
    return isinstance(value, str) and GLOB_CHARS.fullmatch(value) is not None

def resolve(p, base):
    """The path the tool would read, or None when it cannot be judged."""
    if p.startswith('~'):
        return None
    return posixpath.normpath(p if p.startswith('/') else posixpath.join(base, p))

EXTENSION_GLOB = re.compile(r'[^{},]*\.([A-Za-z0-9]+|\{[A-Za-z0-9]+(,[A-Za-z0-9]+)*\})')

def grep_glob_allowed(value):
    if not glob_ok(value):
        return False
    # Claude Code splits on whitespace, which glob_ok has already refused, then
    # on commas unless a part holds a brace group.
    parts = [value] if '{' in value and '}' in value else [t for t in value.split(',') if t]
    return bool(parts) and all(EXTENSION_GLOB.fullmatch(t) and '.git' not in t.lower()
                               for t in parts)

def inside(p):
    return p is not None and not under(p, git_dir) and any(under(p, r) for r in roots)

def calls(node):
    if isinstance(node, dict):
        if node.get('type') == 'tool_use':
            yield node
        for v in node.values():
            yield from calls(v)
    elif isinstance(node, list):
        for v in node:
            yield from calls(v)

def allowed(call):
    name, args = call.get('name'), call.get('input')
    if not isinstance(args, dict):
        args = {}
    if name == 'Read':
        fp = args.get('file_path')
        return path_ok(fp) and inside(resolve(fp, ws))
    if name in ('Glob', 'Grep'):
        path = args.get('path')
        if name == 'Grep' and 'glob' in args and args['glob'] is not None \
                and not grep_glob_allowed(args['glob']):
            return False
        if path is None:
            base = ws
        elif path_ok(path):
            base = resolve(path, ws)
            if not inside(base):
                return False
        else:
            return False
        if name == 'Glob' and 'pattern' in args:
            pattern = args['pattern']
            return glob_ok(pattern) and inside(resolve(pattern, base))
        return True
    return True  # any other name was refused by the name check above

trace = json.load(open(sys.argv[1]))
print(', '.join(f"{c.get('name')} call {i}"
                for i, c in enumerate(calls(trace), 1) if not allowed(c)))
PY
) || {
  echo "check-trace-tools: the paths in '$TRACE' could not be checked" >&2
  exit 1
}
if [ -n "$outside_roots" ]; then
  echo "check-trace-tools: the agent used a path outside the allowed roots (the workspace except .git, the head, the input directory) or with a character outside the allowlist: ${outside_roots}" >&2
  exit 1
fi
echo "check-trace-tools: ${total} tool call(s), all Read, Glob or Grep, all inside the allowed roots"
