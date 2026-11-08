#!/usr/bin/env bash
# Transcribe one audio file with Deepgram (push-to-talk desk floater path, and
# the call recorder's Deepgram engine through --segments).
#
# Usage:
#   fm-deepgram-stt.sh [--json | --segments] <audio-file>
#   fm-deepgram-stt.sh --check-key
#   fm-deepgram-stt.sh --help
#
# Reads DEEPGRAM_API_KEY from the environment or the home's gitignored .env.
# Never logs the key. Default model: nova-3 (override with DEEPGRAM_STT_MODEL
# in the environment or the home's gitignored .env; the environment wins).
#
# Prints the transcript text on stdout (or the raw JSON with --json).
# --segments prints the transcript as timed segments in whisper.cpp's JSON
# shape, {"transcription": [{"text", "offsets": {"from", "to"}}]} with the
# offsets in milliseconds from the start of the file, which is what the call
# recorder's speaker labelling (bin/fm-call-speaker-split.py) reads. Deepgram's
# words are grouped into a segment until a sentence ends, a pause longer than
# 0.8 seconds follows, or the segment reaches 12 seconds; the vocabulary's
# rewrites below apply to each segment's text. A response with no words gives
# an empty list.
#
# Vocabulary: an optional private $FM_HOME/config/stt-vocabulary (gitignored;
# absent changes nothing).
#   - `#` comment lines and blank lines are ignored.
#   - A plain line is a key term sent to Deepgram as a recognition hint:
#     `keyterm=<term>` for nova-3 models, `keywords=<term>:2` for any
#     other model. Terms are URL-encoded and capped at Deepgram's documented
#     limits (100 keywords; keyterms stop at a conservative estimate of the
#     500-token budget), so an oversized list is trimmed rather than refused.
#   - A `heard => written` line rewrites the printed transcript after
#     smart formatting: use the returned text as `heard`, including formatted
#     numbers (e.g. `pat dot example 1 => pat.example1`). Matching ignores case
#     and accepts any run of whitespace between words. Match whole tokens only:
#     never a part of an email address, dotted name, contraction or hyphenated
#     word, though a possessive `'s` or `’s` may follow (`kai => KAI` turns
#     `kai's` into `KAI's`). Surrounding sentence punctuation is preserved.
#     Try the longest heard phrase first, each span rewritten at most once.
#     --json stays raw.
#   - A line with `=>` but an empty side is ignored. A vocabulary that cannot
#     be read or parsed is skipped with a note on stderr; it never fails the
#     transcription.
#
# Long recordings: there is no length cap here; the whole file is uploaded.
# The request is bounded instead of left to hang. Each attempt gives up
# connecting after 15 seconds and gives up in all after 120 seconds plus one
# second per 100 kB of audio, so a slow uplink still has time to send a long
# recording (a 10-minute desk recording is about 19 MB, so about five minutes
# an attempt). Now and then Deepgram takes the upload and never answers; an
# attempt therefore also gives up once nothing has moved either way for 20
# seconds plus one second per MB of audio, the time Deepgram may take to work
# through the file (20 seconds for a few seconds of speech, about 40 for a
# 10-minute recording). That window only counts while not one byte a second
# is moving, so a slow upload that keeps going is never cut off by it. A
# stalled or timed-out attempt, a dropped connection or a busy Deepgram (HTTP
# 408, 429 or 5xx) is retried twice, three seconds apart, before the helper
# fails; the retry of a stalled attempt usually answers at once. The worst
# case is three full attempts: about 16 minutes for a 10-minute recording.
#
# --check-key asks Deepgram whether it accepts the key, with one free,
# read-only request (GET /v1/auth/token) that transcribes nothing.
#
# A TERM or INT stops the request at once and removes the temporary key file
# and Deepgram's answer.
#
# Exit:
#   0  transcript printed (may be empty if Deepgram heard silence), or the key
#      was accepted
#   1  request failure: Deepgram could not be reached or did not answer well
#   2  missing key, missing file, or bad usage
#   3  Deepgram rejected the key (HTTP 401 or 403) or its account is out of
#      credit (HTTP 402)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

