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
# with plain files. This check covers, lexically:
#
#   - Read's file_path, and Glob's and Grep's path, trimmed of surrounding
#     whitespace as Claude Code trims them, refused when they start with ~
#     (Claude Code expands it to the home directory), resolved against the
#     workspace when relative and normalised, so a .. that climbs out is
#     caught. They must land in $GITHUB_WORKSPACE but not its .git, in
#     $REVIEW_HEAD_DIR or in $REVIEW_INPUT_DIR (each when set).
#   - A Glob pattern, treated the same way and resolved against its path.
#   - A Grep glob, split on whitespace and then on commas outside braces, as
#     Claude Code splits it. A user glob is passed to ripgrep after Claude
#     Code's own !.git exclusion and overrides it, so each part must end in a
#     literal file extension (*.php, *.{php,module}, src/**/*.ts) and must not
#     name .git.
#
# A Glob or Grep with no path searches the working directory and is allowed. A
# Read with no file_path is refused. Nothing is resolved on disk, so a symlink
# is not followed here; the head's are replaced before any agent runs, and the
# workspace is the trusted checkout of main. A refusal names the tool and the
# call's position, never the path: the job log is public and the path is
# agent-written text.
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

def resolve(p, base):
    """The path the tool would read, or None when it cannot be judged."""
    p = p.strip()
    if p.startswith('~'):
        return None
    return posixpath.normpath(p if p.startswith('/') else posixpath.join(base, p))

EXTENSION_GLOB = re.compile(r'^!?\S*\.(\w+|\{\w+(,\w+)*\})$')

def grep_glob_allowed(value):
    if not isinstance(value, str):
        return False
    parts = []
    for token in value.split():
        if '{' in token and '}' in token:
            parts.append(token)
        else:
            parts.extend(t for t in token.split(',') if t)
    return all(EXTENSION_GLOB.match(t) and '.git' not in t.lower() for t in parts)

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
        return isinstance(fp, str) and fp.strip() != '' and inside(resolve(fp, ws))
    if name in ('Glob', 'Grep'):
        path = args.get('path')
        if name == 'Grep' and args.get('glob') not in (None, '') \
                and not grep_glob_allowed(args.get('glob')):
            return False
        if path is None or (isinstance(path, str) and path.strip() == ''):
            base = ws
        elif isinstance(path, str):
            base = resolve(path, ws)
            if not inside(base):
                return False
        else:
            return False
        pattern = args.get('pattern')
        if name == 'Glob' and isinstance(pattern, str) and pattern.strip():
            return inside(resolve(pattern, base))
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
  echo "check-trace-tools: the agent used a path outside the allowed roots (the workspace except .git, the head, the input directory): ${outside_roots}" >&2
  exit 1
fi
echo "check-trace-tools: ${total} tool call(s), all Read, Glob or Grep, all inside the allowed roots"
