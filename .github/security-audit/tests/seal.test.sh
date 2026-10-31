#!/usr/bin/env bash
# Tests for seal.sh. The round trip and wrong-identity cases need the real age;
# without it they print a skip line and the stub-based cases still run.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
SEAL="$(cd "$(dirname "$0")/.." && pwd)/seal.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/in/sub"
echo "alpha" > "$WORK/in/a.txt"
echo "beta" > "$WORK/in/sub/b.txt"

if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  age-keygen -o "$WORK/key1.txt" 2>/dev/null
  age-keygen -o "$WORK/key2.txt" 2>/dev/null
  age-keygen -y "$WORK/key1.txt" > "$WORK/recipient1.txt"
  KEY1="$(grep '^AGE-SECRET-KEY-' "$WORK/key1.txt")"
  KEY2="$(grep '^AGE-SECRET-KEY-' "$WORK/key2.txt")"
  export KEY1 KEY2

  sum="$(bash "$SEAL" seal "$WORK/recipient1.txt" "$WORK/in" "$WORK/sealed.age")"
  assert_eq "$(sha256sum "$WORK/sealed.age" | cut -d' ' -f1)" "$sum" "seal prints the sha256 of the output"
  mkdir "$WORK/out"
  bash "$SEAL" open KEY1 "$sum" "$WORK/sealed.age" "$WORK/out"
  assert_eq "alpha" "$(cat "$WORK/out/a.txt")" "round trip restores a.txt"
  assert_eq "beta" "$(cat "$WORK/out/sub/b.txt")" "round trip restores sub/b.txt"

  mkdir "$WORK/out-wrong"
  rc=0
  bash "$SEAL" open KEY2 "$sum" "$WORK/sealed.age" "$WORK/out-wrong" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: wrong identity was accepted" >&2; exit 1; }
  assert_eq "0" "$(find "$WORK/out-wrong" -type f | wc -l | tr -d ' ')" "wrong identity extracts nothing"
else
  echo "SKIP: age not installed, round trip and wrong identity cases not run"
fi

# Stubs that record their arguments.
mkdir -p "$WORK/stubs"
cat > "$WORK/stubs/age" <<'STUB'
#!/usr/bin/env bash
echo "age $*" >> "$STUB_LOG"
prev=""; out=""; ident=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$prev" = "-i" ] && ident="$a"
  prev="$a"
done
if [ -n "$ident" ]; then cat "$ident" > "$STUB_IDENT_SEEN"; echo payload; fi
if [ -n "$out" ] && [ "$out" != "-" ]; then cat > "$out"; fi
exit 0
STUB
cat > "$WORK/stubs/tar" <<'STUB'
#!/usr/bin/env bash
echo "tar $*" >> "$STUB_LOG"
case " $* " in *" -c"*|*" -cf "*) echo tarbytes;; *) cat >/dev/null;; esac
exit 0
STUB
chmod +x "$WORK/stubs/age" "$WORK/stubs/tar"
export STUB_LOG="$WORK/argv.log" STUB_IDENT_SEEN="$WORK/ident.seen"
SECRET="AGE-SECRET-KEY-1CANARY$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
export SECRET

: > "$STUB_LOG"
echo "age1recipient" > "$WORK/stub-recipient.txt"
sum="$(PATH="$WORK/stubs:$PATH" bash "$SEAL" seal "$WORK/stub-recipient.txt" "$WORK/in" "$WORK/stub.age")"
assert_eq "$(sha256sum "$WORK/stub.age" | cut -d' ' -f1)" "$sum" "stubbed seal prints the sha256"
assert_contains "$(cat "$STUB_LOG")" "-R $WORK/stub-recipient.txt" "age gets the recipient file"

mkdir "$WORK/stub-out"
PATH="$WORK/stubs:$PATH" bash "$SEAL" open SECRET "$sum" "$WORK/stub.age" "$WORK/stub-out"
assert_eq "$SECRET" "$(cat "$STUB_IDENT_SEEN")" "age could read the identity through its -i file"
case "$(cat "$STUB_LOG")" in *"$SECRET"*) echo "FAIL: identity appeared in a process argument" >&2; exit 1;; esac
assert_contains "$(cat "$STUB_LOG")" "age -d -i /dev/fd/" "identity passed as a descriptor path"

# Mismatch is refused before age runs.
: > "$STUB_LOG"
rc=0
PATH="$WORK/stubs:$PATH" bash "$SEAL" open SECRET "0000" "$WORK/stub.age" "$WORK/stub-out" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: sha256 mismatch was accepted" >&2; exit 1; }
assert_eq "" "$(cat "$STUB_LOG")" "no age or tar ran after a sha256 mismatch"

pass seal.test.sh
