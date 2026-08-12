#!/usr/bin/env bash
# Static regression tests for the captain-facing plain-English translation
# contract owned by AGENTS.md section 9.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
BOOTSTRAP="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
DECISION="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODEXAPP="$ROOT/.agents/skills/firstmate-codexapp/SKILL.md"
FMX="$ROOT/.agents/skills/fmx-respond/SKILL.md"
UPDATE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"
BEARINGS="$ROOT/.agents/skills/bearings/SKILL.md"
AHOY="$ROOT/.agents/skills/ahoy/SKILL.md"
README="$ROOT/README.md"

section_9() {
  awk '
    /^## 9\. Escalation and captain etiquette$/ { found = 1 }
    found && /^## 10\. / { exit }
    found { print }
  ' "$AGENTS"
}

test_section_9_owns_positive_translation_contract() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Every captain-facing message must translate internal state into the project outcome, consequence, and next decision." \
    "section 9 does not own the positive captain-facing translation contract"
  assert_contains "$contract" "Use the captain's nouns:" \
    "section 9 does not require captain-owned nouns"
  assert_contains "$contract" "When evidence uses an internal label, rewrite it before sending:" \
    "section 9 does not own the rewrite mapping list"
  pass "section 9 owns the positive captain-facing translation contract"
}

test_scout_remains_allowed_house_vocabulary() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation" \
    "section 9 does not preserve scout as allowed Firstmate vocabulary"
  assert_not_contains "$contract" "scout -> investigation" \
    "section 9 must not map scout to investigation"
  assert_not_contains "$contract" "scout, ship" \
    "section 9 must not add scout to the internal-vocabulary ban"
  assert_not_contains "$contract" "secondmate -> domain supervisor" \
    "section 9 must not map secondmate to domain supervisor"
  pass "scout remains allowed in private captain chat"
}

test_compressed_safety_labels_have_plain_renderings() {
  local contract
  contract=$(section_9)
  for phrase in \
    "fail-closed" \
    "fails closed" \
    "fail-open" \
    "fails open" \
    "fail loudly"; do
    assert_contains "$contract" "$phrase" "section 9 does not cover compressed safety label '$phrase'"
  done
  assert_contains "$contract" "stops safely when something goes wrong" \
    "fail-closed behavior lacks a concrete plain rendering"
  assert_contains "$contract" "refuses rather than proceeding" \
    "fail-closed behavior lacks refusal wording"
  assert_contains "$contract" "steps aside and lets work continue when the check cannot complete" \
    "fail-open behavior lacks a concrete plain rendering"
  pass "compressed safety labels require concrete plain renderings"
}

test_mapping_list_covers_high_risk_internal_families() {
  local contract
  contract=$(section_9)
  for phrase in \
    "worktree, checkout, primary checkout, or local-main -> local copy" \
    "teardown -> cleanup" \
    "wake, watcher, heartbeat, stale, signal, or check -> notification" \
    "hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision" \
    "done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result" \
    "brief -> instructions" \
    "crewmate -> worker" \
    "harness, backend, runtime, or adapter -> worker runtime or tool" \
    "status file, metadata, state, task id, or raw path -> durable record"; do
    assert_contains "$contract" "$phrase" "section 9 mapping list is missing '$phrase'"
  done
  pass "section 9 maps high-risk internal vocabulary families"
}

test_verbatim_internal_evidence_is_rejected_from_chat() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into captain chat." \
    "section 9 does not reject verbatim internal evidence in captain chat"
  assert_contains "$contract" "Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms" \
    "section 9 does not preserve private evidence precision"
  assert_contains "$contract" "the captain-facing chat summary that points to the report still follows this translation rule" \
    "section 9 does not keep chat summaries plain English"
  pass "captain chat rejects verbatim internal evidence while private reports stay precise"
}

test_routine_no_action_response_is_event_scoped() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" 'reply exactly `Captain, shipshape.` without characterizing the visible session' \
    "section 9 does not require the exact event-scoped routine no-action response"
  assert_not_contains "$contract" 'Captain, no decision is needed.' \
    "section 9 implies the visible session has no unrelated open decisions"
  pass "routine no-action response is exact and scoped to its event"
}

test_ahoy_contract() {
  assert_present "$AHOY" "ahoy skill is missing"
  assert_grep 'name: ahoy' "$AHOY" "ahoy skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$AHOY" "ahoy skill is not user-invocable"
  assert_grep '  internal: true' "$AHOY" "ahoy skill is not internal"
  [ ! -e "$ROOT/skills/ahoy" ] || fail "ahoy must not exist in the public installer-facing skills directory"
  assert_grep '| `/ahoy`' "$README" "README built-in skills table does not list /ahoy"
  assert_grep '[`../bearings/SKILL.md`](../bearings/SKILL.md)' "$AHOY" \
    "first-message fallback does not delegate to Bearings"
  assert_grep 'session-history-only' "$AHOY" "later Ahoy recaps are not limited to visible history"
  assert_grep 'every explicit captain decision that remains unanswered' "$AHOY" \
    "Ahoy does not preserve visibly unanswered decisions"
  assert_grep 'address the captain directly at least once' "$AHOY" \
    "Ahoy does not enforce the direct-address contract"
  assert_grep 'Use the captain'"'"'s project language' "$AHOY" \
    "Ahoy does not require captain-facing outcome language"
  pass "ahoy is internal, visible-history-only, decision-aware, and captain-facing"
}