CURL_BIN="${FM_DEEPGRAM_CURL:-curl}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-deepgram-stt: %s\n' "$*" >&2
}

refuse() {
  note "$*"
  exit 2
}

die() {
  note "$*"
  exit 1
}

# The vocabulary parser and transcript reader, run by python3 with argv: <mode> <vocab> ...
# Modes: `query <model>` prints the extra query string (leading `&`, or
# nothing); `transcript <json-file>` prints the rewritten transcript;
# `segments <json-file>` prints the rewritten transcript as timed segments.
vocab_py() {
  cat <<'PY'
import json, re, sys
from urllib.parse import quote

def note(msg):
    print(f"fm-deepgram-stt: {msg}", file=sys.stderr)

def load_vocab(path):
    terms, rewrites = [], []
    if not path:
        return terms, rewrites
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return terms, rewrites
    except OSError as exc:
        note(f"vocabulary skipped: {exc.strerror or exc}")
        return terms, rewrites
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=>" in line:
            heard, _, written = line.partition("=>")
            heard, written = " ".join(heard.split()), written.strip()
            if heard and written:
                rewrites.append((heard, written))
            continue
        term = " ".join(line.split())
        if term and term not in terms:
            terms.append(term)
    return terms, rewrites

def query(terms, model):
    if not terms:
        return ""
    m = model.lower()
    parts = []
    if m.startswith("nova-3"):
        # Deepgram caps keyterms at 500 tokens per request and errors beyond
        # it; budget conservatively (about one token per three characters).
        budget = 450
        for term in terms:
            cost = len(term) // 3 + 2
            if cost > budget:
                break
            budget -= cost
            parts.append("keyterm=" + quote(term, safe=""))
    else:
        for term in terms[:100]:
            parts.append("keywords=" + quote(term + ":2", safe=""))
    return "".join("&" + p for p in parts)

def rewrite(text, rewrites):
    if not text or not rewrites:
        return text
    table = {}
    for heard, written in rewrites:
        table.setdefault(heard.lower(), written)
    ordered = sorted(table, key=len, reverse=True)
    # A rewrite may replace a complete compound token, but must never start or
    # finish inside one, except just before a trailing possessive 's.
    # Email local parts allow more punctuation than names.
    compound = re.compile(
        r"[\w.!#$%&'*+/=?^`{|}~\-]+@[\w-]+(?:\.[\w-]+)*"
        r"|\w+(?:[.'’\u2010\u2011-]\w+)+"
    )
    interiors = set()
    for token in compound.finditer(text):
        interiors.update(range(token.start() + 1, token.end()))
        if token.group().lower().endswith(("'s", "’s")):
            interiors.discard(token.end() - 2)
    # Check each alternative at a valid start so a longer phrase ending inside
    # a compound cannot hide a shorter, valid rewrite at that same position.
    patterns = [
        (re.compile(r"\s+".join(re.escape(w) for w in h.split()) + r"(?!\w)", re.IGNORECASE), table[h])
        for h in ordered
    ]
    pieces, cursor = [], 0
    for candidate in re.finditer(r"(?<!\w)(?=\S)", text):
        start = candidate.start()
        if start < cursor or start in interiors:
            continue
        for rule, written in patterns:
            match = rule.match(text, start)
            if match is None or match.end() in interiors:
                continue
            pieces.extend((text[cursor:start], written))
            cursor = match.end()
            break
    pieces.append(text[cursor:])
    return "".join(pieces)

SEGMENT_GAP_SECONDS = 0.8
SEGMENT_MAX_SECONDS = 12.0

def segments(words):
    """Deepgram's timed words as whisper-shaped segments: a segment ends at a
    sentence end, before a pause longer than SEGMENT_GAP_SECONDS, or once it
    is SEGMENT_MAX_SECONDS long."""
    found, current = [], None
    for word in words:
        text = str(word.get("punctuated_word") or word.get("word") or "").strip()
        if not text:
            continue
        start = float(word.get("start", 0.0))
        end = float(word.get("end", start))
        if current is not None and (
            start - current["end"] > SEGMENT_GAP_SECONDS
            or current["end"] - current["start"] >= SEGMENT_MAX_SECONDS
            or current["text"][-1] in ".?!"
        ):
            found.append(current)
            current = None
        if current is None:
            current = {"text": text, "start": start, "end": end}
        else:
            current["text"] += " " + text
            current["end"] = max(current["end"], end)
    if current is not None:
        found.append(current)
    return found

mode, vocab = sys.argv[1], sys.argv[2]
if mode == "query":
    try:
        terms, _ = load_vocab(vocab)
        sys.stdout.write(query(terms, sys.argv[3]))
    except Exception as exc:  # a bad vocabulary never breaks the request
        note(f"vocabulary skipped: {exc}")
    raise SystemExit(0)

data = json.load(open(sys.argv[3], encoding="utf-8"))
try:
    alternative = data["results"]["channels"][0]["alternatives"][0]
    text = alternative.get("transcript", "")
    words = alternative.get("words") or []
except (KeyError, IndexError, TypeError, AttributeError) as exc:
    note(f"unexpected JSON shape: {exc}")
    raise SystemExit(1)
try:
    _, rewrites = load_vocab(vocab)
except Exception as exc:
    note(f"vocabulary rewrites skipped: {exc}")
    rewrites = []
if mode == "segments":
    try:
        timed = segments(words)
    except (TypeError, ValueError, AttributeError) as exc:
        note(f"unexpected words shape: {exc}")
        raise SystemExit(1)
    rows = []
    for segment in timed:
        try:
            spoken = rewrite(segment["text"], rewrites)
        except Exception as exc:
            note(f"vocabulary rewrites skipped: {exc}")
            spoken = segment["text"]
        rows.append({"text": spoken, "offsets": {"from": int(round(segment["start"] * 1000)),
                                                  "to": int(round(segment["end"] * 1000))}})
    json.dump({"transcription": rows}, sys.stdout)
    sys.stdout.write("\n")
    raise SystemExit(0)
try:
    text = rewrite(text, rewrites)
except Exception as exc:
    note(f"vocabulary rewrites skipped: {exc}")
sys.stdout.write(text)
if text and not text.endswith("\n"):
    sys.stdout.write("\n")
PY
}

