#!/usr/bin/env bash
# Contract and synthetic event replay for the PR body compliance workflow.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

# The signature and attestation rules are no longer spelled in this workflow:
# they live in the pinned shared action below, so nothing here can replay them.
# The gate contract below holds this workflow to the creator's v1.80.1 pin, so a
# silent re-pin fails here. tests/fm-no-mistakes-required.test.sh is the
# creator's own suite driving that action's real verifier; it still pins its
# earlier SHA, whose verifier accepts and rejects the same attestation shapes.
GATE_ACTION=kunchenguid/no-mistakes/.github/actions/require-no-mistakes
GATE_ACTION_REF=f6441c96c352a18b9cadcaef6b6c7017e9ac3970

command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/no-mistakes-required.yml as YAML"

# The workflow is parsed as YAML and asked what GitHub would act on, rather than
# how the file happens to be spelled. `on` is a YAML 1.1 boolean, so a workflow
# document carries it under the `true` key.
workflow_query() {
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
trigger = doc.key?("on") ? doc.fetch("on") : doc.fetch(true)
case ARGV[1]
when "pull-request-types"
  puts trigger.fetch("pull_request").fetch("types").join(" ")
when "gate-step-uses"
  doc.fetch("jobs").fetch("check").fetch("steps").each { |step| puts step.fetch("uses", "") }
else
  raise "unknown query: #{ARGV[1]}"
end
' "$WORKFLOW" "$1"
}

test_gate_is_the_pinned_shared_action() {
  local types uses action ref
  types=$(workflow_query pull-request-types) || fail "could not read the workflow's pull_request types"
  [ "$types" = "opened edited synchronize reopened" ] \
    || fail "gate must run on opened, edited, synchronize and reopened, got: $types"

  uses=$(workflow_query gate-step-uses) || fail "could not read the gate job's steps"
  [ "$(printf '%s\n' "$uses" | grep -c .)" = 1 ] \
    || fail "the gate job must verify through exactly one action, got: $uses"
  action=${uses%@*}
  ref=${uses##*@}
  [ "$action" = "$GATE_ACTION" ] || fail "gate no longer verifies through $GATE_ACTION, got: $action"
  [ "$ref" = "$GATE_ACTION_REF" ] \
    || fail "gate action ref drifted from the SHA tests/fm-no-mistakes-required.test.sh exercises: $ref"
  [ "${#ref}" = 40 ] && [ -z "${ref//[0-9a-f]/}" ] \
    || fail "gate action must be pinned to an immutable 40-hex commit SHA, not a mutable tag: $ref"
  pass "the gate verifies through the shared action pinned at an immutable commit SHA"
}

render_group() {
  local action=$1 run_id=$2
  case "$action" in
    opened|edited) printf 'no-mistakes-required-418-%s\n' "$run_id" ;;
    synchronize|reopened) printf 'no-mistakes-required-418-head-change\n' ;;
  esac
}

render_run_name() {
  local action=$1 run_number=$2 run_id=$3
  printf 'PR #418 body compliance - %s - event %s (run %s)\n' "$action" "$run_number" "$run_id"
}

test_event_identity_contract() {
  local opened edited_one edited_two synchronize reopened
  opened=$(render_group opened 9001)
  edited_one=$(render_group edited 9002)
  edited_two=$(render_group edited 9003)
  synchronize=$(render_group synchronize 9004)
  reopened=$(render_group reopened 9005)
  [ "$opened" != "$edited_one" ] && [ "$opened" != "$edited_two" ] && [ "$edited_one" != "$edited_two" ] || \
    fail "body events must have distinct immutable groups"
  [ "$synchronize" = "$reopened" ] || fail "synchronize and reopened must share head-change"
  case "$opened $edited_one $edited_two" in *head-change*) fail "body event reused head-change" ;; esac

  assert_grep "group: no-mistakes-required-\${{ github.event.pull_request.number }}-\${{ (github.event.action == 'opened' || github.event.action == 'edited') && github.run_id || 'head-change' }}" "$WORKFLOW" \
    "workflow does not implement immutable body-event groups"
  assert_grep 'cancel-in-progress: true' "$WORKFLOW" "workflow lost cancellation for coalesced head changes"
  pass "body event groups are distinct while head changes remain coalesced"
}

test_run_names_are_ordered_and_unique() {
  local first second
  first=$(render_run_name edited 73 9002)
  second=$(render_run_name edited 74 9003)
  [ "$first" = 'PR #418 body compliance - edited - event 73 (run 9002)' ] || fail "first synthetic run name is incomplete"
  [ "$second" = 'PR #418 body compliance - edited - event 74 (run 9003)' ] || fail "second synthetic run name is incomplete"
  [ "$first" != "$second" ] || fail "distinct events must have unique run names"
  assert_grep 'run-name: "PR #${{ github.event.pull_request.number }} body compliance - ${{ github.event.action }} - event ${{ github.run_number }} (run ${{ github.run_id }})"' "$WORKFLOW" \
    "workflow run name does not expose PR, action, monotonic run number, and immutable run ID"
  pass "run names expose monotonic numbers and immutable IDs"
}

test_security_and_signature_contract_is_preserved() {
  assert_grep '  pull_request:' "$WORKFLOW" "workflow must use pull_request"
  assert_no_grep 'pull_request_target' "$WORKFLOW" "workflow must not use pull_request_target"
  assert_grep '  contents: read' "$WORKFLOW" "contents permission must remain read-only"
  assert_no_grep 'contents: write' "$WORKFLOW" "workflow must not gain contents write permission"
  assert_no_grep 'secrets.' "$WORKFLOW" "workflow must not read secrets"
  assert_no_grep 'actions/checkout' "$WORKFLOW" "workflow must not check out fork code"
  assert_grep 'name: PR must be raised via no-mistakes' "$WORKFLOW" "stable required check name changed"
  assert_grep "github.event.pull_request.user.login != 'github-actions[bot]'" "$WORKFLOW" "github-actions bot exemption changed"
  assert_grep "github.event.pull_request.user.login != 'dependabot[bot]'" "$WORKFLOW" "dependabot bot exemption changed"
  assert_no_grep 'release-please[bot]' "$WORKFLOW" "Firstmate must not exempt release-please"
  pass "fork, permission, check-name, and bot-exemption contracts are preserved"
}

test_gate_is_the_pinned_shared_action
test_event_identity_contract
test_run_names_are_ordered_and_unique
test_security_and_signature_contract_is_preserved
