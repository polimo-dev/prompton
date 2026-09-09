#!/bin/sh
set -eu

source_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/prompton-worktrees.XXXXXX")
test_root=$(CDPATH='' cd -- "$test_root" && pwd -P)
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM
fixture="$test_root/primary checkout"
mkdir -p "$fixture/scripts" "$test_root/hooks" "$test_root/bin"

test -f "$source_root/Makefile" || { echo 'FAIL: root Makefile is missing' >&2; exit 1; }
cp "$source_root/Makefile" "$source_root/.gitignore" "$source_root/.dockerignore" "$source_root/README.md" "$fixture/"
cp "$source_root/scripts/worktree.sh" "$fixture/scripts/"
git init -q -b main "$fixture"
git -C "$fixture" config core.hooksPath "$test_root/hooks"
git -C "$fixture" config user.name 'Worktree Test'
git -C "$fixture" config user.email 'worktree-test@example.invalid'
git -C "$fixture" add .
git -C "$fixture" commit -q --no-gpg-sign -sm 'Keep a stable base for isolated worktree tests'
base_commit=$(git -C "$fixture" rev-parse HEAD)

run_make() { make --no-print-directory -C "$fixture" "$@"; }
expect_failure() {
  if "$@" >"$test_root/failure.log" 2>&1; then
    echo "FAIL: command unexpectedly succeeded: $*" >&2
    exit 1
  fi
}

expect_failure run_make worktree
expect_failure run_make worktree-rm
for invalid in ../escape /tmp/escape -option bad..name 'bad name' 'bad;command'; do
  expect_failure run_make worktree "name=$invalid"
  expect_failure run_make worktree-rm "name=$invalid"
done
expect_failure run_make worktree name=missing-base from=missing-ref
expect_failure git -C "$fixture" show-ref --verify --quiet refs/heads/missing-base

# Make must treat branch/ref arguments as data, even when they resemble Make functions.
expression="\$(shell touch $test_root/make-expanded)"
expect_failure run_make worktree "name=$expression"
test ! -e "$test_root/make-expanded" || { echo 'FAIL: Make evaluated a branch argument' >&2; exit 1; }
expect_failure run_make worktree name=literal-ref "from=$expression"
test ! -e "$test_root/make-expanded" || { echo 'FAIL: Make evaluated a starting ref' >&2; exit 1; }

run_make worktree name=feature/one
test "$(git -C "$fixture/.worktrees/feature/one" rev-parse HEAD)" = "$base_commit"
test "$(git -C "$fixture/.worktrees/feature/one" branch --show-current)" = feature/one
test "$(git -C "$fixture/.worktrees/feature/one" rev-parse --show-toplevel)" = "$fixture/.worktrees/feature/one"
git -C "$fixture" check-ignore -q .worktrees/feature/one/README.md
expect_failure run_make worktree name=feature/one
expect_failure run_make worktree name=main
expect_failure run_make worktree name=feature/one/nested
run_make worktree-list | grep -F '.worktrees/feature/one'
git -C "$fixture" worktree lock "$fixture/.worktrees/feature/one"
expect_failure run_make worktree-rm name=feature/one
git -C "$fixture" worktree unlock "$fixture/.worktrees/feature/one"

