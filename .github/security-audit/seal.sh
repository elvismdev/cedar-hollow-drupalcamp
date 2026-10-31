#!/usr/bin/env bash
# Seals a directory to an age recipient and opens it again.
#   seal.sh seal <recipient-file> <in-dir> <out>
#   seal.sh open <identity-env-name> <expected-sha256> <in> <out-dir>
# seal prints the sha256 of <out>. open checks that sha256 before decrypting and
# hands the identity to age through a file descriptor, never an argument or file.
set -euo pipefail

usage() {
  echo "usage: seal.sh seal <recipient-file> <in-dir> <out>" >&2
  echo "       seal.sh open <identity-env-name> <expected-sha256> <in> <out-dir>" >&2
  exit 2
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

[ "$#" -ge 1 ] || usage
mode="$1"
shift

case "$mode" in
  seal)
    [ "$#" -eq 3 ] || usage
    recipient="$1"; in_dir="$2"; out="$3"
    tar -C "$in_dir" -cf - . | age -R "$recipient" -o "$out"
    sha256_of "$out"
    ;;
  open)
    [ "$#" -eq 4 ] || usage
    name="$1"; expected="$2"; in="$3"; out_dir="$4"
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "seal.sh: invalid environment variable name" >&2
      exit 2
    fi
    if [ -z "${!name:-}" ]; then
      echo "seal.sh: environment variable $name is empty or unset" >&2
      exit 2
    fi
    actual="$(sha256_of "$in")"
    if [ "$actual" != "$expected" ]; then
      echo "seal.sh: sha256 mismatch for $in (expected $expected, got $actual)" >&2
      exit 1
    fi
    age -d -i <(printf '%s\n' "${!name}") -o - "$in" | tar -x -C "$out_dir"
    ;;
  *) usage ;;
esac
