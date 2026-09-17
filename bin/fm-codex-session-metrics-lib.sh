#!/usr/bin/env bash
# Supply the Codex/Astra companion row with real context and provider-quota
# metrics for the EXACT primary session the companion is following.
#
# Sourced by bin/fm-status-bar.sh. The field, threshold, placeholder, and
# provenance contract lives in docs/status-bar.md; this file owns the mechanics.
#
# Public entry point:
#   fm_codex_session_metrics <pane> <backend> <herdr-session> <state-dir>
#     -> "<context-used>\t<quota-used>\t<quota-window>"
#
# Every field is "--" when it cannot be established truthfully. A missing,
# malformed, stale, expired, or unattributable reading is always "--", never 0.
#
# Two metrics, two DIFFERENT owners, deliberately not interchangeable.
#
# Context is this thread's own occupancy of the model context window, so it must
# come from the exact session the companion follows. The followed pane resolves
# to its foreground Codex process - positively identified as such on both
# backends - that process is asked which rollout file it currently holds OPEN,
# and only that file is read. Codex holds exactly one rollout open per thread,
# so the open descriptor is the process's own statement of which thread it is
# running. Nothing here picks the newest file in the sessions tree: a sibling
# Codex session - another primary, a worker, the desktop app - owns a different
# descriptor and can never be borrowed. No Codex process behind the pane, no
# rollout, or MORE than one rollout is a refusal.
#
# Provider quota is an ACCOUNT-level allowance and is not this thread's
# consumption, so it is never derived from thread totals. It comes from
# quota-axi, which already owns provider and account resolution, read strictly
# read-only. quota-axi is the ONLY quota source here. The row reports the
# account's own binding window with that window named, so the figure can never
# imply a scope it does not have.
#
# The rollout's own rate_limits block is a THIRD thing, and it is NOT a quota
# source. It is stamped with a limit identity - limit_id and limit_name - which
# is frequently NOT the running model's: a live gpt-6-astra primary was measured
# carrying limit_id=codex_bengalfox (GPT-5.3-Codex-Spark) at 0% used while the
# account's actual binding weekly window sat at 54% used. Reporting that 0% as
# the primary's quota reads as "plenty of headroom" when there is none. No
# identity rule recovers the block's true scope either, because the block never
# states which account or which model allowance it describes, and a name-shaped
# guess mismatches exactly where it matters: the plain `codex` profile's model
# string is a substring of `codex_bengalfox`. So the block is not read for quota
# at all, under any name. The rollout supplies context, and nothing else.
#
# Only metric metadata is read: the last token-count event's token totals and
# context window. Conversation content in the rollout is never parsed, printed,
# or cached.
#
# Cost control: the pane/process/descriptor resolution and rollout read are
# cached for FM_CODEX_METRICS_TTL seconds (default 15), and the rollout is read
# through a bounded escalating tail rather than a whole-file scan, because a
# live rollout reaches hundreds of megabytes. The quota-axi read is a
# subprocess, so a refresh NEVER waits on it: a cache miss starts one detached
# read whose answer a later refresh picks up, under its own longer
# FM_CODEX_QUOTA_TTL (default 120) and an in-flight lock. A one-second companion
# refresh therefore performs no blocking subprocess work on any tick. No
# credential is read, no credential refresh is delegated, and no token value is
# ever printed.
#
# Test seams:
#   FM_CODEX_METRICS_ROLLOUT     use this rollout path instead of resolving one
#   FM_CODEX_METRICS_TTL         rollout cache lifetime in seconds
#   FM_CODEX_METRICS_TAIL_BYTES  first rollout tail step in bytes
#   FM_CODEX_CONTEXT_MAX_AGE     how long a last-known context sample survives
#   FM_CODEX_QUOTA_TTL           provider-quota cache lifetime in seconds
#   FM_CODEX_QUOTA_JSON          read provider quota from this file, not quota-axi
#   FM_CODEX_QUOTA_DISABLE       set to 1 to skip the provider-quota source
#   FM_CODEX_QUOTA_WAIT          bound on the detached provider read, seconds
#   FM_CODEX_QUOTA_WARM_TTL      how long one detached read is considered in flight
#   FM_CODEX_METRICS_NOW         override the current epoch
#   FM_CODEX_METRICS_NO_CACHE    set to 1 to bypass both caches

