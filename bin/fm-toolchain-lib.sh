# shellcheck shell=bash
# Read-only runtime version-drift detection against the toolchain manifest.
# Usage: . bin/fm-toolchain-lib.sh
#
# fm_toolchain_check prints one actionable bootstrap line per drifted runtime:
#   TOOLCHAIN_DRIFT: <runtime> installed <version>, certified <version> (<evidence>) - <why>
# Silent for a runtime whose installed version matches, whose binary is not on
# PATH, or whose --version could not be parsed. Silent overall when the manifest
# is missing or has no rows.
#
# Rows come from docs/toolchain-manifest.tsv (override: FM_TOOLCHAIN_MANIFEST).
# That file owns the runtime set and every certified version; this file owns the
# probe, the comparison, and the diagnostic wording.
#
# ---------------------------------------------------------------------------
# Why this is detection only
# ---------------------------------------------------------------------------
# It FAILS OPEN by design: it reports drift and never blocks a launch, never
# installs, never pins, and always exits 0.
#
# That is a decision, not an omission. Claude Code, Codex, and Kimi all update
# themselves - Kimi's updater has fired from inside a managed worker seconds
# after spawn - so an installed version is not a stable fact even within one
# session. A strict equality gate in front of a self-updating binary converts
# every publisher release into an unscheduled fleet outage, which is exactly
# what bin/fm-primary.sh's exact-match Kimi pin already does: it is the reason a
# certified primary path is down rather than merely uncertified.
#
# The failure this check exists to prevent is the opposite one - silence. Every
# other certified runtime drifted past its certification with nothing noticing,
# because only the strict gate made drift visible and only for one runtime. So
# the goal is a loud, cheap, universal report that lets a human decide whether
# to re-certify or to pin, while work keeps moving in the meantime.
#
# Practical consequences of that choice, all deliberate:
#   - An unparseable --version is silence, not a diagnostic. A runtime that
#     changed its version banner is a manifest bug to fix, not a reason to nag
#     every session about a binary that is probably fine.
#   - An absent binary is silence. Required-tool absence is already owned by
#     bin/fm-bootstrap.sh's MISSING lines; repeating it here would double-report
#     one problem under two labels.
#   - Comparison is exact string inequality, with no ordering. Newer, older, and
#     sideways all read as drift, because "certified" means "this exact build
#     carries evidence", and a downgrade invalidates the evidence just as a
#     bump does. Runtime version strings here are not all semver anyway - Cursor
#     ships date-plus-hash builds.

# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_TOOLCHAIN_MANIFEST_DEFAULT="${FM_TOOLCHAIN_MANIFEST_DEFAULT:-docs/toolchain-manifest.tsv}"
FM_TOOLCHAIN_PROBE_TIMEOUT_DEFAULT="${FM_TOOLCHAIN_PROBE_TIMEOUT_DEFAULT:-5}"

# Extract a version from a --version banner: the first whitespace-separated
# token that starts with a digit and contains a dot. Prints nothing when the
# banner has no such token.
#
# Verified against every runtime in the manifest:
#   claude  "2.1.220 (Claude Code)"        -> 2.1.220
#   codex   "codex-cli 0.144.6"            -> 0.144.6
#   kimi    "0.31.1"                       -> 0.31.1
#   agent   "2026.07.23-e383d2b"           -> 2026.07.23-e383d2b
#   pi      "0.80.10"                      -> 0.80.10
fm_toolchain_parse_version() {
  awk '
    { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9][^ \t]*\./) { print $i; exit } }
  '
}

# Print the installed version of <command>, or nothing when it is absent, times
# out, fails, or prints no recognizable version.
fm_toolchain_installed_version() {
  local bin_name=$1 timeout_secs=$2 banner
  command -v "$bin_name" >/dev/null 2>&1 || return 0
  banner=$(fm_run_timeout "$timeout_secs" "$bin_name" --version 2>/dev/null </dev/null || true)
  [ -n "$banner" ] || return 0
  printf '%s\n' "$banner" | fm_toolchain_parse_version
}

# Compare the manifest at <root> against PATH and print one line per drifted
# runtime. Always exits 0; see this file's header for why it never blocks.
fm_toolchain_check() {
  local root=$1 manifest timeout_secs runtime bin_name certified why evidence
  local installed rest

  manifest=${FM_TOOLCHAIN_MANIFEST-$root/$FM_TOOLCHAIN_MANIFEST_DEFAULT}
  [ -n "$manifest" ] || return 0
  [ -f "$manifest" ] || return 0

  timeout_secs=${FM_TOOLCHAIN_PROBE_TIMEOUT:-$FM_TOOLCHAIN_PROBE_TIMEOUT_DEFAULT}
  case "$timeout_secs" in
    *[!0-9]* | '' | 0) timeout_secs=$FM_TOOLCHAIN_PROBE_TIMEOUT_DEFAULT ;;
  esac

  while IFS=$'\t' read -r runtime bin_name certified why evidence rest; do
    case "$runtime" in '' | '#'*) continue ;; esac
    [ -n "$bin_name" ] && [ -n "$certified" ] || continue
    installed=$(fm_toolchain_installed_version "$bin_name" "$timeout_secs")
    # No binary, no banner, no version: nothing honest to report.
    [ -n "$installed" ] || continue
    [ "$installed" != "$certified" ] || continue
    printf 'TOOLCHAIN_DRIFT: %s installed %s, certified %s (%s) - %s\n' \
      "$runtime" "$installed" "$certified" "${evidence:-no evidence recorded}" \
      "${why:-no rationale recorded}"
  done < "$manifest"
  return 0
}
