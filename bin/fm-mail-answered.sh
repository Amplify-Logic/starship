#!/usr/bin/env bash
# fm-mail-answered.sh - close a mail ask once the owner has replied in its thread.
#
# Usage:
#   fm-mail-answered.sh [check]
#   fm-mail-answered.sh arm
#   fm-mail-answered.sh disarm
#   fm-mail-answered.sh --help
#
# For mail only, the owner's own reply in the thread closes the ask without
# its content being read: an exception to the channel intake's rule that a
# reply counts by what it says (docs/channel-intake.md "Resolution"). Any
# promise in that reply becomes its own line on the next intake pass
# ("Promised follow-ups"); this script never touches a promise line.
#
# OPT-IN. Inert until the private config/mail-answered holds `enabled = true`.
# Its `key = value` lines, unknown keys refused:
#   enabled    true to arm this home (default false)
#   reader     the read-only mail thread command, required when enabled;
#              split like a shell line, so it may carry its own arguments
#   hours      HH:MM-HH:MM local window a run may act in (default all day);
#              a start after the end wraps midnight
#   skip_from  comma-separated extra words that mark a sender as automated
# The local day and hours use the `timezone` of config/channel-intake, else
# this machine's zone. A run does nothing outside the hours or on a Saturday
# or Sunday.
#
# THE READER. Called only as `<reader> thread <id>`, with the thread id in the
# case the line's alias holds. It prints one JSON object per line, one per
# message in the thread: `id`, `sent_at` (epoch seconds), `from`, `from_owner`
# (true or false) and `headers`, an object of header name (any case) to its
# value as a string. A reader that exits non-zero, or prints anything else,
# is a failed read and closes nothing.
#
# WHICH LINES. Each run takes the open lines in data/todo/items/ that carry a
# `<source>:thread-<id>` alias, the ref the intake observes a mail ask with,
# and skips a line with a `promise-` ref or a `due` mark. The id comes from
# that alias, never from an about key, which is lowercased.
#
# WHEN IT CLOSES. The ask time is the line's `asked_at`, else `first_seen`.
# When the owner sent a message after it that is not automated, and every
# message after that one is automated, the line closes with
# `bin/fm-todo.sh close --reason fulfilled --actor mail-answered` and the
# message id as evidence. A message is automated when it has a List-Id
# header, Precedence bulk or list, Auto-Submitted other than no, or a sender
# whose address before the @ contains noreply, no-reply, donotreply,
# mailer-daemon, postmaster, notifications, newsletter, bounce or a
# skip_from word. An owner's own automated message, such as an out-of-office
# reply, is not a reply.
#
# ONCE PER REPLY. data/mail-answered/closed.tsv records each close (item,
# message, its sent_at, closed at), so a line reopened after a close closes
# again only on a newer owner reply.
#
# AS A WATCHER CHECK. `arm` writes state/mail-answered.check.sh and binds its
# bytes with bin/fm-check-register.sh, as bin/fm-mail-check.sh does, so the
# watcher runs it on its normal cadence; `disarm` removes the shim and its
# binding. `check` prints one line only when it closed a line, which the
# watcher turns into a wake; errors go to stderr.
#
# FM_MAIL_ANSWERED_NOW pins the clock for tests.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CHECK_ID=mail-answered
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

