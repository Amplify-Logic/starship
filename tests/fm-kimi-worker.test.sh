#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

test_kimi_busy_regex_wired() {
  local composer="$ROOT/bin/fm-composer-lib.sh"
  # shellcheck source=bin/fm-composer-lib.sh
  . "$composer"
  printf '\xf0\x9f\x8c\x91 \xc2\xb7 thinking...\n' | grep -qE "$FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT" \
    || fail "Kimi busy spinner did not match its delivery signature"
  printf 'K3 thinking: max/high\n' | grep -qE "$FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT" \
    && fail "Kimi idle footer false-matched the delivery signature"
  pass "Kimi delivery signature distinguishes spinner from idle footer"
}

test_kimi_busy_regex_wired
