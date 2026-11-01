#!/usr/bin/env bash
# Tests for check-key-pair.sh with throwaway age keys: the right key passes;
# the other pair's key, an unrelated key and a key holding garbage fail; an
# unset key is a usage error; no key or token is printed.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SA="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for k in agents sandbox unrelated; do
  age-keygen -o "$tmp/$k.key" 2>/dev/null
  age-keygen -y "$tmp/$k.key" > "$tmp/$k.pub"
done
secret() { grep AGE-SECRET-KEY "$tmp/$1.key"; }
check() { # key-value
  RC=0; OUT=$(TEST_KEY="$1" bash "$SA/check-key-pair.sh" TEST_KEY "$tmp/agents.pub" "$tmp/sandbox.pub" 2>&1) || RC=$?
  case "$OUT" in *AGE-SECRET-KEY*) echo "FAIL: a key was printed" >&2; exit 1;; esac
}
check "$(secret agents)"
assert_exit 0 "$RC" "the agents key pairs with agents.pub and not sandbox.pub"
check "$(secret sandbox)"
assert_exit 1 "$RC" "the sandbox key fails the agents check"
check "$(secret unrelated)"
assert_exit 1 "$RC" "an unrelated key fails"
check "AGE-SECRET-KEY-1GARBAGE"
assert_exit 1 "$RC" "a malformed key fails"
# The other key's public half given as both: the second open succeeds, so it fails.
RC=0; TEST_KEY="$(secret agents)" bash "$SA/check-key-pair.sh" TEST_KEY "$tmp/agents.pub" "$tmp/agents.pub" > /dev/null 2>&1 || RC=$?
assert_exit 1 "$RC" "a key that opens what is sealed to the other public key fails"
RC=0; bash "$SA/check-key-pair.sh" UNSET_KEY_NAME "$tmp/agents.pub" "$tmp/sandbox.pub" > /dev/null 2>&1 || RC=$?
assert_exit 2 "$RC" "an unset key is a usage error"
pass
