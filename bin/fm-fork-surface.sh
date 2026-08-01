#!/usr/bin/env bash
# Own the declared fork-surface manifest schema, queries, base snapshot, and CI gate.
#
# Usage:
#   fm-fork-surface.sh check
#   fm-fork-surface.sh list [--topology NAME] [--config]
#   fm-fork-surface.sh paths
#   fm-fork-surface.sh port-allowlist
#   fm-fork-surface.sh sync-base [GIT_REF]
#   fm-fork-surface.sh --help
#
# check validates schema 1 and assertions G1-G10 from docs/fork-surface.md.
# list prints active and frozen capabilities as tab-separated id/title rows.
# --topology filters list; --config appends each config or secret path.
# paths prints every declared owns path as a tab-separated id/path row.
# port-allowlist prints portable config paths, excluding secrets, one per line.
# sync-base rewrites the base path snapshot from GIT_REF (default: upstream_base).
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${FM_FORK_SURFACE_MANIFEST:-$ROOT/fork-surface.conf}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-fork-surface: %s\n' "$*" >&2
  exit 2
}

parse_manifest() {
  local out=$1
  [ -f "$MANIFEST" ] || die "manifest missing: ${MANIFEST#"$ROOT"/}"
  awk -F= '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function err(msg) { printf "fm-fork-surface: manifest line %d: %s\n", NR, msg > "/dev/stderr"; bad=1 }
    function known_cap_key(k) {
      return k == "id" || k == "title" || k == "layer" || k == "scope" || k == "status" || k == "why" || \
        k == "owns" || k == "modifies" || k == "anchor" || k == "proves" || \
        k == "proves_note" || k == "assert" || k == "config" || k == "secret" || \
        k == "commits" || k == "upstream_ref" || k == "topology" || \
        k == "retired_reason" || k == "retired_pr"
    }
    function singleton(k) {
      return k == "id" || k == "title" || k == "layer" || k == "scope" || k == "status" || k == "why" || \
        k == "proves_note" || k == "assert" || k == "topology" || \
        k == "retired_reason" || k == "retired_pr"
    }
    function flush(    i,k,v,id,layer,scope,status,assertion,topology,has_none) {
      if (!in_cap) return
      id=one["id"]
      for (k in required) if (count[k] != 1) err("capability requires exactly one " k)
      if (id == "") id="<missing-id-at-line-" cap_line ">"
      if (seen_id[id]++) err("duplicate capability id: " id)
      layer=one["layer"]; scope=one["scope"]; status=one["status"]; assertion=one["assert"]; topology=one["topology"]
      if (layer != "shared" && layer != "personal" && layer != "converged") err(id ": invalid layer: " layer)
      if (scope != "core" && scope != "team" && scope != "personal") err(id ": invalid scope: " scope)
      if (status != "active" && status != "frozen" && status != "retired") err(id ": invalid status: " status)
      if (assertion != "files+test" && assertion != "files" && assertion != "test") err(id ": invalid assert: " assertion)
      if (topology != "independent" && topology != "herdr-topology") err(id ": invalid topology: " topology)
      if (count["commits"] < 1) err(id ": requires at least one commits entry")
      if (status == "retired" && (count["retired_reason"] != 1 || count["retired_pr"] != 1)) err(id ": retired entries require retired_reason and retired_pr")
      if (status != "retired" && (count["retired_reason"] || count["retired_pr"])) err(id ": retirement fields require status = retired")
      for (i=1; i<=n; i++) {
        k=keys[i]; v=vals[i]
        if (k == "proves" && v == "none") has_none=1
        printf "C\t%s\t%s\t%s\t%d\n", id, k, v, lines[i]
      }
      if (has_none && count["proves_note"] != 1) err(id ": proves = none requires proves_note")
      delete one; delete count; delete keys; delete vals; delete lines
      n=0; in_cap=0
    }
    BEGIN {
      required["id"]=1; required["title"]=1; required["layer"]=1; required["scope"]=1; required["status"]=1
      required["why"]=1; required["assert"]=1; required["topology"]=1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[capability\][[:space:]]*$/ { flush(); in_cap=1; cap_line=NR; next }
    {
      if (index($0, "\t")) { err("tabs are not allowed"); next }
      if (index($0, "=") == 0) { err("expected key = value"); next }
      key=trim($1); value=substr($0, index($0, "=")+1); value=trim(value)
      if (key == "" || value == "") { err("empty key or value"); next }
      if (!in_cap) {
        if (key != "schema" && key != "upstream_remote" && key != "upstream_base" && key != "upstream_base_paths") {
          err("unknown header key: " key); next
        }
        if (header_seen[key]++) { err("duplicate header key: " key); next }
        printf "H\t%s\t%s\t%d\n", key, value, NR
        next
      }
      if (!known_cap_key(key)) { err("unknown capability key: " key); next }
      if (singleton(key) && count[key]++) { err("duplicate singleton key: " key); next }
      if (!singleton(key)) count[key]++
      if (singleton(key)) one[key]=value
      n++; keys[n]=key; vals[n]=value; lines[n]=NR
    }
    END {
      flush()
      for (k in header_seen) headers++
      if (header_seen["schema"] != 1 || header_seen["upstream_remote"] != 1 || \
          header_seen["upstream_base"] != 1 || header_seen["upstream_base_paths"] != 1) {
        printf "fm-fork-surface: manifest requires schema, upstream_remote, upstream_base, and upstream_base_paths exactly once\n" > "/dev/stderr"
        bad=1
      }
      if (bad) exit 2
    }
  ' "$MANIFEST" >"$out"
}

header_value() {
  local parsed=$1 key=$2
  awk -F '\t' -v want="$key" '$1 == "H" && $2 == want { print $3 }' "$parsed"
}

path_is_safe() {
  local path=$1
  case "$path" in
    ""|/*|./*|../*|*/../*|*/..|*//*|*[$'\r\n']*) return 1 ;;
  esac
  return 0
}

check_manifest() {
  local parsed tmp base snapshot schema snapshot_base failures=0
  local kind id key value line scope status assertion path pattern proof mode lanes count commit job
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-surface.XXXXXX")
  trap 'rm -rf "${tmp:-}"' EXIT
  parsed="$tmp/parsed"
  parse_manifest "$parsed"

  schema=$(header_value "$parsed" schema)
  [ "$schema" = 1 ] || { printf 'fm-fork-surface: unsupported schema: %s (expected 1)\n' "$schema" >&2; failures=$((failures + 1)); }
  base=$(header_value "$parsed" upstream_base)
  snapshot=$(header_value "$parsed" upstream_base_paths)
  path_is_safe "$snapshot" || { printf 'fm-fork-surface: unsafe upstream_base_paths: %s\n' "$snapshot" >&2; failures=$((failures + 1)); }
  snapshot="$ROOT/$snapshot"
  if [ ! -f "$snapshot" ]; then
    printf 'fm-fork-surface: base path snapshot missing: %s; run bin/fm-fork-surface.sh sync-base\n' "${snapshot#"$ROOT"/}" >&2
    failures=$((failures + 1))
  else
    snapshot_base=$(awk 'NR == 1 && /^# upstream_base = / { print $4 }' "$snapshot")
    if [ "$snapshot_base" != "$base" ]; then
      printf 'fm-fork-surface: upstream_base %s does not match snapshot base %s; run bin/fm-fork-surface.sh sync-base\n' "$base" "${snapshot_base:-<missing>}" >&2
      failures=$((failures + 1))
    fi
  fi

  # G1: path syntax and commit existence.
  while IFS=$'\t' read -r kind id key value line; do
    [ "$kind" = C ] || continue
    case "$key" in
      owns|modifies|config|secret)
        path_is_safe "$value" || { printf 'fm-fork-surface: %s: unsafe %s path at line %s: %s\n' "$id" "$key" "$line" "$value" >&2; failures=$((failures + 1)); }
        ;;
      anchor)
        path=${value%% :: *}
        pattern=${value#* :: }
        if [ "$path" = "$value" ] || ! path_is_safe "$path" || [ -z "$pattern" ]; then
          printf 'fm-fork-surface: %s: invalid anchor at line %s: %s\n' "$id" "$line" "$value" >&2
          failures=$((failures + 1))
        fi
        ;;
      proves)
        case "$value" in
          tests/*.test.sh|ci:*|none) ;;
          *) printf 'fm-fork-surface: %s: invalid proves value at line %s: %s\n' "$id" "$line" "$value" >&2; failures=$((failures + 1)) ;;
        esac
        ;;
      commits)
        for commit in $value; do
          if ! printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{7,40}$' || ! git -C "$ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
            printf 'fm-fork-surface: %s: commits entry does not resolve at line %s: %s\n' "$id" "$line" "$commit" >&2
            failures=$((failures + 1))
          fi
        done
        ;;
      upstream_ref)
        for commit in $value; do
          if ! printf '%s\n' "$commit" | grep -Eq '^[0-9a-f]{7,40}$'; then
            printf 'fm-fork-surface: %s: invalid upstream_ref at line %s: %s\n' "$id" "$line" "$commit" >&2
            failures=$((failures + 1))
          fi
        done
        ;;
    esac
  done <"$parsed"

  # G2 and G9: core/team files match assertions; personal surfaces are optional.
  while IFS=$'\t' read -r id scope status assertion path; do
    [ -n "$id" ] || continue
    if [ "$status" = retired ]; then
      if git -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
        printf 'fm-fork-surface: %s: retired surface is still tracked: %s; remove it or restore status = active\n' "$id" "$path" >&2
        failures=$((failures + 1))
      fi
    elif [ "$scope" != personal ] && { [ "$assertion" = files ] || [ "$assertion" = files+test ]; }; then
      if ! git -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
        printf 'fm-fork-surface: %s: declared %s surface missing from the index: %s; restore it or declare a reviewed retirement\n' "$id" "$scope" "$path" >&2
        failures=$((failures + 1))
      fi
    fi
  done < <(awk -F '\t' '
    $1 == "C" && $3 == "scope" { scope[$2]=$4 }
    $1 == "C" && $3 == "status" { status[$2]=$4 }
    $1 == "C" && $3 == "assert" { assertion[$2]=$4 }
    $1 == "C" && $3 == "owns" { n[$2]+=1; owns[$2 SUBSEP n[$2]]=$4 }
    END { for (id in n) for (i=1; i<=n[id]; i++) print id "\t" scope[id] "\t" status[id] "\t" assertion[id] "\t" owns[id SUBSEP i] }
  ' "$parsed")

  # Cache lane membership once for G3.
  : >"$tmp/lanes"
  for lanes in portable-parallel-1 portable-parallel-2 portable-serial real-herdr-gated; do
    while IFS= read -r proof; do
      [ -n "$proof" ] && printf '%s\t%s\n' "$proof" "$lanes" >>"$tmp/lanes"
    done < <("$ROOT/bin/fm-test-run.sh" --list --lane "$lanes")
  done

  # G3 and G4: every proving test/job is present and live in CI.
  while IFS=$'\t' read -r id scope proof; do
    [ "$scope" != personal ] || continue
    case "$proof" in
      tests/*.test.sh)
        mode=$(git -C "$ROOT" ls-files -s -- "$proof" | awk 'NR == 1 { print $1 }')
        if [ "$mode" != 100755 ]; then
          printf 'fm-fork-surface: %s: proving test must be tracked mode 100755: %s; run chmod +x %s and git add %s\n' "$id" "$proof" "$proof" "$proof" >&2
          failures=$((failures + 1))
        fi
        count=$(awk -F '\t' -v p="$proof" '$1 == p { n++ } END { print n+0 }' "$tmp/lanes")
        if [ "$count" -ne 1 ]; then
          printf 'fm-fork-surface: %s: proving test must belong to exactly one CI lane (found %s): %s; update bin/fm-test-run.sh lane ownership\n' "$id" "$count" "$proof" >&2
          failures=$((failures + 1))
        fi
        ;;
      ci:*)
        job=${proof#ci:}
        if ! awk -v want="$job" '$0 ~ "^  " want ":[[:space:]]*$" { found=1 } END { exit !found }' "$ROOT/.github/workflows/ci.yml"; then
          printf 'fm-fork-surface: %s: proving CI job is missing: %s; restore the job or update proves\n' "$id" "$job" >&2
          failures=$((failures + 1))
        fi
        ;;
    esac
  done < <(awk -F '\t' '
    $1 == "C" && $3 == "scope" { scope[$2]=$4 }
    $1 == "C" && $3 == "proves" { count[$2]+=1; proves[$2 SUBSEP count[$2]]=$4 }
    END { for (id in count) for (i=1; i<=count[id]; i++) print id "\t" scope[id] "\t" proves[id SUBSEP i] }
  ' "$parsed")

  # G5: author-selected markers defend in-place edits without hashes or line numbers.
  while IFS=$'\t' read -r id status scope value; do
    [ "$status" != retired ] && [ "$scope" != personal ] || continue
    path=${value%% :: *}
    pattern=${value#* :: }
    if [ ! -f "$ROOT/$path" ] || ! grep -Eq "$pattern" "$ROOT/$path" 2>/dev/null; then
      printf 'fm-fork-surface: %s: anchor missing in %s: %s; restore the fork edit or update the declaration in the same change\n' "$id" "$path" "$pattern" >&2
      failures=$((failures + 1))
    fi
  done < <(awk -F '\t' '
    $1 == "C" && $3 == "status" { status[$2]=$4 }
    $1 == "C" && $3 == "scope" { scope[$2]=$4 }
    $1 == "C" && $3 == "anchor" { count[$2]+=1; anchors[$2 SUBSEP count[$2]]=$4 }
    END { for (id in count) for (i=1; i<=count[id]; i++) print id "\t" status[id] "\t" scope[id] "\t" anchors[id SUBSEP i] }
  ' "$parsed")

  # G6: absent-from-base paths and owns declarations are exact sets with one owner.
  if [ -f "$snapshot" ]; then
    grep -v '^#' "$snapshot" | LC_ALL=C sort -u >"$tmp/base_paths"
    git -C "$ROOT" ls-files | LC_ALL=C sort -u >"$tmp/tracked"
    comm -23 "$tmp/tracked" "$tmp/base_paths" >"$tmp/fork_only"
    awk -F '\t' '$1 == "C" && $3 == "owns" { print $4 }' "$parsed" | LC_ALL=C sort >"$tmp/declared_raw"
    awk -F '\t' '
      $1 == "C" && $3 == "scope" { scope[$2]=$4 }
      $1 == "C" && $3 == "owns" { n[$2]+=1; owns[$2 SUBSEP n[$2]]=$4 }
      END { for (id in n) if (scope[id] != "personal") for (i=1; i<=n[id]; i++) print owns[id SUBSEP i] }
    ' "$parsed" | LC_ALL=C sort -u >"$tmp/declared_required"
    uniq -d "$tmp/declared_raw" >"$tmp/duplicate_owns"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf 'fm-fork-surface: path has multiple capability owners: %s; keep exactly one owns declaration\n' "$path" >&2
      failures=$((failures + 1))
    done <"$tmp/duplicate_owns"
    LC_ALL=C sort -u "$tmp/declared_raw" >"$tmp/declared"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf 'fm-fork-surface: unclaimed fork-only path: %s; add it to a [capability] block or declare a new capability\n' "$path" >&2
      failures=$((failures + 1))
    done < <(comm -23 "$tmp/fork_only" "$tmp/declared")
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf 'fm-fork-surface: owns path is present in the upstream-base snapshot or no longer tracked: %s; remove or reclassify it\n' "$path" >&2
      failures=$((failures + 1))
    done < <(comm -13 "$tmp/fork_only" "$tmp/declared_required")
  fi

  # G7 and G8: secret and portable config declarations agree with ignore/port policy.
  "$ROOT/bin/fm-fork-surface.sh" port-allowlist >"$tmp/manifest_portable"
  "$ROOT/bin/fm-home-port.sh" portable-config-files >"$tmp/home_portable"
  LC_ALL=C sort -u "$tmp/manifest_portable" -o "$tmp/manifest_portable"
  LC_ALL=C sort -u "$tmp/home_portable" -o "$tmp/home_portable"
  if ! cmp -s "$tmp/manifest_portable" "$tmp/home_portable"; then
    printf 'fm-fork-surface: portable config declarations disagree with bin/fm-home-port.sh fallback allowlist; update both in the same change\n' >&2
    comm -3 "$tmp/manifest_portable" "$tmp/home_portable" >&2 || true
    failures=$((failures + 1))
  fi
  while IFS=$'\t' read -r kind id key path line; do
    [ "$kind" = C ] || continue
    case "$key" in
      config|secret)
        if ! git -C "$ROOT" check-ignore -q -- "$path"; then
          printf 'fm-fork-surface: %s: %s knob is not gitignored: %s; add the path to .gitignore\n' "$id" "$key" "$path" >&2
          failures=$((failures + 1))
        fi
        ;;
    esac
    if [ "$key" = secret ]; then
      if ! "$ROOT/bin/fm-home-port.sh" refused-path "$path" >/dev/null; then
        printf 'fm-fork-surface: %s: secret knob is not refused by bin/fm-home-port.sh: %s; register it in is_refused_relpath\n' "$id" "$path" >&2
        failures=$((failures + 1))
      fi
    fi
  done <"$parsed"

  if [ "$failures" -ne 0 ]; then
    printf 'FORK_SURFACE FAIL failures=%s\n' "$failures" >&2
    return 1
  fi
  printf 'FORK_SURFACE OK capabilities=%s owned_paths=%s\n' \
    "$(awk -F '\t' '$1 == "C" && $3 == "id" { n++ } END { print n+0 }' "$parsed")" \
    "$(awk -F '\t' '$1 == "C" && $3 == "owns" { n++ } END { print n+0 }' "$parsed")"
}

list_capabilities() {
  local topology="" with_config=0 parsed kind id key value line
  while [ $# -gt 0 ]; do
    case "$1" in
      --topology) [ $# -ge 2 ] || die "--topology requires a value"; topology=$2; shift 2 ;;
      --config) with_config=1; shift ;;
      *) die "unknown list option: $1" ;;
    esac
  done
  parsed=$(mktemp "${TMPDIR:-/tmp}/fm-fork-surface-list.XXXXXX")
  trap 'rm -f "${parsed:-}"' EXIT
  parse_manifest "$parsed"
  awk -F '\t' -v topology="$topology" -v config="$with_config" '
    $1 == "C" && $3 == "title" { title[$2]=$4 }
    $1 == "C" && $3 == "status" { status[$2]=$4; order[++n]=$2 }
    $1 == "C" && $3 == "topology" { topo[$2]=$4 }
    $1 == "C" && ($3 == "config" || $3 == "secret") { knobs[$2]=knobs[$2] (knobs[$2] ? "," : "") $4 }
    END {
      for (i=1; i<=n; i++) {
        id=order[i]
        if (status[id] == "retired" || (topology != "" && topo[id] != topology)) continue
        printf "%s\t%s", id, title[id]
        if (config) printf "\t%s", knobs[id]
        printf "\n"
      }
    }
  ' "$parsed"
}

list_paths() {
  local parsed
  parsed=$(mktemp "${TMPDIR:-/tmp}/fm-fork-surface-paths.XXXXXX")
  trap 'rm -f "${parsed:-}"' EXIT
  parse_manifest "$parsed"
  awk -F '\t' '$1 == "C" && $3 == "owns" { print $2 "\t" $4 }' "$parsed"
}

port_allowlist() {
  local parsed
  parsed=$(mktemp "${TMPDIR:-/tmp}/fm-fork-surface-port.XXXXXX")
  trap 'rm -f "${parsed:-}"' EXIT
  parse_manifest "$parsed"
  awk -F '\t' '
    $1 == "C" && $3 == "status" { status[$2]=$4 }
    $1 == "C" && $3 == "secret" { secret[$4]=1 }
    $1 == "C" && $3 == "config" { n[$2]+=1; config[$2 SUBSEP n[$2]]=$4 }
    END {
      for (id in n) if (status[id] != "retired") for (i=1; i<=n[id]; i++) {
        path=config[id SUBSEP i]
        if (!secret[path]) print path
      }
    }
  ' "$parsed" | LC_ALL=C sort -u
}

sync_base() {
  local parsed ref base snapshot tmp
  parsed=$(mktemp "${TMPDIR:-/tmp}/fm-fork-surface-sync.XXXXXX")
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fork-surface-base.XXXXXX")
  trap 'rm -f "${parsed:-}" "${tmp:-}"' EXIT
  parse_manifest "$parsed"
  base=$(header_value "$parsed" upstream_base)
  ref=${1:-$base}
  git -C "$ROOT" cat-file -e "$ref^{commit}" 2>/dev/null || die "base ref does not resolve: $ref"
  base=$(git -C "$ROOT" rev-parse "$ref^{commit}")
  snapshot=$(header_value "$parsed" upstream_base_paths)
  path_is_safe "$snapshot" || die "unsafe upstream_base_paths: $snapshot"
  {
    printf '# upstream_base = %s\n' "$base"
    git -C "$ROOT" ls-tree -r --name-only "$base" | LC_ALL=C sort
  } >"$tmp"
  mv "$tmp" "$ROOT/$snapshot"
  printf 'FORK_SURFACE_BASE %s paths=%s\n' "$base" "$(grep -vc '^#' "$ROOT/$snapshot")"
}

main() {
  [ $# -ge 1 ] || { usage; exit 2; }
  case "$1" in
    -h|--help) usage ;;
    check) shift; [ $# -eq 0 ] || die "check takes no arguments"; check_manifest ;;
    list) shift; list_capabilities "$@" ;;
    paths) shift; [ $# -eq 0 ] || die "paths takes no arguments"; list_paths ;;
    port-allowlist) shift; [ $# -eq 0 ] || die "port-allowlist takes no arguments"; port_allowlist ;;
    sync-base) shift; [ $# -le 1 ] || die "sync-base takes at most one ref"; sync_base "$@" ;;
    *) usage; die "unknown command: $1" ;;
  esac
}

main "$@"
