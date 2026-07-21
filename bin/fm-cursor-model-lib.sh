#!/usr/bin/env bash
# bin/fm-cursor-model-lib.sh - cursor worker model identity helpers.
#
# Owns three related facts for the cursor worker adapter:
#   1. Parsing the idle footer model label from a pane capture
#      ("Cursor Grok 4.5 Medium Fast · 7% ... Run Everything").
#   2. Checking a requested model id against `agent --list-models`
#      (or FM_CURSOR_MODEL_CATALOG) so fm-spawn can refuse unknown ids.
#   3. Comparing a requested model id to a live footer label so presentation
#      can relabel when the pane is not running what meta recorded.
#
# Evidence and CLI quirks live in docs/cursor-harness.md; operating facts in
# .agents/skills/harness-adapters/SKILL.md. Re-sourcing is a cheap idempotent
# redefinition (no include guard), matching bin/fm-composer-lib.sh.

# fm_cursor_normalize_model_token: lowercase, drop non-alphanumerics, for
# fuzzy equality between ids ("cursor-grok-4.5-medium-fast") and footer labels
# ("Cursor Grok 4.5 Medium Fast").
fm_cursor_normalize_model_token() {  # <text>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

# fm_cursor_parse_footer_model: extract the idle-footer model display name from
# a plain-text pane capture, or print nothing. Busy panes that only show
# "ctrl+c to stop" have no model line and correctly yield empty.
#
# Idle footer shapes verified 2026-07-19/21 (docs/cursor-harness.md):
#   "  Cursor Grok 4.5 Low · 7%                                   Run Everything"
#   "  GPT-5.6 Sol 1M Extra High · 12%                            Run Everything"
fm_cursor_parse_footer_model() {  # <capture-text>
  local line name found=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'Run Everything'*)
        case "$line" in
          *·*) ;;
          *) continue ;;
        esac
        name=${line%%·*}
        name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$name" ] || continue
        case "$name" in
          'Run Everything'|*'Run Everything'*|*'ctrl+c to stop'*|*'Add a follow-up'*) continue ;;
        esac
        found=$name
        ;;
    esac
  done <<EOF
$1
EOF
  [ -n "$found" ] && printf '%s' "$found"
  return 0
}

# fm_cursor_list_models_text: raw `agent --list-models` (or catalog override).
# Prints catalog text on stdout. Returns non-zero when the catalog cannot be
# read so callers can soft-skip rather than treat "empty" as "no models exist".
#
# FM_CURSOR_MODEL_CATALOG, when set to an existing file path, is the sole
# source (tests and offline checks). Otherwise runs `agent --list-models`.
# fm_cursor_catalog_cache_cleanup: remove this process's catalog cache dir.
# Chained onto the EXIT trap at source time; callers that install their own
# EXIT trap after sourcing must include this in it.
fm_cursor_catalog_cache_cleanup() {
  if [ -n "${_FM_CURSOR_CATALOG_CACHE_DIR:-}" ] && [ "${_FM_CURSOR_CATALOG_CACHE_PID:-}" = "$$" ]; then
    rm -rf "$_FM_CURSOR_CATALOG_CACHE_DIR" 2>/dev/null || :
    _FM_CURSOR_CATALOG_CACHE_DIR=''
  fi
}

_fm_cursor_trap_extract() { shift; printf '%s' "${1:-}"; }

# Run any EXIT handler that was installed before this library was sourced, then
# drop the catalog cache. Kept as a named trap target so the previous command
# can live in a durable variable (single-quoted trap; no SC2064 early-expand).
_fm_cursor_catalog_exit_chain() {
  if [ -n "${_FM_CURSOR_CATALOG_PREV_EXIT:-}" ]; then
    eval "$_FM_CURSOR_CATALOG_PREV_EXIT"
  fi
  fm_cursor_catalog_cache_cleanup
}

if [ "${_FM_CURSOR_CATALOG_CACHE_PID:-}" != "$$" ] \
  || [ -z "${_FM_CURSOR_CATALOG_CACHE_DIR:-}" ] || [ ! -d "$_FM_CURSOR_CATALOG_CACHE_DIR" ]; then
  if _FM_CURSOR_CATALOG_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-catalog.XXXXXX" 2>/dev/null); then
    _FM_CURSOR_CATALOG_CACHE_PID=$$
    _fm_cursor_prev_trap=$(trap -p EXIT)
    if [ -n "$_fm_cursor_prev_trap" ]; then
      _FM_CURSOR_CATALOG_PREV_EXIT=$(eval "_fm_cursor_trap_extract ${_fm_cursor_prev_trap#trap}")
    else
      _FM_CURSOR_CATALOG_PREV_EXIT=''
    fi
    trap _fm_cursor_catalog_exit_chain EXIT
    unset _fm_cursor_prev_trap 2>/dev/null || :
  else
    _FM_CURSOR_CATALOG_CACHE_DIR=''
  fi
fi

