#!/usr/bin/env bash
# fm-merge-rules.sh - the one owner of a home's merge rule table: its format,
# which project row a task's merge reads, how a pull request's changed files are
# put into the docs, tests, and dependency classes, and the generic merge-trail
# line a merged pull request receives.
#
# Sourced by bin/fm-pr-merge.sh, which owns when the rule is checked and what a
# refusal does; run directly for its subcommands below. No side effects on
# source.
#
# TABLE (config/merge-rules; optional, private, gitignored, not inherited by
# secondmate homes). Without the file nothing here applies and every merge
# behaves as before. With it, the table is the whole answer to "what may land
# without the owner's yes": one row per project, three fields split by "|":
#
#   # project          | lands by itself   | who must say yes
#   example-app        | docs, tests, deps | the owner
#   example-site       | nothing           | the owner
#   example-sandbox    | anything          | nobody
#
# Blank lines and lines starting with "#" are ignored. The project field is a
# registered project name (data/projects.md), matched against the task's
# project directory basename, then against the registry row that basename
# resolves to (its registered name, then each alias=<name>). "lands by itself"
# is one or more of docs, tests, and deps, separated by commas or spaces, or
# exactly one of anything (every green pull request lands by itself) and
# nothing. "who must say yes" is free text naming who answers for everything
# else; it appears only in local refusal messages, never in a pull request. A
# row with another field count, an empty field, an unknown class, anything or
# nothing beside another class, or a project named twice makes the table
# malformed, and a malformed table refuses every merge until it is fixed.
#
# CLASSES. A pull request lands by itself only when every file it changes,
# including the old name of a renamed file, sits in one single class the row
# lists; a mix of classes, or any file outside them, waits for a yes:
#   tests  a path with a tests, test, __tests__, spec, specs, e2e, or
#          __snapshots__ directory, or a file named *.test.*, *.spec.*,
#          *_test.*, *_spec.*, or test_*.py.
#   deps   a lockfile (package-lock.json, npm-shrinkwrap.json, yarn.lock,
#          pnpm-lock.yaml, bun.lock, bun.lockb, Cargo.lock, go.sum,
#          poetry.lock, uv.lock, composer.lock, Package.resolved) or a
#          package.json. A changed
#          package.json counts only when deps-check below passes between its
#          merge-base and head versions; an added or removed one never counts.
#          Other manifests (go.mod, Cargo.toml, requirements files) are outside
#          every class.
#   docs   a .md, .mdx, .markdown, .rst, or .adoc file other than an agent
#          instruction file (AGENTS.md, CLAUDE.md, GEMINI.md).
# A path with any directory or file name starting with "." (.github/,
# .agents/, .claude/, dotfiles) is outside every class. Tests are matched
# before deps, and deps before docs.
#
# DEPS-CHECK. Between two package.json versions, only the dependencies,
# devDependencies, optionalDependencies, and peerDependencies sections may
# differ, no dependency may be added or removed, and every changed version must
# be a plain version or ^, ~, = range whose major number is unchanged (and,
# for a 0.x version, whose minor number is unchanged too). Anything else is
# reported and the change waits for a yes.
#
# TRAIL. While the table exists, bin/fm-pr-merge.sh leaves one generic line on
# each GitHub pull request it confirms merged, saying who let it land and under
# which rule, with no names: "merged on the owner's yes" when the merge was
# --captain-approved, otherwise "landed by itself under this project's merge
# rule" with the class that let it.
#
# Usage:
#   fm-merge-rules.sh check                 validate the table; prints its row count
#   fm-merge-rules.sh rule <project>        print the row a project path or name reads
#   fm-merge-rules.sh classify              classify GitHub pull request file pages on stdin
#   fm-merge-rules.sh deps-check <old> <new>  compare two package.json files
#   fm-merge-rules.sh trail <class|approved>  print the merge-trail line
#   fm-merge-rules.sh -h | --help
# FM_HOME selects the home whose config/merge-rules is read.

_FM_MERGE_RULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_RULES_ACTIVE=false
# shellcheck disable=SC2034
FM_MERGE_RULES_ERROR=
# shellcheck disable=SC2034
FM_MERGE_RULE_PROJECT=
# shellcheck disable=SC2034
FM_MERGE_RULE_LANDS=
# shellcheck disable=SC2034
FM_MERGE_RULE_YES=

fm_merge_rules_path() {  # <home>
  printf '%s/config/merge-rules\n' "${1:?}"
}

