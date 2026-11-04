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

# A tool name is agent-controlled text: only a known Claude Code name is printed.
tcanary="Tn$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf '[%s,%s,%s]' "$(call Read '{"file_path":"/w/repo/a"}')" "$(call "$tcanary")" "$(call Bash)" > "$tmp/t.json"
out=$(bash "$C" "$tmp/t.json" 2>&1)
assert_eq "1" "$(rc "$tmp/t.json")" "an unlisted tool name fails"
case "$out" in *"$tcanary"*) echo "FAIL: an unlisted tool name reached the log" >&2; exit 1;; esac
assert_contains "$out" "call 2: tool not allowed (unlisted name)" "an unlisted name is replaced by a fixed phrase"
assert_contains "$out" "Bash call 3: tool not allowed" "a known name is still printed"

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
# a later glob wins, when its last segment matches the name .git. After the same
# split on commas that Claude Code applies, a glob passes when no part or
# expansion has a .., a leading !, an empty or ** last segment, or a segment
# that can match .git.
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
ok_path Grep '{"pattern":"x","glob":"!*.php"}' "a negated part passes from any path"
ok_path Grep '{"pattern":"x","glob":"**/{a,b}.php"}' "a brace group of names before the extension passes after **/"
ok_path Grep '{"pattern":"x","glob":"{a,b}.php"}' "a brace group of names before the extension passes on its own"
ok_path Grep '{"pattern":"x","glob":"src/**/*.{php,module}"}' "a brace group of extensions passes after a directory"
ok_path Grep '{"pattern":"x","glob":"**/{a,*}.php"}' "a wildcard in a names brace group before an extension passes"
no_path Grep '{"pattern":"x","glob":"**/{..,a}.php"}' "a .. in the names brace group is refused"
ok_path Grep '{"pattern":"x","glob":"{a,b}/x.php"}' "a brace group in a directory segment passes"
ok_path Grep '{"pattern":"x","glob":"**/{a,b}"}' "a brace group of names with no extension passes"

# A brace group of literal names passes. A glob is refused when it can match
# the name .git (*.git, .GIT, *.{git,sample}), or holds a / and can match .git
# or name it on the way to a path inside it (.git/config, **/.Git/hooks/*);
# a glob anchored elsewhere (x/.git/y.md, src/*.Git) and a name that only ends
# in .git ({a,b}.git) pass, as does a literal name such as .gitignore. Both
# with no options and with the audit's. The first two passing globs, {REVIEW.md,AGENTS.md,CLAUDE.md} and
# *.{yml,yaml,sh,htaccess,gitignore,json,php,md}, are real calls from audit run
# 41347206214; every other glob in these loops is synthetic.
glob_rc () { # glob [option...]: exit status of a Grep with that glob and no path
  printf '[%s]' "$(call Grep "{\"pattern\":\"x\",\"glob\":\"$1\"}")" > "$tmp/g.json"; shift
  rc "$tmp/g.json" "$@"
}
AUDIT_OPTS=(--tools "Read,Glob,Grep,Write,Edit,Agent,Task,SubagentHandback" --root /mnt/audit/source/in --root /mnt/audit/source/out --write-root /mnt/audit/source/out --grep-any-glob-in-subfolders)
for opts in none audit; do
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  for g in '{REVIEW.md,AGENTS.md,CLAUDE.md}' '*.{yml,yaml,sh,htaccess,gitignore,json,php,md}' \
           'src/{a.php,b.yml}' '*.gitignore' '.gitattributes' '**/*.gitkeep' \
           '{REVIEW,AGENTS.md}' 'src/{a,b}' '{a.md,*.md}' '{a.md,b/c.md}' '{.htaccess,a.md}' \
           'x/.git/y.md' '{a,b}.git' '{x.git,y.md}' 'src/*.Git'; do
    assert_eq "0" "$(glob_rc "$g" "${O[@]}")" "the Grep glob $g passes ($opts options)"
  done
  for g in '.git/config' '**/.git/**' '{.git,x}/config' '.GIT/config' '{.git/x.php,a.php}' \
           '**/.Git/hooks/*.sample' 'a.php,.git/x.md' '{a.md,../b.md}' \
           '.git*/hooks/pre-commit.sample' '**/.git*/**/*.pack' '*.git' '**/*.git' '*.GIT' \
           '*.{git,sample}' '*.git,*.sample' '*.git,*.pack,*.idx'; do
    assert_eq "1" "$(glob_rc "$g" "${O[@]}")" "the Grep glob $g is still refused ($opts options)"
  done
done

# The .git rule protects the workspace's .git/config, so it applies
# only when the search root can reach the workspace: no path, or a path inside
# it. The head's .git is a pointer file and the input directory holds a diff, so
# any glob that passes the character allowlist is fine there.
ok_path Grep '{"pattern":"x","path":"/rt/head","glob":"**"}' "a Grep glob of ** in the head passes"
ok_path Grep '{"pattern":"x","path":"/rt/head/.github","glob":".github/workflows/*"}' "a path glob in a head subdirectory passes"
ok_path Grep '{"pattern":"x","path":"/rt/review-input","glob":"*"}' "a Grep glob of * in the input directory passes"
no_path Grep '{"pattern":"x","glob":"**"}' "a Grep glob of ** with no path is refused"
no_path Grep '{"pattern":"x","path":"/w/repo","glob":"**"}' "a Grep glob of ** in the workspace is refused"
no_path Grep '{"pattern":"x","path":"/rt/head","glob":"../**"}' "a .. glob in the head is refused"

# *gitignore* with no path and {.gitignore,composer.json} at the workspace are
# the two real Grep calls the extension rule refused in audit run 41396278548,
# and they pass; the refused globs below are synthetic, and they stay refused
# because they can reopen .git, climb or negate: with no options and with the
# audit's, with no path and with the workspace as path.
grep_rc () { # path-or-empty glob [option...]
  local input
  if [ -n "$1" ]; then input="{\"pattern\":\"x\",\"path\":\"$1\",\"glob\":\"$2\"}"
  else input="{\"pattern\":\"x\",\"glob\":\"$2\"}"; fi
  printf '[%s]' "$(call Grep "$input")" > "$tmp/x.json"; shift 2
  rc "$tmp/x.json" "$@"
}
for opts in none audit; do
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  assert_eq "0" "$(grep_rc '' '*gitignore*' "${O[@]}")" "*gitignore* with no path passes ($opts options)"
  assert_eq "0" "$(grep_rc /w/repo '{.gitignore,composer.json}' "${O[@]}")" "{.gitignore,composer.json} at the workspace passes ($opts options)"
  for p in '' /w/repo; do
    for g in '**' '{a,**}' '*' '*.git' '.git*/x' '{.git,a}' '*.{git,php}' '../x' 'a/../*' \
             'a,**' '*.*' '**/*' '.g*' '**/.git' '.git/config' '**/.git/**' '{a,*}' '{x,**}' '*/' '/.git' \
             '.git/' '**/'; do
      assert_eq "1" "$(grep_rc "$p" "$g" "${O[@]}")" "the Grep glob $g is refused (path ${p:-none}, $opts options)"
    done
  done
done

# The whole glob is judged as ripgrep matches it: folder lists and globs that
# cannot match .git pass, with no options and with the audit's. The first five
# are the shapes of the 14 brace-list globs refused in audit run 41414274201.
for opts in none audit; do
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  for p in '' /w/repo; do
    for g in '{tests/**/*,web/modules/custom/**/*.{php,js},REVIEW.md,config/*.yml,recipes/**/*}' \
             '{scripts/*,.github/workflows/*.yml,composer.json}' '{web/modules/custom/**,tests/**}' \
             '{.github/workflows/*,config/*,scripts/*}' '{*.md,.github/claude-review/*.md}' \
             '*/x.php' 'web/*/x.php' 'src/**' 'src/' '{a,b}/**' 'web/modules/*.php' 'src/.gi*/x.php' '*/*' '**/x.php'; do
      assert_eq "0" "$(grep_rc "$p" "$g" "${O[@]}")" "the Grep glob $g passes (path ${p:-none}, $opts options)"
    done
  done
done
# From the directory above the checkout, in an added root, the glob is also
# judged against .git's path from there (repo/.git).
for opts in none audit; do
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}" --root /w); else O=(--root /w); fi
  for g in 'repo/*' '*/.git' '*/*' 'repo/**' 'repo/.git/x' '*/.git/*' '*' '**/.git'; do
    assert_eq "1" "$(grep_rc /w "$g" "${O[@]}")" "the Grep glob $g from above the checkout is refused ($opts options)"
  done
  for g in 'repo/web/*.php' '*.php' 'repo/{web,tests}/**' '**/x.php'; do
    assert_eq "0" "$(grep_rc /w "$g" "${O[@]}")" "the Grep glob $g from above the checkout passes ($opts options)"
  done
done

