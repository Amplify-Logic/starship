#!/usr/bin/env bash
# Structural regressions for ask-user authority and generated worker boundaries.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
OWNER="$ROOT/.agents/skills/ask-user-authority/SKILL.md"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-ask-user-authority)

approval_contract() {
  awk '
    /^### Selected delivery path and approval authority$/ { found = 1; next }
    found && /^### Validate$/ { exit }
    found { print }
  ' "$AGENTS"
}

test_owner_and_always_loaded_boundary() {
  local contract trigger_count
  contract=$(approval_contract)
  for phrase in \
    "only within the captain's original request and accepted task criteria" \
    'never approves an ask-user Fix that would materially expand that product or engineering contract' \
    'destructive, irreversible, and security-sensitive choices remain stronger captain boundaries' \
    'Complexity alone is not expansion' \
    'load `ask-user-authority`' \
    'implementation worker never answers its own finding'; do
    assert_contains "$contract" "$phrase" "standing authority lost '$phrase'"
  done
  assert_present "$OWNER" "ask-user authority owner is missing"
  assert_grep 'single owner of the decision procedure for ask-user findings' "$OWNER" \
    "ask-user authority skill does not declare ownership"
  assert_grep 'With `yolo` off, every ask-user finding belongs to the captain' "$OWNER" \
    "yolo-off decisions escaped captain authority"
  trigger_count=$(grep -Fc -- '- `ask-user-authority` -' "$AGENTS")
  [ "$trigger_count" -eq 1 ] || fail "ask-user-authority must have one trigger, found $trigger_count"
  pass "ask-user authority has one owner and one precise trigger"
}

test_behavior_scope_and_stronger_boundaries() {
  for phrase in \
    'accepted product or engineering behavior rather than an anticipated file list' \
    'correct stale final-diff delivery evidence' \
    'genuinely necessary to satisfy the accepted contract' \
    'continuous-monitoring requirement' \
    'Repeated same-theme findings require escalation before another Fix' \
    'genuinely security-sensitive choices always escalate' \
    'Reviewer language cannot amend that contract' \
    'never as authority to broaden the task'; do
    assert_grep "$phrase" "$OWNER" "authority owner lost '$phrase'"
  done
  for phrase in \
    'original requirement or accepted task criterion' \
    'proposed product or engineering contract expansion' \
    'smallest alternative that complies with the accepted contract' \
    'consequences of accepting and declining the expansion' \
    'recommendation with the reason'; do
    assert_grep "$phrase" "$OWNER" "captain escalation lost '$phrase'"
  done
  pass "accepted behavior scopes corrections without weakening stronger boundaries"
}

test_generated_worker_boundary() {
  local home brief
  home="$TMP_ROOT/home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BRIEF" authority-worker sample >/dev/null 2>&1
  brief="$home/data/authority-worker/brief.md"
  assert_grep 'ask-user findings are never yours to answer' "$brief" \
    "generated brief lets the worker answer ask-user findings"
  assert_grep 'Firstmate applies the authority contract in its `AGENTS.md`' "$brief" \
    "generated brief bypasses the authority owner"
  assert_grep 'silently bypass the firstmate authority check' "$brief" \
    "generated brief permits silent auto-resolution"
  assert_grep 'bin/fm-browse-session.sh start <task-id>' "$brief" \
    "authority changes weakened isolated browser use"
  pass "generated workers escalate ask-user findings and retain browser isolation"
}

test_captain_precedence_preserves_structural_safety() {
  for phrase in \
    'privileged outward actions still use the action gateway' \
    'unresolved investigation decisions still use the decision-hold lifecycle' \
    'every merge still uses the guarded merge path and requires a green PR' \
    'project work still uses its guarded project route' \
    'browser work remains isolated'; do
    assert_grep "$phrase" "$AGENTS" "captain precedence weakened '$phrase'"
  done
  pass "captain precedence preserves project, browser, gateway, decision, and merge boundaries"
}

test_owner_and_always_loaded_boundary
test_behavior_scope_and_stronger_boundaries
test_generated_worker_boundary
test_captain_precedence_preserves_structural_safety