# The cache, freshness, and single-refresh mechanics are shared with the other
# status supply in bin/fm-status-cache-lib.sh, so both agree on what "still true
# enough to show" means. The POLICY - the TTLs above and the no-cache seam -
# stays here, with the library that owns these readings.
_FM_CODEX_LIB_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-status-cache-lib.sh
. "$_FM_CODEX_LIB_DIR/fm-status-cache-lib.sh"
# The wall-clock bound on the provider read comes from the one owner of that
# helper rather than a second open-coded background wait; see bin/fm-timeout-lib.sh.
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_CODEX_LIB_DIR/fm-timeout-lib.sh"

# _fm_codex_now: current epoch, or failure when it cannot be read.
_fm_codex_now() {
  local now=${FM_CODEX_METRICS_NOW:-}
  [ -n "$now" ] || now=$(date +%s 2>/dev/null)
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$now"
}

# _fm_codex_ttl: a non-negative integer TTL, or the supplied default.
_fm_codex_ttl() {  # <value> <default>
  fm_status_ttl "$1" "$2"
}

# _fm_codex_age_within: 0 iff <stamp> is a readable epoch no more than <window>
# seconds before <now>. An unreadable, absent, or future stamp is never within,
# so every freshness decision in this file fails toward "unavailable".
_fm_codex_age_within() {  # <now> <stamp> <window>
  fm_status_age_within "$1" "$2" "$3"
}

# _fm_codex_file_mtime: a file's modification epoch, BSD or GNU stat.
_fm_codex_file_mtime() {  # <path>
  fm_status_file_mtime "$1"
}

# _fm_codex_file_size: a file's size in bytes, BSD or GNU stat.
_fm_codex_file_size() {  # <path>
  fm_status_file_size "$1"
}

# _fm_codex_cache_key: a filesystem-safe token for a cache file name.
_fm_codex_cache_key() {  # <value>
  fm_status_cache_key "$1"
}

# _fm_codex_cache_read: a cached payload that is still inside its TTL.
_fm_codex_cache_read() {  # <cache-file> <now> <ttl>
  [ "${FM_CODEX_METRICS_NO_CACHE:-}" != 1 ] || return 1
  fm_status_cache_read "$1" "$2" "$3"
}

# _fm_codex_cache_load: a cached payload whatever its age, so a reading can
# carry its own recorded timestamps rather than inferring them from the file.
_fm_codex_cache_load() {  # <cache-file>
  [ "${FM_CODEX_METRICS_NO_CACHE:-}" != 1 ] || return 1
  fm_status_cache_load "$1"
}

# _fm_codex_cache_write: best effort. A state directory that cannot be written
# costs freshness, never a render.
_fm_codex_cache_write() {  # <cache-file> <payload>
  [ "${FM_CODEX_METRICS_NO_CACHE:-}" != 1 ] || return 0
  fm_status_cache_write "$1" "$2"
}

