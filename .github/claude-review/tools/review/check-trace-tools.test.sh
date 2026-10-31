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
ok_path Grep '{"pattern":"x","glob":"**/{a,b}.php"}' "a brace group of names before the extension passes after **/"
ok_path Grep '{"pattern":"x","glob":"{a,b}.php"}' "a brace group of names before the extension passes on its own"
ok_path Grep '{"pattern":"x","glob":"src/**/*.{php,module}"}' "a brace group of extensions passes after a directory"
no_path Grep '{"pattern":"x","glob":"**/{a,*}.php"}' "a wildcard in the names brace group is refused"
no_path Grep '{"pattern":"x","glob":"**/{..,a}.php"}' "a .. in the names brace group is refused"
no_path Grep '{"pattern":"x","glob":"{a,b}/x.php"}' "a brace group in a directory segment is refused"
no_path Grep '{"pattern":"x","glob":"**/{a,b}"}' "a brace group of names with no extension is refused"

# Closed input fields. Each tool's input may hold only the fields of its own
# schema in Claude Code 2.1.309. Claude Code reads aliases and stray fields
# (Grep reads file_path as path when path is absent), so any other key is
# refused rather than mirrored.
no_field () { printf '[%s]' "$(call "$1" "$2")" > "$tmp/p.json"; assert_eq "1" "$(rc "$tmp/p.json")" "$3"; assert_contains "$(run "$tmp/p.json")" "outside that tool's input fields" "$3 says why"; }
no_field Grep '{"pattern":"SECRET","output_mode":"content","file_path":"/proc/self/environ"}' "a Grep with file_path and no path is refused"
no_field Grep '{"pattern":"x","path":"/w/repo","file_path":"/proc/self/environ"}' "a Grep with file_path beside path is refused"
no_field Grep '{"pattern":"x","foo":"bar"}' "a Grep with an unknown key is refused"
no_field Read '{"file_path":"/w/repo/a","foo":1}' "a Read with an unknown key is refused"
no_field Read '{"file_path":"/w/repo/a","length":10}' "a Read with Claude Code's length alias is refused"
no_field Glob '{"pattern":"*.php","file_path":"/proc"}' "a Glob with file_path is refused"
no_field Grep '{"pattern":"x","_host":"other"}' "the attached-machine field is refused"
no_field Grep '{"pattern":"x","-r":true}' "a Grep with -r is refused"
printf '[{"type":"tool_use","name":"Grep","input":"/proc/self/environ"}]' > "$tmp/p.json"
assert_eq "1" "$(rc "$tmp/p.json")" "an input that is not an object is refused"
ok_path Read '{"file_path":"/w/repo/a.pdf","offset":1,"limit":20,"pages":"1-2","allow_large":false}' "every Read field passes"
ok_path Glob '{"pattern":"**/*.php","path":"/w/repo"}' "every Glob field passes"
ok_path Grep '{"pattern":"x","path":"/w/repo","glob":"*.php","type":"php","output_mode":"content","-B":1,"-A":1,"-C":1,"context":1,"-n":true,"-i":true,"-o":false,"head_limit":5,"offset":0,"multiline":false}' "every Grep field passes"

# A Glob pattern must be relative. Claude Code searches an absolute pattern from
# its static prefix, not from the path the check would compute, so a brace group
# holding .. made the check judge a different directory from the one listed.
no_path Glob '{"pattern":"/proc/self/{environ,x/../../../w/repo/y}"}' "an absolute Glob pattern with a brace group is refused"
no_path Glob '{"pattern":"/w/repo/**/*.php"}' "an absolute Glob pattern inside the workspace is refused"
no_path Glob '{"pattern":"/proc/self/{environ,x}"}' "an absolute Glob pattern /proc/self/{environ,x} is refused"
no_path Glob '{"pattern":"{..,x}/../../proc/*"}' "a relative Glob pattern climbing through a brace group is refused"

# Without the head and input directories set, only the workspace is allowed.
printf '[%s]' "$(call Read '{"file_path":"/rt/head/a"}')" > "$tmp/p.json"
assert_eq "1" "$(REVIEW_HEAD_DIR='' REVIEW_INPUT_DIR='' rc "$tmp/p.json")" "an unset head directory is not a root"

# With no workspace there is nothing to compare against, so it fails closed.
printf '[%s]' "$(call Read '{"file_path":"/w/repo/a"}')" > "$tmp/p.json"
assert_eq "1" "$(GITHUB_WORKSPACE='' rc "$tmp/p.json")" "an unset workspace fails closed"

