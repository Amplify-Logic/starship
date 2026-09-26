#!/usr/bin/env bash
# Shared Deepgram helpers for desk speak-out and the desk floater.
#
# Source this file; do not execute it.
# Contract:
#   fm_deepgram_api_key
#     Print the API key to stdout when available. Prefer the process environment
#     (DEEPGRAM_API_KEY). Otherwise read only that key from the home's gitignored
#     .env. Never prints the key to stderr. Exit 0 with empty stdout when absent.
#   fm_deepgram_load_dotenv_key
#     Internal: read one key from a .env-style file without sourcing it.
#   fm_deepgram_tts_model / fm_deepgram_stt_model
#     Resolve model names from the environment, then (text-to-speech only) the
#     home's gitignored .env, then the documented defaults.
#   fm_deepgram_auth_config <key>
#     Write a 0600 curl config file carrying the Authorization header and print
#     its path, so the key never appears in curl's argv. Caller removes it.
#
# The key is a secret. Callers must never log it, put it in argv of long-lived
# processes that other users can read, or write it to state/.
set -u

FM_DEEPGRAM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_DEEPGRAM_DEFAULT_ROOT="$(cd "$FM_DEEPGRAM_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_DEEPGRAM_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

FM_DEEPGRAM_DEFAULT_TTS_MODEL="${FM_DEEPGRAM_DEFAULT_TTS_MODEL:-aura-2-thalia-en}"
FM_DEEPGRAM_DEFAULT_STT_MODEL="${FM_DEEPGRAM_DEFAULT_STT_MODEL:-nova-2}"

# Read one KEY=VALUE from a .env-style file without sourcing. Last assignment
# wins. Tolerates optional export, surrounding whitespace, and one matching
# quote layer. Prints nothing when the file or key is absent.
fm_deepgram_load_dotenv_key() {  # <key> <file>
  local key=$1 file=$2
  [ -f "$file" ] || return 0
  [ ! -L "$file" ] || return 0
  python3 - "$key" "$file" <<'PY'
import re, sys
key, path = sys.argv[1], sys.argv[2]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    raise SystemExit(0)
pat = re.compile(
    r"(?m)^(?:export\s+)?" + re.escape(key) + r"\s*=\s*(.*)$"
)
val = ""
for m in pat.finditer(text):
    raw = m.group(1).strip()
    if raw[:1] in "'\"" and raw[-1:] == raw[:1] and len(raw) >= 2:
        raw = raw[1:-1]
    # Strip an inline comment only when unquoted and preceded by space.
    if " #" in raw:
        raw = raw.split(" #", 1)[0].rstrip()
    val = raw.strip()
if val:
    sys.stdout.write(val)
PY
}

fm_deepgram_api_key() {
  local key env_file
  if [ -n "${DEEPGRAM_API_KEY:-}" ]; then
    printf '%s' "$DEEPGRAM_API_KEY"
    return 0
  fi
  env_file="${FM_DEEPGRAM_ENV_FILE:-$FM_HOME/.env}"
  key=$(fm_deepgram_load_dotenv_key DEEPGRAM_API_KEY "$env_file") || key=
  printf '%s' "$key"
}

fm_deepgram_tts_model() {
  local model env_file
  if [ -n "${DEEPGRAM_TTS_MODEL:-}" ]; then
    printf '%s' "$DEEPGRAM_TTS_MODEL"
    return 0
  fi
  env_file="${FM_DEEPGRAM_ENV_FILE:-$FM_HOME/.env}"
  model=$(fm_deepgram_load_dotenv_key DEEPGRAM_TTS_MODEL "$env_file") || model=
  printf '%s' "${model:-$FM_DEEPGRAM_DEFAULT_TTS_MODEL}"
}

fm_deepgram_stt_model() {
  printf '%s' "${DEEPGRAM_STT_MODEL:-$FM_DEEPGRAM_DEFAULT_STT_MODEL}"
}

fm_deepgram_auth_config() {  # <key>
  local key=$1 path
  path=$(umask 077 && mktemp "${TMPDIR:-/tmp}/fm-deepgram-auth.XXXXXX") || return 1
  chmod 600 "$path" 2>/dev/null || true
  printf 'header = "Authorization: Token %s"\n' "$key" > "$path" || {
    rm -f "$path"
    return 1
  }
  printf '%s' "$path"
}