# _fm_codex_is_codex_pid: 0 iff <pid>'s own executable is the Codex CLI. The
# check is on the command's basename and is exact, because the same install tree
# ships neighbours - codex-code-mode-host - and the ChatGPT desktop app runs its
# own `codex` binary that must never be mistaken for a pane's primary.
_fm_codex_is_codex_pid() {  # <pid>
  local pid=$1 comm
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  comm=${comm#-}
  [ "${comm##*/}" = codex ]
}

# _fm_codex_pane_pids: every Codex process id behind the followed pane, one per
# line. Both providers are asked about the pane the companion was given, and an
# answer about a different pane yields nothing rather than a guess. Both arms
# apply the same positive Codex identity rule, so an unrelated descendant that
# happens to hold a rollout open can never widen the resolution.
_fm_codex_pane_pids() {  # <pane> <backend> <herdr-session>
  local pane=$1 backend=$2 session=$3 shell_pid frontier next p c pids
  case "$backend" in
    herdr)
      command -v herdr >/dev/null 2>&1 || return 0
      herdr --session "$session" pane process-info --pane "$pane" 2>/dev/null \
        | jq -r --arg pane "$pane" '
            select(.result.type == "pane_process_info")
            | select(.result.process_info.pane_id == $pane)
            | .result.process_info.foreground_processes[]?
            | select((.name // "") == "codex" or (.argv0 // "") == "codex")
            | .pid
          ' 2>/dev/null
      ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || return 0
      # tmux reports the pane's OWN process, which is the login shell: a task
      # pane has the launch line typed into that shell, so Codex is a
      # descendant rather than the pane process. Bounded at five levels for the
      # same reason fm_tmux_pane_argv_matches (bin/fm-tmux-lib.sh) is - a
      # launcher shim, a treehouse subshell, and the runtime itself can each add
      # a level.
      shell_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || return 0
      case "$shell_pid" in
        ''|*[!0-9]*) return 0 ;;
      esac
      pids="$shell_pid"
      frontier="$shell_pid"
      for _ in 1 2 3 4 5; do
        next=
        for p in $frontier; do
          for c in $(pgrep -P "$p" 2>/dev/null); do next="$next $c"; done
        done
        [ -n "$next" ] || break
        pids="$pids$next"
        frontier=$next
      done
      for p in $pids; do
        ! _fm_codex_is_codex_pid "$p" || printf '%s\n' "$p"
      done
      ;;
  esac
}

# _fm_codex_rollout_for_pids: the single rollout file those processes hold open.
# Zero matches and more than one match are both refusals: there is no safe way
# to choose, and choosing wrongly would report another session's context.
_fm_codex_rollout_for_pids() {  # <pid>...
  local pids paths count
  pids=$(printf '%s,' "$@")
  pids=${pids%,}
  [ -n "$pids" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  paths=$(lsof -p "$pids" -Fn 2>/dev/null \
    | sed -n 's|^n\(.*/sessions/.*/rollout-.*\.jsonl\)$|\1|p' \
    | sort -u)
  [ -n "$paths" ] || return 1
  count=$(printf '%s\n' "$paths" | grep -c .)
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$paths"
}

# _fm_codex_resolve_rollout: the rollout bound to the followed pane.
_fm_codex_resolve_rollout() {  # <pane> <backend> <herdr-session>
  local forced=${FM_CODEX_METRICS_ROLLOUT:-} pids
  if [ -n "$forced" ]; then
    [ -f "$forced" ] || return 1
    printf '%s' "$forced"
    return 0
  fi
  pids=$(_fm_codex_pane_pids "$1" "$2" "$3")
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC2086 # Deliberate splitting: one argument per pid.
  _fm_codex_rollout_for_pids $pids
}

# _fm_codex_window_from_id: "<label>\t<window-minutes>" for a quota-axi window
# identifier. Label and length come from one table so a window can never be
# named one thing and ordered as another. The label is derived from what the
# source actually reported and is never assumed: an unrecognized window yields
# nothing, which makes the whole quota reading unavailable rather than
# ambiguously scoped.
_fm_codex_window_from_id() {  # <window-id>
  case "$1" in
    ''|null) return 1 ;;
    five_hour|five-hour|5h|*:5h) printf '5h\t300' ;;
    daily|*:24h|*:1d) printf '24h\t1440' ;;
    weekly|*:7d|*:weekly) printf 'wk\t10080' ;;
    monthly|*:30d) printf 'mo\t43200' ;;
    annual|yearly|*:1y) printf 'yr\t525600' ;;
    *) return 1 ;;
  esac
}

# _FM_CODEX_WINDOW_LABEL_MAX: the widest window token the row will carry, shared
# with sanitize_window_label in bin/fm-status-bar.sh. A tie that cannot be
# spelled inside it collapses to its shortest window rather than being dropped.
_FM_CODEX_WINDOW_LABEL_MAX=8