vocab_query() {  # <vocab> <model>
  python3 -c "$(vocab_py)" query "$1" "$2" || true
}

extract_transcript() {  # <vocab> <json-file>
  python3 -c "$(vocab_py)" transcript "$1" "$2"
}

extract_segments() {  # <vocab> <json-file>
  python3 -c "$(vocab_py)" segments "$1" "$2"
}

tmp=
auth_cfg=
curl_pid=

# shellcheck disable=SC2329 # Invoked by the EXIT trap prepare_request sets.
remove_temp_files() {
  rm -f "${auth_cfg:-}"
  [ -z "$tmp" ] || rm -f "$tmp" "$tmp.code"
}

# shellcheck disable=SC2329 # Invoked by the signal traps prepare_request sets.
on_signal() {
  [ -z "$curl_pid" ] || kill "$curl_pid" 2>/dev/null || true
  exit 143
}

# request <curl-args...> - one Deepgram request with the key from $auth_cfg;
# the body lands in $tmp and the HTTP status in $http. curl runs in the
# background so a TERM or INT stops it and removes the key and the answer at
# once instead of after curl returns. Returns curl's own status.
request() {
  local status=0
  "$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" --config "$auth_cfg" "$@" > "$tmp.code" &
  curl_pid=$!
  wait "$curl_pid" || status=$?
  curl_pid=
  rm -f "$auth_cfg"
  http=$(cat "$tmp.code" 2>/dev/null || true)
  return "$status"
}