# ripgrep's globset compiles a brace group as an alternation, so a ** that
# starts an alternative before a / is recursive whatever precedes the group:
# *{**/.git,**/*} reopens .git with the * matching nothing, and returned
# .git/config with rg 13.0.0 and Claude Code's 14.1.1, as did
# *{**/git,**/config} and *{**/it,**/config} (the * taking .g or .g plus a
# segment start), while the expansions ***/.git and ***/git read as single
# segments. So a brace alternative that starts with **/ is refused unless its
# group starts the glob or follows a /, where such a ** is a whole segment of
# every expansion and reads as ripgrep does. A ** with no / after it at the
# start of an alternative is two * within one segment to ripgrep, as the
# expansion reads, and passes when it cannot reach .git.
EDGE='glob holds ** at the edge of a brace alternative that is not a whole path segment (field glob)'
edge_out () { # path-or-empty glob [option...]: the check's output for one Grep
  local input
  if [ -n "$1" ]; then input="{\"pattern\":\"x\",\"path\":\"$1\",\"glob\":\"$2\"}"
  else input="{\"pattern\":\"x\",\"glob\":\"$2\"}"; fi
  printf '[%s]' "$(call Grep "$input")" > "$tmp/e.json"; shift 2
  bash "$C" "$tmp/e.json" "$@" 2>&1; echo "rc=$?"
}
for opts in none audit; do
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  for p in '' /w/repo; do
    for g in '*{**/.git,**/*}' '*{**/.git,**/*.php}' '*{**/git,**/config}' '*{**/it,**/config}' '*{**/.git}' \
             '.{**/git}' '*.{**/git}' '{.g,x}{**/it,y}' '*{**/.gi*,y}' '{**/x,.g}{**/it}' '.git{**/,}' \
             'a{**/.git,y}' '{x,y}{**/.git}' '*{**/x}/*' 'src{**/*.php,x}' '*{**/x.php,y}' \
             '{a,{**/x}}' 'r*{**/o/.git,**/o/.git/*}'; do
      out=$(edge_out "$p" "$g" "${O[@]}")
      assert_contains "$out" "Grep call 1: $EDGE" "the Grep glob $g is refused for a ** at a brace edge (path ${p:-none}, $opts options)"
    done
    for g in '{**,y}' '.git**' '**.git' '.g**' '**git' '.{**,x}' '*{**}' '{x/**,.g}it'; do
      assert_eq "1" "$(grep_rc "$p" "$g" "${O[@]}")" "the Grep glob $g is refused (path ${p:-none}, $opts options)"
    done
    for g in 'x/{**/.git}' '{x,**}/config' 'a**/.git' 'src/{**/*.php,x}' '{**/a,b}/x' 'x/{a,**}' '{src,web}/**/*.php' \
             '!*{**/.git,**/*}' '{**,y}{a,b}' '{x/**,y}.git' '.{**.git}/*' '{x/**}y'; do
      assert_eq "0" "$(grep_rc "$p" "$g" "${O[@]}")" "the Grep glob $g passes (path ${p:-none}, $opts options)"
    done
  done
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}" --root /w); else O=(--root /w); fi
  for g in 're{**/po/.git}' 're{**/po}/*' 'r{**/epo/.git/x}' 'r*{**/po/.git,**/config}' '*{**/po/.git,**/config}' \
           'r*{**/o/.git,**/o/.git/*}' 'x{**/repo/.git}'; do
    assert_contains "$(edge_out /w "$g" "${O[@]}")" "Grep call 1: $EDGE" "the Grep glob $g from above the checkout is refused ($opts options)"
  done
  assert_eq "1" "$(grep_rc /w 're{**/po/.git,**/po/.git/*}' "${O[@]}")" "re{**/po/.git,**/po/.git/*} from above the checkout is refused ($opts options)"
  for g in 'repo/{**/*.php,x}' '{repo,x}/{**/*.php,y}'; do
    assert_eq "0" "$(grep_rc /w "$g" "${O[@]}")" "the Grep glob $g from above the checkout passes ($opts options)"
  done
done

# ripgrep matches a glob against the path as written, and follows a symlinked
# folder, so where the glob rule applies a Grep path that holds a .. segment or
# passes through a symlink is refused: web/.. with web/** and a link to the
# checkout with web/** each returned .git/info/x.php with ripgrep 13.0.0. This
# needs a real folder, since the symlink is looked up on disk.
sws="$(realpath "$tmp")/sym/repo"
mkdir -p "$sws/web"
ln -s .. "$sws/web/link"
sym_grep () { # path glob [option...]: the check's output for one Grep in the scratch checkout
  printf '[%s]' "$(call Grep "{\"pattern\":\"x\",\"path\":\"$1\",\"glob\":\"$2\"}")" > "$tmp/s.json"; shift 2
  GITHUB_WORKSPACE="$sws" bash "$C" "$tmp/s.json" "$@" 2>&1; echo "rc=$?"
}
out=$(sym_grep web/.. 'web/**')
assert_contains "$out" "Grep call 1: Grep path holds a .. segment (field path)" "web/.. with web/** is refused"
assert_contains "$out" "rc=1" "and fails"
out=$(sym_grep "$sws/.." '*/repo/**' --root "$(dirname "$sws")")
assert_contains "$out" "Grep call 1: Grep path holds a .. segment (field path)" "<workspace>/.. with */repo/** from an added root is refused"
assert_contains "$out" "rc=1" "and fails"
out=$(sym_grep web/link 'web/**')
assert_contains "$out" "Grep call 1: Grep path passes through a symlink (field path)" "a symlinked folder with web/** is refused"
assert_contains "$out" "rc=1" "and fails"
out=$(sym_grep "$sws/web/link/web" '*.php')
assert_contains "$out" "Grep call 1: Grep path passes through a symlink (field path)" "a path through a symlinked folder is refused"
assert_contains "$(sym_grep web 'web/**')" "rc=0" "an ordinary subfolder with web/** still passes"
assert_contains "$(sym_grep "$sws/web" '*.php')" "rc=0" "an ordinary absolute subfolder still passes"
assert_contains "$(sym_grep "$sws" '*.php')" "rc=0" "the workspace itself still passes"
# Only the components below the root that holds the path are judged, so a
# workspace reached through a symlinked parent folder still takes ordinary
# Greps, while a symlink inside it is still refused.
ln -s "$(dirname "$sws")" "$(realpath "$tmp")/symparent"
lws="$(realpath "$tmp")/symparent/repo"
lgrep () { # path glob [option...]: as sym_grep, with the workspace behind the link
  printf '[%s]' "$(call Grep "{\"pattern\":\"x\",\"path\":\"$1\",\"glob\":\"$2\"}")" > "$tmp/s.json"; shift 2
  GITHUB_WORKSPACE="$lws" bash "$C" "$tmp/s.json" "$@" 2>&1; echo "rc=$?"
}
assert_contains "$(lgrep "$lws" '*.php')" "rc=0" "a workspace behind a symlinked parent takes a top-level Grep"
assert_contains "$(lgrep web 'web/**')" "rc=0" "and a subfolder Grep"
assert_contains "$(lgrep "$lws/web" '*.php')" "rc=0" "and an absolute subfolder Grep"
assert_contains "$(lgrep "$(dirname "$lws")" '*.php' --root "$(dirname "$lws")")" "rc=0" "and a Grep at an added root behind the link"
assert_contains "$(lgrep web/link 'web/**')" "Grep path passes through a symlink (field path)" "a symlink inside that workspace is still refused"
# There, ripgrep run in the workspace with its spelled path as the target
# matches a glob against the absolute path, so */*/** returned
# .git/info/x.php with ripgrep 13.0.0; such a glob is judged against .git's
# absolute paths too.
for g in '*/*/**' '**/*/*' '*/**/*'; do
  assert_contains "$(lgrep "$lws" "$g")" "Grep glob can reach .git (field glob)" "$g at a workspace behind a symlinked parent is refused"