# _fm_codex_read_rollout: this thread's context use, as an integer percentage.
#
# Context is the share of the model context window this thread currently
# occupies, from the same two numbers Codex's own `context-used` item is built
# from: the last turn's prompt size and the window Codex itself reported for the
# session. The window is read from the session rather than a model catalog, so
# no capacity is assumed anywhere. Compaction needs no special handling: a
# compacted thread's next event reports the smaller post-compaction prompt.
#
# The newest token-count event is usually within a few kilobytes of the end, but
# mid-turn tool output pushes it far further back - measured on a live rollout,
# most appended bytes sit beyond a 256 KB tail, with gaps up to 22 MB. So the
# tail escalates while nothing is found and stops at the file's own size, which
# keeps a frame off a whole-file scan of a rollout that reaches hundreds of
# megabytes. Candidates are selected on payload.type exactly, never on the text
# of the line, because conversation content that merely mentions the event name
# is not an event.
_fm_codex_read_rollout() {  # <rollout>
  local rollout=$1 first step size event ctx
  first=$(_fm_codex_ttl "${FM_CODEX_METRICS_TAIL_BYTES:-}" 262144)
  [ "$first" -gt 0 ] || first=262144
  size=$(_fm_codex_file_size "$rollout") || size=
  event=
  for step in "$first" "$((first * 16))" "$((first * 128))"; do
    event=$(tail -c "$step" "$rollout" 2>/dev/null \
      | grep -F '"token_count"' \
      | tail -n 50 \
      | jq -Rc '
          fromjson?
          | select(type == "object")
          | select((.payload | type) == "object")
          | select(.payload.type == "token_count")
        ' 2>/dev/null \
      | tail -1)
    [ -z "$event" ] || break
    [ -z "$size" ] || [ "$step" -lt "$size" ] || break
  done
  [ -n "$event" ] || return 1

  ctx=$(printf '%s' "$event" | jq -r '
    def num(v): if (v | type) == "number" then v else null end;
    (.payload.info // {}) as $i
    | (num($i.model_context_window)) as $win
    | (num($i.last_token_usage.input_tokens)) as $tok
    | if $win == null or $win <= 0 or $tok == null or $tok < 0 then "--"
      else (100 * $tok / $win | floor | if . > 100 then 100 else . end)
      end
  ' 2>/dev/null)
  case "$ctx" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$ctx"
}

# _fm_codex_quota_reading: the ACCOUNT's binding allowance from one quota-axi
# report, as "<used>\t<window-label>\t<window-ids>".
#
# The all_models scope is the right one for a Codex primary: Codex reports a
# single account-wide availability scope, so an Astra primary draws on the
# ordinary Codex windows rather than an allowance of its own. quota-axi's
# effective availability already resolves which window binds, so the row does
# not re-derive it.
#
# Everything about this reading must be positively known or it is unavailable:
# a stale report, an unknown semantics status, an unknown scope status, a
# non-numeric percentage, or a binding window whose length cannot be named.
#
# quota-axi reports every window tied at the minimum remaining, so more than one
# limiting window is an ordinary state - a fully unused account ties at 100%
# remaining, an exhausted one ties at 0% - and the tied percentage is a known
# figure either way. The label names the tied windows shortest-first, and when
# that will not fit the row it collapses to the shortest one; the full id list
# is retained in the reading, because the windows the compact label omits stay
# just as binding as the one it names.
_fm_codex_quota_reading() {  # <json>
  local json=$1 remaining ids id reading label minutes ranked ordered
  local joined shortest
  IFS=$'\t' read -r remaining ids <<EOF
$(printf '%s' "$json" | jq -r '
  def num(v): if (v | type) == "number" then v else null end;
  (.providers // [] | map(select(.provider == "codex")) | first) as $p
  | if $p == null then ["--", ""]
    elif ($p.state.stale == true) then ["--", ""]
    elif (($p.quotaSemantics.status // "") != "known") then ["--", ""]
    else
      (($p.quotaSemantics.effectiveAvailability // [])
        | map(select(.scope == "all_models")) | first) as $s
      | if $s == null or (($s.status // "") != "known") then ["--", ""]
        else
          (num($s.effectivePercentRemaining)) as $r
          | [ (if $r == null then "--" else ($r | floor) end),
              (($s.limitingWindowIds // []) | map(tostring) | join(",")) ]
        end
    end
  | @tsv
' 2>/dev/null)
EOF

  case "$remaining" in
    ''|--|*[!0-9]*) return 1 ;;
  esac
  [ "$remaining" -le 100 ] || return 1
  [ -n "$ids" ] || return 1

  ranked=
  for id in $(printf '%s' "$ids" | tr ',' ' '); do
    reading=$(_fm_codex_window_from_id "$id") || return 1
    IFS=$'\t' read -r label minutes <<EOF
$reading
EOF
    ranked="$ranked$minutes $label"$'\n'
  done
  # Shortest binding window first, and one entry per distinct window: two ids
  # can name the same window, and the label states each window once.
  ordered=$(printf '%s' "$ranked" | sort -n -u | awk '{print $2}')
  joined=
  shortest=
  for label in $ordered; do
    [ -n "$shortest" ] || shortest=$label
    if [ -z "$joined" ]; then joined=$label; else joined="$joined/$label"; fi
  done
  [ -n "$joined" ] || return 1
  [ "${#joined}" -le "$_FM_CODEX_WINDOW_LABEL_MAX" ] || joined=$shortest
  # quota-axi reports REMAINING; the canonical row reports USED.
  printf '%s\t%s\t%s' "$((100 - remaining))" "$joined" "$ids"
}

# _fm_codex_quota_seam_reading: the reading from FM_CODEX_QUOTA_JSON. A plain
# file read is not a subprocess, so this is the one provider source that is safe
# to resolve inline on a refresh.
_fm_codex_quota_seam_reading() {
  local path=${FM_CODEX_QUOTA_JSON:-} json
  [ -n "$path" ] || return 1
  [ -f "$path" ] || return 1
  json=$(cat "$path" 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  _fm_codex_quota_reading "$json"
}

# _fm_codex_quota_axi_reading: one quota-axi report, read strictly read-only and
# under a bounded wait so a wedged provider read can never linger.
# --no-credential-refresh is mandatory here: it keeps the read from delegating
# an expired session's renewal to the vendor CLI, which is what would otherwise
# surface a login prompt behind a status bar. Only the detached warmer below
# calls this; a render never does.
#
# The bound is fm_run_timeout, the declared single owner of that mechanism: it
# runs the probe in its own process group so a forking quota-axi leaves no
# orphans behind, and it detaches stdin, which is load-bearing rather than tidy -
# a vendor CLI that touches the terminal on stdin otherwise stops on SIGTTIN and
# the caller reads an empty answer from a healthy tool. An empty or non-zero
# read is a refusal here, which the warmer renders as the "--" placeholder.
_fm_codex_quota_axi_reading() {
  local out limit json status
  command -v quota-axi >/dev/null 2>&1 || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/fm-codex-quota.XXXXXX") || return 1
  limit=$(_fm_codex_ttl "${FM_CODEX_QUOTA_WAIT:-}" 10)
  fm_run_timeout "$limit" quota-axi --provider codex --json --no-credential-refresh \
    > "$out" 2>/dev/null
  status=$?
  json=
  # A read that hit the bound is refused outright, exactly as the wait it
  # replaces did: whatever it managed to write is a truncated report, and half a
  # provider answer must never become a figure. Any other exit is judged on its
  # output, so a tool that reports a complete quota and exits non-zero still
  # reads, and an empty answer is still a refusal.
  [ "$status" -eq 124 ] || [ ! -s "$out" ] || json=$(cat "$out" 2>/dev/null)
  rm -f "$out"
  [ -n "$json" ] || return 1
  _fm_codex_quota_reading "$json"
}

# _fm_codex_quota_warm: start ONE detached provider read that writes the quota
# cache, and return at once. The caller renders whatever the cache already holds
# - the "--" placeholder on the very first frame - and a later frame picks the
# answer up, so a cache miss costs freshness rather than a blank pane.
#
# The redirection is load-bearing, not tidiness: a background child that
# inherited the caller's stdout would keep a command substitution around it open
# and reintroduce exactly the wait this exists to remove.
#
# The lock file bounds how often a read is started: one in flight at a time,
# and a warmer that died without clearing it is retried once the lock ages out.
_fm_codex_quota_warm() {  # <cache-file> <now>
  local cache=$1 now=$2 lock="$1.warming" modified warm_ttl
  [ "${FM_CODEX_QUOTA_DISABLE:-}" != 1 ] || return 0
  [ -z "${FM_CODEX_QUOTA_JSON:-}" ] || return 0
  [ "${FM_CODEX_METRICS_NO_CACHE:-}" != 1 ] || return 0
  command -v quota-axi >/dev/null 2>&1 || return 0
  warm_ttl=$(_fm_codex_ttl "${FM_CODEX_QUOTA_WARM_TTL:-}" 30)
  if modified=$(_fm_codex_file_mtime "$lock"); then
    ! _fm_codex_age_within "$now" "$modified" "$warm_ttl" || return 0
  fi
  : > "$lock" 2>/dev/null || return 0
  (
    reading=$(_fm_codex_quota_axi_reading) || reading=$'--\t\t'
    _fm_codex_cache_write "$cache" "$reading"
    rm -f "$lock" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  return 0
}

# fm_codex_session_metrics: the public entry point.
# Always succeeds: every failure mode renders as the "--" placeholders the row
# already displays dimly, so a broken reading can never be mistaken for a real
# zero.
fm_codex_session_metrics() {  # <pane> <backend> <herdr-session> <state-dir>
  local pane=$1 backend=$2 session=$3 state=$4
  local now key context_cache quota_cache ttl max_age quota_ttl
  local cached cached_ctx cached_at attempt_at fresh rollout
  local ctx quota label quota_raw

  now=$(_fm_codex_now) || {
    printf '%s\t%s\t' -- --
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\t%s\t' -- --
    return 0
  }

  ttl=$(_fm_codex_ttl "${FM_CODEX_METRICS_TTL:-}" 15)
  max_age=$(_fm_codex_ttl "${FM_CODEX_CONTEXT_MAX_AGE:-}" 900)
  quota_ttl=$(_fm_codex_ttl "${FM_CODEX_QUOTA_TTL:-}" 120)
  # Caches are keyed by the followed pane, so two companions in one home never
  # read each other's reading.
  key=$(_fm_codex_cache_key "$pane")
  context_cache="$state/.status-codex-metrics.$key"
  quota_cache="$state/.status-codex-quota.$key"

  # The context cache records the reading, when the reading was taken, and when
  # a read was last attempted. The attempt stamp paces the resolution work; the
  # reading stamp ages the reading itself.
  cached_ctx=--
  cached_at=
  attempt_at=
  cached=$(_fm_codex_cache_load "$context_cache") || cached=
  if [ -n "$cached" ]; then
    IFS=$'\t' read -r cached_ctx cached_at attempt_at <<EOF
$cached
EOF
  fi
  case "$cached_ctx" in
    ''|*[!0-9]*) cached_ctx=--; cached_at= ;;
  esac
  case "$cached_at" in
    *[!0-9]*) cached_at= ;;
  esac
  [ -n "$cached_at" ] || cached_ctx=--

  if ! _fm_codex_age_within "$now" "$attempt_at" "$ttl"; then
    rollout=$(_fm_codex_resolve_rollout "$pane" "$backend" "$session") || rollout=
    fresh=
    [ -z "$rollout" ] || fresh=$(_fm_codex_read_rollout "$rollout") || fresh=
    case "$fresh" in
      ''|*[!0-9]*) fresh= ;;
    esac
    if [ -n "$fresh" ]; then
      cached_ctx=$fresh
      cached_at=$now
    fi
    # The attempt is always recorded, so a session that cannot be resolved is
    # retried on the cache's cadence rather than on every tick.
    _fm_codex_cache_write "$context_cache" \
      "$cached_ctx"$'\t'"$cached_at"$'\t'"$now"
  fi

  # No newer token event inside the bounded tail keeps the last known reading
  # until it ages out, because a live session's occupancy does not become
  # unknown the moment its newest event scrolls past the window. Past that
  # bound the reading is too old to stand for the current thread and goes back
  # to unavailable - never to zero.
  ctx=--
  if [ "$cached_ctx" != -- ] \
    && _fm_codex_age_within "$now" "$cached_at" "$max_age"; then
    ctx=$cached_ctx
  fi

  quota=--
  label=
  quota_raw=
  if [ "${FM_CODEX_QUOTA_DISABLE:-}" != 1 ]; then
    quota_raw=$(_fm_codex_cache_read "$quota_cache" "$now" "$quota_ttl") || quota_raw=
    if [ -z "$quota_raw" ]; then
      if [ -n "${FM_CODEX_QUOTA_JSON:-}" ]; then
        quota_raw=$(_fm_codex_quota_seam_reading) || quota_raw=$'--\t\t'
        _fm_codex_cache_write "$quota_cache" "$quota_raw"
      else
        _fm_codex_quota_warm "$quota_cache" "$now"
        quota_raw=$'--\t\t'
      fi
    fi
  fi
  if [ -n "$quota_raw" ]; then
    # The third field is the full list of tied limiting window ids. It is
    # retained in the reading and its cache; the row carries the compact label.
    IFS=$'\t' read -r quota label _ <<EOF
$quota_raw
EOF
  fi
  case "$quota" in
    ''|*[!0-9]*) quota=--; label= ;;
  esac
  # A figure whose window cannot be named is not reportable: the row would have
  # to imply a window it does not know.
  [ "$quota" = -- ] || [ -n "$label" ] || quota=--

  printf '%s\t%s\t%s' "$ctx" "$quota" "$label"
}