action_check() {
  FM_MA_CONFIG="$CONFIG/mail-answered" \
  FM_MA_INTAKE_CONFIG="$CONFIG/channel-intake" \
  FM_MA_ITEMS="${FM_TODO_STORE_OVERRIDE:-$DATA/todo}/items" \
  FM_MA_LEDGER="$DATA/mail-answered/closed.tsv" \
  FM_MA_TODO="$SCRIPT_DIR/fm-todo.sh" \
    python3 - <<'PY'
import json, os, re, shlex, subprocess, sys, time
from datetime import datetime
from pathlib import Path

def die(msg):
    print(f'fm-mail-answered: {msg}', file=sys.stderr)
    sys.exit(1)

def read_kv(path, allowed):
    out = {}
    try:
        text = Path(path).read_text()
    except FileNotFoundError:
        return out
    except OSError as exc:
        die(f'cannot read {path}: {exc}')
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        key, value = key.strip(), value.strip()
        if not sep:
            die(f'{path}: not a key = value line: {line}')
        if allowed is not None and key not in allowed:
            die(f'{path}: unknown key {key}')
        out[key] = value
    return out

conf = read_kv(os.environ['FM_MA_CONFIG'], {'enabled', 'reader', 'hours', 'skip_from'})
enabled = conf.get('enabled', 'false')
if enabled not in ('true', 'false'):
    die('enabled must be true or false')
if enabled != 'true':
    sys.exit(0)
try:
    reader = shlex.split(conf.get('reader', ''))
except ValueError:
    die('reader is not a valid command line')
if not reader:
    die('reader is required when enabled')
skip = [w.strip().lower() for w in conf.get('skip_from', '').split(',') if w.strip()]

zone = read_kv(os.environ['FM_MA_INTAKE_CONFIG'], None).get('timezone', '')
if zone:
    os.environ['TZ'] = zone
    time.tzset()
now_raw = os.environ.get('FM_MAIL_ANSWERED_NOW', '')
now = int(now_raw) if now_raw.isdigit() else int(time.time())
local = datetime.fromtimestamp(now)
if local.isoweekday() >= 6:
    sys.exit(0)
hours = conf.get('hours', '')
if hours:
    m = re.fullmatch(r'([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)', hours)
    if not m:
        die('hours must be HH:MM-HH:MM')
    start = int(m[1]) * 60 + int(m[2])
    end = int(m[3]) * 60 + int(m[4])
    minute = local.hour * 60 + local.minute
    inside = start <= minute < end if start <= end else (minute >= start or minute < end)
    if not inside:
        sys.exit(0)

AUTOMATED_WORDS = ('noreply', 'no-reply', 'donotreply', 'mailer-daemon', 'postmaster',
                   'notifications', 'newsletter', 'bounce')

def automated(msg):
    headers = {str(k).lower(): str(v).strip().lower() for k, v in msg['headers'].items()}
    if 'list-id' in headers:
        return True
    if headers.get('precedence') in ('bulk', 'list'):
        return True
    if 'auto-submitted' in headers and headers['auto-submitted'] != 'no':
        return True
    sender = msg['from']
    angle = re.search(r'<([^<>]*)>', sender)
    address = (angle[1] if angle else sender).strip().lower()
    localpart = address.split('@', 1)[0]
    return any(w in localpart for w in AUTOMATED_WORDS + tuple(skip))

def read_thread(thread):
    try:
        res = subprocess.run(reader + ['thread', thread], capture_output=True, text=True,
                             stdin=subprocess.DEVNULL)
    except OSError as exc:
        print(f'fm-mail-answered: reader failed for thread {thread}: {exc}', file=sys.stderr)
        return None
    if res.returncode != 0:
        print(f'fm-mail-answered: reader exited {res.returncode} for thread {thread}', file=sys.stderr)
        return None
    msgs = []
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            msg = None
        if (not isinstance(msg, dict) or not isinstance(msg.get('id'), str) or not msg['id']
                or not isinstance(msg.get('sent_at'), int) or isinstance(msg.get('sent_at'), bool)
                or not isinstance(msg.get('from'), str) or not isinstance(msg.get('from_owner'), bool)
                or not isinstance(msg.get('headers'), dict)
                or not all(isinstance(v, str) for v in msg['headers'].values())):
            print(f'fm-mail-answered: reader printed a malformed message for thread {thread}', file=sys.stderr)
            return None
        msgs.append(msg)
    return msgs

def owner_reply(msgs, asked):
    """The owner's reply after the ask when every later message is automated, else None."""
    later = sorted((m for m in msgs if m['sent_at'] > asked), key=lambda m: m['sent_at'])
    people = [m for m in later if not automated(m)]
    if people and people[-1]['from_owner']:
        return people[-1]
    return None

ledger_path = Path(os.environ['FM_MA_LEDGER'])
closed_before = {}
try:
    for row in ledger_path.read_text().splitlines():
        cols = row.split('\t')
        if len(cols) >= 3 and cols[2].isdigit():
            closed_before[cols[0]] = max(closed_before.get(cols[0], -1), int(cols[2]))
except FileNotFoundError:
    pass

items_dir = Path(os.environ['FM_MA_ITEMS'])
closed = []
for path in sorted(items_dir.glob('*.json')) if items_dir.is_dir() else []:
    try:
        rec = json.loads(path.read_text())
    except (OSError, ValueError):
        continue
    if not isinstance(rec, dict) or rec.get('state') != 'open':
        continue
    aliases = [a for a in rec.get('aliases') or [] if isinstance(a, str)]
    refs = [a.split(':', 1)[1] for a in aliases if ':' in a and not a.startswith('ledger:')]
    if any(r.startswith('promise-') for r in refs):
        continue
    if 'due' in (rec.get('marks') or {}):
        continue
    threads = list(dict.fromkeys(r[len('thread-'):] for r in refs if r.startswith('thread-') and len(r) > 7))
    if not threads:
        continue
    asked = rec.get('asked_at') or rec.get('first_seen')
    if not isinstance(asked, (int, float)) or isinstance(asked, bool) or asked <= 0:
        continue
    iid = rec.get('id') or path.stem
    for thread in threads:
        msgs = read_thread(thread)
        if msgs is None:
            continue
        reply = owner_reply(msgs, asked)
        if reply is None or reply['sent_at'] <= closed_before.get(iid, -1):
            continue
        res = subprocess.run([os.environ['FM_MA_TODO'], 'close', '--item', iid, '--reason', 'fulfilled',
                              '--actor', 'mail-answered',
                              '--evidence', f"Owner replied by mail, message {reply['id']}"],
                             capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if res.returncode != 0:
            print(f'fm-mail-answered: closing {iid} failed: {res.stderr.strip()}', file=sys.stderr)
            break
        ledger_path.parent.mkdir(parents=True, exist_ok=True)
        with ledger_path.open('a') as fh:
            fh.write(f"{iid}\t{reply['id']}\t{reply['sent_at']}\t{now}\n")
        closed.append(iid)
        break

if closed:
    print(f"mail-answered: closed {len(closed)} answered mail ask(s): {' '.join(closed)}")
PY
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-mail-answered.sh - closes mail asks the owner answered.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-mail-answered.sh") check"
}

action_arm() {
  local home tmp
  mkdir -p "$STATE" || return 1
  [ ! -L "$STATE" ] && [ ! -L "$CHECK_SHIM" ] || {
    printf 'fm-mail-answered: refusing a symlinked state path\n' >&2
    return 1
  }
  # The watcher runs the shim from its own directory, so it names the home absolutely.
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-mail-answered: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  tmp=$(umask 077; mktemp "$STATE/.fm-mail-answered.XXXXXX") || return 1
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-mail-answered: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  # An unbound shim is rejected by the watcher every cycle, so a failed
  # registration leaves no shim behind.
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || rm -f -- "$CHECK_SHIM"
    printf 'fm-mail-answered: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  [ -d "$STATE" ] || { printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"; return 0; }
  FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || return 1
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) printf 'fm-mail-answered: unknown action: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
