#!/usr/bin/env bash
# fm-direct-line.sh - the owner's direct line to a direct-line second mate.
#
# Usage, from the parent home (FM_HOME must be set explicitly):
#   fm-direct-line.sh list
#   fm-direct-line.sh enable <mate-id>
#   fm-direct-line.sh disable <mate-id>
#   fm-direct-line.sh send <mate-id> --client-id <id>
#                     [--answers <task-id> --hold-identity <identity>]
#                     [--image <path>]... [--] <text...>
#   fm-direct-line.sh delivery <mate-id> <client-id>
#   fm-direct-line.sh talking <mate-id>
#   fm-direct-line.sh conversation <mate-id>
# Usage, from the mate's own home (its FM_HOME):
#   fm-direct-line.sh waiting [--for <seconds> | --clear]
#   fm-direct-line.sh answered <task-id> --client-id <id>
#
# docs/direct-line.md owns the design and bin/fm-direct-line-lib.sh owns the
# opt-in and the "talking with owner" state. Every command prints one JSON
# document whose "schema" field names its versioned shape:
#   list          fm-direct-line-mates.v1     every registered second mate:
#                 id, summary, home, remote, direct_line, talking_with_owner,
#                 talking_reason, talking_until, last_owner_message_at,
#                 waiting_until (epochs, or null)
#   send, delivery, answered
#                 fm-direct-line-delivery.v1  mate, client_id, state, outcome,
#                 detail, parent_copy, images, created_at, updated_at, and
#                 hold (null, or task, identity, result, detail,
#                 answered_via, answered_at)
#   talking, waiting, enable, disable
#                 fm-direct-line-talking.v1   mate, enabled, talking, reason,
#                 until, last_owner_message_at, waiting_until
#   conversation  fm-web-conversation.v1      bin/fm-web.py owns its fields
#
# RESOLUTION. A mate is resolved only through this home's registry,
# data/secondmates.md, and then asserted before anything is read or typed: the
# entry is local, its home's .fm-secondmate-home names the same id, its
# .fm-secondmate-parent binds it locally to this very home, its own
# data/charter.md carries the opt-in line, and this home enabled it (`enable`,
# which checks everything else first). Any failure refuses (exit 2) and nothing
# is typed. A remote second mate has no direct line yet. `list` applies the
# same assertions, so it shows direct_line true only for a mate send accepts.
#
# SEND. One send per mate at a time (a per-mate lock, waited for up to
# FM_DIRECT_LINE_LOCK_WAIT seconds, default 60). When the lock stays busy, a
# send whose id is already recorded prints that record with its own exit code
# (below; 4 while it is still sending), and one whose id is not prints state
# busy and exits 2: nothing was recorded or typed
# for it, so send it again with the same id. The text is at most 8000
# characters; --answers needs words and --hold-identity, the identity the
# owner was shown (bin/fm-captain-hold.sh open <task> --identity).
#   1. The client id (8 to 64 letters, digits, dot, underscore, hyphen, first a
#      letter or digit) names a record in this home's
#      state/direct-line/<mate>/deliveries/<client-id>.json holding a digest of
#      the text, images, and held call. A send whose id is already recorded
#      with another digest is refused; with the same digest it types nothing
#      new: it adopts desk-voice's own record of that id for a send still
#      marked sending or unknown, finishes any step a stopped send left undone
#      while the record is younger than FM_DIRECT_LINE_RESUME_SECS (default
#      300), and prints the record. An older unfinished record is never
#      resumed or answered: it is marked expired.
#   2. The message is copied to the mate's parent channel first, as one
#      sanitised note: line (bin/fm-parent-channel-lib.sh) carrying the first
#      900 characters and a pointer to the full record. Nothing is typed
#      unless that copy is recorded; a resumed send copies again (the channel
#      appends the same line once).
#   3. The mate is marked talking with its owner before anything is typed, so
#      no lifecycle action can land between the check and the words; a failed
#      delivery puts the earlier mark back.
#   4. The words go through bin/fm-desk-voice.sh only (an answer typed after
#      "[direct line message <id> answers <task>]", so the mate can cite it), bounded by
#      FM_DIRECT_LINE_SEND_TIMEOUT seconds (default 120) plus 60 seconds for
#      desk-voice to finish words it is already typing, their Enter, and any
#      mailbox fallback (it ignores the stop signal), with FM_HOME set to
#      the mate's home, every home override, pane variable and desk-voice
#      submit knob cleared, the same --client-id, and --expect-home, so they
#      are typed only into the pane of the session that holds that mate's lock
#      and runs for that home, under its pane-writer lock, and otherwise land
#      in its mailbox. While the mate's mailbox still holds an undrained
#      message, a new one goes there too (desk-voice send --mailbox), so the
#      owner's messages arrive in the order sent.
#   5. Once delivered, --answers closes that call held for the owner in the
#      mate's home with compare-and-answer (bin/fm-captain-hold.sh answer
#      --expect-identity, bounded by 60 seconds). The decision records the
#      owner's words and that they came by direct line through this client id,
#      and the record keeps answered_via and answered_at. A refused answer (the
#      call closed or changed) is final; a failed one, or one a timed-out send
#      never reached, is tried again by a resend of the same id, a delivery
#      poll, or the mate's `answered`, while the record is young.
# States: sending, typed, typed-unconfirmed, mailbox, failed, unknown,
# expired, for send only busy (above), and, for delivery only, interrupted
# (the send stopped before desk-voice claimed the id; send it again with the
# same id within the resume window). delivery adopts desk-voice's record the same way before it prints,
# and then, when the per-mate send lock is free right away, closes the held
# call a delivered message names, exactly as a resend of the same id would;
# when it is busy, the poll never waits and a later poll closes it.
# Exit: 0 delivered, 1 not delivered (failed or expired), 2 refused, 3
# delivered but the held call is not answered, 4 the outcome is not known yet
# (still sending, or stopped while typing): poll delivery, never resend new
# words.
#
# WAITING. The mate itself runs `waiting` when it has asked the owner
# something and waits for the answer, so the first mate leaves it alone for
# --for seconds (default and maximum 14400); `waiting --clear` ends that early.
#
# ANSWERED. A mate never closes a held call from its own reading of the chat.
# `answered <task> --client-id <id>` is the one way it may: it cites the
# direct-line delivery that named that call, and only finishes that
# delivery's own answer (the owner's recorded words, the identity the owner
# was shown) while the record is young; anything else is refused.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-direct-line-lib.sh
. "$SCRIPT_DIR/fm-direct-line-lib.sh"

