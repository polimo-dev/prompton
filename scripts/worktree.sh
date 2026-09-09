#!/bin/sh
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }

checkout=$(git rev-parse --show-toplevel)
git_dir=$(git rev-parse --absolute-git-dir)
common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
test "$git_dir" = "$common_dir" || fail 'Run this command from the primary checkout, not a linked worktree.'

case "${1:-}" in
  require-primary) exit 0 ;;
  worktree|worktree-rm) action=$1 ;;
  *) fail 'Usage: worktree.sh worktree|worktree-rm|require-primary' ;;
esac

branch=${WORKTREE_NAME:-}
case "$branch" in
  ''|/*|-*|*[!a-zA-Z0-9._/-]*) fail 'Provide name=<branch> using letters, digits, dots, hyphens, underscores or slashes.' ;;
esac
git check-ref-format "refs/heads/$branch" || fail 'Invalid worktree branch name.'

# All paths stay under the primary checkout. Do not follow symlinks or nest
# one checkout inside another, including names with multiple path components.
directory="$checkout/.worktrees"
test ! -L "$directory" || fail '.worktrees must be a real directory, not a symlink.'
test ! -e "$directory/.git" || fail '.worktrees must not itself be a checkout.'
remaining=$branch
target=$directory
while :; do
  component=${remaining%%/*}
  target="$target/$component"
  test ! -L "$target" || fail "Refusing symlinked path: $target"
  case "$remaining" in
    */*)
      test ! -e "$target/.git" || fail "Refusing to nest a worktree inside $target"
      remaining=${remaining#*/}
      ;;
    *) break ;;
  esac
done

case "$action" in
  worktree)
    test ! -e "$target" || fail "Worktree path already exists: $target"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add "$target" "$branch"
    else
      start_ref=${WORKTREE_FROM:-main}
      start_commit=$(git rev-parse --verify --end-of-options "$start_ref^{commit}") || fail "Invalid starting ref: $start_ref"
      git worktree add -b "$branch" "$target" "$start_commit"
    fi
    printf '\nWorktree ready: %s\n' "$target"
    printf '  cd "%s/app"\n  mix deps.get\n' "$target"
    printf '%s\n' 'Local env files, deps and _build are not copied. See README for setup and database/port isolation.'
    printf '%s\n' 'Run make dev-deploy from the primary checkout only.'
    ;;
  worktree-rm)
    # Native Git refuses modified, untracked or locked worktrees. Do not force,
    # delete the branch, or prune unrelated registrations.
    git worktree remove "$target"
    ;;
esac