prepare_request() {  # <key>
  trap remove_temp_files EXIT
  trap on_signal INT TERM
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deepgram-stt.XXXXXX") || die "cannot create a temporary file"
  auth_cfg=$(fm_deepgram_auth_config "$1") || die "cannot create the auth config file"
}

# Deepgram refused the key itself: unknown or revoked (401, 403) or out of
# credit (402).
key_refused() {
  case "$http" in 401|402|403) return 0 ;; *) return 1 ;; esac
}

check_key() {  # <key>
  prepare_request "$1"
  request --request GET --connect-timeout 15 --max-time 30 --url "https://api.deepgram.com/v1/auth/token" \
    || die "could not check the key: Deepgram could not be reached"
  if key_refused; then
    note "Deepgram rejected the key (HTTP $http)"
    exit 3
  fi
  [ "$http" = "200" ] || die "could not check the key: Deepgram answered HTTP $http"
  printf 'Deepgram accepted the key\n'
  exit 0
}

main() {
  local output=text audio='' key model http ctype vocab extra bytes max_time stall_time
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --json) output=json; shift ;;
      --segments) output=segments; shift ;;
      --check-key) output=check; shift ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  if [ "$output" = check ]; then
    [ "$#" -eq 0 ] || refuse "usage: fm-deepgram-stt.sh --check-key"
    key=$(fm_deepgram_api_key)
    [ -n "$key" ] || refuse "DEEPGRAM_API_KEY is not set (env or gitignored .env)"
    check_key "$key"
  fi
  [ "$#" -eq 1 ] || refuse "usage: fm-deepgram-stt.sh [--json | --segments] <audio-file>"
  audio=$1
  [ -f "$audio" ] || refuse "audio file not found: $audio"

  key=$(fm_deepgram_api_key)
  [ -n "$key" ] || refuse "DEEPGRAM_API_KEY is not set (env or gitignored .env)"
  model=$(fm_deepgram_stt_model)
  vocab=$FM_HOME/config/stt-vocabulary
  extra=$(vocab_query "$vocab" "$model")

  case "$audio" in
    *.wav|*.WAV) ctype=audio/wav ;;
    *.mp3|*.MP3) ctype=audio/mpeg ;;
    *.m4a|*.M4A) ctype=audio/mp4 ;;
    *.webm|*.WEBM) ctype=audio/webm ;;
    *.ogg|*.OGG) ctype=audio/ogg ;;
    *) ctype=application/octet-stream ;;
  esac

  bytes=$(wc -c < "$audio" | tr -d ' ')
  max_time=$(( 120 + ${bytes:-0} / 100000 ))
  stall_time=$(( 20 + ${bytes:-0} / 1000000 ))

  prepare_request "$key"
  request \
    --request POST \
    --connect-timeout 15 \
    --max-time "$max_time" \
    --speed-limit 1 \
    --speed-time "$stall_time" \
    --retry 2 \
    --retry-delay 3 \
    --retry-connrefused \
    --header "Content-Type: ${ctype}" \
    --data-binary @"$audio" \
    --url "https://api.deepgram.com/v1/listen?model=${model}&smart_format=true&mip_opt_out=true${extra}" \
    || {
      # Deepgram can answer 401 or 402 and then cancel the upload, so curl
      # fails after the status arrived; that is still a rejected key.
      if key_refused; then
        note "Deepgram rejected the key (HTTP $http) and cut the upload short"
        exit 3
      fi
      die "curl failed talking to Deepgram (no answer within ${max_time}s, nothing moving for ${stall_time}s, or the connection failed)"
    }

  if [ "$http" != "200" ]; then
    note "Deepgram listen failed HTTP $http"
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    ! key_refused || exit 3
    exit 1
  fi

  if [ "$output" = json ]; then
    cat "$tmp"
    exit 0
  fi

  if [ "$output" = segments ]; then
    extract_segments "$vocab" "$tmp" || die "could not parse Deepgram transcript JSON"
    exit 0
  fi

  extract_transcript "$vocab" "$tmp" || die "could not parse Deepgram transcript JSON"
  exit 0
}

main "$@"
