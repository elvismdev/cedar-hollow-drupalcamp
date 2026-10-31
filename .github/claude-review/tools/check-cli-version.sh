#!/usr/bin/env bash
# The eval must score the reviewer the review job runs, so the Claude Code
# version eval/action.yml installs has to equal the one claude-code-action
# installs at the sha review/action.yml pins. Reads that action's own source
# at that sha, rather than a copy of the number.
#
# Usage: check-cli-version.sh        (needs gh, authenticated)
set -euo pipefail
root=$(git rev-parse --show-toplevel)
sha=$(grep -m1 -oE 'anthropics/claude-code-action@[0-9a-f]{40}' "$root/review/action.yml" | cut -d@ -f2) || {
  echo "check-cli-version: no pinned claude-code-action in review/action.yml" >&2; exit 1; }
# Read whole before searching: grep -m1 at the end of a pipe exits at its first
# match, the decoder upstream dies of SIGPIPE, and pipefail reports a failure.
source_file=$(gh api "repos/anthropics/claude-code-action/contents/base-action/action.yml?ref=$sha" --jq .content | base64 -d) || {
  echo "check-cli-version: could not read base-action/action.yml at claude-code-action@$sha" >&2; exit 1; }
pinned=$(grep -m1 -oE 'CLAUDE_CODE_VERSION="[0-9.]+"' <<<"$source_file" | cut -d'"' -f2) || {
  echo "check-cli-version: no CLAUDE_CODE_VERSION in claude-code-action@$sha's base action" >&2; exit 1; }
ours=$(grep -m1 -oE 'CLAUDE_CODE_VERSION="[0-9.]+"' "$root/eval/action.yml" | cut -d'"' -f2) || {
  echo "check-cli-version: no CLAUDE_CODE_VERSION in eval/action.yml" >&2; exit 1; }
if [ "$pinned" != "$ours" ]; then
  echo "check-cli-version: eval/action.yml installs Claude Code $ours, but claude-code-action@${sha:0:7} installs $pinned; set them equal" >&2
  exit 1
fi
echo "check-cli-version: $ours in both, claude-code-action@${sha:0:7}"
