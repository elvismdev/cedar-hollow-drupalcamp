#!/usr/bin/env bash
# Keep the workspace's .git away from the agents while they run.
#
# claude-code-action writes its write-capable token into the working
# directory's .git/config before the agent starts, and the agent's Read tool
# can open that file. With .git moved out of the workspace, git finds no
# repository there, the action's git setup fails (it catches that and carries
# on), and no token is written anywhere the agent can read.
#
#   hide     move $GITHUB_WORKSPACE/.git to $RUNNER_TEMP/workspace-git
#   check    after the agent: fail if the workspace has a .git again, or if the
#            moved config holds an access token
#   restore  move it back, refusing to overwrite a .git in the workspace
#
# Nothing that needs git may run between hide and restore. Messages name the
# reason only, never a path or a value, because the job log is public.
#
# Usage: workspace-git.sh hide|check|restore   (GITHUB_WORKSPACE, RUNNER_TEMP)
set -uo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}" "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
live="$GITHUB_WORKSPACE/.git"
away="$RUNNER_TEMP/workspace-git"

fail () { echo "workspace-git: $1" >&2; exit 1; }

case "${1:-}" in
  hide)
    [ -d "$live" ] || fail "the workspace has no .git directory to move away"
    [ ! -e "$away" ] || fail "a moved .git is already present, so a previous restore did not run"
    mv -- "$live" "$away" || fail "moving the workspace's .git away failed"
    echo "workspace-git: the workspace's .git is away while the agent runs"
    ;;
  check)
    [ ! -e "$live" ] || fail "the workspace has a .git again after the agent step, so the action may have written its token where the agent could read it"
    [ -d "$away" ] || fail "the moved .git is missing, so it cannot be checked or restored"
    if [ -e "$away/config" ] && grep -qF 'x-access-token' "$away/config"; then
      fail "the moved .git config holds an access token, which should have had no repository to be written to"
    fi
    echo "workspace-git: no .git in the workspace and no access token in its config"
    ;;
  restore)
    [ -d "$away" ] || fail "there is no moved .git to restore"
    [ ! -e "$live" ] || fail "the workspace has a .git, so the moved one was not put back over it"
    mv -- "$away" "$live" || fail "moving the workspace's .git back failed"
    echo "workspace-git: the workspace's .git is back"
    ;;
  *)
    echo "usage: workspace-git.sh hide|check|restore" >&2
    exit 2
    ;;
esac
