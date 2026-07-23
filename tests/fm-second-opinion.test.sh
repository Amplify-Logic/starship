#!/usr/bin/env bash
# Behavior tests for bin/fm-second-opinion.sh: rival-model second-opinion wrapper.
#
# Covers happy-path --out header writes, neutral-cwd enforcement, unknown
# reviewer refusal, quota floor refusal plus FM_SECOND_OPINION_FORCE override,
# ambient API-key stripping, and empty reviewer output as a loud failure.
# The `pi` binary is stubbed so the suite never spends a real Codex/OpenAI run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SO_SH="$ROOT/bin/fm-second-opinion.sh"
TMP=$(fm_test_tmproot fm-second-opinion)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

write_quota_fixture() {
  local path=$1 remaining=$2
  cat >"$path" <<JSON
{
  "schemaVersion": 2,
  "providers": [
    {
      "provider": "codex",
      "windows": [
        {
          "id": "five_hour",
          "kind": "session",
          "percentRemaining": ${remaining}
        }
      ],
      "state": { "status": "fresh" }
    }
  ]
}
JSON
}

install_pi_stub() {
  local fakebin=$1 mode=${2:-ok}
  cat >"$fakebin/pi" <<SH
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$*" > "\${FM_SECOND_OPINION_TEST_ARGV_LOG:?}"
pwd -P > "\${FM_SECOND_OPINION_CWD_LOG:?}"
if [ -n "\${ANTHROPIC_API_KEY+x}" ] || [ -n "\${OPENAI_API_KEY+x}" ]; then
  printf 'API key was set\\n' >&2
  exit 9
fi
case "${mode}" in
  empty)
    exit 0
    ;;
  fail)
    printf 'stub pi refusal\\n' >&2
    exit 3
    ;;
  *)
    printf 'FINDING: CRITICAL - stub finding for: %s\\n' "\$#"
    printf 'hostile review body\\n'
    exit 0
    ;;
esac
SH
  chmod +x "$fakebin/pi"
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$SO_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-second-opinion.sh --out' "--help usage"
  assert_contains "$out" 'docs/second-opinion.md' "--help docs pointer"
  pass "fm-second-opinion --help exits 0"
}

test_happy_path_writes_out_with_header() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP/happy")
  install_pi_stub "$fakebin" ok
  write_quota_fixture "$TMP/happy/quota.json" 80

  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_SECOND_OPINION_QUOTA_JSON="$TMP/happy/quota.json" \
    FM_SECOND_OPINION_TEST_ARGV_LOG="$TMP/happy/argv.txt" \
    FM_SECOND_OPINION_CWD_LOG="$TMP/happy/cwd.txt" \
    ANTHROPIC_API_KEY=should-be-stripped \
    OPENAI_API_KEY=should-be-stripped \
    env -u FM_SECOND_OPINION_BIN -u FM_SECOND_OPINION_FORCE \
      "$SO_SH" --out "$TMP/happy/out.md" -- "adopt the gateway design" 2>&1
  )
  rc=$?
  set -e

  expect_code 0 "$rc" "happy-path exit"
  assert_contains "$(cat "$TMP/happy/out.md")" '# Second-opinion review' \
    "happy-path: header present"
  assert_contains "$(cat "$TMP/happy/out.md")" 'Reviewer: sol' \
    "happy-path: reviewer in header"
  assert_contains "$(cat "$TMP/happy/out.md")" 'Subject: adopt the gateway design' \
    "happy-path: subject in header"
  assert_contains "$(cat "$TMP/happy/out.md")" 'hostile review body' \
    "happy-path: reviewer body written"
  assert_contains "$(cat "$TMP/happy/argv.txt")" '--print' \
    "happy-path: pi --print"
  assert_contains "$(cat "$TMP/happy/argv.txt")" 'openai-codex/gpt-5.6-sol' \
    "happy-path: sol model"
  assert_contains "$(cat "$TMP/happy/argv.txt")" '--thinking xhigh' \
    "happy-path: thinking xhigh"
  assert_contains "$out" 'quota advisory: Codex general-window percentRemaining=80' \
    "happy-path: quota advisory line"
  assert_contains "$out" 'wrote' \
    "happy-path: wrapper reports the output path"
  assert_not_contains "$out" 'API key was set' \
    "happy-path: must not pass ambient API keys into pi"
  pass "fm-second-opinion writes --out with header and strips API keys"
}