CLIENT_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$'
TASK_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
TEXT_MAX=8000
NOTE_TEXT_MAX=900
DELIVERY_SCHEMA=fm-direct-line-delivery.v1
TALKING_SCHEMA=fm-direct-line-talking.v1
RESUME_SECS=$(_fm_direct_line_number "${FM_DIRECT_LINE_RESUME_SECS:-}" 300)
SEND_TIMEOUT=$(_fm_direct_line_number "${FM_DIRECT_LINE_SEND_TIMEOUT:-}" 120)
SEND_GRACE=60
HOLD_TIMEOUT=60

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# The command prefix that runs a script for the mate's home, never this one:
# every home override, pane variable and desk-voice submit knob cleared, so
# neither this caller's pane nor its home can leak in.
mate_env() {
  MATE_ENV=(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION
    -u HERDR_SOCKET_PATH -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND
    -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u STATE
    -u PRIMARY_SUBMIT_COMPOSER -u PRIMARY_SUBMIT_RING -u PRIMARY_SUBMIT_EXPECT_HOME
    FM_HOME="$MATE_HOME")
}

# The one-line, control-free form of <text> (the same rule desk-voice types by).
plain_text() {  # <text>
  python3 -c '
import sys, unicodedata
text = "".join(" " if unicodedata.category(c) in ("Cc", "Zl", "Zp") else c for c in sys.argv[1])
sys.stdout.write(" ".join(text.split()))
' "$1"
}