done
assert_contains "$(lgrep "$lws" '*/x.php')" "rc=0" "*/x.php at a workspace behind a symlinked parent still passes"
# With no path, a glob spelling the linked parent's absolute path ahead of a
# brace group whose alternatives start with ** after a * returned
# <parent>/repo/.git/config by the raw path with both ripgreps (a leading *
# matches the empty name before the path's first /); it is refused
# for that **, with no options and with the audit's.
lup=$(dirname "$lws"); lrest=${lup#/}
for o in none audit; do
  if [ "$o" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  for g in "{/,z}$lrest/r*{**/o/.git,**/o/.git/*}" "*/$lrest/r*{**/o/.git,**/o/.git/*}"; do
    printf '[%s]' "$(call Grep "{\"pattern\":\"x\",\"glob\":\"$g\"}")" > "$tmp/s.json"
    out=$(GITHUB_WORKSPACE="$lws" bash "$C" "$tmp/s.json" "${O[@]}" 2>&1)
    assert_contains "$out" "Grep call 1: glob holds ** at the edge of a brace alternative that is not a whole path segment (field glob)" "the linked parent's path ahead of r*{**/o/.git,**/o/.git/*} is refused ($o options)"
  done
  # An alternative ending with /** spliced onto the rest of the path is /.*
  # to ripgrep, so with the parent's second folder left out
  # {/<first>/**,z}<third and on>/repo/{.git,.git/*} returned .git/config by
  # the raw path with both ripgreps.
  lfirst=${lrest%%/*}
  g="{/$lfirst/**,z}${lrest#*/*/}/repo/{.git,.git/*}"
  printf '[%s]' "$(call Grep "{\"pattern\":\"x\",\"glob\":\"$g\"}")" > "$tmp/s.json"
  out=$(GITHUB_WORKSPACE="$lws" bash "$C" "$tmp/s.json" "${O[@]}" 2>&1)
  assert_contains "$out" "Grep call 1: Grep glob can reach .git (field glob)" "a /** ending a brace alternative ahead of the linked parent's path is refused ($o options)"
done
assert_contains "$(sym_grep "$sws" '*/*/**')" "rc=0" "*/*/** at a workspace with no symlinked parent still passes"
# A symlinked folder is not a subfolder for --grep-any-glob-in-subfolders: the
# link to the checkout with * returned .git/info/x.php, searched as Claude Code
# 2.1.309 spawns ripgrep (in the opened folder) and by its raw path.
out=$(sym_grep web/link '*' --tools Read,Glob,Grep --grep-any-glob-in-subfolders)
assert_contains "$out" "Grep call 1: Grep glob can reach .git (field glob)" "a symlinked folder with * in subfolder mode is refused"
assert_contains "$out" "rc=1" "and fails"
out=$(sym_grep web/link '*.php' --tools Read,Glob,Grep --grep-any-glob-in-subfolders)
assert_contains "$out" "Grep call 1: Grep path passes through a symlink (field path)" "a symlinked folder with *.php in subfolder mode is refused as a symlink"
assert_contains "$(sym_grep web '*' --tools Read,Glob,Grep --grep-any-glob-in-subfolders)" "rc=0" "an ordinary subfolder with * in subfolder mode still passes"

# Every containment decision is made on the spelled and on the resolved form
# of the path, the workspace and each root, and a call passes only under both.
# With the workspace spelled through a link and an added root given by its
# real path, a Grep at that root with * or repo/** passed and ripgrep 13.0.0
# returned repo/.git files.
zr="$(realpath "$tmp")/zf7"
mkdir -p "$zr/real/repo/web" "$zr/other"
ln -s "$zr/real" "$zr/link"            # the workspace's parent, spelled through a link
ln -s "$zr/real/repo" "$zr/rootlink"   # an added root that is a link to the checkout
ln -s "$zr/real" "$zr/uplink"          # an added root that is a link to the checkout's parent
ln -s ../.git "$zr/real/repo/web/gitlink"
ln -s "$zr/other" "$zr/outlink"
zgrep () { # workspace path glob [option...]: the check's output for one Grep
  local w="$1"
  printf '[%s]' "$(call Grep "{\"pattern\":\"x\",\"path\":\"$2\",\"glob\":\"$3\"}")" > "$tmp/z.json"; shift 3
  GITHUB_WORKSPACE="$w" bash "$C" "$tmp/z.json" "$@" 2>&1; echo "rc=$?"
}
zcall () { # workspace name input-json [option...]: the check's output for one call
  local w="$1"
  printf '[%s]' "$(call "$2" "$3")" > "$tmp/z.json"; shift 3
  GITHUB_WORKSPACE="$w" bash "$C" "$tmp/z.json" "$@" 2>&1; echo "rc=$?"
}
for g in '*' 'repo/**'; do
  out=$(zgrep "$zr/link/repo" "$zr/real" "$g" --root "$zr/real")
  assert_contains "$out" "Grep glob can reach .git (field glob)" "a workspace behind a link and the real parent as a root refuse $g"
  out=$(zgrep "$zr/real/repo" "$zr/uplink" "$g" --root "$zr/uplink")
  assert_contains "$out" "Grep glob can reach .git (field glob)" "a real workspace and a root linked to its parent refuse $g"
done
out=$(zgrep "$zr/real/repo" "$zr/rootlink" '*' --root "$zr/rootlink")
assert_contains "$out" "Grep glob can reach .git (field glob)" "a root that is a link to the checkout keeps the glob rule"
out=$(zgrep "$zr/real/repo" "$zr/rootlink/web" '*' --root "$zr/rootlink" --grep-any-glob-in-subfolders)
assert_contains "$out" "rc=0" "a subfolder under a root linked to the checkout still takes any glob"
assert_contains "$(zgrep "$zr/link/repo" "$zr/real" 'repo/web/*.php' --root "$zr/real")" "rc=0" "a folder glob at the real parent still passes"
assert_contains "$(zgrep "$zr/real/repo" "$zr/uplink" 'repo/web/*.php' --root "$zr/uplink")" "rc=0" "a folder glob at the linked parent still passes"
out=$(zcall "$zr/real/repo" Read '{"file_path":"web/gitlink/config"}')
assert_contains "$out" "Read call 1: path under .git (field file_path)" "a Read through a link into .git is refused"
out=$(zcall "$zr/real/repo" Read "{\"file_path\":\"$zr/rootlink/.git/config\"}" --root "$zr/rootlink")
assert_contains "$out" "Read call 1: path under .git (field file_path)" "a Read of .git through a root linked to the checkout is refused"
# A path in no root gets that label before the symlink check.
out=$(zgrep "$zr/real/repo" "$zr/outlink" '*.php')
assert_contains "$out" "Grep call 1: path outside the allowed roots (field path)" "a linked path in no root is refused as outside the roots"
# A link from the head or the input directory to the checkout or its parent
# resolves into the workspace, so the glob rule holds there.
mkdir -p "$zr/head" "$zr/input"
ln -s "$zr/real/repo" "$zr/head/wslink"
ln -s "$zr/real/repo" "$zr/input/wslink"
ln -s "$zr/real" "$zr/head/uplink"
for p in head/wslink input/wslink head/uplink; do
  out=$(REVIEW_HEAD_DIR="$zr/head" REVIEW_INPUT_DIR="$zr/input" zgrep "$zr/real/repo" "$zr/$p" '*')
  assert_contains "$out" "Grep glob can reach .git (field glob)" "$p with * is refused"
done
assert_contains "$(REVIEW_HEAD_DIR="$zr/head" REVIEW_INPUT_DIR="$zr/input" zgrep "$zr/real/repo" "$zr/head" '*')" "rc=0" "the head itself still takes *"
# The head or the input directory that is itself a link to the checkout or
# its parent is not away from it, so the glob rule holds there too.
ln -s "$zr/real/repo" "$zr/headlink"
ln -s "$zr/real" "$zr/inputlink"
out=$(REVIEW_HEAD_DIR="$zr/headlink" REVIEW_INPUT_DIR="$zr/input" zgrep "$zr/real/repo" "$zr/headlink" '*')
assert_contains "$out" "Grep glob can reach .git (field glob)" "a head that is a link to the checkout keeps the glob rule"
out=$(REVIEW_HEAD_DIR="$zr/head" REVIEW_INPUT_DIR="$zr/inputlink" zgrep "$zr/real/repo" "$zr/inputlink" '*')
assert_contains "$out" "Grep glob can reach .git (field glob)" "an input directory that is a link to the checkout's parent keeps the glob rule"
# A Grep path must be in normal form where the glob rule applies: ripgrep
# matches a glob against the path as written.
for p in './/web' 'web//x' "//$zr/real/repo" "///$zr/real/repo" "$zr/real/repo/." 'web/./x' 'web/.'; do
  out=$(zgrep "$zr/real/repo" "$p" '*.php')
  assert_contains "$out" "Grep call 1: Grep path is not in normal form (field path)" "the Grep path $p is refused"
done
for p in './web' 'web/' '.' "$zr/real/repo/web/"; do
  assert_contains "$(zgrep "$zr/real/repo" "$p" '*.php')" "rc=0" "the Grep path $p still passes"
done

# A part that starts with ! is an exclusion to ripgrep and only removes files,
# so it passes from any path; every other part is judged as before. A ! not at
# the start of a part Claude Code splits off is a literal character to
# ripgrep, and is refused; a kept-whole glob holding one is warned about. The
# first three are the negated globs Grep calls in audit run 41554500456 used
# with no path.
for opts in none audit; do
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  for p in '' /w/repo /w/repo/web /rt/head; do
    for g in '!web/**' '!.github/workflows/**' '!.github/**' '!**/node_modules/**' '!*' '!**' '!.git' '!{a,b}' \
             '!web/**,*.php' '!*,!**' '!{.git,*}'; do
      assert_eq "0" "$(grep_rc "$p" "$g" "${O[@]}")" "the negated Grep glob $g passes (path ${p:-none}, $opts options)"
    done
  done
  for p in '' /w/repo; do
    for g in '!web/**,*' '*,!web/**' '{!a,*}' 'a/!b' '!!a' '!../x' '!a/../b' '! a' '!' '!,*'; do
      assert_eq "1" "$(grep_rc "$p" "$g" "${O[@]}")" "the Grep glob $g is refused (path ${p:-none}, $opts options)"
    done
  done
done

# A glob holding a brace group is kept whole, so a comma outside its braces
# is a literal character to ripgrep and the glob may match nothing the agent
# meant: such a glob passes with one warning line, whatever its first
# character, in every mode, and the other rules still judge it as ripgrep
# reads it. A } before its { cannot be expanded and is refused.
WARN='glob holds a brace group and a comma outside it, so ripgrep reads it as one pattern and it may match nothing (warning)'
grep_out () { # path-or-empty glob [option...]: the check's output and status for one Grep
  local input
  if [ -n "$1" ]; then input="{\"pattern\":\"x\",\"path\":\"$1\",\"glob\":\"$2\"}"
  else input="{\"pattern\":\"x\",\"glob\":\"$2\"}"; fi
  printf '[%s]' "$(call Grep "$input")" > "$tmp/x.json"; shift 2
  bash "$C" "$tmp/x.json" "$@" 2>&1; echo "rc=$?"
}
warned () { # path-or-empty glob message [option...]: the Grep passes with the warning
  local out p="$1" g="$2" msg="$3"; shift 3
  out=$(grep_out "$p" "$g" "$@")
  assert_contains "$out" "check-trace-tools: Grep call 1: $WARN" "$msg warns"
  assert_contains "$out" "all inside the allowed roots" "$msg reads as passing"
  assert_contains "$out" "rc=0" "$msg passes"
}
for opts in none audit; do
  if [ "$opts" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  for p in '' /w/repo /rt/head; do
    for g in '!web/**,{a/**,z.php}' '!{a,b},c' '!x,{y,z}/**' 'src/**/*.php,{web,docs}/**' '*.md,{a,b}/x' 'a,{b,c}'; do
      warned "$p" "$g" "the kept-whole glob $g with a comma outside its braces (path ${p:-none}, $opts options)" "${O[@]}"
    done
    for g in '}x,{a,b}' '{a,b}},c'; do
      out=$(grep_out "$p" "$g" "${O[@]}")
      assert_contains "$out" "Grep call 1: braces cannot be expanded (field glob)" "the glob $g is refused (path ${p:-none}, $opts options)"
      case "$out" in *"(warning)"*) echo "FAIL: the refused glob $g also printed a warning" >&2; exit 1;; esac
    done
    for g in '!{vendor,node_modules}/**' '!web/{a,b}/**' 'src/**/*.php,!vendor/**' '{a,b}/x' 'web/{a,b}/*.php'; do
      out=$(grep_out "$p" "$g" "${O[@]}")
      assert_contains "$out" "rc=0" "the Grep glob $g passes (path ${p:-none}, $opts options)"
      case "$out" in *"(warning)"*) echo "FAIL: the glob $g printed a warning" >&2; exit 1;; esac
    done
  done
done
# In such a glob a ! after the first character is a literal character to
# ripgrep, and passes as one; in a part Claude Code splits off it is still
# refused.
warned '' 'src/**/*.php,!{vendor,node_modules}/**' "a negated brace group after a comma, no options"
for g in 'a/!b' 'x,a/!b' 'a!b,*.php'; do
  out=$(grep_out '' "$g")
  assert_contains "$out" "Grep call 1: character outside the allowlist (field glob)" "the glob $g with a mid-glob ! is still refused"
done
warned web/modules/custom 'src/**/*.php,!{vendor,node_modules}/**' "a negated brace group after a comma in a subfolder, audit options" "${AUDIT_OPTS[@]}"
# The warning is on stderr: stdout holds only the summary, so nothing that
# reads stdout can take it for a refusal.
printf '[%s,%s]' "$(call Grep '{"pattern":"x","glob":"a,{b,c}"}')" "$(call Grep '{"pattern":"x","glob":"*.php"}')" > "$tmp/x.json"
assert_eq "check-trace-tools: 2 tool call(s), all Read, Glob or Grep, all inside the allowed roots" \
  "$(bash "$C" "$tmp/x.json" 2>/dev/null)" "the warning stays off stdout"
assert_eq "1" "$(bash "$C" "$tmp/x.json" 2>&1 >/dev/null | grep -c '(warning)')" "one warning line per warned call"
# The three globs the eighth audit run refused for a comma outside their
# braces (run 41728378524, calls 203, 519 and 801), each with its path, with
# and without the audit's options.
for o in none audit; do
  if [ "$o" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  warned web '{modules/custom/**,themes/custom/**},!**/node_modules/**' "the audit's glob with path web ($o options)" "${O[@]}"
  warned '' '{config/**,recipes/**,scripts/**,tests/**,web/modules/custom/**,web/themes/custom/**},!**/node_modules/**' \
    "the audit's glob with no path ($o options)" "${O[@]}"
  warned web/themes/custom/cedar_hollow/components \
    '{organisms,layouts}/**,atoms/{tag,date,readtime}/**,molecules/{filter-group,speaker-byline,session-meta,hero,breadcrumb}/**' \
    "the audit's component glob in a subfolder ($o options)" "${O[@]}"
done
# A kept-whole glob that can reach .git as ripgrep reads it is still refused,
# with no warning: from above a checkout named re,po, {re,x},po/** matches
# re,po/.git/config with ripgrep 13.0.0 and Claude Code's 14.1.1.
for o in none audit; do
  if [ "$o" = audit ]; then O=("${AUDIT_OPTS[@]}" --root /w); else O=(--root /w); fi
  for g in '{re,x},po/**' '{*,x},po/**' '{re,*},po/.git/config'; do
    out=$(zgrep /w/re,po /w "$g" "${O[@]}")
    assert_contains "$out" "Grep call 1: Grep glob can reach .git (field glob)" "$g from above a checkout named re,po is refused ($o options)"
    case "$out" in *"(warning)"*) echo "FAIL: the refused glob $g also printed a warning" >&2; exit 1;; esac
  done
  out=$(zgrep /w/re,po /w '{re,x},po/*.php' "${O[@]}")
  assert_contains "$out" "rc=0" "{re,x},po/*.php from above a checkout named re,po passes ($o options)"
  # Its ! is literal, so the glob is not an exclusion: from above a checkout
  # named !re,po, {!re,x},po/** matches !re,po/.git/config with both rg
  # versions, and is refused. !{re,x},po/** starts with ! and only excludes.
  out=$(zgrep '/w/!re,po' /w '{!re,x},po/**' "${O[@]}")
  assert_contains "$out" "Grep call 1: Grep glob can reach .git (field glob)" "{!re,x},po/** from above a checkout named !re,po is refused ($o options)"
  out=$(zgrep '/w/!re,po' /w '!{re,x},po/**' "${O[@]}")
  assert_contains "$out" "rc=0" "!{re,x},po/** from above a checkout named !re,po passes ($o options)"
done

# A kept-whole glob is one glob to ripgrep, so a ! after its first character
# is a literal character there and excludes nothing: {a/**,!b/**} matches
# a/x and a file under a folder named !b, and not b/x, with ripgrep 13.0.0 and
# Claude Code's 14.1.1. Such a glob passes with one warning line, and the .git
# rule judges it as ripgrep reads it, each brace expansion a positive glob
# with its ! in place. A ! after the first character of a part Claude Code
# splits off is still refused.
BANG_WARN="glob is kept whole and holds '!' after its first character, which ripgrep reads as a literal character, so it excludes nothing (warning)"
# A kept-whole glob that starts with ! is an exclusion, so its warning calls
# only the later ! literal and never says the glob excludes nothing.
NEG_BANG_WARN="glob is kept whole, starts with '!' and holds another '!' after it, which ripgrep reads as a literal character (warning)"
bang_warned () { # path-or-empty glob message [option...]: the Grep passes with the ! warning
  local out p="$1" g="$2" msg="$3" w="$BANG_WARN"; shift 3
  case "$g" in '!'*) w="$NEG_BANG_WARN";; esac
  out=$(grep_out "$p" "$g" "$@")
  assert_contains "$out" "check-trace-tools: Grep call 1: $w" "$msg warns"
  case "$g" in '!'*) case "$out" in *"excludes nothing"*)
    echo "FAIL: $msg says a glob that starts with ! excludes nothing" >&2; exit 1;; esac;; esac
  assert_contains "$out" "all inside the allowed roots" "$msg reads as passing"
  assert_contains "$out" "rc=0" "$msg passes"
}
# The six globs the tenth audit run refused as a character outside the
# allowlist, all with no path, with and without the audit's options.
for o in none audit; do
  if [ "$o" = audit ]; then O=("${AUDIT_OPTS[@]}"); else O=(); fi
  for g in '{web/modules/custom/**,web/themes/custom/**,!**/node_modules/**,!**/storybook-static/**}' \
           '{config/**,recipes/**,scripts/**,tests/**,web/modules/custom/**,web/themes/custom/**,.github/workflows/**,.github/claude-review/**,!**/node_modules/**}' \
           '{config/**,web/modules/custom/**,web/themes/custom/**,tests/**,recipes/**,!**/node_modules/**,!**/storybook-static/**,!**/dist/**}' \
           '{.github/workflows/**,.github/claude-review/**,scripts/**,web/themes/custom/**,!**/node_modules/**,!**/*.test.sh}' \
           '{web/themes/custom/cedar_hollow/{agenda-builder,components,js,src}/**,tests/**,scripts/**,!**/node_modules/**}' \
           '{web/themes/custom/**,tests/**,scripts/**,!**/node_modules/**,!**/storybook/**}'; do
    bang_warned '' "$g" "the audit's kept-whole glob $g ($o options)" "${O[@]}"
  done
  for p in '' /w/repo /w/repo/web /rt/head; do
    for g in '{!a,b}' '{a,!b}' '{a,!b}/x' '{a/**,!b/**}' 'src/{x,!y}/*.php' '{a,b}/!c' 'x,{a,b}/!c' \
             '!{a,!b}' '!!{a,b}' '!{a,b}/!c'; do
      bang_warned "$p" "$g" "the kept-whole glob $g (path ${p:-none}, $o options)" "${O[@]}"
    done
  done
  # A glob with both shapes gets both warning lines.
  out=$(grep_out '' 'src/**/*.php,!{vendor,node_modules}/**' "${O[@]}")
  assert_contains "$out" "Grep call 1: $WARN" "a glob with an outer comma and a later ! names the comma ($o options)"
  assert_contains "$out" "Grep call 1: $BANG_WARN" "a glob with an outer comma and a later ! names the ! ($o options)"
  # A kept-whole glob with no ! after its first character has no ! warning.
  for g in '!{a,b}' '{a,b}/x' '!web/{a,b}/**'; do
    out=$(grep_out '' "$g" "${O[@]}")
    case "$out" in *"(warning)"*) echo "FAIL: the glob $g printed a warning ($o options)" >&2; exit 1;; esac
  done
  # A ! after the first character of a split part is still refused.
  for g in 'a/!b' 'x,a/!b' 'a!b,*.php' '*.php,src/!x/**' 'a,!!b'; do
    out=$(grep_out '' "$g" "${O[@]}")
    assert_contains "$out" "Grep call 1: character outside the allowlist (field glob)" "the split glob $g with a mid-glob ! is still refused ($o options)"
  done
  # Read as ripgrep reads it, a kept-whole glob with a literal ! can reach .git:
  # from above a checkout named !re, {x/**,!re/**}, {x,!r*}/**, {!re/**} and
  # {a/**,!*/**} match !re/.git/config with both rg versions, through an
  # alternative that starts with ! and no other. Each is refused with no
  # warning; {x/**,!re/*.php} and !{x,!re}/** pass.
  if [ "$o" = audit ]; then O=("${AUDIT_OPTS[@]}" --root /w); else O=(--root /w); fi
  for g in '{x/**,!re/**}' '{x,!r*}/**' '{!re/**}' '{a/**,!*/**}' '{x,!re}/.git/config'; do
    out=$(zgrep '/w/!re' /w "$g" "${O[@]}")
    assert_contains "$out" "Grep call 1: Grep glob can reach .git (field glob)" "$g from above a checkout named !re is refused ($o options)"
    case "$out" in *"(warning)"*) echo "FAIL: the refused glob $g also printed a warning" >&2; exit 1;; esac
  done
  for g in '{x/**,!re/*.php}' '!{x,!re}/**'; do
    out=$(zgrep '/w/!re' /w "$g" "${O[@]}")
    assert_contains "$out" "rc=0" "$g from above a checkout named !re passes ($o options)"
  done
done
# The refusals above rest on the check judging an expansion that starts with
# ! as a positive glob: a copy of the check that skips every such expansion
# accepts {a/**,!*/**} and {x/**,!re/**} from above !re.
mkdir -p "$tmp/mutant"
cp "$(dirname "$C")"/{check-trace-tools.sh,grep_glob_parts.py,glob_search_split.py,expand-braces.cjs} "$tmp/mutant/"
exempt="if t.startswith('!') and (value.startswith('!') or not kept):"
assert_eq "1" "$(grep -cF "$exempt" "$tmp/mutant/check-trace-tools.sh")" "the mutant finds the check's ! exemption once"
sed -i "s/$exempt/if t.startswith('!'):/" "$tmp/mutant/check-trace-tools.sh"
for g in '{a/**,!*/**}' '{x/**,!re/**}'; do
  out=$(C="$tmp/mutant/check-trace-tools.sh" zgrep '/w/!re' /w "$g" --root /w)
  assert_contains "$out" "rc=0" "the mutant accepts $g from above !re, so the test above can fail"
done

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

# An absolute Glob pattern is judged like a path. Claude Code 2.1.316 ignores
# the call's path for it: it searches the directory before the last / ahead of
# the first * or {, and runs ripgrep --files --hidden --no-ignore there with the
# rest as the glob, listing hidden files and .git, with a glob that has no /
# matching names at any depth. So every expansion must be a normal absolute
# path, that directory and every expansion must be inside the roots and not
# under .git, and the glob must not be able to match .git or a path below it.
no_path Glob '{"pattern":"/proc/self/{environ,x/../../../w/repo/y}"}' "an absolute Glob pattern with a brace group is refused"
no_path Glob '{"pattern":"/w/repo/**/*.php"}' "an absolute Glob pattern whose ** reaches .git is refused"
no_path Glob '{"pattern":"/proc/self/{environ,x}"}' "an absolute Glob pattern /proc/self/{environ,x} is refused"
no_path Glob '{"pattern":"{..,x}/../../proc/*"}' "a relative Glob pattern climbing through a brace group is refused"
# The check's split of an absolute pattern matches every split measured from
# the Claude Code 2.1.316 binary in glob-split-corpus.json.
split_out=$(python3 -I - "$(dirname "$C")" <<'PY'
import json, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from glob_search_split import split
rows = json.load(open(os.path.join(sys.argv[1], 'glob-split-corpus.json')))['splits']
bad = [r[0] for r in rows if list(split(r[0])) != r[1:]]
print('%d rows, %d mismatched%s' % (len(rows), len(bad), (': ' + ' '.join(bad)) if bad else ''))
PY
)
assert_contains "$split_out" ", 0 mismatched" "the absolute Glob split matches the measured corpus"
case "$split_out" in [0-7]" rows"*) echo "FAIL: the measured split corpus has fewer than 8 rows" >&2; exit 1;; esac
# The ninth audit run's poc-write call: its own input directory, a root.
PW=(--tools "Read,Glob,Grep,Write,Agent,Task,SubagentHandback" --root /mnt/audit/poc-write/out --root /mnt/audit/poc-write/in --write-root /mnt/audit/poc-write/out --grep-any-glob-in-subfolders)
glob_abs () { # input-json expected-rc message [options...]
  printf '[%s]' "$(call Glob "$1")" > "$tmp/ga.json"
  local want="$2" msg="$3"; shift 3
  assert_eq "$want" "$(rc "$tmp/ga.json" "$@")" "$msg"
}
glob_abs '{"pattern":"/mnt/audit/poc-write/in/*.json"}' 0 "the run's absolute Glob of its input directory passes" "${PW[@]}"
glob_abs '{"pattern":"/mnt/audit/poc-write/in/*.json"}' 1 "the same Glob without that root is refused"
glob_abs '{"pattern":"/mnt/audit/poc-write/in/**/*.{json,txt}"}' 0 "a ** and an extension group in the input directory pass" "${PW[@]}"
glob_abs '{"pattern":"/mnt/audit/poc-write/{in,out}/*.json"}' 1 "a brace group that moves the search to a folder outside the roots is refused" "${PW[@]}"
glob_abs '{"pattern":"/mnt/audit/poc-write/in/*.json","path":"/proc"}' 1 "a path outside the roots is still refused beside it" "${PW[@]}"
ok_path Glob '{"pattern":"/rt/head/**/*.php"}' "an absolute Glob in the head passes"
ok_path Glob '{"pattern":"/rt/head/{src,tests}/*.php"}' "an absolute folder brace group in the head passes"
ok_path Glob '{"pattern":"/w/repo/src/*.php"}' "an absolute Glob in a workspace subfolder passes"
ok_path Glob '{"pattern":"/w/repo/web/{modules,themes}/**/*.yml"}' "an absolute brace group of workspace subfolders passes"
ok_path Glob '{"pattern":"/rt/review-input/review-diff.patch"}' "an absolute Glob naming a file in the input directory passes"
ok_path Glob '{"pattern":"/w/repo/src/x.php"}' "an absolute Glob naming a file in a workspace subfolder passes"
no_path Glob '{"pattern":"/rt/head-other/*.php"}' "an absolute Glob in a sibling of the head is refused"
no_path Glob '{"pattern":"/rt/{head,other}/*.php"}' "an absolute brace group leaving the roots is refused"
no_path Glob '{"pattern":"/rt/head/{src,../../etc}/*"}' "an absolute brace expansion with .. is refused"
no_path Glob '{"pattern":"/etc/passwd"}' "an absolute Glob of a file outside the roots is refused"
no_path Glob '{"pattern":"/*"}' "an absolute Glob of / is refused"
for p in '/rt/head/src/../*.php' '/rt/head/./*.php' '/rt/head//*.php' '/rt/head/src/' '/rt/head/{src,}/x.php' '//rt/head/*.php' '/rt/head/{..}/x'; do
  glob_abs "{\"pattern\":\"$p\"}" 1 "the absolute Glob $p, not in normal form, is refused"
