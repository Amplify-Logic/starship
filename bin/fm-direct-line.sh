#!/usr/bin/env bash
# fm-direct-line.sh - the owner's direct line to a direct-line second mate.
#
# Usage, from the parent home (FM_HOME must be set explicitly):
#   fm-direct-line.sh list
#   fm-direct-line.sh send <mate-id> --client-id <id> [--answers <task-id>
#                     [--hold-identity <identity>]] [--image <path>]... [--] <text...>
#   fm-direct-line.sh delivery <mate-id> <client-id>
#   fm-direct-line.sh talking <mate-id>
#   fm-direct-line.sh conversation <mate-id>
# Usage, from the mate's own home (its FM_HOME):
#   fm-direct-line.sh waiting [--for <seconds> | --clear]
#
# docs/direct-line.md owns the design and bin/fm-direct-line-lib.sh owns the
# opt-in and the "talking with owner" state. Every command prints one JSON
# document whose "schema" field names its versioned shape:
#   list          fm-direct-line-mates.v1     every registered second mate:
#                 id, summary, home, remote, direct_line, talking_with_owner,
#                 talking_reason, talking_until, last_owner_message_at,
#                 waiting_until (epochs, or null)
#   send, delivery fm-direct-line-delivery.v1 mate, client_id, state, outcome,
#                 detail, parent_copy, hold, created_at, updated_at
#   talking, waiting fm-direct-line-talking.v1 mate, talking, reason, until,
#                 last_owner_message_at, waiting_until
#   conversation  fm-web-conversation.v1      bin/fm-web.py owns its fields
#
# RESOLUTION. A mate is resolved only through this home's registry,
# data/secondmates.md, and then asserted before anything is read or typed: the
# entry is local, its home's .fm-secondmate-home names the same id, its
# .fm-secondmate-parent binds it locally to this very home, and its own
# data/charter.md opts into the direct line. Any failure refuses (exit 2) and
# nothing is typed. A remote second mate has no direct line yet.
#
# SEND. One send per mate at a time (a per-mate lock, waited for up to
# FM_DIRECT_LINE_LOCK_WAIT seconds, default 60), in this order:
#   1. The client id is claimed in the mate's
#      state/direct-line/deliveries/<client-id>.json. A send whose id is
#      already recorded types nothing: it finishes any step a stopped earlier
#      send left undone and prints the record, so a retried request is
#      delivered once.
#   2. The message is copied to the mate's parent channel first, as a note:
#      line (bin/fm-parent-channel-lib.sh), so the first mate sees every word
#      the owner sends a mate. If that copy fails, nothing is typed.
#   3. The words go through bin/fm-desk-voice.sh only, with FM_HOME set to the
#      mate's home, every override and pane variable cleared, --client-id, and
#      --expect-home, so they are typed only into the pane of the session that
#      holds that mate's lock and runs for that home, under its pane-writer
#      lock, and otherwise land in its mailbox. While the mate's mailbox still
#      holds an undrained message, a new one goes to the mailbox too, so the
#      owner's messages arrive in the order sent.
#   4. Once delivered, the mate is marked talking with its owner, and
#      --answers closes that call held for the owner in the mate's home with
#      the owner's words (bin/fm-captain-hold.sh answer, compare-and-answer
#      when --hold-identity is given). A refused answer (the call already
#      closed or changed) is recorded, never retried with other words.
# States: sending, typed, typed-unconfirmed, mailbox, failed, unknown, and
# interrupted (a delivery read while an earlier send stopped mid-way; send it
# again with the same client id to finish it).
# Exit: 0 delivered (or already recorded), 1 not delivered, 2 refused,
# 3 delivered but the held call could not be answered.
#
# WAITING. The mate itself runs `waiting` when it has asked the owner
# something and waits for the answer, so the first mate leaves it alone for
# --for seconds (default 43200); `waiting --clear` ends that early.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'fm-direct-line: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'fm-direct-line: %s\n' "$*" >&2; exit 2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