# Check mate <id> through the registry and its home. 0 and MATE_ID/MATE_HOME
# when every assertion holds, else 2 (registry unreadable) or 1, with the
# reason in MATE_ERR. With <need-enabled> 1 the parent's opt-in is required.
check_mate() {  # <id> <need-enabled>
  local id=$1 need=$2 rc=0 home marker_id parent_real self_real
  MATE_ERR=
  case "$id" in ''|*[!A-Za-z0-9._-]*|.*) MATE_ERR="not a second mate id: '$id'"; return 1 ;; esac
  secondmate_registry_line_for_id "$REGISTRY" "$id" || rc=$?
  case "$rc" in
    0) ;;
    2) MATE_ERR=$SECONDMATE_REGISTRY_ERROR; return 2 ;;
    *) MATE_ERR="second mate '$id' is not registered (exactly once) in $REGISTRY"; return 1 ;;
  esac
  if [ "$SECONDMATE_REGISTRY_REMOTE" -ne 0 ]; then
    MATE_ERR="second mate '$id' runs on $SECONDMATE_REGISTRY_HOST; a remote second mate has no direct line yet"
    return 1
  fi
  home=$SECONDMATE_REGISTRY_HOME
  case "$home" in /*) ;; *) MATE_ERR="second mate '$id' has a relative home in the registry: $home"; return 1 ;; esac
  [ -d "$home" ] || { MATE_ERR="second mate '$id' home is missing: $home"; return 1; }
  marker_id=$(fm_parent_channel_home_id "$home") \
    || { MATE_ERR="second mate '$id' home has no usable identity marker: $home"; return 1; }
  [ "$marker_id" = "$id" ] \
    || { MATE_ERR="second mate '$id' home names itself '$marker_id'; refusing to reach a different mate"; return 1; }
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" \
    || { MATE_ERR="second mate '$id' has no readable parent binding"; return 1; }
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || { MATE_ERR="second mate '$id' is not bound to a local parent"; return 1; }
  parent_real=$(real_dir "$FM_SECONDMATE_PARENT_HOME") \
    || { MATE_ERR="second mate '$id' parent home is missing: $FM_SECONDMATE_PARENT_HOME"; return 1; }
  self_real=$(real_dir "$FM_HOME") || { MATE_ERR="cannot resolve FM_HOME '$FM_HOME'"; return 1; }
  [ "$parent_real" = "$self_real" ] \
    || { MATE_ERR="second mate '$id' belongs to another home ($FM_SECONDMATE_PARENT_HOME), not this one"; return 1; }
  fm_direct_line_charter_opted_in "$home" \
    || { MATE_ERR="second mate '$id' has no direct line: its charter does not opt in ('$FM_DIRECT_LINE_CHARTER_LINE')"; return 1; }
  MATE_ID=$id
  MATE_HOME=$(real_dir "$home")
  if [ "$need" = 1 ] && ! fm_direct_line_enabled "$STATE" "$MATE_ID" "$MATE_HOME"; then
    MATE_ERR="second mate '$id' has no direct line: this home has not enabled it (fm-direct-line.sh enable $id)"
    return 1
  fi
  return 0
}

resolve_mate() {  # <id> [need-enabled, default 1]
  check_mate "$1" "${2:-1}" || refuse "$MATE_ERR"
  mate_env
}

json_epoch() {  # <value>
  if [ -n "$1" ]; then printf '%s' "$1"; else printf 'null'; fi
}

talking_json() {
  local talking=false enabled=false reason='' until=''
  ! fm_direct_line_enabled "$STATE" "$MATE_ID" "$MATE_HOME" || enabled=true
  if fm_direct_line_talking "$STATE" "$MATE_ID" "$MATE_HOME"; then
    talking=true
    reason=$FM_DIRECT_LINE_TALKING_REASON
    until=$FM_DIRECT_LINE_TALKING_UNTIL
  fi
  jq -cn --arg schema "$TALKING_SCHEMA" --arg mate "$MATE_ID" --argjson enabled "$enabled" \
    --argjson talking "$talking" --arg reason "$reason" --argjson until "$(json_epoch "$until")" \
    --argjson last "$(json_epoch "$(fm_direct_line_last_owner_message "$STATE" "$MATE_ID")")" \
    --argjson waiting "$(json_epoch "$(fm_direct_line_waiting_until "$MATE_HOME")")" \
    '{schema:$schema, mate:$mate, enabled:$enabled, talking:$talking,
      reason:(if $reason == "" then null else $reason end), until:$until,
      last_owner_message_at:$last, waiting_until:$waiting}'
}

cmd_list() {
  local line rows='' row enabled talking reason until last waiting id rc
  [ "$#" -eq 0 ] || refuse "usage: fm-direct-line.sh list"
  [ ! -L "$REGISTRY" ] || refuse "$(secondmate_registry_symlink_refusal "$REGISTRY")"
  if [ -f "$REGISTRY" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      secondmate_registry_parse_line "$line" || continue
      id=$SECONDMATE_REGISTRY_ID
      row=$(jq -cn --arg id "$id" --arg summary "$SECONDMATE_REGISTRY_SUMMARY" \
        --arg home "$SECONDMATE_REGISTRY_HOME" \
        --argjson remote "$([ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] && echo true || echo false)" \
        '{id:$id, summary:$summary, home:$home, remote:$remote}')
      enabled=false talking=false reason='' until='' last='' waiting='' rc=0
      check_mate "$id" 1 || rc=$?
      if [ "$rc" -eq 0 ]; then
        enabled=true
        if fm_direct_line_talking "$STATE" "$MATE_ID" "$MATE_HOME"; then
          talking=true
          reason=$FM_DIRECT_LINE_TALKING_REASON
          until=$FM_DIRECT_LINE_TALKING_UNTIL
        fi
        last=$(fm_direct_line_last_owner_message "$STATE" "$MATE_ID")
        waiting=$(fm_direct_line_waiting_until "$MATE_HOME")
      fi
      row=$(jq -c --argjson direct "$enabled" --argjson talking "$talking" --arg reason "$reason" \
        --argjson until "$(json_epoch "$until")" --argjson last "$(json_epoch "$last")" \
        --argjson waiting "$(json_epoch "$waiting")" \
        '. + {direct_line:$direct, talking_with_owner:$talking,
          talking_reason:(if $reason == "" then null else $reason end),
          talking_until:$until, last_owner_message_at:$last, waiting_until:$waiting}' <<<"$row")
      rows="$rows$row"$'\n'
    done < "$REGISTRY"
  fi
  printf '%s' "$rows" | jq -cs --arg home "$FM_HOME" \
    '{schema:"fm-direct-line-mates.v1", home:$home, mates:.}'
}

cmd_enable() {
  [ "$#" -eq 1 ] || refuse "usage: fm-direct-line.sh enable <mate-id>"
  resolve_mate "$1" 0
  fm_direct_line_enable "$STATE" "$MATE_ID" || die "cannot record the opt-in under $(fm_direct_line_parent_dir "$STATE" "$MATE_ID")"
  talking_json
}

cmd_disable() {
  [ "$#" -eq 1 ] || refuse "usage: fm-direct-line.sh disable <mate-id>"
  check_mate "$1" 0 || true
  case "$1" in ''|.*|*/*|*[!A-Za-z0-9._-]*) refuse "not a second mate id: '$1'" ;; esac
  fm_direct_line_disable "$STATE" "$1" || die "cannot remove the opt-in"
  jq -cn --arg schema "$TALKING_SCHEMA" --arg mate "$1" \
    '{schema:$schema, mate:$mate, enabled:false, talking:false, reason:null, until:null,
      last_owner_message_at:null, waiting_until:null}'
}

