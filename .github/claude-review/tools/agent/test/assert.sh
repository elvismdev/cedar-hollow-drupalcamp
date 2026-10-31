# shellcheck shell=bash
# Minimal assert helpers for fixture-driven *.test.sh scripts. No framework
# (this repo has none); a failing assert prints and exits 1 so run.sh sees it.
assert_eq() { # expected actual message
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (expected [$1], got [$2])" >&2; exit 1; fi
}
assert_exit() { # expected_code actual_code message
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (expected exit $1, got $2)" >&2; exit 1; fi
}
assert_contains() { # haystack needle message
  case "$1" in *"$2"*) ;; *) echo "FAIL: $3 (missing [$2])" >&2; exit 1;; esac
}
pass() { echo "ok: ${1:-$(basename "$0")}"; }