[ -n "${FM_HOME:-}" ] || refuse "FM_HOME is not set; the direct line resolves mates only through an explicit home"
[ -d "$FM_HOME" ] || refuse "FM_HOME '$FM_HOME' is not a directory"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REGISTRY="$DATA/secondmates.md"

command -v jq >/dev/null 2>&1 || die "jq is required"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-direct-line-lib.sh
. "$SCRIPT_DIR/fm-direct-line-lib.sh"

CLIENT_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$'
DELIVERY_SCHEMA=fm-direct-line-delivery.v1
TALKING_SCHEMA=fm-direct-line-talking.v1

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Run a script for the mate's home, never this one: every home override and
# pane variable cleared, so neither this caller's pane nor its home can leak in.
run_for_mate() {  # <command...>
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u HERDR_SOCKET_PATH -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u STATE \
    FM_HOME="$MATE_HOME" "$@"
}

# Resolve <id> through the registry and assert its home (see RESOLUTION).
# Sets MATE_ID and MATE_HOME.
resolve_mate() {  # <id>
  local id=$1 rc=0 home marker_id parent_real self_real
  case "$id" in ''|*[!A-Za-z0-9._-]*) refuse "not a second mate id: '$id'" ;; esac
  secondmate_registry_line_for_id "$REGISTRY" "$id" || rc=$?
  case "$rc" in
    0) ;;
    2) refuse "$SECONDMATE_REGISTRY_ERROR" ;;
    *) refuse "second mate '$id' is not registered (exactly once) in $REGISTRY" ;;
  esac
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] \
    || refuse "second mate '$id' runs on $SECONDMATE_REGISTRY_HOST; a remote second mate has no direct line yet"
  home=$SECONDMATE_REGISTRY_HOME
  case "$home" in /*) ;; *) refuse "second mate '$id' has a relative home in the registry: $home" ;; esac
  [ -d "$home" ] || refuse "second mate '$id' home is missing: $home"
  marker_id=$(fm_parent_channel_home_id "$home") \
    || refuse "second mate '$id' home has no usable identity marker: $home"
  [ "$marker_id" = "$id" ] \
    || refuse "second mate '$id' home names itself '$marker_id'; refusing to reach a different mate"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" \
    || refuse "second mate '$id' has no readable parent binding"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || refuse "second mate '$id' is not bound to a local parent"
  parent_real=$(real_dir "$FM_SECONDMATE_PARENT_HOME") \
    || refuse "second mate '$id' parent home is missing: $FM_SECONDMATE_PARENT_HOME"
  self_real=$(real_dir "$FM_HOME") || refuse "cannot resolve FM_HOME '$FM_HOME'"
  [ "$parent_real" = "$self_real" ] \
    || refuse "second mate '$id' belongs to another home ($FM_SECONDMATE_PARENT_HOME), not this one"
  fm_direct_line_enabled "$home" \
    || refuse "second mate '$id' has no direct line: its charter does not opt in ('$FM_DIRECT_LINE_CHARTER_LINE')"
  MATE_ID=$id
  MATE_HOME=$(real_dir "$home")
}

json_epoch() {  # <value>
  if [ -n "$1" ]; then printf '%s' "$1"; else printf 'null'; fi
}

talking_json() {  # <id> <home>
  local talking=false reason='' until=''
  if fm_direct_line_talking "$2"; then
    talking=true
    reason=$FM_DIRECT_LINE_TALKING_REASON
    until=$FM_DIRECT_LINE_TALKING_UNTIL
  fi
  jq -cn --arg schema "$TALKING_SCHEMA" --arg mate "$1" --argjson talking "$talking" \
    --arg reason "$reason" --argjson until "$(json_epoch "$until")" \
    --argjson last "$(json_epoch "$(fm_direct_line_last_owner_message "$2")")" \
    --argjson waiting "$(json_epoch "$(fm_direct_line_waiting_until "$2")")" \
    '{schema:$schema, mate:$mate, talking:$talking,
      reason:(if $reason == "" then null else $reason end), until:$until,
      last_owner_message_at:$last, waiting_until:$waiting}'
}

cmd_list() {
  local line rows='' row enabled talking reason until
  [ "$#" -eq 0 ] || refuse "usage: fm-direct-line.sh list"
  [ ! -L "$REGISTRY" ] || refuse "$(secondmate_registry_symlink_refusal "$REGISTRY")"
  if [ -f "$REGISTRY" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      secondmate_registry_parse_line "$line" || continue
      enabled=false talking=false reason='' until=''
      if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] && fm_direct_line_enabled "$SECONDMATE_REGISTRY_HOME"; then
        enabled=true
        if fm_direct_line_talking "$SECONDMATE_REGISTRY_HOME"; then
          talking=true
          reason=$FM_DIRECT_LINE_TALKING_REASON
          until=$FM_DIRECT_LINE_TALKING_UNTIL
        fi
      fi
      row=$(jq -cn --arg id "$SECONDMATE_REGISTRY_ID" --arg summary "$SECONDMATE_REGISTRY_SUMMARY" \
        --arg home "$SECONDMATE_REGISTRY_HOME" --argjson remote "$([ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] && echo true || echo false)" \
        --argjson direct "$enabled" --argjson talking "$talking" --arg reason "$reason" \
        --argjson until "$(json_epoch "$until")" \
        --argjson last "$(json_epoch "$( [ "$enabled" = true ] && fm_direct_line_last_owner_message "$SECONDMATE_REGISTRY_HOME")")" \
        --argjson waiting "$(json_epoch "$( [ "$enabled" = true ] && fm_direct_line_waiting_until "$SECONDMATE_REGISTRY_HOME")")" \
        '{id:$id, summary:$summary, home:$home, remote:$remote, direct_line:$direct,
          talking_with_owner:$talking, talking_reason:(if $reason == "" then null else $reason end),
          talking_until:$until, last_owner_message_at:$last, waiting_until:$waiting}')
      rows="$rows$row"$'\n'
    done < "$REGISTRY"
  fi
  printf '%s' "$rows" | jq -cs --arg home "$FM_HOME" \
    '{schema:"fm-direct-line-mates.v1", home:$home, mates:.}'
}

# --- the per-mate delivery record -------------------------------------------

record_path() { printf '%s/deliveries/%s.json\n' "$(fm_direct_line_dir "$MATE_HOME")" "$1"; }

# Merge the jq object <patch-json> into the record for <client-id>.
record_update() {  # <client-id> <patch-json>
  local path tmp
  path=$(record_path "$1")
  mkdir -p "${path%/*}" && chmod 700 "${path%/*}" 2>/dev/null || true
  tmp=$(mktemp "${path%/*}/.record.XXXXXX") || return 1
  if [ -f "$path" ]; then
    jq -c --argjson patch "$2" --arg at "$(now_iso)" '. + $patch + {updated_at:$at}' "$path" > "$tmp"
  else
    jq -cn --argjson patch "$2" --arg at "$(now_iso)" '$patch + {created_at:$at, updated_at:$at}' > "$tmp"
  fi || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path"
}

record_field() {  # <client-id> <jq-path>
  jq -r "$2 // empty" "$(record_path "$1")" 2>/dev/null
}

SEND_LOCK=
send_lock_acquire() {
  local wait=${FM_DIRECT_LINE_LOCK_WAIT:-60} deadline
  case "$wait" in ''|*[!0-9]*) wait=60 ;; esac
  fm_direct_line_ensure_dir "$MATE_HOME" || die "cannot create $(fm_direct_line_dir "$MATE_HOME")"
  SEND_LOCK="$(fm_direct_line_dir "$MATE_HOME")/.send.lock"
  deadline=$(( $(date +%s) + wait ))
  until fm_lock_try_acquire "$SEND_LOCK"; do
    [ "$(date +%s)" -lt "$deadline" ] || { SEND_LOCK=; die "another direct-line send to '$MATE_ID' is still running"; }
    sleep 0.2
  done
  trap 'fm_lock_release "$SEND_LOCK"' EXIT
}

# Copy the owner's message to the mate's parent channel. 0 copied.
copy_to_parent() {  # <client-id> <text> <images>
  local note
  note="owner to $MATE_ID by direct line (msg $1): $2"
  [ "$3" -eq 0 ] || note="$note [$3 image(s)]"
  fm_parent_channel_report "$MATE_HOME" "$MATE_HOME/state" \
    "note: $(fm_parent_channel_clean_note "$note")"
}

# Answer the held call the record names, once. Records the result.
answer_hold() {  # <client-id>
  local cid=$1 task identity text file rc=0 err result detail
  task=$(record_field "$cid" '.hold.task')
  [ -n "$task" ] || return 0
  [ -z "$(record_field "$cid" '.hold.result')" ] || return 0
  identity=$(record_field "$cid" '.hold.identity')
  text=$(record_field "$cid" '.text')
  file=$(mktemp "$(fm_direct_line_dir "$MATE_HOME")/.answer.XXXXXX") || return 1
  printf '%s\n' "$text" > "$file"
  err=$(run_for_mate "$SCRIPT_DIR/fm-captain-hold.sh" answer "$task" --decision-file "$file" \
    ${identity:+--expect-identity "$identity"} 2>&1 >/dev/null) || rc=$?
  rm -f "$file"
  case "$rc" in
    0) result=answered detail='' ;;
    3) result=refused detail=$err ;;
    *) result=failed detail=$err ;;
  esac
  record_update "$cid" "$(jq -c --arg r "$result" --arg d "$(printf '%s' "$detail" | tail -n 3)" \
    '{hold:(.hold + {result:$r, detail:(if $d == "" then null else $d end)})}' "$(record_path "$cid")")" \
    || return 1
  [ "$result" = answered ]
}

# Steps after a delivery: mark the conversation, answer any held call.
after_delivery() {  # <client-id>
  fm_direct_line_mark_owner_message "$MATE_HOME" \
    || printf 'fm-direct-line: warning: could not mark %s as talking with its owner\n' "$MATE_ID" >&2
  answer_hold "$1"
}

state_of_outcome() {  # <desk-voice outcome line>
  case "$1" in
    sent-unconfirmed:*) printf 'typed-unconfirmed' ;;
    sent:*) printf 'typed' ;;
    mailbox:*) printf 'mailbox' ;;
    pending:*|unknown:*) printf 'unknown' ;;
    *) printf 'failed' ;;
  esac
}

finish_and_print() {  # <client-id>
  local cid=$1 state hold
  cat "$(record_path "$cid")"
  state=$(record_field "$cid" '.state')
  case "$state" in
    typed|typed-unconfirmed|mailbox)
      hold=$(record_field "$cid" '.hold.result')
      if [ -n "$(record_field "$cid" '.hold.task')" ] && [ "$hold" != answered ]; then
        exit 3
      fi
      exit 0
      ;;
    unknown) exit 0 ;;
    *) exit 1 ;;
  esac
}

cmd_send() {
  local id=${1:-} cid='' answers='' identity='' text outcome state rc=0 images=0 mailbox_pending=0 f
  local -a image_args=()
  [ "$#" -ge 1 ] || refuse "usage: fm-direct-line.sh send <mate-id> --client-id <id> [--] <text...>"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --client-id) [ "$#" -ge 2 ] || refuse "--client-id needs an id"; cid=$2; shift 2 ;;
      --answers) [ "$#" -ge 2 ] || refuse "--answers needs a task id"; answers=$2; shift 2 ;;
      --hold-identity) [ "$#" -ge 2 ] || refuse "--hold-identity needs a value"; identity=$2; shift 2 ;;
      --image)
        [ "$#" -ge 2 ] || refuse "--image needs a path"
        case "$2" in /*) ;; *) refuse "--image needs an absolute path: $2" ;; esac
        [ -f "$2" ] || refuse "no such image: $2"
        image_args+=(--image "$2"); images=$((images + 1)); shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  text=$*
  printf '%s' "$cid" | grep -Eq "$CLIENT_ID_RE" \
    || refuse "--client-id must be 8 to 64 letters, digits, dots, underscores or hyphens"
  case "$text" in *[![:space:]]*) ;; *) text='' ;; esac
  [ -n "$text" ] || [ "$images" -gt 0 ] || refuse "nothing to send"
  [ -z "$identity" ] || [ -n "$answers" ] || refuse "--hold-identity needs --answers"
  case "$answers" in ''|*[!A-Za-z0-9._-]*) [ -z "$answers" ] || refuse "not a task id: $answers" ;; esac
  resolve_mate "$id"
  send_lock_acquire

  if [ -f "$(record_path "$cid")" ]; then
    state=$(record_field "$cid" '.state')
    case "$state" in
      sending)
        # An earlier send stopped mid-way. desk-voice's own record of the same
        # client id says whether anything was typed.
        outcome=$(run_for_mate "$SCRIPT_DIR/fm-desk-voice.sh" delivery "$cid" 2>/dev/null | jq -r '.outcome // empty') || outcome=
        if [ -n "$outcome" ]; then
          state=$(state_of_outcome "$outcome")
          record_update "$cid" "$(jq -cn --arg s "$state" --arg o "$outcome" '{state:$s, outcome:$o}')" || die "cannot update the delivery record"
        elif [ "$(record_field "$cid" '.parent_copy')" = copied ]; then
          state=resume
        fi
        ;;
    esac
    case "$state" in
      typed|typed-unconfirmed|mailbox) after_delivery "$cid" || true; finish_and_print "$cid" ;;
      resume) ;;
      *) finish_and_print "$cid" ;;
    esac
  else
    record_update "$cid" "$(jq -cn --arg schema "$DELIVERY_SCHEMA" --arg mate "$MATE_ID" --arg cid "$cid" \
      --arg text "$text" --argjson images "$images" --arg task "$answers" --arg ident "$identity" \
      '{schema:$schema, mate:$mate, client_id:$cid, state:"sending", outcome:null, detail:null,
        text:$text, images:$images, parent_copy:"pending",
        hold:(if $task == "" then null else {task:$task, identity:(if $ident == "" then null else $ident end), result:null} end)}')" \
      || die "cannot write the delivery record"
    if copy_to_parent "$cid" "$text" "$images"; then
      record_update "$cid" '{"parent_copy":"copied"}' || die "cannot update the delivery record"
    else
      record_update "$cid" '{"parent_copy":"failed","state":"failed","detail":"the parent channel could not be written, so nothing was typed"}' || true
      finish_and_print "$cid"
    fi
  fi

  # Keep the owner's order: behind an undrained mailbox message, use the mailbox.
  for f in "$MATE_HOME/state/desk-voice/inbox"/*.json; do
    [ -e "$f" ] && { mailbox_pending=1; break; }
  done
  if [ "$mailbox_pending" -eq 1 ]; then
    outcome=$(run_for_mate "$SCRIPT_DIR/fm-desk-voice.sh" deliver --source direct-line \
      ${image_args[@]+"${image_args[@]}"} -- "$text") || rc=$?
    [ "$rc" -ne 0 ] || outcome="mailbox: $outcome"
  else
    outcome=$(run_for_mate "$SCRIPT_DIR/fm-desk-voice.sh" send --client-id "$cid" \
      --expect-home "$MATE_HOME" --source direct-line \
      ${image_args[@]+"${image_args[@]}"} -- "$text") || rc=$?
  fi
  outcome=$(printf '%s\n' "$outcome" | tail -n 1)
  [ "$rc" -eq 0 ] && [ -n "$outcome" ] || outcome="failed: the message could not be delivered"
  state=$(state_of_outcome "$outcome")
  record_update "$cid" "$(jq -cn --arg s "$state" --arg o "$outcome" '{state:$s, outcome:$o}')" \
    || die "cannot update the delivery record"
  case "$state" in
    typed|typed-unconfirmed|mailbox) after_delivery "$cid" || true ;;
    failed)
      fm_parent_channel_report "$MATE_HOME" "$MATE_HOME/state" \
        "note: owner's direct-line message $cid to $MATE_ID was not delivered" >/dev/null 2>&1 || true
      ;;
  esac
  finish_and_print "$cid"
}

cmd_delivery() {
  local id=${1:-} cid=${2:-} path held=0
  [ "$#" -eq 2 ] || refuse "usage: fm-direct-line.sh delivery <mate-id> <client-id>"
  printf '%s' "$cid" | grep -Eq "$CLIENT_ID_RE" || refuse "not a client id: $cid"
  resolve_mate "$id"
  path=$(record_path "$cid")
  if [ ! -f "$path" ]; then
    jq -cn --arg schema "$DELIVERY_SCHEMA" --arg mate "$MATE_ID" --arg cid "$cid" \
      '{schema:$schema, mate:$mate, client_id:$cid, state:"unknown-id"}'
    exit 1
  fi
  if [ "$(record_field "$cid" '.state')" = sending ]; then
    # Still sending only while a sender holds this mate's send lock.
    if fm_lock_try_acquire "$(fm_direct_line_dir "$MATE_HOME")/.send.lock"; then
      fm_lock_release "$(fm_direct_line_dir "$MATE_HOME")/.send.lock"
    else
      held=1
    fi
    if [ "$held" -eq 0 ]; then
      jq -c '. + {state:"interrupted"}' "$path"
      return 0
    fi
  fi
  cat "$path"
}

cmd_talking() {
  [ "$#" -eq 1 ] || refuse "usage: fm-direct-line.sh talking <mate-id>"
  resolve_mate "$1"
  talking_json "$MATE_ID" "$MATE_HOME"
  fm_direct_line_talking "$MATE_HOME"
}

cmd_conversation() {
  [ "$#" -eq 1 ] || refuse "usage: fm-direct-line.sh conversation <mate-id>"
  resolve_mate "$1"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  run_for_mate python3 "$SCRIPT_DIR/fm-web.py" conversation --home "$MATE_HOME"
}

cmd_waiting() {
  local secs=${FM_DIRECT_LINE_WAIT_SECS:-$FM_DIRECT_LINE_WAIT_SECS_DEFAULT} clear=0 id home
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for) [ "$#" -ge 2 ] || refuse "--for needs seconds"; secs=$2; shift 2 ;;
      --clear) clear=1; shift ;;
      *) refuse "usage: fm-direct-line.sh waiting [--for <seconds> | --clear]" ;;
    esac
  done
  case "$secs" in ''|*[!0-9]*) refuse "--for needs whole seconds: $secs" ;; esac
  home=$(real_dir "$FM_HOME")
  id=$(fm_parent_channel_home_id "$home") || refuse "this home is not a second mate home"
  fm_direct_line_enabled "$home" || refuse "this second mate's charter does not opt into the direct line"
  if [ "$clear" -eq 1 ]; then
    fm_direct_line_clear_waiting "$home" || die "cannot clear the waiting record"
  else
    fm_direct_line_set_waiting "$home" "$(( $(date +%s) + secs ))" || die "cannot write the waiting record"
  fi
  talking_json "$id" "$home"
}

verb=$1
shift
case "$verb" in
  list) cmd_list "$@" ;;
  send) cmd_send "$@" ;;
  delivery) cmd_delivery "$@" ;;
  talking) cmd_talking "$@" ;;
  conversation) cmd_conversation "$@" ;;
  waiting) cmd_waiting "$@" ;;
  *) usage >&2; exit 2 ;;
esac