done
# From the workspace's top level, or above it, a glob that can match .git or
# a path below it is refused; with no / it matches names at any depth, so it
# can always match one below .git.
for p in '/w/repo/*.php' '/w/repo/README.md' '/w/repo/*/config' '/w/repo/**' '/w/repo/.g*/config' '/w/repo/{.git,x}/**' '/w/repo/.git/config' '/w/repo/{src,.gi*}/*' '/w/repo/*/*'; do
  glob_abs "{\"pattern\":\"$p\"}" 1 "the absolute Glob $p, which can reach .git, is refused"
  glob_abs "{\"pattern\":\"$p\"}" 1 "and with the audit options" "${AUDIT_OPTS[@]}"
done
for p in '/w/*/.git/config' '/w/repo/../repo/.git/config' '/w/*/*' '/w/*.php' '/w/{repo,x}/.git/config' '/w/repo*/**'; do
  glob_abs "{\"pattern\":\"$p\"}" 1 "the absolute Glob $p from above the workspace in an added root is refused" --root /w
done
glob_abs '{"pattern":"/w/other/*.php"}' 0 "a folder beside the workspace in an added root passes" --root /w
glob_abs '{"pattern":"/w/repo/src/*/x.php"}' 0 "a wildcard below a workspace subfolder passes" --root /w
glob_abs '{"pattern":"/w/repo/{src,web}/**"}' 0 "** below workspace subfolders passes"
# The same globset reading of a ** that starts a brace alternative holds for
# the listed glob: re{**/po/.git/config} from above lists repo/.git/config.
# A brace alternative with ** at an edge is refused in an absolute Glob
# pattern as in a Grep glob: re{**/po/.git/config} from above lists
# repo/.git/config.
glob_abs '{"pattern":"/w/re{**/po/.git/config}"}' 1 "a ** at a brace edge after a prefix from above the workspace is refused" --root /w
glob_abs '{"pattern":"/w/repo/src/x{**/*.php}"}' 1 "a ** at a brace edge after a prefix in a workspace subfolder is refused"
printf '[%s]' "$(call Glob '{"pattern":"/w/repo/src/x{**/*.php}"}')" > "$tmp/ga.json"
assert_contains "$(run "$tmp/ga.json")" "Glob call 1: glob holds ** at the edge of a brace alternative that is not a whole path segment (field pattern)" "and says why"
glob_abs '{"pattern":"/w/repo/src/{**/*.php,x.php}"}' 0 "a ** at a brace edge after a / in a workspace subfolder passes"
# A symlink below its root is refused, as elsewhere: a link inside a root can
# lead anywhere.
sg="$(realpath "$tmp")/sglob"
mkdir -p "$sg/root/d" "$sg/elsewhere"
ln -s "$sg/elsewhere" "$sg/root/l"
ln -s "$sg/root/d" "$sg/root/l2"
glob_abs "{\"pattern\":\"$sg/root/d/*.php\"}" 0 "an absolute Glob in a real folder of an added root passes" --root "$sg/root"
glob_abs "{\"pattern\":\"$sg/root/l/*.php\"}" 1 "an absolute Glob through a symlink in an added root is refused" --root "$sg/root"
printf '[%s]' "$(call Glob "{\"pattern\":\"$sg/root/l/*.php\"}")" > "$tmp/ga.json"
assert_contains "$(run "$tmp/ga.json" --root "$sg/root")" "check-trace-tools: Glob call 1: path outside the allowed roots (field pattern)" "and is labelled outside the roots, its real path being judged first"
glob_abs "{\"pattern\":\"$sg/root/{d,l}/*.php\"}" 1 "a brace expansion through a symlink is refused" --root "$sg/root"
glob_abs "{\"pattern\":\"$sg/root/l2/*.php\"}" 1 "an absolute Glob through a symlink to a folder of the same root is refused" --root "$sg/root"

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
label_is Glob '{"pattern":"/w/repo/src/../*.php"}' "Glob pattern is absolute (field pattern)" "label: absolute, not in normal form"
printf '[%s]' "$(call Glob "{\"pattern\":\"$sg/root/l2/*.php\"}")" > "$tmp/l.json"
assert_contains "$(run "$tmp/l.json" --root "$sg/root")" "check-trace-tools: Glob call 1: Glob pattern is absolute (field pattern)" "label: absolute, through a symlink"
label_is Glob '{"pattern":"/proc/*"}' "path outside the allowed roots (field pattern)" "label: absolute, outside the roots"
label_is Glob '{"pattern":"/w/repo/*/config"}' "path under .git (field pattern)" "label: absolute, can reach .git"
label_is Glob '{"pattern":"/w/repo/.git/*"}' "path under .git (field pattern)" "label: absolute, under .git"
label_is Grep '{"pattern":"x","glob":"*"}' "Grep glob can reach .git (field glob)" "label: can reach .git"
label_is Grep '{"pattern":"x","glob":"!web/**,{a/**,z.php}"}' "$WARN" "warning: kept-whole negation with an outer comma"
label_is Grep '{"pattern":"x","glob":"src/**/*.php,{web,docs}/**"}' "$WARN" "warning: kept-whole glob with an outer comma"
label_is Grep '{"pattern":"x","glob":"**"}' "Grep glob can reach .git (field glob)" "label: no path, glob **"
label_is Grep '{"pattern":"x","path":"/w/repo","glob":"**"}' "Grep glob can reach .git (field glob)" "label: workspace path, glob **"
label_is Grep '{"pattern":"x","path":"/rt/head","glob":"../**"}' "Grep glob holds a .. segment (field glob)" "label: head path, .. glob"
label_is Grep '{"pattern":"x","glob":"../x"}' "Grep glob holds a .. segment (field glob)" "label: no path, .. glob"
label_is Read '{"file_path":""}' "empty field (field file_path)" "label: empty field"
label_is Grep '{"pattern":"x","path":""}' "empty field (field path)" "label: empty field, path"
# Several broken rules: the first checked wins (field set, then glob, then path).
label_is Grep '{"pattern":"x","glob":"**","path":"/proc","zzkey":1}' "unknown field" "first rule wins: field set"
label_is Grep '{"pattern":"x","glob":"**","path":"/proc"}' "Grep glob can reach .git (field glob)" "first rule wins: glob before path"

