#!/usr/bin/env bash
# Behavior tests for bin/fm-secondmate-pin.sh: the versioned pin read, a set
# that edits only the mate's own line and resolves through the real
# bin/fm-harness.sh, clear, and refusals that leave the file untouched.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-secondmate-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-pin)
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home
  home=$("$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/$1") || return 1
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf -- '- music - Music crew (home: %s/music; scope: music; projects: sample; added 2026-11-17)\n' "$home" \
    > "$home/data/secondmates.md"
  printf -- '- plain - Plain crew (home: %s/plain; scope: other; projects: sample; added 2026-11-17)\n' "$home" \
    >> "$home/data/secondmates.md"
  printf '%s\n' "$home"
}

pin() {  # <home> <args...>
  local home=$1
  shift
  (unset FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE; FM_HOME="$home" "$PIN" "$@")
}

test_set_edits_only_that_mates_line() {
  local home out
  home=$(make_home set)
  printf '# pins\nclaude opus high\nmate plain: codex\n' > "$home/config/secondmate-harness"
  out=$(pin "$home" set music claude sonnet medium) || fail "set failed: $out"
  assert_equals fm-secondmate-pin.v1 "$(jq -r .schema <<<"$out")" "the pin read is versioned"
  assert_equals claude "$(jq -r .harness <<<"$out")" "the harness resolves"
  assert_equals sonnet "$(jq -r .model <<<"$out")" "the model resolves"
  assert_equals medium "$(jq -r .effort <<<"$out")" "the effort resolves"
  assert_equals mate "$(jq -r .source <<<"$out")" "the mate's own line governs"
  assert_contains "$(cat "$home/config/secondmate-harness")" "mate plain: codex" "another mate's line is kept"
  assert_contains "$(cat "$home/config/secondmate-harness")" "claude opus high" "the default line is kept"
  out=$(pin "$home" set music claude opus) || fail "second set failed: $out"
  assert_equals 1 "$(grep -c '^mate music:' "$home/config/secondmate-harness")" "a second set replaces the line"
  assert_equals null "$(jq -r .effort <<<"$out")" "an omitted effort is absent"
  out=$(pin "$home" clear music) || fail "clear failed: $out"
  assert_equals default "$(jq -r .source <<<"$out")" "clear falls back to the default line"
  assert_equals opus "$(jq -r .model <<<"$out")" "the default line's model applies"
  pass "fm-secondmate-pin: set and clear edit only that mate's line"
}

test_refusals_leave_the_file_untouched() {
  local home before out
  home=$(make_home refuse)
  # A legacy file: a second plain line is ignored only while no mate line exists.
  printf 'claude opus high\ncodex\n' > "$home/config/secondmate-harness"
  before=$(cat "$home/config/secondmate-harness")
  out=$(pin "$home" set music claude sonnet 2>&1) && fail "a set that breaks the file must refuse: $out"
  assert_contains "$out" "would not resolve" "the refusal says the file would break"
  assert_equals "$before" "$(cat "$home/config/secondmate-harness")" "a refused set changes nothing"
  out=$(pin "$home" set drums claude 2>&1) && fail "an unregistered mate must refuse"
  out=$(pin "$home" set music nosuchharness 2>&1) && fail "an unknown harness must refuse"
  out=$(pin "$home" set music claude opus extreme 2>&1) && fail "an unknown effort must refuse"
  out=$(pin "$home" set music default opus 2>&1) && fail "a default pin with a model must refuse"
  out=$(pin "$home" set music claude -oops 2>&1) && fail "a model starting with a dash must refuse"
  out=$(pin "$home" set ../music claude 2>&1) && fail "a mate id with a path must refuse"
  assert_equals "$before" "$(cat "$home/config/secondmate-harness")" "no refusal changes the file"
  out=$(FM_HOME='' "$PIN" show music 2>&1) && fail "an unset FM_HOME must refuse"
  pass "fm-secondmate-pin: refusals leave the pin file untouched"
}

test_show_without_a_pin_file() {
  local home out
  home=$(make_home show)
  out=$(pin "$home" show music) || fail "show failed: $out"
  assert_equals none "$(jq -r .source <<<"$out")" "no pin file pins nothing"
  pass "fm-secondmate-pin show: reports an absent pin"
}

test_set_edits_only_that_mates_line
test_refusals_leave_the_file_untouched
test_show_without_a_pin_file