# --- the per-mate delivery record -------------------------------------------

record_dir() { printf '%s/deliveries\n' "$(fm_direct_line_parent_dir "$STATE" "$MATE_ID")"; }
record_path() { printf '%s/%s.json\n' "$(record_dir)" "$1"; }

# Merge the jq object <patch-json> into the record for <client-id>.
record_update() {  # <client-id> <patch-json>
  local path tmp
  path=$(record_path "$1")
  _fm_direct_line_private_dir "${path%/*}" || return 1
  tmp=$(mktemp "${path%/*}/.record.XXXXXX") || return 1
  if [ -f "$path" ]; then
    jq -c --argjson patch "$2" --arg at "$(now_iso)" '. + $patch + {updated_at:$at}' "$path" > "$tmp"
  else
    jq -cn --argjson patch "$2" --arg at "$(now_iso)" --argjson epoch "$(date +%s)" \
      '$patch + {created_at:$at, created_epoch:$epoch, updated_at:$at}' > "$tmp"
  fi || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path"
}

record_field() {  # <client-id> <jq-path>
  jq -r "$2 // empty" "$(record_path "$1")" 2>/dev/null
}

record_age() {  # <client-id>
  local created
  created=$(record_field "$1" '.created_epoch')
  case "$created" in ''|*[!0-9]*) printf '%s\n' 999999999; return ;; esac
  printf '%s\n' "$(( $(date +%s) - created ))"
}

SEND_LOCK=
send_lock_path() { printf '%s/.send.lock\n' "$(fm_direct_line_parent_dir "$STATE" "$MATE_ID")"; }
send_lock_acquire() {
  local wait deadline
  wait=$(_fm_direct_line_number "${FM_DIRECT_LINE_LOCK_WAIT:-}" 60)
  _fm_direct_line_private_dir "$(fm_direct_line_parent_dir "$STATE" "$MATE_ID")" \
    || die "cannot create $(fm_direct_line_parent_dir "$STATE" "$MATE_ID")"
  SEND_LOCK=$(send_lock_path)
  deadline=$(( $(date +%s) + wait ))
  until fm_lock_try_acquire "$SEND_LOCK"; do
    [ "$(date +%s)" -lt "$deadline" ] || { SEND_LOCK=; return 1; }
    sleep 0.2
  done
  trap 'fm_lock_release "$SEND_LOCK"' EXIT
}

