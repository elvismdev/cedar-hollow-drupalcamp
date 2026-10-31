#!/usr/bin/env bash
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 1
cd "$ROOT" || exit 1
export CLAUDE_PROJECT_DIR="$ROOT"
HOOK=.claude/hooks/posttool-css.sh
COMPONENTS=web/themes/custom/cedar_hollow/components
FIXTURES=("$COMPONENTS/zz-hooktest" "$COMPONENTS/atoms/zz-hooktest-atom" "$COMPONENTS/organisms/zz-hooktest-organism")
STUBS=$(mktemp -d)
trap 'rm -rf "${FIXTURES[@]}" "$STUBS"' EXIT

failures=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (expected '$1', got '$2')"; failures=$((failures + 1)); fi
}
assert_contains() {
  case "$2" in *"$1"*) echo "ok: $3" ;; *) echo "FAIL: $3 (missing '$1' in '$2')"; failures=$((failures + 1)) ;; esac
}

# Stylelint stub: --version succeeds; a file mentioning !important fails with exit 2.
cat > "$STUBS/stylelint" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && exit 0
if grep -q '!important' "$1"; then echo "stub stylelint violation"; exit 2; fi
exit 0
STUB
chmod +x "$STUBS/stylelint"
[ -x "$STUBS/stylelint" ] || { echo "FAIL: stylelint stub missing"; exit 1; }

run() {
  local out err code
  out=$(printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK" 2>"$STUBS/err")
  code=$?
  err=$(cat "$STUBS/err")
  printf '%s|%s|%s' "$code" "$out" "$err"
}

mkdir -p "${FIXTURES[@]}"
printf '#main { color: red !important; }\n' > "$COMPONENTS/zz-hooktest/bad.css"
printf '.zz-hooktest {\n  color: red;\n}\n' > "$COMPONENTS/zz-hooktest/clean.css"
printf "{%% include 'cedar_hollow:zz-hooktest-organism' %%}\n" > "$COMPONENTS/atoms/zz-hooktest-atom/zz-hooktest-atom.twig"
printf '<div></div>\n' > "$COMPONENTS/organisms/zz-hooktest-organism/zz-hooktest-organism.twig"

export STYLELINT_BIN="$STUBS/stylelint"

res=$(run "$ROOT/$COMPONENTS/zz-hooktest/bad.css")
assert_eq "2" "${res%%|*}" "important and ID selector exit 2"
assert_contains "stub stylelint violation" "$res" "stylelint output is reported"
assert_contains "important" "$res" "check_css.py output is reported"

res=$(run "$ROOT/$COMPONENTS/zz-hooktest/clean.css")
assert_eq "0||" "$res" "clean CSS exits 0 quietly"

res=$(run "$ROOT/$COMPONENTS/atoms/zz-hooktest-atom/zz-hooktest-atom.twig")
assert_eq "2" "${res%%|*}" "atom including an organism exits 2"
assert_contains "includes organisms" "$res" "hierarchy finding is reported"

res=$(run "$ROOT/scripts/check_css.py")
assert_eq "0||" "$res" "path outside the theme exits 0 quietly"

res=$(STYLELINT_BIN="$STUBS/missing-stylelint" run "$ROOT/$COMPONENTS/zz-hooktest/clean.css")
assert_eq "0" "${res%%|*}" "no stylelint on clean CSS exits 0"
assert_contains "CSS hook: stylelint skipped (run npm ci in the theme); check_css.py ran" "$res" "no stylelint prints the skip message"

res=$(STYLELINT_BIN="$STUBS/missing-stylelint" run "$ROOT/$COMPONENTS/zz-hooktest/bad.css")
assert_eq "2" "${res%%|*}" "no stylelint still runs check_css.py"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
