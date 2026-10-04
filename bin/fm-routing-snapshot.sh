#!/usr/bin/env bash
# fm-routing-snapshot.sh - one read-only JSON snapshot of dispatch routing: the
# model roster, the most recent dispatch decisions, and each task record's
# kind and model.
#
# Usage:
#   fm-routing-snapshot.sh [--json]
#
# It reads three local inputs and nothing else, so it makes no network call,
# takes no lock, and writes nothing:
#   config/crew-dispatch.json        roster: every rule's short label and use
#                                    profiles, then the default profiles
#                                    (docs/configuration.md "Crew dispatch profiles")
#   state/dispatch-decisions.jsonl   recent decisions, as bin/fm-dispatch-resolve.sh
#                                    records them (its header owns the line format)
#   state/<id>.meta                  per task: kind, model, effort, and the
#                                    spawn time from spawn_gen
#                                    (bin/fm-spawn.sh owns those fields)
# A meta's outcome= line and every brief stay unread, so no task description
# reaches the snapshot. Current state is not read here: a consumer joins each
# worker by id to the canonical reader it already uses (the bridge page joins
# the in_flight rows of its bearings read; docs/bridge-view.md "Routing").
#
# Output, schema fm-routing.v1:
#   {"schema":"fm-routing.v1","generated":<epoch>,
#    "roster":[{"rule":"rule_<n>|default","label":"..","profiles":[{"harness":..,"model":..|null,"effort":..|null}]}],
#    "roster_error":null|"<why the rules file could not be read>",
#    "decisions":[{"at":<epoch>,"task":"..","status":"..","rule":"..","label":"..","p":<0..1>|null,"profile":{..}|null}],
#    "workers":[{"id":"..","kind":"..","model":"..","effort":"..","started":<epoch>|null}]}
# A rule's label is its `when` cut at the first ": ", ". ", or " (" within 64
# characters, else its first 64 characters at a word boundary with an ellipsis.
# decisions holds the newest 5 well-formed lines, newest first; a malformed line
# is skipped. An absent rules file is an empty
# roster with no error.
#
# Environment:
#   FM_HOME                 the home to read (default: the code root)
#   FM_CONFIG_OVERRIDE      config directory, as in the other scripts
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="$FM_HOME/state"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 2; }

# shellcheck disable=SC2016 # a jq program: its $names are jq variables
LABEL_JQ='
  def short_label:
    (gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")) as $w
    | ([($w | index(": ")), ($w | index(". ")), ($w | index(" ("))]
       | map(select(. != null and . > 0)) | min) as $cut
    | if $cut != null and $cut <= 64 then $w[0:$cut]
      elif ($w | length) <= 64 then ($w | sub("[.]$"; ""))
      else ($w[0:65] | sub(" [^ ]*$"; "") | sub("[,;: ]+$"; "")) + "…"
      end;
  def profiles($v):
    (if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end)
    | map(select(type == "object")
          | {harness: (.harness // null), model: (.model // null), effort: (.effort // null)});
'

# ---- roster ---------------------------------------------------------------------
RULES_PATH="$CONFIG/crew-dispatch.json"
ROSTER='[]'
ROSTER_ERROR=null
if [ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ]; then
  if ROSTER=$(jq -c "$LABEL_JQ"'
      if type != "object" then error("not an object") else . end
      | ([(.rules // [])
          | to_entries[]
          | select(.value | type == "object")
          | {rule: ("rule_" + ((.key + 1) | tostring)),
             label: ((.value.when // "") | tostring | short_label),
             profiles: profiles(.value.use)}]
         + (if has("default") then [{rule: "default", label: "default", profiles: profiles(.default)}] else [] end))
    ' "$RULES_PATH" 2>/dev/null); then
    :
  else
    ROSTER='[]'
    ROSTER_ERROR='"rules file is unreadable or malformed"'
  fi
fi

# ---- recent decisions -------------------------------------------------------------
DECISIONS='[]'
LOG="$STATE/dispatch-decisions.jsonl"
if [ -f "$LOG" ] && [ -r "$LOG" ]; then
  DECISIONS=$(tail -n 200 "$LOG" 2>/dev/null | jq -R -s -c "$LABEL_JQ"'
    def num01: if type == "number" and . >= 0 and . <= 1 then . else null end;
    def text: if type == "string" then gsub("[[:cntrl:]]"; " ") else null end;
    [split("\n")[]
     | select(length > 0)
     | (try fromjson catch null)
     | select(type == "object" and (.at | type) == "number" and (.task | type) == "string")
     | {at, task: (.task | text),
        status: ((.status // "") | text),
        rule: ((.rule // "") | text),
        label: (if .rule == "default" then "default"
                else ((.rule_when // "") | text // "" | short_label) as $l
                  | if ($l | endswith("…")) or ($l | length) < 60 then $l
                    else ($l | sub(" [^ ]*$"; "") | sub("[,;: ]+$"; "")) + "…" end
                end),
        p: (.p | num01),
        profile: (if (.profile | type) == "object"
                  then (.profile | {harness: (.harness | text), model: (.model | text), effort: (.effort | text)})
                  else null end)}]
    | reverse | .[0:5]
  ' 2>/dev/null) || DECISIONS='[]'
fi

# ---- workers from task records ------------------------------------------------------
WORKERS=$(
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    awk -F= -v id="$id" '
      BEGIN { want["kind"]; want["model"]; want["model_live"]; want["effort"]; want["spawn_gen"] }
      ($1 in want) && !($1 in seen) { seen[$1] = 1; v[$1] = substr($0, index($0, "=") + 1) }
      END {
        printf "%s", id
        n = split("kind model model_live effort spawn_gen", k, " ")
        for (i = 1; i <= n; i++) printf "\t%s", v[k[i]]
        printf "\n"
      }
    ' "$meta" 2>/dev/null
  done | jq -R -s -c '
    [split("\n")[]
     | select(length > 0)
     | split("\t")
     | {id: .[0], kind: .[1],
        model: (if (.[3] // "") != "" then .[3] else .[2] end),
        effort: .[4],
        started: (((.[5] // "") | capture("^s(?<t>[0-9]+)\\.") | .t | tonumber)? // null)}
     | with_entries(if (.value | type) == "string" and .value == "" then .value = null else . end)]
  '
) || WORKERS='[]'
[ -n "$WORKERS" ] || WORKERS='[]'

jq -n -c \
  --argjson generated "$(date +%s)" \
  --argjson roster "$ROSTER" \
  --argjson roster_error "$ROSTER_ERROR" \
  --argjson decisions "$DECISIONS" \
  --argjson workers "$WORKERS" \
  '{schema: "fm-routing.v1", generated: $generated, roster: $roster,
    roster_error: $roster_error, decisions: $decisions, workers: $workers}'
