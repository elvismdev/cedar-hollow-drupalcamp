#!/usr/bin/env bash
# Emit a `name<<DELIMITER` block for $GITHUB_OUTPUT or $GITHUB_ENV, with a
# delimiter the content cannot contain.
#
# The runner reads such a block until the first line that ordinally equals the
# delimiter and never checks whether the value contains it, so a hardcoded
# delimiter is a value the content can be written to match: the assignment ends
# early and the lines after it are parsed as further assignments. Every prompt
# here carries untrusted text, such as a pull request body or a dispatch input, so a
# fixed delimiter let that text replace the whole prompt, contract included.
# A delimiter drawn from /dev/urandom per call cannot be matched by content
# written before it existed.
#
# Takes a FILE and not stdin on purpose. The runner's default shell for a `run`
# block is `bash -e {0}` with no pipefail, so `producer | emit-block.sh` would
# report this script's exit status and an assembler that died would emit an
# empty prompt as a green step. With a file the producer's own redirect fails
# the step under -e before this runs.
#
# Usage: emit-block.sh <output-name> <file>   (writes the block to stdout)
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: emit-block.sh <output-name> <file>" >&2; exit 2; }
name=$1
file=$2

[ -f "$file" ] || { echo "emit-block: no such file: $file" >&2; exit 1; }
# An empty value is refused rather than emitted: a prompt that assembled to
# nothing reaches the agent as a run that asks for nothing and looks fine.
[ -s "$file" ] || { echo "emit-block: $file is empty" >&2; exit 1; }

# od and tr are coreutils, present wherever bash is, so this adds no dependency
# the runner image has to carry.
delimiter="AGENT_BLOCK_$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"

printf '%s<<%s\n' "$name" "$delimiter"
cat "$file"
# The delimiter has to be a whole line. Command substitution strips a trailing
# newline, so this is empty exactly when the file already ends in one.
[ -z "$(tail -c1 "$file")" ] || printf '\n'
printf '%s\n' "$delimiter"
