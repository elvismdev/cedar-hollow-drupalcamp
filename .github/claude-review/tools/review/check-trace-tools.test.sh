#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
C="$ROOT/tools/review/check-trace-tools.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

run () { bash "$C" "$@" 2>&1; }
rc  () { bash "$C" "$@" >/dev/null 2>&1; echo $?; }

# The roots the agents may read: the workspace without its .git, the head and
# the input directory. Paths only; nothing is resolved on disk.
export GITHUB_WORKSPACE=/w/repo
export REVIEW_HEAD_DIR=/rt/head
export REVIEW_INPUT_DIR=/rt/review-input

# A call shaped as claude-code-action's execution file records it.
# Usage: call <name> [input-json]
call () { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t%s","name":"%s","input":%s}]}}' "$RANDOM" "$1" "${2:-{\}}"; }

# The allowed tools pass, and the count says the check read something.
printf '[{"type":"system","subtype":"init","tools":["Read","Bash"]},%s,%s,%s]' \
  "$(call Read '{"file_path":"/w/repo/REVIEW.md"}')" "$(call Glob '{"pattern":"**/*.php"}')" "$(call Grep '{"pattern":"x"}')" > "$tmp/ok.json"
assert_eq "0" "$(rc "$tmp/ok.json")" "Read, Glob and Grep pass"
assert_contains "$(run "$tmp/ok.json")" "3 tool call(s)" "and the calls are counted"

# A tool listed as available but never called is not a violation: the init
# message lists Bash above, and it passed.

# Any other tool fails and is named.
printf '[%s,%s]' "$(call Read '{"file_path":"/w/repo/a"}')" "$(call Bash)" > "$tmp/bash.json"
assert_eq "1" "$(rc "$tmp/bash.json")" "a Bash call fails"
assert_contains "$(run "$tmp/bash.json")" ": Bash" "and names the tool"

# Every outside name is reported, once each.
printf '[%s,%s,%s]' "$(call Write)" "$(call WebFetch)" "$(call Write)" > "$tmp/two.json"
assert_contains "$(run "$tmp/two.json")" ": WebFetch,Write" "every outside tool is named once"

# An MCP tool is outside the list too.
printf '[%s]' "$(call mcp__github__create_issue)" > "$tmp/mcp.json"
assert_eq "1" "$(rc "$tmp/mcp.json")" "an MCP tool fails"

# A call nested anywhere counts, not only at the message level.
printf '[{"type":"user","wrapper":{"deep":[{"type":"tool_use","name":"Edit"}]}}]' > "$tmp/nested.json"
assert_eq "1" "$(rc "$tmp/nested.json")" "a nested call is found"

# A call with no name cannot be shown to be allowed.
printf '[{"type":"tool_use","id":"x"}]' > "$tmp/unnamed.json"
assert_contains "$(run "$tmp/unnamed.json")" "<unnamed>" "an unnamed call fails and says so"

# No calls at all is a clean trace.
printf '[{"type":"assistant","message":{"content":[{"type":"text","text":"[]"}]}}]' > "$tmp/none.json"
assert_eq "0" "$(rc "$tmp/none.json")" "a trace with no tool calls passes"

# Paths. Every Read, Glob and Grep must stay inside the allowed roots, because
# claude-code-action writes a write-capable token into the workspace's
# .git/config, and /proc and the runner's other directories hold more.
ok_path () { printf '[%s]' "$(call "$1" "$2")" > "$tmp/p.json"; assert_eq "0" "$(rc "$tmp/p.json")" "$3"; }
no_path () { printf '[%s]' "$(call "$1" "$2")" > "$tmp/p.json"; assert_eq "1" "$(rc "$tmp/p.json")" "$3"; assert_contains "$(run "$tmp/p.json")" "outside the allowed roots" "$3 says why"; }

ok_path Read '{"file_path":"/w/repo/web/index.php"}' "a read in the workspace passes"
ok_path Read '{"file_path":"web/index.php"}' "a relative read resolves against the workspace"
ok_path Read '{"file_path":"/rt/head/web/index.php"}' "a read in the head passes"
ok_path Read '{"file_path":"/rt/review-input/review-diff.patch"}' "a read in the input directory passes"
ok_path Grep '{"pattern":"token","path":"/rt/head/web"}' "a Grep in the head passes"
ok_path Glob '{"pattern":"**/*.yml","path":"/rt/head"}' "a Glob in the head passes"
ok_path Read '{"file_path":"/w/repo/.github/x/../../REVIEW.md"}' "a .. that stays inside passes"
ok_path Read '{"file_path":"/w/repo/.gitignore"}' "a name that only starts with .git passes"

no_path Read '{"file_path":"/w/repo/.git/config"}' "a read of .git/config is refused"
no_path Read '{"file_path":".git/config"}' "a relative read of .git/config is refused"
no_path Read '{"file_path":"/proc/self/environ"}' "a read of /proc/self/environ is refused"
no_path Read '{"file_path":"/rt/other"}' "a read elsewhere in the runner's temporary directory is refused"
no_path Read '{"file_path":"../x"}' "a relative ../x is refused"
no_path Read '{"file_path":"/rt/head/../other/x"}' "a .. that escapes the head is refused"
no_path Read '{"file_path":"/rt/head-other/x"}' "a sibling sharing the head's prefix is refused"
no_path Grep '{"pattern":"token","path":".git"}' "a Grep with path .git is refused"
no_path Glob '{"pattern":"/proc/*"}' "an absolute Glob pattern outside the roots is refused"
no_path Glob '{"pattern":"../../*"}' "a relative Glob pattern that climbs out is refused"
no_path Read '{}' "a Read with no file_path is refused"

# Characters. Claude Code trims and expands a path before reading it, and its
# trim (JavaScript's) removes more than any reimplementation can be shown to,
# U+FEFF among them. So nothing is normalised: a path or glob must consist only
# of allowlisted ASCII characters as written, and anything else is refused.
no_path Read '{"file_path":"~/work/repo/repo/.git/config"}' "a ~ path is refused"
no_path Grep '{"pattern":"x","path":"~"}' "a Grep path of ~ is refused"
no_path Read '{"file_path":" /w/repo/.git/config"}' "a path with a leading space is refused"
no_path Grep '{"pattern":"x","path":" /proc/self"}' "a Grep path with a leading space is refused"
no_path Read '{"file_path":"﻿/proc/self/environ"}' "a Read with a leading U+FEFF is refused"
no_path Grep '{"pattern":"x","path":"﻿/proc/self"}' "a Grep path with a leading U+FEFF is refused"
no_path Glob '{"pattern":"﻿/proc/*"}' "a Glob pattern with a leading U+FEFF is refused"
no_path Grep '{"pattern":"x","glob":"**﻿*.php"}' "a Grep glob containing U+FEFF is refused"
no_path Read "{\"file_path\":\"$(printf '\xef\xbb\xbf')/proc/self/environ\"}" "a raw UTF-8 U+FEFF is refused too"
no_path Read '{"file_path":"/w/repo/REVIEW.md "}' "a trailing space is refused"
no_path Read '{"file_path":"/w/repo/REVIEW.md\t"}' "a tab is refused"
no_path Read '{"file_path":"/w/repo/REVIEW.md\n"}' "a newline is refused"
no_path Read '{"file_path":"/w/repo/café.php"}' "a non-ASCII letter is refused"
no_path Read '{"file_path":"/w/repo/a b.php"}' "a path with a space in it is refused"
no_path Read '{"file_path":""}' "an empty file_path is refused"
no_path Grep '{"pattern":"x","path":""}' "an empty Grep path is refused"
no_path Glob '{"pattern":"**/*.php","path":""}' "an empty Glob path is refused"
no_path Glob '{"pattern":""}' "an empty Glob pattern is refused"
no_path Grep '{"pattern":"x","path":"/w/repo/*"}' "a wildcard in a Grep path is refused"
ok_path Read '{"file_path":"/w/repo/web/themes/custom/cedar_hollow/package.json"}' "a real repository path passes"
ok_path Read '{"file_path":"/rt/head/web/modules/custom/cedar_hollow_core/cedar_hollow_core.routing.yml"}' "a real head path passes"
ok_path Read '{"file_path":"/w/repo/node_modules/@scope/pkg+x/a-b.js"}' "@, + and - are allowed"

# A Grep glob overrides Claude Code's own exclusion of .git in ripgrep, because
# a later glob wins. Only a glob that ends in a file extension is allowed, after
# the same split on commas that Claude Code applies.
no_path Grep '{"pattern":"x","glob":"**"}' "a Grep glob of ** is refused"
no_path Grep '{"pattern":"x","glob":"*"}' "a Grep glob of * is refused"
no_path Grep '{"pattern":"x","glob":"**,*.php"}' "a comma-joined ** is refused"
no_path Grep '{"pattern":"x","glob":"*.php **"}' "a space-joined ** is refused (a space is outside the allowlist)"
no_path Grep '{"pattern":"x","glob":".git/**"}' "a glob naming .git is refused"
no_path Grep '{"pattern":"x","glob":"*.{php,*}"}' "a brace group with a wildcard is refused"
ok_path Grep '{"pattern":"x","glob":"*.php"}' "a Grep glob *.php passes"
ok_path Grep '{"pattern":"x","glob":"*.{php,module}"}' "a Grep glob *.{php,module} passes"
ok_path Grep '{"pattern":"x","glob":"src/**/*.ts"}' "a Grep glob src/**/*.ts passes"
ok_path Grep '{"pattern":"x","glob":"*.php,*.inc"}' "comma-separated extension globs pass"
no_path Grep '{"pattern":"x","glob":""}' "an empty Grep glob is refused"
no_path Grep '{"pattern":"x","glob":"!*.php"}' "a ! outside the allowlist is refused"

# Without the head and input directories set, only the workspace is allowed.
printf '[%s]' "$(call Read '{"file_path":"/rt/head/a"}')" > "$tmp/p.json"
assert_eq "1" "$(REVIEW_HEAD_DIR='' REVIEW_INPUT_DIR='' rc "$tmp/p.json")" "an unset head directory is not a root"

# With no workspace there is nothing to compare against, so it fails closed.
printf '[%s]' "$(call Read '{"file_path":"/w/repo/a"}')" > "$tmp/p.json"
assert_eq "1" "$(GITHUB_WORKSPACE='' rc "$tmp/p.json")" "an unset workspace fails closed"

# It fails closed on what it cannot read.
assert_eq "1" "$(rc "$tmp/absent.json")" "a missing trace fails"
: > "$tmp/empty.json"
assert_eq "1" "$(rc "$tmp/empty.json")" "an empty trace fails"
printf 'not json' > "$tmp/bad.json"
assert_eq "1" "$(rc "$tmp/bad.json")" "an unreadable trace fails"
assert_contains "$(run "$tmp/bad.json")" "not readable JSON" "and says why"

pass
