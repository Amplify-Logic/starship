#!/usr/bin/env bash
# Behavior tests for deterministic crew-dispatch profile selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-dispatch-select-tests)
mkdir -p "$TMP_ROOT"

# A quota-axi stand-in that records any call, so a test can prove selection
# never consults quota: spendPriority ranking belongs to quota-array-dispatch.
quota_spy() {  # <case-name> -> fakebin dir; marker at <fakebin>/../quota-called
  local fakebin marker
  fakebin=$(fm_fakebin "$TMP_ROOT/$1")
  marker="$TMP_ROOT/$1/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

test_retired_quota_balanced_still_loads_without_ranking() {
  local fakebin marker out err status rule
  fakebin=$(quota_spy retired)
  marker="$TMP_ROOT/retired/quota-called"
  rule='{"when":"big work","use":[{"harness":"cursor","model":"composer-2.5","effort":"high"},{"harness":"claude","model":"opus","effort":"high"},{"harness":"codex","model":"gpt-6-sol","effort":"high"}],"select":"quota-balanced"}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$rule" 2>"$TMP_ROOT/retired.err")
  status=$?
  err=$(cat "$TMP_ROOT/retired.err")
  expect_code 0 "$status" "a rule still naming quota-balanced must keep loading"
  [ "$out" = '{"harness":"cursor","model":"composer-2.5","effort":"high"}' ] \
    || fail "the retired selector should resolve to the first profile, got: $out"
  assert_contains "$err" "spendPriority" "the retired selector should point at the spendPriority ranker"
  assert_contains "$err" "quota-array-dispatch" "the retired selector should name the owning skill"
  [ ! -e "$marker" ] || fail "the retired selector must never consult quota-axi"

  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$rule" 2>/dev/null)
  [ "$out" = '{"harness":"cursor","model":"composer-2.5","effort":"high"}' ] \
    || fail "--select quota-balanced should resolve to the first profile, got: $out"
  [ ! -e "$marker" ] || fail "--select quota-balanced must never consult quota-axi"
  pass "a rule naming the retired quota-balanced selector loads, resolves to its first profile, and never ranks by quota"
}

test_backward_compatible_first_selection() {
  local fakebin marker out single array_rule
  fakebin=$(quota_spy no-call)
  marker="$TMP_ROOT/no-call/quota-called"

  single='{"harness":"grok","model":"grok-4","effort":"high"}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$single")
  [ "$out" = '{"harness":"grok","model":"grok-4","effort":"high"}' ] \
    || fail "single-object use should resolve to itself, got: $out"

  array_rule='{"when":"big work","use":[{"harness":"claude","effort":"high"},{"harness":"codex","effort":"high"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$array_rule")
  [ "$out" = '{"harness":"claude","effort":"high"}' ] \
    || fail "array without select should resolve to first, got: $out"
  [ ! -e "$marker" ] || fail "quota-axi should never be called for first-profile selection"
  pass "single-object use and no-select arrays preserve first-profile selection"
}

test_retired_quota_balanced_still_loads_without_ranking
test_backward_compatible_first_selection

echo "# all fm-dispatch-select tests passed"
