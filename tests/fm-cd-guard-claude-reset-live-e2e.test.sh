#!/usr/bin/env bash
# Live guard for the harness behavior the cd-guard's Claude allowance rests on
# (docs/cd-guard.md "Claude: a cd that ends outside every working folder").
#
# tests/fm-cd-pretool-check.test.sh pins the decision with no harness. It cannot
# catch Claude Code changing the behavior itself, and this guard checks it: a
# real `claude -p` session runs one cd per Bash call, then records where the
# next call starts. A cd that ends outside every working folder must come back
# to the start folder, while a cd into a subfolder or into an --add-dir folder
# must persist, which is why the guard keeps denying those.
#
# It submits prompts, so it is opt-in:
#   FM_CD_GUARD_CLAUDE_LIVE_E2E=1 bash tests/fm-cd-guard-claude-reset-live-e2e.test.sh
# Refresh the dated record in docs/verification/runtime-backends.md from its
# output after every Claude Code upgrade.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CD_GUARD_CLAUDE_LIVE_E2E claude git

LAB=$(fm_test_tmproot fm-cd-guard-claude-live)
LAB=$(cd "$LAB" && pwd -P)
START="$LAB/start"
mkdir -p "$START/sub" "$LAB/outside" "$LAB/added" "$LAB/marks"
git -C "$START" init -q

version=$(claude --version 2>/dev/null)
printf 'claude %s\n' "$version"

prompt="Run each of these shell commands with the Bash tool, exactly as written, ONE command per Bash tool call, strictly in this order. Never combine them and never add a cd of your own.
1) cd $LAB/outside
2) pwd > $LAB/marks/after-outside
3) cd $LAB/added
4) pwd > $LAB/marks/after-added
5) cd $START/sub
6) pwd > $LAB/marks/after-sub
7) cd $LAB/outside && pwd > $LAB/marks/inside-compound
8) pwd > $LAB/marks/after-compound
Then reply DONE."

(cd "$START" && claude -p "$prompt" --model haiku --permission-mode bypassPermissions \
  --add-dir "$LAB/added" >"$LAB/claude.out" 2>&1) \
  || fail "claude -p did not complete: $(tail -5 "$LAB/claude.out")"

mark() {
  [ -s "$LAB/marks/$1" ] || fail "the session did not run the step that writes $1; output: $(tail -5 "$LAB/claude.out")"
  cat "$LAB/marks/$1"
}

assert_equals "$START" "$(mark after-outside)" \
  "Claude Code $version must return the shell to the start folder after a cd outside every working folder"
pass "Claude Code $version: a cd outside every working folder does not persist"

assert_equals "$LAB/outside" "$(mark inside-compound)" \
  "a compound command must still run in the folder its cd chose"
assert_equals "$START" "$(mark after-compound)" \
  "Claude Code $version must return the shell to the start folder after a compound command that ends outside"
pass "Claude Code $version: a compound command runs outside, then the shell returns"

assert_equals "$LAB/added" "$(mark after-added)" \
  "Claude Code $version: a cd into an --add-dir folder is expected to persist"
assert_equals "$START/sub" "$(mark after-sub)" \
  "Claude Code $version: a cd into a subfolder of the start folder is expected to persist"
pass "Claude Code $version: a cd into a working folder or a subfolder persists, so the guard keeps denying it"
