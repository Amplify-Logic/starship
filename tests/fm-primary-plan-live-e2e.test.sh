#!/usr/bin/env bash
# Default-on live guard for the first mate's plan-based default effort
# (bin/fm-primary.sh "Plan default") against the REAL installed Claude CLI.
#
# The default comes from vendor output - the subscriptionType field of
# `claude auth status` and oauthAccount.organizationRateLimitTier in the account
# record beside the Claude config directory - so a fake can only restate the
# assumption written into it. This guard reads the operator's own signed-in
# account, read-only, and proves both signals still exist in the shape the
# launcher reads, then that a dry-run launch names the plan it resolved instead
# of falling back to "the Claude plan cannot be read".
#
# It submits no prompt and spends no tokens, so the shared live gate runs it by
# default wherever claude is installed. A machine whose Claude is not signed in
# with a Claude subscription has no plan to read and is reported, not passed.
# Run it after every Claude Code upgrade and before trusting the "First mate
# plan default" entry in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_PRIMARY_PLAN_LIVE_E2E claude jq

TMP_ROOT=$(fm_test_tmproot fm-primary-plan-live)
version=$(claude --version 2>/dev/null | head -1)
status=$(claude auth status </dev/null 2>/dev/null) || true
method=$(printf '%s' "$status" | jq -r 'select(.loggedIn == true) | .authMethod // empty' 2>/dev/null)
if [ "$method" != claude.ai ]; then
  if [ "${FM_PRIMARY_PLAN_LIVE_E2E:-${FM_LIVE:-}}" = 1 ]; then
    fail "claude $version: the plan live guard was requested but this Claude is not signed in with a Claude subscription (auth method '${method:-none}')"
  fi
  echo "skip: live: claude $version is not signed in with a Claude subscription, so there is no plan to read"
  exit 0
fi

subscription=$(printf '%s' "$status" | jq -r '.subscriptionType // empty')
[ -n "$subscription" ] ||
  fail "claude $version: \`claude auth status\` no longer reports subscriptionType for a subscription sign-in; revisit claude_plan in bin/fm-primary.sh"

record="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
tier=$(jq -r '.oauthAccount.organizationRateLimitTier // empty' "$record" 2>/dev/null)
if [ "$subscription" = max ]; then
  case "$tier" in
    *20x* | *5x*) ;;
    *) fail "claude $version: a Max sign-in's account record no longer carries a 5x or 20x rate-limit tier (read '${tier:-nothing}' from $record); revisit claude_plan in bin/fm-primary.sh" ;;
  esac
fi

mkdir -p "$TMP_ROOT/home"
out=$(cd "$TMP_ROOT" && FM_HOME="$TMP_ROOT/home" FM_PRIMARY_DRY_RUN=1 "$ROOT/bin/fm-primary.sh" opus 2>&1) ||
  fail "claude $version: the dry-run launch failed: $out"
case "$subscription" in
  pro | max)
    assert_contains "$out" "the default for a Claude" \
      "claude $version: a $subscription sign-in did not resolve to a plan default"
    ;;
  *)
    assert_contains "$out" "the Claude plan cannot be read" \
      "claude $version: a $subscription sign-in was given a Pro or Max default"
    ;;
esac
assert_contains "$out" "config/primary-effort sets your own" \
  "claude $version: the launch line no longer says how to change the effort"
pass "claude $version: the first mate's default effort reads the real $subscription plan (tier ${tier:-none})"