# The send lock stayed busy: finish <client-id>'s record when it is recorded,
# else print a busy document and exit 2.
send_lock_busy() {  # <client-id>
  printf "fm-direct-line: another direct-line send to '%s' is still running\n" "$MATE_ID" >&2
  if [ -f "$(record_path "$1")" ]; then
    finish_and_print "$1"
  fi
  jq -cn --arg schema "$DELIVERY_SCHEMA" --arg mate "$MATE_ID" --arg cid "$1" \
    '{schema:$schema, mate:$mate, client_id:$cid, state:"busy",
      detail:"another direct-line send to this mate is still running; nothing was recorded or typed for this id"}'
  exit 2
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

# Adopt desk-voice's own record of <client-id> into ours when ours says the
# send is still sending or unknown. Sets DESK_STATE to desk-voice's state
# (unknown-id when it never claimed the id).
reconcile_record() {  # <client-id>
  local cid=$1 state desk outcome
  DESK_STATE=
  state=$(record_field "$cid" '.state')
  case "$state" in sending|unknown) ;; *) return 0 ;; esac
  desk=$(fm_run_timed 20 "${MATE_ENV[@]}" "$SCRIPT_DIR/fm-desk-voice.sh" delivery "$cid" 2>/dev/null) || true
  DESK_STATE=$(jq -r '.state // empty' <<<"$desk" 2>/dev/null) || DESK_STATE=
  outcome=$(jq -r '.outcome // empty' <<<"$desk" 2>/dev/null) || outcome=
  case "$DESK_STATE" in
    typed|typed-unconfirmed|mailbox|failed|not-in-front)
      record_update "$cid" "$(jq -cn --arg s "$(state_of_outcome "$outcome")" --arg o "$outcome" '{state:$s, outcome:$o}')" \
        || die "cannot update the delivery record"
      ;;
    unknown)
      [ "$state" = unknown ] || record_update "$cid" '{"state":"unknown","detail":"the send stopped while typing; it is never typed again"}' \
        || die "cannot update the delivery record"
      ;;
  esac
}

# Copy the owner's message to the mate's parent channel. 0 copied.
copy_to_parent() {  # <client-id>
  local cid=$1 text images note
  text=$(plain_text "$(record_field "$cid" '.text')")
  images=$(record_field "$cid" '.images')
  if [ "${#text}" -gt "$NOTE_TEXT_MAX" ]; then
    text="${text:0:$NOTE_TEXT_MAX}... (full text: $(record_path "$cid"))"
  fi
  note="owner to $MATE_ID by direct line (msg $cid): $text"
  [ "${images:-0}" -eq 0 ] || note="$note [$images image(s)]"
  fm_parent_channel_report "$MATE_HOME" "$MATE_HOME/state" \
    "note: $(fm_parent_channel_clean_note "$note")"
}

# Answer the held call the record names, at most once. Records the result.
answer_hold() {  # <client-id>
  local cid=$1 task identity text file rc=0 err result detail done_result
  task=$(record_field "$cid" '.hold.task')
  [ -n "$task" ] || return 0
  done_result=$(record_field "$cid" '.hold.result')
  case "$done_result" in answered|refused|expired) return 0 ;; esac
  if [ "$(record_age "$cid")" -gt "$RESUME_SECS" ]; then
    record_update "$cid" "$(jq -c '{hold:(.hold + {result:"expired", detail:"too old to answer; the owner must answer the call again"})}' "$(record_path "$cid")")" || true
    return 1
  fi
  identity=$(record_field "$cid" '.hold.identity')
  text=$(record_field "$cid" '.text')
  file=$(mktemp "$(fm_direct_line_parent_dir "$STATE" "$MATE_ID")/.answer.XXXXXX") || return 1
  printf '%s\n\nAnswered by the owner on the direct line to %s, message %s, at %s.\n' \
    "$text" "$MATE_ID" "$cid" "$(now_iso)" > "$file"
  err=$(fm_run_timed "$HOLD_TIMEOUT" "${MATE_ENV[@]}" "$SCRIPT_DIR/fm-captain-hold.sh" answer "$task" \
    --decision-file "$file" --expect-identity "$identity" 2>&1 >/dev/null) || rc=$?
  rm -f "$file"
  case "$rc" in
    0) result=answered detail='' ;;
    3) result=refused detail=$err ;;
    *) result=failed detail=$err ;;
  esac
  record_update "$cid" "$(jq -c --arg r "$result" --arg d "$(printf '%s' "$detail" | tail -n 3)" \
    --arg via "$cid" --arg at "$(now_iso)" \
    '{hold:(.hold + {result:$r, detail:(if $d == "" then null else $d end),
      answered_via:(if $r == "answered" then $via else null end),
      answered_at:(if $r == "answered" then $at else null end)})}' "$(record_path "$cid")")" \
    || return 1
  [ "$result" = answered ]
}

