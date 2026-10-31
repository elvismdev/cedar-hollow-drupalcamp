#!/usr/bin/env bash
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 1
cd "$ROOT" || exit 1
export CLAUDE_PROJECT_DIR="$ROOT"
HOOK=.claude/hooks/posttool-phpcs.sh
DIR=web/modules/custom/zz_hooktest
STUBS=$(mktemp -d)
trap 'rm -rf "$DIR" "$STUBS"' EXIT

failures=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (expected '$1', got '$2')"; failures=$((failures + 1)); fi
}
assert_contains() {
  case "$2" in *"$1"*) echo "ok: $3" ;; *) echo "FAIL: $3 (missing '$1' in '$2')"; failures=$((failures + 1)) ;; esac
}

# The stub stands in for both `ddev` and `phpcs`: the first argument decides what it emulates.
cat > "$STUBS/ddev" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  describe) echo '{"raw":{"status":"running"}}'; exit 0 ;;
  exec) shift; shift; exec "$PHPCS_STUB" "$@" ;;
esac
exit 1
STUB
cat > "$STUBS/phpcs" <<'STUB'
#!/usr/bin/env bash
for last; do :; done
case "$(basename "$last")" in
  Bad.php) echo "FOUND 1 ERROR: stub violation"; exit 2 ;;
  Crash.php) echo "stub crash"; exit 3 ;;
esac
exit 0
STUB
cat > "$STUBS/ddev-down" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUBS"/*
for stub in "$STUBS/ddev" "$STUBS/phpcs" "$STUBS/ddev-down"; do
  [ -x "$stub" ] || { echo "FAIL: stub $stub missing"; exit 1; }
done
export PHPCS_STUB="$STUBS/phpcs"

run() {
  # Usage: run <path>; prints "<exit>|<stdout>|<stderr>".
  local out err code
  out=$(printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK" 2>"$STUBS/err")
  code=$?
  err=$(cat "$STUBS/err")
  printf '%s|%s|%s' "$code" "$out" "$err"
}

mkdir -p "$DIR"
printf '<?php\n' > "$DIR/Good.php"
printf '<?php\n' > "$DIR/Bad.php"
printf '<?php\n' > "$DIR/Crash.php"

export DDEV_BIN="$STUBS/ddev" PHPCS_BIN="$STUBS/phpcs"

res=$(run "$ROOT/$DIR/Good.php")
assert_eq "0||" "$res" "clean file exits 0 quietly"

res=$(run "$ROOT/$DIR/Bad.php")
assert_eq "2" "${res%%|*}" "Bad.php exits 2"
assert_contains "stub violation" "$res" "Bad.php report goes to stderr"

res=$(run "$ROOT/scripts/check_css.py")
assert_eq "0||" "$res" "path outside the ruleset exits 0 quietly"

res=$(run "$ROOT/web/themes/custom/cedar_hollow/stories/zz.php")
assert_eq "0||" "$res" "ruleset path miss exits 0 quietly"

res=$(run "$ROOT/$DIR/Crash.php")
assert_eq "0" "${res%%|*}" "stub exit 3 exits 0"
assert_contains 'PHPCS hook could not run (exit 3)' "$res" "exit 3 prints the could-not-run message"

res=$(DDEV_BIN="$STUBS/ddev-down" PHPCS_BIN="$STUBS/missing-phpcs" run "$ROOT/$DIR/Good.php")
assert_eq "0" "${res%%|*}" "no runner exits 0"
assert_contains 'PHPCS hook skipped: no ddev or vendor/bin/phpcs' "$res" "no runner prints the skip message"

res=$(DDEV_BIN="$STUBS/ddev-down" PHPCS_BIN="$STUBS/phpcs" run "$ROOT/$DIR/Bad.php")
assert_eq "2" "${res%%|*}" "host runner is used when ddev is not running"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