# No value, and no unknown key's name, reaches the log.
canary="Zq$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
for input in \
  "Read {\"file_path\":\"/proc/$canary\"}" \
  "Read {\"file_path\":\"/w/repo/$canary \"}" \
  "Read {\"file_path\":\"$canary\",\"$canary\":1}" \
  "Grep {\"pattern\":\"$canary\",\"path\":\"/proc/$canary\"}" \
  "Grep {\"pattern\":\"$canary\",\"glob\":\"{$canary,*}\"}" \
  "Grep {\"pattern\":\"$canary\",\"file_path\":\"/proc/$canary\"}" \
  "Glob {\"pattern\":\"/$canary/*\"}" \
  "Glob {\"pattern\":\"$canary/../../*\",\"path\":\"/proc/$canary\"}"; do
  printf '[%s]' "$(call "${input%% *}" "${input#* }")" > "$tmp/c.json"
  out=$(bash "$C" "$tmp/c.json" 2>&1)
  assert_eq "1" "$(rc "$tmp/c.json")" "the canary call is refused: ${input%% *}"
  case "$out" in *"$canary"*) echo "FAIL: a value reached the log for ${input%% *}" >&2; exit 1;; esac
done

# Options. The security audit's agents also write and delegate, so the tool
# list, the read roots and the write roots can be widened, each a closed set.
A=(--tools "Read,Glob,Grep,Write,Edit,Agent,Task" --root /mnt/a/in --root /mnt/a/out --write-root /mnt/a/out)
ok_opt () { printf '[%s]' "$(call "$1" "$2")" > "$tmp/o.json"; assert_eq "0" "$(rc "$tmp/o.json" "${A[@]}")" "$3"; }
no_opt () { # name input-json label message
  printf '[%s]' "$(call "$1" "$2")" > "$tmp/o.json"
  assert_eq "1" "$(rc "$tmp/o.json" "${A[@]}")" "$4"
  assert_contains "$(run "$tmp/o.json" "${A[@]}")" "$1 call 1: $3" "$4 says why"
}
ok_opt Read '{"file_path":"/mnt/a/in/state/findings.json"}' "a read in an added root passes"
ok_opt Read '{"file_path":"/w/repo/web/index.php"}' "the workspace stays a root"
ok_opt Write '{"file_path":"/mnt/a/out/agents/h1/scratch/entry.json","content":"{\"x\":\"a b ~ ..\"}"}' "a Write under a write root passes, whatever its content"
ok_opt Edit '{"file_path":"/mnt/a/out/run-metadata.json","old_string":"a","new_string":"b","replace_all":false}' "an Edit with every field passes"
ok_opt Agent '{"description":"agent-id: h1 hunt","prompt":"p","subagent_type":"general-purpose","run_in_background":false}' "an Agent call with every field passes"
ok_opt Task '{"description":"agent-id: h1 hunt","prompt":"p"}' "the subagent tool's other name passes"
ok_opt Grep '{"pattern":"x","path":"/mnt/a/out","glob":"**"}' "a Grep glob of ** in an added root outside the workspace passes"
no_opt Read '{"file_path":"/mnt/a/other/x"}' "path outside the allowed roots (field file_path)" "a read beside the added roots is refused"
no_opt Write '{"file_path":"agents/h1/scratch/entry.json","content":""}' "write path is relative (field file_path)" "a relative Write is refused"
no_opt Write '{"file_path":"/mnt/a/out/agents/../x.json","content":""}' "write path contains .. (field file_path)" "a Write with .. is refused even when it stays inside"
no_opt Edit '{"file_path":"/mnt/a/out/x/../../in/y","old_string":"a","new_string":"b"}' "write path contains .. (field file_path)" "an Edit with .. is refused"
no_opt Write '{"file_path":"/mnt/a/in/x.json","content":""}' "path outside the write roots (field file_path)" "a Write in a read-only root is refused"
no_opt Write '{"file_path":"/w/repo/web/index.php","content":""}' "path outside the write roots (field file_path)" "a Write in the workspace is refused"
no_opt Write '{"file_path":"/w/repo/.git/config","content":""}' "path under .git (field file_path)" "a Write into .git is refused"
no_opt Write '{"file_path":"/mnt/a/out-other/x","content":""}' "path outside the write roots (field file_path)" "a sibling sharing the write root's prefix is refused"
no_opt Write '{"file_path":" /mnt/a/out/x","content":""}' "character outside the allowlist (field file_path)" "a Write path with a leading space is refused"
no_opt Write '{"content":"x"}' "empty field (field file_path)" "a Write with no file_path is refused"
no_opt Agent '{"description":"agent-id: h1","prompt":"p","model":"other"}' "unknown field" "an Agent call naming a model is refused"
no_opt Bash '{"command":"id"}' "tool not allowed" "a tool outside --tools is still refused"
assert_contains "$(run "$tmp/o.json" "${A[@]}")" "outside Read, Glob, Grep, Write, Edit, Agent and Task" "and the message names the allowed list"
# SubagentHandback, the tool a foreground subagent hands its report back with,
# passes only when --tools names it, and only with exactly a string message.
H=(--tools "Read,Glob,Grep,Write,Edit,Agent,Task,SubagentHandback" --root /mnt/a/in --root /mnt/a/out --write-root /mnt/a/out)
hand () { printf '[%s]' "$(call SubagentHandback "$1")" > "$tmp/h.json"; }
hand '{"message":"done: 3 files read"}'
assert_eq "0" "$(rc "$tmp/h.json" "${H[@]}")" "a SubagentHandback with a string message passes when --tools names it"
assert_eq "1" "$(rc "$tmp/h.json" "${A[@]}")" "a SubagentHandback is refused when --tools does not name it"
assert_eq "1" "$(rc "$tmp/h.json")" "a SubagentHandback is refused with no options, as before"
hand '{"message":"done","file_path":"/mnt/a/out/x"}'
assert_eq "1" "$(rc "$tmp/h.json" "${H[@]}")" "a SubagentHandback with another field is refused"
assert_contains "$(run "$tmp/h.json" "${H[@]}")" "SubagentHandback call 1: unknown field" "and says why"
hand '{}'
assert_contains "$(run "$tmp/h.json" "${H[@]}")" "SubagentHandback call 1: empty field (field message)" "a SubagentHandback with no message is refused"
hand '{"message":""}'
assert_contains "$(run "$tmp/h.json" "${H[@]}")" "SubagentHandback call 1: empty field (field message)" "a SubagentHandback with an empty message is refused"
hand '{"message":null}'
assert_contains "$(run "$tmp/h.json" "${H[@]}")" "SubagentHandback call 1: empty field (field message)" "a SubagentHandback with a null message is refused"
hand '{"message":["x"]}'
assert_contains "$(run "$tmp/h.json" "${H[@]}")" "SubagentHandback call 1: field not a string (field message)" "a SubagentHandback whose message is not a string is refused"
hand '"done"'
assert_eq "1" "$(rc "$tmp/h.json" "${H[@]}")" "a SubagentHandback whose input is not an object is refused"
printf '[%s]' "$(call Write '{"file_path":"/mnt/a/out/x","content":""}')" > "$tmp/o.json"
assert_eq "1" "$(rc "$tmp/o.json" --tools Read,Write --root /mnt/a/out)" "with no write root every Write is refused"
assert_eq "2" "$(rc "$tmp/o.json" --tools Read,Bash)" "--tools may name only tools whose fields are checked"
assert_eq "2" "$(rc "$tmp/o.json" --tools "Read Glob")" "--tools matches whole names, so a space-joined list is refused"
assert_eq "2" "$(rc "$tmp/o.json" --tools "Read,Gre")" "--tools refuses part of a name"
assert_eq "2" "$(rc "$tmp/o.json" --root mnt/a)" "a relative --root is a usage error"
assert_eq "2" "$(rc "$tmp/o.json" --write-root)" "a --write-root with no directory is a usage error"
assert_eq "2" "$(rc "$tmp/o.json" --bogus x)" "an unknown option is a usage error"
assert_eq "2" "$(rc)" "no trace argument is a usage error"
wcanary="Wq$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf '[%s]' "$(call Write "{\"file_path\":\"/tmp/$wcanary\",\"content\":\"$wcanary\"}")" > "$tmp/o.json"
case "$(run "$tmp/o.json" "${A[@]}")" in *"$wcanary"*) echo "FAIL: a Write value reached the log" >&2; exit 1;; esac
# An added root inside the workspace does not lift the Grep glob rule there.
printf '[%s]' "$(call Grep '{"pattern":"x","path":"/w/repo/web","glob":"**"}')" > "$tmp/o.json"
assert_eq "1" "$(rc "$tmp/o.json" --root /w/repo/web)" "an added root inside the workspace keeps the glob rule"