test_outward_facing_skill_points_reference_section_9_owner() {
  assert_grep "using \`AGENTS.md\` section 9's captain-facing translation contract" "$BOOTSTRAP" \
    "bootstrap diagnostics do not reference section 9 at captain handoff"
  assert_grep "Acknowledge** in \`AGENTS.md\` section 9 language" "$AFK" \
    "afk acknowledgement does not reference section 9"
  assert_grep "Captain, away mode is active; I will batch routine updates" "$AFK" \
    "afk acknowledgement lacks a local plain-English example"
  assert_grep "as decisions from Bearings' Captain's Call section under \`AGENTS.md\` section 9" "$DECISION" \
    "decision relay does not reference section 9"
  assert_grep "using \`AGENTS.md\` section 9; do not mention metadata, harness, window, or worktree" "$RECOVERY" \
    "stuck-worker failure does not reference section 9"
  assert_grep "under \`AGENTS.md\` section 9 that the requested worker runtime is not verified yet" "$HARNESS" \
    "runtime fallback does not reference section 9"
  assert_grep "use firstmate's own verified runtime for current work" "$HARNESS" \
    "runtime fallback does not require the current-work fallback"
  assert_grep "Do not pause current work for that future-verification choice, and never launch an unverified adapter." "$HARNESS" \
    "runtime fallback permits waiting on future verification or launching an unverified adapter"
  assert_grep "translate status prefixes and return-channel evidence through \`AGENTS.md\` section 9" "$CODEXAPP" \
    "Codex Desktop result reporting does not reference section 9"
  assert_grep "It supplements \`AGENTS.md\` section 9; apply both, and this public-channel rule wins wherever it is stricter." "$FMX" \
    "X reply safety does not state that it supplements section 9"
  assert_grep "under \`AGENTS.md\` section 9 without firstmate's internal vocabulary" "$UPDATE" \
    "Firstmate update reporting does not reference section 9"
  assert_grep "The chat follows \`AGENTS.md\` section 9" "$BEARINGS" \
    "the bearings chat digest does not reference section 9"
  pass "outward-facing skill handoffs point to the section 9 owner"
}

# The pure-upstream trial (data/fm-upstream-trial-verdict-v2/report.md) recorded two
# captain-facing wording failures alongside the completion-truth defect: internal
# mechanics leaking into the visible surface, and an "all clear" announced while a
# completion problem was still unresolved. Bearings is the surface that reports fleet
# outcomes, so it is where both rules have to hold.
test_bearings_forbids_premature_all_clear() {
  assert_grep "Never render an all-clear verdict while anything is unresolved." "$BEARINGS" \
    "bearings does not forbid a premature all-clear verdict"
  assert_grep "CLAIM ABOUT FLEET WORK OUTCOMES" "$BEARINGS" \
    "bearings does not scope the ban to verdicts and work-outcome claims"
  assert_grep "Do not turn an unavailable or unreadable state into a verdict that work is fine" "$BEARINGS" \
    "bearings treats unreadable state as an all-clear"
  # The ban must not swallow the always-render rule: a truthful empty-state sentence
  # for one section is a fact about that section, not an all-clear about the fleet,
  # so suppressing it would trade one trust failure for another.
  assert_grep "A section's own empty-state sentence is not such a verdict" "$BEARINGS" \
    "bearings lets the all-clear ban suppress a factual empty-state sentence"
  assert_grep "Every section ALWAYS renders, even when empty, with its short empty-state sentence" "$BEARINGS" \
    "bearings dropped the always-render empty-state rule"
  pass "bearings forbids a premature all-clear verdict without suppressing empty-state facts"
}

test_bearings_guarantees_completion_truth() {
  assert_grep "including one recorded seconds ago" "$BEARINGS" \
    "bearings does not require completions recorded up to report time"
  assert_grep "always keeps a slot and the cap can never be what drops it" "$BEARINGS" \
    "bearings does not pin the cap direction that keeps the newest completion visible"
  assert_grep "fm-landed-lib.sh" "$BEARINGS" \
    "bearings does not point at the ordering owner"
  # The guarantee has to be scoped to what the ordering can actually deliver: an
  # undated Done row can rotate out under the cap, a completion never recorded into
  # Done cannot appear at all, and only rows at the fleet's newest completion date
  # are reserved against the cap once there are more homes than slots. An
  # unconditional promise would tell the agent to trust the list in exactly the
  # cases it is known to be incomplete.
  assert_grep "recorded with its completion date" "$BEARINGS" \
    "bearings promises completion truth without scoping it to a recorded completion date"
  assert_grep "Three gaps sit outside that guarantee" "$BEARINGS" \
    "bearings does not name the gaps its ordering cannot cover"
  assert_grep "more homes than the cap has slots" "$BEARINGS" \
    "bearings does not name the home-count gap, so a capacity drop reads as a recording failure"
  pass "bearings scopes the completion-truth guarantee to what the ordering delivers"
}

test_section_9_owner_is_not_duplicated_into_skills() {
  local duplicate_count file
  duplicate_count=0
  for file in "$BOOTSTRAP" "$AFK" "$DECISION" "$RECOVERY" "$HARNESS" "$CODEXAPP" "$UPDATE" "$BEARINGS" "$AHOY"; do
    if grep -Fq "When evidence uses an internal label, rewrite it before sending:" "$file"; then
      duplicate_count=$((duplicate_count + 1))
    fi
  done
  [ "$duplicate_count" -eq 0 ] || fail "skills duplicated section 9's mapping owner"
  pass "skills cross-reference section 9 instead of duplicating the mapping list"
}

test_section_9_owns_positive_translation_contract
test_scout_remains_allowed_house_vocabulary
test_compressed_safety_labels_have_plain_renderings
test_mapping_list_covers_high_risk_internal_families
test_verbatim_internal_evidence_is_rejected_from_chat
test_routine_no_action_response_is_event_scoped
test_ahoy_contract
test_outward_facing_skill_points_reference_section_9_owner
test_section_9_owner_is_not_duplicated_into_skills
test_bearings_forbids_premature_all_clear
test_bearings_guarantees_completion_truth