# Each refusal names the tool, the call's position, the rule as a fixed label
# and, when it is one of the tool's own fields, that field's name.
label_is () { # name input-json expected-line message
  printf '[%s,%s]' "$(call Read '{"file_path":"/w/repo/a"}')" "$(call "$1" "$2")" > "$tmp/l.json"
  assert_contains "$(run "$tmp/l.json")" "check-trace-tools: $1 call 2: $3" "$4"
}
printf '[%s,%s]' "$(call Read '{"file_path":"/w/repo/a"}')" "$(call Bash)" > "$tmp/l.json"
assert_contains "$(run "$tmp/l.json")" "check-trace-tools: Bash call 2: tool not allowed" "label: tool not allowed"
printf '[%s,{"type":"tool_use","name":"Grep","input":"x"}]' "$(call Read '{"file_path":"/w/repo/a"}')" > "$tmp/l.json"
assert_contains "$(run "$tmp/l.json")" "check-trace-tools: Grep call 2: input not an object" "label: input not an object"
label_is Grep '{"pattern":"x","zzkey":1}' "unknown field" "label: unknown field"
case "$(run "$tmp/l.json")" in *zzkey*) echo "FAIL: key name printed" >&2; exit 1;; esac
label_is Read '{"file_path":7}' "field not a string (field file_path)" "label: field not a string"
label_is Read '{"file_path":"/w/repo/a b"}' "character outside the allowlist (field file_path)" "label: character, Read"
label_is Grep '{"pattern":"x","path":"a b"}' "character outside the allowlist (field path)" "label: character, path"
label_is Glob '{"pattern":"a b"}' "character outside the allowlist (field pattern)" "label: character, pattern"
label_is Grep '{"pattern":"x","glob":"a b"}' "character outside the allowlist (field glob)" "label: character, glob"
label_is Read '{"file_path":"/proc/self/environ"}' "path outside the allowed roots (field file_path)" "label: outside roots"
label_is Glob '{"pattern":"../../*"}' "path outside the allowed roots (field pattern)" "label: outside roots, pattern"
label_is Read '{"file_path":"/w/repo/.git/config"}' "path under .git (field file_path)" "label: under .git"
label_is Read '{"file_path":"~/x"}' "path starts with ~ (field file_path)" "label: starts with ~"
label_is Glob '{"pattern":"/w/repo/*.php"}' "Glob pattern is absolute (field pattern)" "label: absolute"
label_is Grep '{"pattern":"x","glob":"**"}' "Grep glob is not extension-shaped (field glob)" "label: not extension-shaped"
label_is Read '{"file_path":""}' "empty field (field file_path)" "label: empty field"
label_is Grep '{"pattern":"x","path":""}' "empty field (field path)" "label: empty field, path"
# Several broken rules: the first checked wins (field set, then glob, then path).
label_is Grep '{"pattern":"x","glob":"**","path":"/proc","zzkey":1}' "unknown field" "first rule wins: field set"
label_is Grep '{"pattern":"x","glob":"**","path":"/proc"}' "Grep glob is not extension-shaped (field glob)" "first rule wins: glob before path"

# No value, and no unknown key's name, reaches the log.
canary="Zq$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
for input in \
  "Read {\"file_path\":\"/proc/$canary\"}" \
  "Read {\"file_path\":\"/w/repo/$canary \"}" \
  "Read {\"file_path\":\"$canary\",\"$canary\":1}" \
  "Grep {\"pattern\":\"$canary\",\"path\":\"/proc/$canary\"}" \
  "Grep {\"pattern\":\"$canary\",\"glob\":\"$canary\"}" \
  "Grep {\"pattern\":\"$canary\",\"file_path\":\"/proc/$canary\"}" \
  "Glob {\"pattern\":\"/$canary/*\"}" \
  "Glob {\"pattern\":\"$canary/../../*\",\"path\":\"/proc/$canary\"}"; do
  printf '[%s]' "$(call "${input%% *}" "${input#* }")" > "$tmp/c.json"
  out=$(bash "$C" "$tmp/c.json" 2>&1)
  assert_eq "1" "$(rc "$tmp/c.json")" "the canary call is refused: ${input%% *}"
  case "$out" in *"$canary"*) echo "FAIL: a value reached the log for ${input%% *}" >&2; exit 1;; esac
done

# It fails closed on what it cannot read.
assert_eq "1" "$(rc "$tmp/absent.json")" "a missing trace fails"
: > "$tmp/empty.json"
assert_eq "1" "$(rc "$tmp/empty.json")" "an empty trace fails"
printf 'not json' > "$tmp/bad.json"
assert_eq "1" "$(rc "$tmp/bad.json")" "an unreadable trace fails"
assert_contains "$(run "$tmp/bad.json")" "not readable JSON" "and says why"

pass
