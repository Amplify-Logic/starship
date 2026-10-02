#!/usr/bin/env bash
# Transcribe one audio file with Deepgram (push-to-talk desk floater path).
#
# Usage:
#   fm-deepgram-stt.sh [--json] <audio-file>
#   fm-deepgram-stt.sh --help
#
# Reads DEEPGRAM_API_KEY from the environment or the home's gitignored .env.
# Never logs the key. Default model: nova-3 (override with DEEPGRAM_STT_MODEL).
#
# Prints the transcript text on stdout (or the raw JSON with --json).
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
#     transcription: case-insensitive, whole words only, longest heard phrase
#     first, each span rewritten at most once. Words in `heard` match across
#     any run of whitespace. --json output stays Deepgram's raw response.
#   - A line with `=>` but an empty side is ignored. A vocabulary that cannot
#     be read or parsed is skipped with a note on stderr; it never fails the
#     transcription.
#
# Exit:
#   0  transcript printed (may be empty if Deepgram heard silence)
#   1  request failure
#   2  missing key, missing file, or bad usage
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
# nothing); `transcript <json-file>` prints the rewritten transcript.
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
    pattern = re.compile(
        r"(?<!\w)(?:"
        + "|".join(r"\s+".join(re.escape(w) for w in h.split()) for h in ordered)
        + r")(?!\w)",
        re.IGNORECASE,
    )
    return pattern.sub(
        lambda m: table.get(" ".join(m.group(0).split()).lower(), m.group(0)), text
    )

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
    text = data["results"]["channels"][0]["alternatives"][0].get("transcript", "")
except (KeyError, IndexError, TypeError) as exc:
    note(f"unexpected JSON shape: {exc}")
    raise SystemExit(1)
try:
    _, rewrites = load_vocab(vocab)
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

main() {
  local json_out=false audio='' key model http tmp ctype auth_cfg vocab extra
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --json) json_out=true; shift ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || refuse "usage: fm-deepgram-stt.sh [--json] <audio-file>"
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

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deepgram-stt.XXXXXX") || die "cannot create a temporary file"
  auth_cfg=$(fm_deepgram_auth_config "$key") || {
    rm -f "$tmp"
    die "cannot create the auth config file"
  }
  trap 'rm -f "$auth_cfg"' EXIT
  http=$("$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" \
    --request POST \
    --config "$auth_cfg" \
    --header "Content-Type: ${ctype}" \
    --data-binary @"$audio" \
    --url "https://api.deepgram.com/v1/listen?model=${model}&smart_format=true${extra}") || {
    rm -f "$tmp"
    die "curl failed talking to Deepgram"
  }
  rm -f "$auth_cfg"

  if [ "$http" != "200" ]; then
    note "Deepgram listen failed HTTP $http"
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    rm -f "$tmp"
    exit 1
  fi

  if [ "$json_out" = true ]; then
    cat "$tmp"
    rm -f "$tmp"
    exit 0
  fi

  if ! extract_transcript "$vocab" "$tmp"; then
    rm -f "$tmp"
    die "could not parse Deepgram transcript JSON"
  fi
  rm -f "$tmp"
  exit 0
}

main "$@"