# --grep-any-glob-in-subfolders: a Grep whose path is a folder inside the roots,
# other than the workspace's top level, takes any glob. Without the option, or
# with no path or the top level as the path, the .git rule holds.
G=(--tools "Read,Glob,Grep" --root /mnt/a/out --grep-any-glob-in-subfolders)
grep_glob () { # path-json-or-empty glob expected-rc message [options...]
  local input
  if [ -n "$1" ]; then input="{\"pattern\":\"x\",\"path\":$1,\"glob\":\"$2\"}"; else input="{\"pattern\":\"x\",\"glob\":\"$2\"}"; fi
  printf '[%s]' "$(call Grep "$input")" > "$tmp/g.json"
  shift 2; local want="$1" msg="$2"; shift 2
  assert_eq "$want" "$(rc "$tmp/g.json" "$@")" "$msg"
}
grep_glob '"web/modules/custom"' '!**/node_modules/**' 0 "a negated glob with a subfolder path passes" "${G[@]}"
grep_glob '"/w/repo/web"' '{web/modules/custom/**,tests/**,scripts/**}' 0 "a brace folder list with a subfolder path passes" "${G[@]}"
grep_glob '"/mnt/a/out/agents"' '!*.json' 0 "a negated glob in an added root passes" "${G[@]}"
grep_glob '' '!**/node_modules/**' 0 "the same negated glob with no path passes" "${G[@]}"
grep_glob '".git"' '!**/node_modules/**' 1 "the same glob with path .git fails" "${G[@]}"
grep_glob '".git/hooks"' '!**/node_modules/**' 1 "the same glob with path .git/hooks fails" "${G[@]}"
grep_glob '"/w/repo"' '{web/modules/custom/**,tests/**}' 0 "a brace folder list with the checkout root as path passes" "${G[@]}"
grep_glob '"."' '{web/modules/custom/**,tests/**}' 0 "a brace folder list with . as path passes" "${G[@]}"
grep_glob '"/w/repo"' '{web/**,*}' 1 "a brace list holding * with the checkout root as path fails" "${G[@]}"
grep_glob '"/w/repo/web/"' '**' 0 "a trailing slash on a subfolder path passes" "${G[@]}"
grep_glob '"web"' '../.git/**' 1 "a .. glob from a subfolder still fails" "${G[@]}"
grep_glob '"web"' '!../x' 1 "a negated .. glob from a subfolder still fails" "${G[@]}"
grep_glob '"web"' '* *' 1 "a space in the glob still fails" "${G[@]}"
# A path above the checkout, inside an added root, reaches .git/config too.
W=(--tools "Read,Glob,Grep" --root /w --grep-any-glob-in-subfolders)
grep_glob '"/w"' '**/.git/config' 1 "a Grep rooted above the checkout in an added root keeps the .git rule" "${W[@]}"
grep_glob '"/w"' 'repo/**' 1 "and repo/**, which can match repo/.git, from above the checkout is refused" "${W[@]}"
grep_glob '"/w/repo/.."' '**' 1 "as is ** from above the checkout reached with .." "${W[@]}"
grep_glob '"/w/repo/.."' '**/.git/config' 1 "and so does one that climbs there with .." "${W[@]}"
grep_glob '"/w/repo/web"' '!**/node_modules/**' 0 "a real subfolder under the same options still passes" "${W[@]}"
grep_glob '"web/modules/custom"' '!**/node_modules/**' 0 "without the option the negated glob passes too"
grep_glob '"web/modules/custom"' '{web/**,tests/**}' 0 "without the option a brace folder list in the workspace passes"
grep_glob '"web/modules/custom"' '{web/**,**}' 1 "without the option a brace list holding ** in the workspace fails"