# Git alone must protect modified and untracked user work; no force or branch deletion.
printf '\nChanged in the worktree.\n' >> "$fixture/.worktrees/feature/one/README.md"
expect_failure run_make worktree-rm name=feature/one
git -C "$fixture/.worktrees/feature/one" diff --quiet && exit 1
git -C "$fixture/.worktrees/feature/one" add README.md
git -C "$fixture/.worktrees/feature/one" commit -q --no-gpg-sign -sm 'Preserve edits before exercising clean removal'
cp "$fixture/README.md" "$fixture/.worktrees/feature/one/untracked.md"
expect_failure run_make worktree-rm name=feature/one
test -f "$fixture/.worktrees/feature/one/untracked.md"
git -C "$fixture/.worktrees/feature/one" add untracked.md
git -C "$fixture/.worktrees/feature/one" commit -q --no-gpg-sign -sm 'Keep untracked content before exercising clean removal'
feature_commit=$(git -C "$fixture/.worktrees/feature/one" rev-parse HEAD)
run_make worktree-rm name=feature/one
test ! -e "$fixture/.worktrees/feature/one"
test "$(git -C "$fixture" rev-parse feature/one)" = "$feature_commit"
run_make worktree name=feature/one from=missing-ref
test "$(git -C "$fixture/.worktrees/feature/one" rev-parse HEAD)" = "$feature_commit"
run_make worktree name=from-feature from=feature/one
test "$(git -C "$fixture/.worktrees/from-feature" rev-parse HEAD)" = "$feature_commit"

# A linked checkout cannot nest more worktrees, remove siblings or deploy.
expect_failure make --no-print-directory -C "$fixture/.worktrees/feature/one" worktree name=nested
expect_failure make --no-print-directory -C "$fixture/.worktrees/feature/one" worktree-rm name=from-feature
test -f "$fixture/.worktrees/from-feature/.git"

# Names must not escape through symlinked parent components.
mkdir "$test_root/outside"
ln -s "$test_root/outside" "$fixture/.worktrees/link"
expect_failure run_make worktree name=link/escape
expect_failure run_make worktree-rm name=link/escape
test ! -e "$test_root/outside/escape"

# A dirty primary checkout and ignored local configuration are not copied or altered.
printf '\nUncommitted primary work.\n' >> "$fixture/README.md"
printf 'LOCAL_TEST_ONLY=1\n' > "$fixture/.env"
run_make worktree name=clean-base
test ! -e "$fixture/.worktrees/clean-base/.env"
git -C "$fixture/.worktrees/clean-base" diff --quiet
git -C "$fixture" diff --quiet && exit 1
test -f "$fixture/.env"

# Deployment smoke tests use stub commands; they never access Docker or Kubernetes.
cat > "$test_root/bin/docker" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$WORKTREE_TEST_LOG"
case "${0##*/}:$*" in
  docker:*build*) test "${WORKTREE_TEST_BUILD_FAIL:-0}" = 0 ;;
esac
STUB
cp "$test_root/bin/docker" "$test_root/bin/kubectl"
chmod +x "$test_root/bin/docker" "$test_root/bin/kubectl"
WORKTREE_TEST_LOG="$test_root/deploy.log"
export WORKTREE_TEST_LOG
PATH="$test_root/bin:$PATH"
export PATH
expect_failure make --no-print-directory -C "$fixture/.worktrees/feature/one" dev-deploy
test ! -e "$WORKTREE_TEST_LOG"
WORKTREE_TEST_BUILD_FAIL=1
export WORKTREE_TEST_BUILD_FAIL
expect_failure run_make dev-deploy
test "$(wc -l < "$WORKTREE_TEST_LOG" | tr -d ' ')" = 1
grep -F 'docker --context orbstack build -f app/Dockerfile -t prompton-server:dev-local .' "$WORKTREE_TEST_LOG"
WORKTREE_TEST_BUILD_FAIL=0
export WORKTREE_TEST_BUILD_FAIL
run_make dev-deploy
test "$(wc -l < "$WORKTREE_TEST_LOG" | tr -d ' ')" = 5
grep -F 'docker --context orbstack image inspect prompton-server:dev-local' "$WORKTREE_TEST_LOG"
grep -F 'kubectl --context orbstack -n prompton rollout restart deployment/prompton' "$WORKTREE_TEST_LOG"
grep -F 'kubectl --context orbstack -n prompton rollout status deployment/prompton --timeout=300s' "$WORKTREE_TEST_LOG"

echo 'PASS: worktree lifecycle, branch preservation, path safety, local isolation and dev-deploy guards'