test_neutral_cwd_not_repo() {
  local fakebin out rc cwd_recorded repo
  fakebin=$(fm_fakebin "$TMP/cwd")
  install_pi_stub "$fakebin" ok
  write_quota_fixture "$TMP/cwd/quota.json" 90
  repo=$(cd "$ROOT" && pwd -P)

  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_SECOND_OPINION_QUOTA_JSON="$TMP/cwd/quota.json" \
    FM_SECOND_OPINION_TEST_ARGV_LOG="$TMP/cwd/argv.txt" \
    FM_SECOND_OPINION_CWD_LOG="$TMP/cwd/cwd.txt" \
    env -u FM_SECOND_OPINION_BIN -u FM_SECOND_OPINION_FORCE \
      "$SO_SH" --out "$TMP/cwd/out.md" -- "neutral cwd check" 2>&1
  )
  rc=$?
  set -e

  expect_code 0 "$rc" "neutral-cwd exit"
  cwd_recorded=$(cat "$TMP/cwd/cwd.txt")
  [ -n "$cwd_recorded" ] || fail "neutral-cwd: cwd log empty"
  if [ "$cwd_recorded" = "$repo" ]; then
    fail "neutral-cwd: pi was invoked with the repo as cwd ($cwd_recorded)"
  fi
  case "$cwd_recorded" in
    "$repo"|"$repo"/*)
      fail "neutral-cwd: pi cwd is inside the repo ($cwd_recorded)"
      ;;
  esac
  assert_contains "$out" 'wrote' "neutral-cwd: completed write"
  pass "fm-second-opinion does not invoke pi with the repo as cwd"
}

test_unknown_reviewer_refused() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP/unknown")
  install_pi_stub "$fakebin" ok
  write_quota_fixture "$TMP/unknown/quota.json" 90

  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_SECOND_OPINION_QUOTA_JSON="$TMP/unknown/quota.json" \
    env -u FM_SECOND_OPINION_BIN \
      "$SO_SH" --out "$TMP/unknown/out.md" --reviewer not-a-real-reviewer -- "should refuse" 2>&1
  )
  rc=$?
  set -e

  expect_code 1 "$rc" "unknown-reviewer exit"
  assert_contains "$out" 'unknown reviewer: not-a-real-reviewer' \
    "unknown-reviewer: refusal message"
  assert_absent "$TMP/unknown/out.md" \
    "unknown-reviewer: must not write --out"
  pass "fm-second-opinion refuses unknown reviewer names loudly"
}

test_quota_floor_refusal_and_force_override() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP/quota")
  install_pi_stub "$fakebin" ok
  write_quota_fixture "$TMP/quota/low.json" 5

  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_SECOND_OPINION_QUOTA_JSON="$TMP/quota/low.json" \
    FM_SECOND_OPINION_TEST_ARGV_LOG="$TMP/quota/argv-refuse.txt" \
    FM_SECOND_OPINION_CWD_LOG="$TMP/quota/cwd-refuse.txt" \
    env -u FM_SECOND_OPINION_BIN -u FM_SECOND_OPINION_FORCE \
      "$SO_SH" --out "$TMP/quota/out-refuse.md" -- "low quota" 2>&1
  )
  rc=$?
  set -e

  expect_code 1 "$rc" "quota-floor refusal exit"
  assert_contains "$out" 'below floor' \
    "quota-floor: refusal message"
  assert_absent "$TMP/quota/out-refuse.md" \
    "quota-floor: must not write --out when refusing"

  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_SECOND_OPINION_QUOTA_JSON="$TMP/quota/low.json" \
    FM_SECOND_OPINION_FORCE=1 \
    FM_SECOND_OPINION_TEST_ARGV_LOG="$TMP/quota/argv-force.txt" \
    FM_SECOND_OPINION_CWD_LOG="$TMP/quota/cwd-force.txt" \
    env -u FM_SECOND_OPINION_BIN \
      "$SO_SH" --out "$TMP/quota/out-force.md" -- "low quota forced" 2>&1
  )
  rc=$?
  set -e

  expect_code 0 "$rc" "quota-floor force override exit"
  assert_contains "$out" 'FM_SECOND_OPINION_FORCE=1' \
    "quota-floor: force override advisory"
  assert_contains "$(cat "$TMP/quota/out-force.md")" 'hostile review body' \
    "quota-floor: force override still writes review"
  pass "fm-second-opinion refuses below quota floor and honors FORCE override"
}

test_empty_reviewer_output_fails_loudly() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP/empty")
  install_pi_stub "$fakebin" empty
  write_quota_fixture "$TMP/empty/quota.json" 90

  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_SECOND_OPINION_QUOTA_JSON="$TMP/empty/quota.json" \
    FM_SECOND_OPINION_TEST_ARGV_LOG="$TMP/empty/argv.txt" \
    FM_SECOND_OPINION_CWD_LOG="$TMP/empty/cwd.txt" \
    env -u FM_SECOND_OPINION_BIN -u FM_SECOND_OPINION_FORCE \
      "$SO_SH" --out "$TMP/empty/out.md" -- "empty body" 2>&1
  )
  rc=$?
  set -e

  expect_code 1 "$rc" "empty-output exit"
  assert_contains "$out" 'empty output' \
    "empty-output: loud failure message"
  assert_absent "$TMP/empty/out.md" \
    "empty-output: must not write empty --out"
  pass "fm-second-opinion treats empty reviewer output as a loud failure"
}

test_help_exits_zero
test_happy_path_writes_out_with_header
test_neutral_cwd_not_repo
test_unknown_reviewer_refused
test_quota_floor_refusal_and_force_override
test_empty_reviewer_output_fails_loudly
