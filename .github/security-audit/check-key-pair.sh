#!/usr/bin/env bash
# Proves that the private key in an environment variable pairs with its
# committed public key and not with the other one, since a secret's value
# cannot be read back once set. A fresh random token sealed to <own.pub> must
# open to itself, and one sealed to <other.pub> must not open: the open must
# fail with age's wrong-identity error, not for any other reason.
#   check-key-pair.sh <identity-env-name> <own.pub> <other.pub>
# Exit 0 when both hold, 1 otherwise, 2 on usage. Prints no key or token.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -eq 3 ] || { echo "usage: check-key-pair.sh <identity-env-name> <own.pub> <other.pub>" >&2; exit 2; }
key="$1" own_pub="$2" other_pub="$3"
[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [ -n "${!key:-}" ] || { echo "check-key-pair: $key is not set" >&2; exit 2; }
[ -f "$own_pub" ] && [ -f "$other_pub" ] || { echo "check-key-pair: a public key file is missing" >&2; exit 2; }

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir "$dir/in" "$dir/open" "$dir/other"
token=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
printf '%s\n' "$token" > "$dir/in/token"

own=$(bash "$HERE/seal.sh" seal "$own_pub" "$dir/in" "$dir/own.age")
if ! bash "$HERE/seal.sh" open "$key" "$own" "$dir/own.age" "$dir/open" 2> "$dir/own.err" \
  || [ "$(cat "$dir/open/token" 2>/dev/null)" != "$token" ]; then
  echo "::error::a token sealed to $(basename "$own_pub") did not open to itself with $key"
  exit 1
fi
other=$(bash "$HERE/seal.sh" seal "$other_pub" "$dir/in" "$dir/other.age")
if bash "$HERE/seal.sh" open "$key" "$other" "$dir/other.age" "$dir/other" 2> "$dir/other.err"; then
  echo "::error::$key opened a token sealed to $(basename "$other_pub")"
  exit 1
fi
if ! grep -qF 'age: error: no identity matched any of the recipients' "$dir/other.err"; then
  echo "::error::opening a token sealed to $(basename "$other_pub") failed for a reason other than the key"
  exit 1
fi
echo "$key opens what is sealed to $(basename "$own_pub") and not what is sealed to $(basename "$other_pub")"