# Brace groups are expanded and every expansion judged, with no options too:
# {.,}. spells .. without a literal .. segment.
no_path Glob '{"pattern":"{.,}./{.,}./etc/*"}' "a brace-spelled .. Glob pattern from the workspace is refused"
no_path Glob '{"pattern":".gi{t,x}/config"}' "a brace-spelled .git Glob pattern is refused"
label_is Glob '{"pattern":".gi{t,x}/config"}' "path under .git (field pattern)" "label: brace-spelled .git"
printf '[%s]' "$(call Grep '{"pattern":"x","path":"/rt/head","glob":"{.,}./**"}')" > "$tmp/b.json"
assert_eq "1" "$(rc "$tmp/b.json")" "a brace-spelled .. Grep glob in the head is refused"
ok_path Grep '{"pattern":"x","path":"/rt/head","glob":"*.{php,twig}"}' "an extension brace group in the head passes"
ok_path Grep '{"pattern":"x","path":"/rt/head","glob":"{src,tests}/**/*.php"}' "a folder brace group in the head passes"
ok_path Glob '{"pattern":"{src,tests}/**/*.php","path":"/rt/head"}' "a folder brace group Glob in the head passes"
ok_path Glob '{"pattern":"**/*.{php,twig}"}' "an extension brace group Glob in the workspace passes"
label_is Glob '{"pattern":"{a,b"}' "braces cannot be expanded (field pattern)" "an unbalanced Glob brace is refused"
label_is Grep '{"pattern":"x","path":"/rt/head","glob":"{a,b"}' "braces cannot be expanded (field glob)" "an unbalanced Grep brace is refused"
# Nested groups expand as in bash and minimatch, and each expansion is judged.
ok_path Glob '{"pattern":"{a,{b,c}}/*.php"}' "a nested brace group inside the workspace passes"
ok_path Grep '{"pattern":"x","path":"/rt/head","glob":"{web/modules/custom/**,tests/**,web/themes/custom/**/*.{php,twig,yml}}"}' "a nested folder and extension list in the head passes"
ok_path Glob '{"pattern":"{web/modules/custom/**,tests/**,web/themes/custom/**/*.{php,twig,yml}}","path":"/rt/head"}' "the same nested list as a Glob in the head passes"
no_path Glob '{"pattern":"{.,{.,}.}/{.,{.,}.}/etc/*"}' "a nested brace-spelled .. Glob pattern from the workspace is refused"
printf '[%s]' "$(call Grep '{"pattern":"x","path":"/rt/head","glob":"{.,{.,}.}/**"}')" > "$tmp/b.json"
assert_eq "1" "$(rc "$tmp/b.json")" "a nested brace-spelled .. Grep glob in the head is refused"
# A group with no comma is literal; it is judged as written and without its
# braces, since glob engines differ on it.
no_path Glob '{"pattern":"{..}/{..}/etc/*"}' "a literal {..} group is judged as .. and refused"
printf '[%s]' "$(call Grep '{"pattern":"x","path":"/rt/head","glob":"{..}/**"}')" > "$tmp/b.json"
assert_eq "1" "$(rc "$tmp/b.json")" "a literal {..} Grep glob in the head is refused"
ok_path Grep '{"pattern":"x","glob":"*.{php}"}' "a literal one-extension group still passes"
# Sequence expressions ({a..e}, {1..300}) are ranges in bash and minimatch,
# which the expander does not compute, so a group whose body holds .. is
# refused: .gi{s..u}/config would reach .git/config.
label_is Glob '{"pattern":".gi{s..u}/config"}' "braces cannot be expanded (field pattern)" "a letter sequence expression is refused"
label_is Glob '{"pattern":"{1..300}/*.php"}' "braces cannot be expanded (field pattern)" "a number sequence expression is refused"
label_is Grep '{"pattern":"x","path":"/rt/head","glob":".gi{s..u}/**"}' "braces cannot be expanded (field glob)" "a sequence expression in a Grep glob is refused"
# Every expansion of a Grep path must be a subfolder before the glob rule is
# lifted; a brace in a path is also outside the path allowlist.
printf '[%s]' "$(call Grep '{"pattern":"x","path":"{web,.}","glob":"!**/node_modules/**"}')" > "$tmp/b.json"
assert_eq "1" "$(rc "$tmp/b.json" --grep-any-glob-in-subfolders)" "a Grep path {web,.} with a negated glob is refused"

# More than 256 expansions cannot be judged.
label_is Glob '{"pattern":"{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b}/*.php"}' "braces cannot be expanded (field pattern)" "512 expansions are refused"
ok_path Glob '{"pattern":"{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}/*.php"}' "256 expansions pass"
label_is Glob '{"pattern":"a}/*.php"}' "braces cannot be expanded (field pattern)" "a stray closing brace is refused"
printf '[%s]' "$(call Grep '{"pattern":"x","path":"/mnt/a/out/x","glob":"!{.,}./**"}')" > "$tmp/b.json"
assert_eq "1" "$(rc "$tmp/b.json" --root /mnt/a/out --grep-any-glob-in-subfolders)" "a brace-spelled .. is refused in subfolder mode too"
# Without the expander the check fails closed.
mkdir -p "$tmp/noexp"
cp "$C" "$tmp/noexp/check-trace-tools.sh"
printf '[%s]' "$(call Read '{"file_path":"/w/repo/a"}')" > "$tmp/b.json"
assert_eq "1" "$(bash "$tmp/noexp/check-trace-tools.sh" "$tmp/b.json" >/dev/null 2>&1; echo $?)" "a missing expander fails closed"
# Without the shared glob split it fails closed too.
mkdir -p "$tmp/nosplit"
cp "$C" "$(dirname "$C")/expand-braces.cjs" "$tmp/nosplit/"
assert_eq "1" "$(bash "$tmp/nosplit/check-trace-tools.sh" "$tmp/b.json" >/dev/null 2>&1; echo $?)" "a missing glob split fails closed"
cp "$(dirname "$C")/grep_glob_parts.py" "$tmp/nosplit/"
assert_eq "1" "$(bash "$tmp/nosplit/check-trace-tools.sh" "$tmp/b.json" >/dev/null 2>&1; echo $?)" "a missing absolute Glob split fails closed"
cp "$(dirname "$C")/glob_search_split.py" "$tmp/nosplit/"
assert_eq "0" "$(bash "$tmp/nosplit/check-trace-tools.sh" "$tmp/b.json" >/dev/null 2>&1; echo $?)" "and passes with both beside the script"

# A Read of the tool result Claude Code saved for an earlier call, denied by
# the permission settings, is reported, not refused; every condition matters.
saved_trace () { # out-file key=value...: the call that was saved, then the Read
  python3 -I - "$@" <<'PY'
import json, sys
out, opts = sys.argv[1], dict(a.split('=', 1) for a in sys.argv[2:])
home = opts.get('home', '/home/tester')
path = opts.get('path', home + '/.claude/projects/-w-repo/sess-1/tool-results/toolu_A1.txt')
marker = opts.get('marker', path)
denied = '<tool_use_error>File is in a directory that is denied by your permission settings.</tool_use_error>'
grep = {'type': 'assistant', 'message': {'content': [
    {'type': 'tool_use', 'id': opts.get('grep_id', 'toolu_A1'), 'name': 'Grep', 'input': {'pattern': 'x'}}]}}
saved = {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': opts.get('grep_id', 'toolu_A1'),
         'content': '<persisted-output>\nOutput too large (21.5KB). Full output saved to: %s\n\nPreview (first 2KB):\nx\n</persisted-output>' % marker}]}}
if opts.get('nested') == '1':
    saved = {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'toolu_Z9', 'content': [saved]}]}}
read = {'type': 'assistant', 'message': {'content': [
    {'type': 'tool_use', 'id': 'toolu_R1', 'name': opts.get('tool', 'Read'),
     'input': {'file_path': path} if opts.get('tool', 'Read') == 'Read' else {'pattern': 'x', 'path': path}}]}}
text = opts.get('result', denied)
answer = {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'toolu_R1',
          'is_error': opts.get('is_error', '1') == '1', 'content': text}]}}
msgs = [read, answer, grep, saved] if opts.get('order') == 'read-first' else [grep, saved, read, answer]
json.dump(msgs, open(out, 'w'))
PY
}
saved_rc () { saved_trace "$tmp/s.json" "$@"; HOME=/home/tester rc "$tmp/s.json"; }
saved_trace "$tmp/s.json"
assert_eq "0" "$(HOME=/home/tester rc "$tmp/s.json")" "a denied Read of an earlier call's saved output passes"
assert_contains "$(HOME=/home/tester run "$tmp/s.json")" "check-trace-tools: Read call 2: a denied read of the tool result Claude Code saved for an earlier call; reported, not refused" "and is reported by call number"
assert_eq "0" "$(saved_trace "$tmp/s.json"; HOME=/home/tester rc "$tmp/s.json" "${AUDIT_OPTS[@]}")" "and passes with the audit options"
assert_eq "1" "$(saved_rc is_error=0 result='line one')" "the same Read that was not denied is refused"
assert_eq "1" "$(saved_rc result='<tool_use_error>File does not exist.</tool_use_error>')" "a Read that failed for another reason is refused"
assert_eq "1" "$(saved_rc is_error=0)" "the deny text without is_error is refused"
assert_eq "1" "$(saved_rc order=read-first)" "a Read naming a call that comes later is refused"
assert_eq "1" "$(saved_rc grep_id=toolu_B2)" "a Read naming an id no call has is refused"
assert_eq "1" "$(saved_rc marker=/home/tester/.claude/projects/-w-repo/sess-1/tool-results/toolu_X9.txt)" "a marker naming a different path is refused"
assert_eq "1" "$(saved_rc nested=1)" "a marker only inside another tool_result is refused"
assert_eq "1" "$(saved_rc path=/home/tester/.claude/projects/-w-repo/sess-1/x/tool-results/toolu_A1.txt)" "an extra segment is refused"
assert_eq "1" "$(saved_rc path=/home/tester/.claude/projects/-w-repo/../tool-results/toolu_A1.txt)" "a .. segment is refused"
assert_eq "1" "$(saved_rc path=/home/tester/.claude/settings.json)" "another file under ~/.claude is refused"
assert_eq "1" "$(saved_rc path=/home/tester/.claude/projects/-w-repo/sess-1/tool-results/toolu_A1.json)" "another extension is refused"
assert_eq "1" "$(saved_rc home=/home/other)" "the same shape under another home is refused"
assert_eq "1" "$(saved_rc tool=Grep)" "a Grep of the saved output's path is refused"
assert_eq "1" "$(saved_rc tool=Glob)" "a Glob of the saved output's path is refused"
# The config home is $CLAUDE_CONFIG_DIR when set, else $HOME/.claude.
cfg_rc () { local dir="$1"; shift; saved_trace "$tmp/s.json" "$@"; HOME=/home/tester CLAUDE_CONFIG_DIR="$dir" rc "$tmp/s.json"; }
assert_eq "0" "$(cfg_rc /opt/claude-home path=/opt/claude-home/projects/-w-repo/sess-1/tool-results/toolu_A1.txt)" "with CLAUDE_CONFIG_DIR set, its saved output passes"
assert_eq "1" "$(cfg_rc /opt/claude-home)" "with CLAUDE_CONFIG_DIR set, the same shape under ~/.claude is refused"
assert_eq "0" "$(cfg_rc '')" "with CLAUDE_CONFIG_DIR empty, ~/.claude is the config home"
assert_eq "1" "$(cfg_rc claude-home)" "a relative CLAUDE_CONFIG_DIR excuses nothing, not even ~/.claude"

# It fails closed on what it cannot read.
assert_eq "1" "$(rc "$tmp/absent.json")" "a missing trace fails"
: > "$tmp/empty.json"
assert_eq "1" "$(rc "$tmp/empty.json")" "an empty trace fails"
printf 'not json' > "$tmp/bad.json"
assert_eq "1" "$(rc "$tmp/bad.json")" "an unreadable trace fails"
assert_contains "$(run "$tmp/bad.json")" "not readable JSON" "and says why"

pass