fm_cursor_list_models_text() {
  local key=${FM_CURSOR_MODEL_CATALOG:-} text status cache stamp
  if [ -n "$key" ]; then
    [ -f "$key" ] || return 1
    stamp=$(stat -f '%m:%z' "$key" 2>/dev/null || stat -c '%Y:%s' "$key" 2>/dev/null) || stamp=''
    key="$key@$stamp"
  fi
  cache=''
  if [ -n "${_FM_CURSOR_CATALOG_CACHE_DIR:-}" ] && [ -d "$_FM_CURSOR_CATALOG_CACHE_DIR" ]; then
    cache="$_FM_CURSOR_CATALOG_CACHE_DIR/catalog"
  fi
  if [ -n "$cache" ] && [ -f "$cache.key" ] && [ "$(cat "$cache.key" 2>/dev/null)" = "cached:$key" ]; then
    status=$(cat "$cache.status" 2>/dev/null) || status=''
    case "$status" in
      0)
        cat "$cache.txt" 2>/dev/null
        return 0
        ;;
      [1-9])
        return "$status"
        ;;
    esac
  fi
  status=1
  text=''
  if [ -n "${FM_CURSOR_MODEL_CATALOG:-}" ]; then
    text=$(cat "$FM_CURSOR_MODEL_CATALOG" 2>/dev/null) && status=0
  elif command -v agent >/dev/null 2>&1; then
    text=$(agent --list-models 2>/dev/null) && status=0
  fi
  if [ -n "$cache" ]; then
    rm -f "$cache.key" 2>/dev/null || :
    printf '%s\n' "$text" > "$cache.txt" 2>/dev/null || :
    printf '%s\n' "$status" > "$cache.status" 2>/dev/null || :
    if [ -s "$cache.status" ]; then
      printf 'cached:%s\n' "$key" > "$cache.key" 2>/dev/null || :
    fi
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$text"
    return 0
  fi
  return "$status"
}

# fm_cursor_catalog_has_model: 0 if <model-id> appears as a catalog id (left of
# " - "), 1 if the catalog loaded and the id is absent, 2 if the catalog is
# unavailable. Parameterized overrides ("id[context=1m,...]") match on the bare
# id before '['.
fm_cursor_catalog_has_model() {  # <model-id>
  local want=$1 bare catalog line id
  [ -n "$want" ] && [ "$want" != default ] || return 0
  bare=${want%%\[*}
  catalog=$(fm_cursor_list_models_text) || return 2
  [ -n "$catalog" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'Available models'*) continue ;;
    esac
    id=${line%% - *}
    id=${id%% *}
    [ -n "$id" ] || continue
    if [ "$id" = "$want" ] || [ "$id" = "$bare" ]; then
      return 0
    fi
  done <<EOF
$catalog
EOF
  return 1
}

# fm_cursor_catalog_display_for_id: print the catalog display name for <id>, or
# empty when unknown / catalog unavailable.
fm_cursor_catalog_display_for_id() {  # <model-id>
  local want=$1 bare catalog line id display
  [ -n "$want" ] || return 0
  bare=${want%%\[*}
  catalog=$(fm_cursor_list_models_text) || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'Available models'*) continue ;;
    esac
    case "$line" in
      *' - '*)
        id=${line%% - *}
        id=${id%% *}
        display=${line#* - }
        display=$(printf '%s' "$display" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ "$id" = "$want" ] || [ "$id" = "$bare" ]; then
          printf '%s' "$display"
          return 0
        fi
        ;;
    esac
  done <<EOF
$catalog
EOF
  return 0
}

# fm_cursor_catalog_id_for_display: reverse lookup; print the first catalog id
# whose display name fuzzy-matches <display>, or empty.
fm_cursor_catalog_id_for_display() {  # <display-name>
  local want_norm catalog line id display
  want_norm=$(fm_cursor_normalize_model_token "$1")
  [ -n "$want_norm" ] || return 0
  catalog=$(fm_cursor_list_models_text) || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'Available models'*) continue ;;
      *' - '*)
        id=${line%% - *}
        id=${id%% *}
        display=${line#* - }
        display=$(printf '%s' "$display" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ "$(fm_cursor_normalize_model_token "$display")" = "$want_norm" ] \
          || [ "$(fm_cursor_normalize_model_token "$id")" = "$want_norm" ]; then
          printf '%s' "$id"
          return 0
        fi
        ;;
    esac
  done <<EOF
$catalog
EOF
  return 0
}

# fm_cursor_models_equivalent: 0 when <requested-id> and <live-label-or-id>
# name the same model (exact, catalog display, or normalized equality).
fm_cursor_models_equivalent() {  # <requested-id> <live-label-or-id>
  local req=$1 live=$2 req_norm live_norm req_display
  [ -n "$req" ] && [ -n "$live" ] || return 1
  [ "$req" = "$live" ] && return 0
  req_norm=$(fm_cursor_normalize_model_token "$req")
  live_norm=$(fm_cursor_normalize_model_token "$live")
  [ -n "$req_norm" ] && [ "$req_norm" = "$live_norm" ] && return 0
  req_display=$(fm_cursor_catalog_display_for_id "$req")
  if [ -n "$req_display" ] \
    && [ "$(fm_cursor_normalize_model_token "$req_display")" = "$live_norm" ]; then
    return 0
  fi
  return 1
}

# fm_cursor_runtime_label: preferred presentation token for a live footer
# label - catalog id when resolvable, otherwise the footer display text.
fm_cursor_runtime_label() {  # <live-display-or-id>
  local live=$1 id
  [ -n "$live" ] || return 0
  id=$(fm_cursor_catalog_id_for_display "$live")
  if [ -n "$id" ]; then
    printf '%s' "$id"
  else
    printf '%s' "$live"
  fi
}
