#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must keep evidence files and media local because this repository is public.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_keeps_test_evidence_local() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
test = doc["test"].is_a?(Hash) ? doc["test"] : {}
ev = test["evidence"].is_a?(Hash) ? test["evidence"] : {}
puts "#{ev["store_in_repo"].inspect} #{ev.fetch("attach_media", :absent).inspect}"
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  case "${val% *}" in
    nil|false) ;;
    *) fail "test.evidence.store_in_repo must be false or absent so evidence never reaches the public repository; got: ${val% *}" ;;
  esac
  [ "${val#* }" = false ] \
    || fail "test.evidence.attach_media must be explicitly false (its default is true) so media is never uploaded to the public PR; got: ${val#* }"
  pass "no-mistakes keeps evidence files and media on the local machine"
}

test_nm_has_no_deterministic_test_command
test_nm_keeps_test_evidence_local
