#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)/.github/claude-review"
. "$ROOT/tools/agent/test/assert.sh"
S="$ROOT/tools/review/risk-tier.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
P="$tmp/paths"; B="$tmp/body"

# tier <body> <path>... : the script's output for those changed paths and body.
tier () {
	printf '%s' "$1" > "$B"; shift
	if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$P"; else : > "$P"; fi
	bash "$S" "$P" "$B" 2>&1
}

# One path per pattern in the High list, each alone, so a pattern that never
# matches cannot hide behind another.
high_paths=(
	".github/workflows/ci.yml"
	".claude/settings.json"
	"REVIEW.md"
	"AGENTS.md"
	"composer.json"
	"composer.lock"
	"pantheon.yml"
	"phpcs.xml.dist"
	"phpstan.neon.dist"
	"web/themes/custom/cedar_hollow/stylelint.config.mjs"
	"web/themes/custom/cedar_hollow/package-lock.json"
	"web/themes/custom/cedar_hollow/.storybook/preview.js"
	"tests/package.json"
	"tests/playwright.config.ts"
	"scripts/check_css.py"
	"scripts/npm-audit-check.mjs"
	"scripts/npm-audit-exceptions.json"
	"scripts/rebuild.sh"
	"web/sites/default/settings.php"
	"web/modules/custom/cedar_hollow_core/cedar_hollow_core.routing.yml"
	"web/modules/custom/cedar_hollow_core/cedar_hollow_core.permissions.yml"
	"config/user.role.editor.yml"
	"config/filter.format.basic_html.yml"
	"config/system.site.yml"
	"top.install"
	"web/modules/custom/cedar_hollow_core/cedar_hollow_core.install"
	"web/modules/custom/cedar_hollow_core/cedar_hollow_core.post_update.php"
	"web/modules/custom/cedar_hollow_core/cedar_hollow_core.deploy.php"
)
for p in "${high_paths[@]}"; do
	out=$(tier "" "$p")
	assert_contains "$out" "tier=High" "$p is High"
	assert_contains "$out" "reason=path $p matches " "and the reason names $p"
done

# Every pattern in the list is exercised by a path above.
n_patterns=$(sed -n '/^HIGH_PATTERNS=(/,/^)/p' "$S" | grep -c "^  '")
assert_eq "28" "$n_patterns" "the High list holds the 28 patterns of the plan"

# Ordinary work is Normal.
out=$(tier "" "web/modules/custom/cedar_hollow_core/src/Controller/AgendaController.php" "docs/readme.md")
assert_contains "$out" "tier=Normal" "ordinary paths are Normal"
assert_contains "$out" "reason=" "and still print a reason"
assert_contains "$(tier "" "web/themes/custom/cedar_hollow/components/atoms/button/button.css")" "tier=Normal" "theme CSS is Normal"
assert_contains "$(tier "" "config/user.settings.yml")" "tier=Normal" "a config file outside the list is Normal"

# A rename away from .github/ lists the previous name too, which keeps it High:
# moving a workflow out of .github disables it.
out=$(tier "" "docs/old-ci.yml" ".github/workflows/ci.yml")
assert_contains "$out" "tier=High" "a rename away from .github stays High"
assert_contains "$out" ".github/workflows/ci.yml" "and names the previous path"

# The declared box.
ticked_high=$'## Risk\n\n- [ ] Low\n- [ ] Medium\n- [x] High\n'
out=$(tier "$ticked_high" "docs/notes.md")
assert_contains "$out" "tier=High" "a declared High with only docs changed stays High"
assert_contains "$out" "reason=declared Risk: High" "and the reason is the box"

ticked_low=$'## Risk\n\n- [x] Low\n- [ ] Medium\n- [ ] High\n'
out=$(tier "$ticked_low" ".github/workflows/ci.yml")
assert_contains "$out" "tier=High" "a declared Low with .github changed is raised to High"
assert_contains "$out" "reason=path .github/workflows/ci.yml" "by the path"
assert_contains "$(tier "$ticked_low" "docs/notes.md")" "tier=Normal" "a declared Low with docs is Normal"

two=$'* [X] Low\n* [x] High\n'
assert_contains "$(tier "$two" "docs/notes.md")" "tier=High" "two ticked boxes: the highest wins"
two_low=$'- [x] Low\n- [x] Medium\n'
assert_contains "$(tier "$two_low" "docs/notes.md")" "tier=Normal" "Low and Medium ticked is Normal"

none=$'## Risk\n\n- [ ] Low\n- [ ] Medium\n- [ ] High\n'
assert_contains "$(tier "$none" "docs/notes.md")" "tier=Normal" "no box ticked is Normal"
assert_contains "$(tier "" "docs/notes.md")" "tier=Normal" "an empty body is Normal"

commented=$'<!--\n- [x] High\n-->\n- [ ] High\n'
assert_contains "$(tier "$commented" "docs/notes.md")" "tier=Normal" "a ticked box inside an HTML comment is ignored"
inline=$'- [x] Low <!-- - [x] High -->\n'
assert_contains "$(tier "$inline" "docs/notes.md")" "tier=Normal" "and so is one inside a comment on a line"

crlf=$'- [ ] Low\r\n- [x] High\r\n'
assert_contains "$(tier "$crlf" "docs/notes.md")" "tier=High" "a body with CRLF line ends is read"

# 3000 paths is the files API limit, so the list may be truncated and a
# High path may be missing from it.
mapfile -t many < <(seq -f 'docs/page-%g.md' 3000)
out=$(tier "" "${many[@]}")
assert_contains "$out" "tier=High" "3000 paths is High"
assert_contains "$out" "reason=3000 paths changed" "and the reason is the count"
mapfile -t fewer < <(seq -f 'docs/page-%g.md' 2999)
assert_contains "$(tier "" "${fewer[@]}")" "tier=Normal" "2999 ordinary paths are Normal"

# A missing input is not a Normal tier.
bash "$S" "$tmp/absent" "$B" >/dev/null 2>&1
assert_exit 2 "$?" "a missing paths file fails"
bash "$S" "$P" "$tmp/absent" >/dev/null 2>&1
assert_exit 2 "$?" "a missing body file fails"

pass