# Parse the table into "<project>\t<classes>\t<who>" rows on stdout, classes
# normalized to single spaces. When the table is malformed it prints only the
# reason and returns 1. Args: table path.
fm_merge_rules_rows() {
  local table=$1 out
  if ! out=$(awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      sub(/\r$/, "")
      line = trim($0)
      if (line == "" || substr(line, 1, 1) == "#") next
      n = split(line, f, "|")
      if (n != 3) { printf "line %d has %d fields; a row is project | lands by itself | who must say yes\n", NR, n; exit 1 }
      p = trim(f[1]); c = trim(f[2]); w = trim(f[3])
      if (p == "" || c == "" || w == "") { printf "line %d has an empty field\n", NR; exit 1 }
      if (p in seen) { printf "line %d names project %s a second time\n", NR, p; exit 1 }
      seen[p] = 1
      gsub(/,/, " ", c)
      m = split(c, k, /[ \t]+/)
      cls = ""; whole = 0; count = 0
      for (i = 1; i <= m; i++) {
        if (k[i] == "") continue
        if (k[i] !~ /^(docs|tests|deps|anything|nothing)$/) { printf "line %d has unknown class %s; use docs, tests, deps, anything, or nothing\n", NR, k[i]; exit 1 }
        if (k[i] == "anything" || k[i] == "nothing") whole = 1
        if (index(" " cls " ", " " k[i] " ") == 0) { cls = cls (cls == "" ? "" : " ") k[i]; count++ }
      }
      if (whole && count > 1) { printf "line %d puts anything or nothing beside another class\n", NR; exit 1 }
      printf "%s\t%s\t%s\n", p, cls, w
    }
  ' "$table" 2>&1); then
    printf '%s\n' "${out##*$'\n'}"
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# Resolve the row a merge reads. Sets FM_MERGE_RULES_ACTIVE (true while the
# table exists), FM_MERGE_RULE_PROJECT (empty when no row matches),
# FM_MERGE_RULE_LANDS, and FM_MERGE_RULE_YES. Returns 1 with
# FM_MERGE_RULES_ERROR for a malformed or unreadable table.
# Args: home, project directory or name (may be empty).
fm_merge_rules_resolve() {
  local home=$1 project=${2-} table rows base line name names row
  FM_MERGE_RULES_ACTIVE=false
  FM_MERGE_RULES_ERROR=
  FM_MERGE_RULE_PROJECT=
  FM_MERGE_RULE_LANDS=
  FM_MERGE_RULE_YES=
  table=$(fm_merge_rules_path "$home")
  [ -e "$table" ] || [ -L "$table" ] || return 0
  FM_MERGE_RULES_ACTIVE=true
  if [ ! -f "$table" ] || [ ! -r "$table" ]; then
    FM_MERGE_RULES_ERROR="config/merge-rules exists but is not a readable file"
    return 1
  fi
  if ! rows=$(fm_merge_rules_rows "$table"); then
    FM_MERGE_RULES_ERROR="config/merge-rules is malformed: $rows"
    return 1
  fi
  [ -n "$project" ] || return 0
  base=${project%/}
  base=${base##*/}
  names=$base
  line=$(FM_HOME="$home" "$_FM_MERGE_RULES_DIR/fm-project-mode.sh" --line "$base" 2>/dev/null || true)
  if [ -n "$line" ]; then
    name=$(printf '%s\n' "$line" | sed -E 's/^- //; s/( \[| - ).*$//')
    names="$names"$'\n'"$name"
    names="$names"$'\n'"$(printf '%s\n' "$line" | sed -nE 's/^[^[]*\[([^]]*)\].*$/\1/p' \
      | tr ' ' '\n' | sed -n 's/^alias=//p')"
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    row=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1 == n { print; exit }')
    if [ -n "$row" ]; then
      IFS=$'\t' read -r FM_MERGE_RULE_PROJECT FM_MERGE_RULE_LANDS FM_MERGE_RULE_YES <<< "$row"
      return 0
    fi
  done <<< "$names"
  return 0
}

# Classify GitHub "pulls/<n>/files" pages read on stdin (as gh api --paginate
# prints them). Prints "class=<docs|tests|deps|mixed|other>", then
# "classes=<every class seen, space-separated>", then "outside=<files outside
# every class, comma-separated>", then
# "manifests=<status>:<path> ..." for each package.json the change touches.
# Returns 1 when the pages cannot be read.
fm_merge_rules_classify() {
  jq -rs '
    def segs: split("/");
    def base: segs | last;
    def dotted: segs | any(startswith("."));
    def testfile: (segs[:-1] | any(. == "tests" or . == "test" or . == "__tests__"
        or . == "spec" or . == "specs" or . == "e2e" or . == "__snapshots__"))
      or (base | test("[._](test|spec)\\.[^.]+$|^test_[^/]*\\.py$"));
    def lockfile: base | IN("package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
      "pnpm-lock.yaml", "bun.lock", "bun.lockb", "Cargo.lock", "go.sum",
      "poetry.lock", "uv.lock", "composer.lock", "Package.resolved");
    def docfile: (base | IN("AGENTS.md", "CLAUDE.md", "GEMINI.md") | not)
      and (base | test("\\.(md|mdx|markdown|rst|adoc)$"; "i"));
    def cls: if dotted then "other" elif testfile then "tests"
      elif lockfile or base == "package.json" then "deps"
      elif docfile then "docs" else "other" end;
    [ .[] | if type == "array" then .[] else error("invalid files page") end
      | if (.filename | type) == "string" then . else error("invalid file entry") end ] as $entries
    | [ $entries[] | .filename, (.previous_filename // empty | strings)
        | { path: ., cls: cls } ] as $files
    | ($files | map(.cls) | unique) as $classes
    | (if ($classes | length) == 1 and $classes[0] != "other" then $classes[0]
       elif ($classes | length) <= 1 then "other"
       else "mixed" end) as $class
    | "class=" + $class,
      "classes=" + ($classes | join(" ")),
      "outside=" + ($files | map(select(.cls == "other") | .path) | unique | join(", ")),
      "manifests=" + ([ $entries[] | select((.filename | split("/") | last) == "package.json"
          or ((.previous_filename // "") | split("/") | last) == "package.json")
          | ((.status // "modified") + ":" + .filename) ] | join(" "))
  ' 2>/dev/null
}

# Compare two package.json files. Prints one line per reason the change is not
# a same-major dependency update and returns 1, or prints nothing and returns 0.
fm_merge_rules_deps_check() {  # <old-file> <new-file>
  local out
  out=$(jq -rn --slurpfile o "$1" --slurpfile n "$2" '
    def sections: ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];
    def ver: if type == "string" and test("^[~^=v]*[0-9]+(\\.[0-9]+)?") and (test("[ |<>*xX]") | not)
      then capture("^[~^=v]*(?<maj>[0-9]+)(\\.(?<min>[0-9]+))?") else null end;
    ($o[0]) as $old | ($n[0]) as $new
    | if ($old | type) != "object" or ($new | type) != "object" then "package.json is not a JSON object"
      else
        (if ($old | del(.[sections[]])) != ($new | del(.[sections[]])) then "fields outside the dependency sections changed" else empty end),
        (sections[] as $s
          | ($old[$s] // {}) as $a | ($new[$s] // {}) as $b
          | if ($a | type) != "object" or ($b | type) != "object" then "\($s) is not an object"
            elif ($a | keys) != ($b | keys) then "\($s) adds or removes a dependency"
            else ($a | keys[]) as $k
              | select($a[$k] != $b[$k])
              | ($a[$k] | ver) as $ov | ($b[$k] | ver) as $nv
              | if $ov == null or $nv == null then "\($k) is not a plain version (\($a[$k]) to \($b[$k]))"
                elif $ov.maj != $nv.maj then "\($k) changes major version (\($a[$k]) to \($b[$k]))"
                elif $ov.maj == "0" and $ov.min != $nv.min then "\($k) changes a 0.x minor version (\($a[$k]) to \($b[$k]))"
                else empty end
            end)
      end
  ' 2>/dev/null) || { echo "package.json could not be read as JSON"; return 1; }
  [ -z "$out" ] || { printf '%s\n' "$out"; return 1; }
}

# The generic merge-trail line. Arg: approved, or the class that let it land.
fm_merge_rules_trail() {
  case "${1-}" in
    approved) echo "Merge trail: merged on the owner's yes." ;;
    docs) echo "Merge trail: landed by itself under this project's merge rule (docs only)." ;;
    tests) echo "Merge trail: landed by itself under this project's merge rule (tests only)." ;;
    deps) echo "Merge trail: landed by itself under this project's merge rule (dependency updates within the same major version)." ;;
    anything) echo "Merge trail: landed by itself under this project's merge rule (any green change)." ;;
    *) return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -eu
  case "${1:-}" in
    -h | --help)
      sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
      ;;
    check)
      home=${FM_HOME:-$(cd "$_FM_MERGE_RULES_DIR/.." && pwd)}
      if ! fm_merge_rules_resolve "$home" ""; then
        echo "error: $FM_MERGE_RULES_ERROR" >&2
        exit 1
      fi
      if [ "$FM_MERGE_RULES_ACTIVE" = false ]; then
        echo "no merge rule table"
      else
        echo "merge rule table: $(fm_merge_rules_rows "$(fm_merge_rules_path "$home")" | grep -c . || true) rows"
      fi
      ;;
    rule)
      [ -n "${2:-}" ] || { echo "usage: fm-merge-rules.sh rule <project>" >&2; exit 2; }
      home=${FM_HOME:-$(cd "$_FM_MERGE_RULES_DIR/.." && pwd)}
      if ! fm_merge_rules_resolve "$home" "$2"; then
        echo "error: $FM_MERGE_RULES_ERROR" >&2
        exit 1
      fi
      printf 'active=%s\nproject=%s\nlands=%s\nyes=%s\n' "$FM_MERGE_RULES_ACTIVE" \
        "$FM_MERGE_RULE_PROJECT" "$FM_MERGE_RULE_LANDS" "$FM_MERGE_RULE_YES"
      ;;
    classify)
      fm_merge_rules_classify || { echo "error: the changed files could not be read" >&2; exit 1; }
      ;;
    deps-check)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: fm-merge-rules.sh deps-check <old> <new>" >&2; exit 2; }
      fm_merge_rules_deps_check "$2" "$3"
      ;;
    trail)
      fm_merge_rules_trail "${2:-}" || { echo "usage: fm-merge-rules.sh trail <approved|docs|tests|deps|anything>" >&2; exit 2; }
      ;;
    *)
      echo "usage: fm-merge-rules.sh check|rule|classify|deps-check|trail (see --help)" >&2
      exit 2
      ;;
  esac
fi