finish_and_print() {  # <client-id>
  local cid=$1 state
  jq -c 'del(.digest, .text)' "$(record_path "$cid")"
  state=$(record_field "$cid" '.state')
  case "$state" in
    typed|typed-unconfirmed|mailbox)
      if [ -n "$(record_field "$cid" '.hold.task')" ] && [ "$(record_field "$cid" '.hold.result')" != answered ]; then
        exit 3
      fi
      exit 0
      ;;
    unknown|sending) exit 4 ;;
    *) exit 1 ;;
  esac
}

message_digest() {  # <text> <answers> <identity> [<image>...]
  printf '%s\0' "$@" | shasum -a 256 2>/dev/null | cut -d' ' -f1
}

# Type, or mailbox, the recorded message for <client-id>, then finish it.
deliver_recorded() {  # <client-id> <image-args...>
  local cid=$1 prev outcome state rc=0 mailbox_pending=0 f text task
  shift
  text=$(record_field "$cid" '.text')
  task=$(record_field "$cid" '.hold.task')
  [ -z "$task" ] || text="[direct line message $cid answers $task] $text"
  # Talking is marked before anything is typed; a failure puts it back.
  prev=$(fm_direct_line_last_owner_message "$STATE" "$MATE_ID")
  fm_direct_line_mark_owner_message "$STATE" "$MATE_ID" \
    || die "cannot mark '$MATE_ID' as talking with its owner; nothing was typed"
  for f in "$MATE_HOME/state/desk-voice/inbox"/*.json; do
    [ -e "$f" ] && { mailbox_pending=1; break; }
  done
  set -- --client-id "$cid" --expect-home "$MATE_HOME" --source direct-line "$@"
  [ "$mailbox_pending" -eq 0 ] || set -- --mailbox "$@"
  outcome=$(fm_exec_timed "$SEND_TIMEOUT" "$SEND_GRACE" "${MATE_ENV[@]}" "$SCRIPT_DIR/fm-desk-voice.sh" send "$@" -- "$text") || rc=$?
  outcome=$(printf '%s\n' "$outcome" | tail -n 1)
  if fm_timed_out "$rc"; then
    outcome="unknown: $cid"
  elif [ "$rc" -ne 0 ] || [ -z "$outcome" ]; then
    outcome="failed: the message could not be delivered"
  fi
  state=$(state_of_outcome "$outcome")
  record_update "$cid" "$(jq -cn --arg s "$state" --arg o "$outcome" '{state:$s, outcome:$o}')" \
    || die "cannot update the delivery record"
  case "$state" in
    typed|typed-unconfirmed|mailbox)
      if [ -n "$task" ] && ! answer_hold "$cid"; then
        fm_parent_channel_report "$MATE_HOME" "$MATE_HOME/state" \
          "note: owner's direct-line message $cid to $MATE_ID did not close $task ($(record_field "$cid" '.hold.result'))" >/dev/null 2>&1 || true
      fi
      ;;
    failed)
      fm_direct_line_restore_owner_message "$STATE" "$MATE_ID" "$prev" || true
      fm_parent_channel_report "$MATE_HOME" "$MATE_HOME/state" \
        "note: owner's direct-line message $cid to $MATE_ID was not delivered" >/dev/null 2>&1 || true
      ;;
  esac
  finish_and_print "$cid"
}

cmd_send() {
  local id=${1:-} cid='' answers='' identity='' text state images=0 digest
  local -a image_args=() image_paths=()
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
        image_args+=(--image "$2"); image_paths+=("$2"); images=$((images + 1)); shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  text=$*
  [[ $cid =~ $CLIENT_ID_RE ]] \
    || refuse "--client-id must be 8 to 64 letters, digits, dots, underscores or hyphens, starting with a letter or digit"
  case "$text" in *[![:space:]]*) ;; *) text='' ;; esac
  [ -n "$text" ] || [ "$images" -gt 0 ] || refuse "nothing to send"
  [ "${#text}" -le "$TEXT_MAX" ] || refuse "the message is longer than $TEXT_MAX characters"
  if [ -n "$answers" ] || [ -n "$identity" ]; then
    [[ $answers =~ $TASK_ID_RE ]] || refuse "--answers needs a task id (letters, digits, dot, underscore, hyphen, starting with a letter or digit)"
    [ -n "$identity" ] || refuse "--answers needs --hold-identity, the identity of the call the owner was shown"
    [ -n "$text" ] || refuse "--answers needs the owner's words, not only images"
  fi
  resolve_mate "$id"
  digest=$(message_digest "$text" "$answers" "$identity" ${image_paths[@]+"${image_paths[@]}"})
  [ -n "$digest" ] || die "cannot digest the message"
  if ! send_lock_acquire; then
    [ ! -f "$(record_path "$cid")" ] || [ "$(record_field "$cid" '.digest')" = "$digest" ] \
      || refuse "client id $cid was already used for a different message; nothing was sent"
    send_lock_busy "$cid"
  fi

  if [ -f "$(record_path "$cid")" ]; then
    [ "$(record_field "$cid" '.digest')" = "$digest" ] \
      || refuse "client id $cid was already used for a different message; nothing was sent"
    reconcile_record "$cid"
    state=$(record_field "$cid" '.state')
    case "$state" in
      typed|typed-unconfirmed|mailbox)
        answer_hold "$cid" || true
        finish_and_print "$cid"
        ;;
      sending)
        # desk-voice is still sending it, or never claimed it.
        [ "$DESK_STATE" = unknown-id ] || finish_and_print "$cid"
        if [ "$(record_age "$cid")" -gt "$RESUME_SECS" ]; then
          record_update "$cid" '{"state":"expired","detail":"the send stopped before it was typed and is too old to resume"}' || true
          finish_and_print "$cid"
        fi
        if [ "$(record_field "$cid" '.parent_copy')" != copied ]; then
          copy_to_parent "$cid" || { record_update "$cid" '{"parent_copy":"failed","state":"failed","detail":"the parent channel could not be written, so nothing was typed"}' || true; finish_and_print "$cid"; }
          record_update "$cid" '{"parent_copy":"copied"}' || die "cannot update the delivery record"
        fi
        deliver_recorded "$cid" ${image_args[@]+"${image_args[@]}"}
        ;;
      *) finish_and_print "$cid" ;;
    esac
  fi

  record_update "$cid" "$(jq -cn --arg schema "$DELIVERY_SCHEMA" --arg mate "$MATE_ID" --arg cid "$cid" \
    --arg text "$text" --argjson images "$images" --arg task "$answers" --arg ident "$identity" --arg digest "$digest" \
    '{schema:$schema, mate:$mate, client_id:$cid, state:"sending", outcome:null, detail:null,
      text:$text, images:$images, digest:$digest, parent_copy:"pending",
      hold:(if $task == "" then null else {task:$task, identity:$ident, result:null} end)}')" \
    || die "cannot write the delivery record"
  if ! copy_to_parent "$cid"; then
    record_update "$cid" '{"parent_copy":"failed","state":"failed","detail":"the parent channel could not be written, so nothing was typed"}' || true
    finish_and_print "$cid"
  fi
  record_update "$cid" '{"parent_copy":"copied"}' || die "cannot update the delivery record"
  deliver_recorded "$cid" ${image_args[@]+"${image_args[@]}"}
}

cmd_delivery() {
  local id=${1:-} cid=${2:-} path state
  [ "$#" -eq 2 ] || refuse "usage: fm-direct-line.sh delivery <mate-id> <client-id>"
  [[ $cid =~ $CLIENT_ID_RE ]] || refuse "not a client id"
  resolve_mate "$id"
  path=$(record_path "$cid")
  if [ ! -f "$path" ]; then
    jq -cn --arg schema "$DELIVERY_SCHEMA" --arg mate "$MATE_ID" --arg cid "$cid" \
      '{schema:$schema, mate:$mate, client_id:$cid, state:"unknown-id"}'
    exit 1
  fi
  reconcile_record "$cid"
  state=$(record_field "$cid" '.state')
  case "$state" in
    typed|typed-unconfirmed|mailbox)
      case "$(record_field "$cid" '.hold.task'):$(record_field "$cid" '.hold.result')" in
        :*|*:answered|*:refused|*:expired) ;;
        *)
          if fm_lock_try_acquire "$(send_lock_path)"; then
            SEND_LOCK=$(send_lock_path)
            trap 'fm_lock_release "$SEND_LOCK"' EXIT
            answer_hold "$cid" || true
          fi
          ;;
      esac
      ;;
  esac
  if [ "$state" = sending ] && [ "$DESK_STATE" = unknown-id ]; then
    # Still sending only while a sender holds this mate's send lock.
    if fm_lock_try_acquire "$(send_lock_path)"; then
      fm_lock_release "$(send_lock_path)"
      jq -c 'del(.digest, .text) + {state:"interrupted"}' "$path"
      return 0
    fi
  fi
  jq -c 'del(.digest, .text)' "$path"
}

cmd_talking() {
  [ "$#" -eq 1 ] || refuse "usage: fm-direct-line.sh talking <mate-id>"
  resolve_mate "$1"
  talking_json
  fm_direct_line_talking "$STATE" "$MATE_ID" "$MATE_HOME"
}

cmd_conversation() {
  [ "$#" -eq 1 ] || refuse "usage: fm-direct-line.sh conversation <mate-id>"
  resolve_mate "$1"
  "${MATE_ENV[@]}" python3 "$SCRIPT_DIR/fm-web.py" conversation --home "$MATE_HOME"
}

cmd_waiting() {
  local secs=$FM_DIRECT_LINE_WAIT_MAX_SECS clear=0 home parent_state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for) [ "$#" -ge 2 ] || refuse "--for needs seconds"; secs=$2; shift 2 ;;
      --clear) clear=1; shift ;;
      *) refuse "usage: fm-direct-line.sh waiting [--for <seconds> | --clear]" ;;
    esac
  done
  case "$secs" in ''|*[!0-9]*) refuse "--for needs whole seconds: $secs" ;; esac
  secs=$((10#$secs))
  [ "$secs" -le "$FM_DIRECT_LINE_WAIT_MAX_SECS" ] || refuse "--for is at most $FM_DIRECT_LINE_WAIT_MAX_SECS seconds"
  home=$(real_dir "$FM_HOME")
  MATE_ID=$(fm_parent_channel_home_id "$home") || refuse "this home is not a second mate home"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || refuse "this second mate has no local parent"
  parent_state="$FM_SECONDMATE_PARENT_HOME/state"
  fm_direct_line_enabled "$parent_state" "$MATE_ID" "$home" || refuse "this second mate has no direct line"
  MATE_HOME=$home
  STATE=$parent_state
  if [ "$clear" -eq 1 ]; then
    fm_direct_line_clear_waiting "$home" || die "cannot clear the waiting record"
  else
    fm_direct_line_set_waiting "$home" "$(( $(date +%s) + secs ))" || die "cannot write the waiting record"
  fi
  talking_json
}

# Run from a mate's own home: rebind to its local parent, then resolve the
# mate there exactly as the parent would.
rebind_to_parent() {
  local home id
  home=$(real_dir "$FM_HOME")
  id=$(fm_parent_channel_home_id "$home") || refuse "this home is not a second mate home"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || refuse "this second mate has no local parent"
  FM_HOME=$FM_SECONDMATE_PARENT_HOME
  STATE="$FM_HOME/state"
  DATA="$FM_HOME/data"
  REGISTRY="$DATA/secondmates.md"
  resolve_mate "$id"
  [ "$MATE_HOME" = "$home" ] || refuse "the parent's registry points '$id' at another home"
}

cmd_answered() {
  local task=${1:-} cid='' state
  [ "$#" -ge 1 ] || refuse "usage: fm-direct-line.sh answered <task-id> --client-id <id>"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --client-id) [ "$#" -ge 2 ] || refuse "--client-id needs an id"; cid=$2; shift 2 ;;
      *) refuse "usage: fm-direct-line.sh answered <task-id> --client-id <id>" ;;
    esac
  done
  [[ $task =~ $TASK_ID_RE ]] || refuse "not a task id"
  [[ $cid =~ $CLIENT_ID_RE ]] || refuse "not a client id"
  rebind_to_parent
  [ -f "$(record_path "$cid")" ] || refuse "no direct-line message $cid reached this mate"
  [ "$(record_field "$cid" '.hold.task')" = "$task" ] \
    || refuse "direct-line message $cid does not answer $task; only the owner's own message naming a call can close it"
  send_lock_acquire || send_lock_busy "$cid"
  reconcile_record "$cid"
  state=$(record_field "$cid" '.state')
  case "$state" in
    typed|typed-unconfirmed|mailbox) answer_hold "$cid" || true ;;
    *) refuse "direct-line message $cid was not delivered ($state)" ;;
  esac
  finish_and_print "$cid"
}

verb=$1
shift
case "$verb" in
  list) cmd_list "$@" ;;
  enable) cmd_enable "$@" ;;
  disable) cmd_disable "$@" ;;
  send) cmd_send "$@" ;;
  delivery) cmd_delivery "$@" ;;
  talking) cmd_talking "$@" ;;
  conversation) cmd_conversation "$@" ;;
  waiting) cmd_waiting "$@" ;;
  answered) cmd_answered "$@" ;;
  *) usage >&2; exit 2 ;;
esac
