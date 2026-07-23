#!/usr/bin/env bash
# Kimi worker certification wiring: fm-spawn accepts kimi; busy regex and docs match.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

test_kimi_launch_template_in_fm_spawn() {
  local spawn="$ROOT/bin/fm-spawn.sh"
  assert_grep "kimi) printf '%s' 'KIMI_CODE_HOME=__KIMIHOME__ kimi --yolo __MODELFLAG__'" "$spawn" \
    "fm-spawn missing kimi launch_template branch"
  assert_grep 'KIMI_CODE_HOME=__KIMIHOME__' "$spawn" \
    "kimi template missing isolated KIMI_CODE_HOME"
  # case lists must include kimi alongside the prior verified set
  local case_lists
  case_lists=$(grep -cF 'claude|codex|opencode|pi|grok|cursor|kimi)' "$spawn" || true)
  [ "$case_lists" -ge 2 ] || \
    fail "fm-spawn verified-adapter case lists missing kimi"
  pass "fm-spawn accepts kimi as a verified worker"
}

test_kimi_busy_regex_wired() {
  local watch="$ROOT/bin/fm-watch.sh"
  local tmuxlib="$ROOT/bin/fm-tmux-lib.sh"
  assert_grep 'thinking\.\.\.|Running a command' "$watch" \
    "fm-watch.sh missing kimi busy signatures"
  assert_grep 'thinking\.\.\.|Running a command' "$tmuxlib" \
    "fm-tmux-lib.sh missing kimi busy signatures"
  pass "kimi busy signatures wired into watch/tmux defaults"
}

test_kimi_harness_doc_marks_verified() {
  local doc="$ROOT/docs/kimi-harness.md"
  [ -f "$doc" ] || fail "docs/kimi-harness.md missing"
  assert_grep '2026-07-23' "$doc" "worker cert doc omits 2026-07-23"
  assert_grep '0.27.0' "$doc" "worker cert doc omits 0.27.0"
  assert_grep 'thinking...' "$doc" "worker cert doc omits thinking... evidence"
  assert_grep 'Running a command' "$doc" "worker cert doc omits Running a command evidence"
  assert_grep 'Interrupted by user' "$doc" "worker cert doc omits interrupt evidence"
  assert_grep '"hook_event_name":"Stop"' "$doc" \
    "worker cert doc omits Stop hook payload evidence"
  assert_grep 'stop_hook_active' "$doc" "worker cert doc omits stop_hook_active"
  pass "docs/kimi-harness.md records dated worker verification"
}

test_harness_adapters_lists_kimi_worker() {
  local skill="$ROOT/.agents/skills/harness-adapters/SKILL.md"
  # shellcheck disable=SC2016  # backticks must stay literal in the skill prose
  assert_grep 'The verified WORKER adapters are `claude`, `codex`, `opencode`, `pi`, `grok`, `cursor`, and `kimi`' "$skill" \
    "verified WORKER adapter list missing kimi"
  assert_grep 'thinking...' "$skill" "harness-adapters missing kimi busy fact"
  assert_grep 'Running a command' "$skill" "harness-adapters missing kimi tool-busy fact"
  if grep -F 'Worker dispatch stays refused' "$skill" >/dev/null; then
    fail "harness-adapters still refuses kimi worker dispatch after certification"
  fi
  pass "harness-adapters lists kimi as a verified worker"
}

test_second_opinion_k3_registry() {
  local so="$ROOT/bin/fm-second-opinion.sh"
  assert_grep "REVIEWER_LABEL='k3'" "$so" "second-opinion missing k3 registry entry"
  assert_grep 'kimi-code/k3' "$so" "second-opinion k3 missing model pin"
  assert_grep '--prompt' "$so" "second-opinion k3 missing --prompt"
  pass "second-opinion registers k3 reviewer"
}

test_kimi_launch_template_in_fm_spawn
test_kimi_busy_regex_wired
test_kimi_harness_doc_marks_verified
test_harness_adapters_lists_kimi_worker
test_second_opinion_k3_registry
