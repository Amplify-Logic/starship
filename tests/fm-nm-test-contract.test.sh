#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# must keep evidence files and media local because this repository is public,
# and its test instructions must name only paths that exist.
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

# The test instructions name concrete repository paths for the changed-suite
# listing and its full-run fallback; a renamed or retired file would leave the
# Test agent following a rule about a path that no longer exists.
test_nm_test_instruction_paths_exist() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local paths path missing=
  # shellcheck disable=SC2016
  paths=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
test = doc["test"].is_a?(Hash) ? doc["test"] : {}
text = test["instructions"].to_s
text.scan(/`([^`]+)`/).flatten.each do |tok|
  next unless tok.match?(%r{\A(bin|tests)/[A-Za-z0-9._/-]+\z})
  puts tok
end
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ -n "$paths" ] || fail "test.instructions names no bin/ or tests/ path to check"
  while IFS= read -r path; do
    [ -e "$ROOT/$path" ] || missing="$missing $path"
  done <<<"$paths"
  [ -z "$missing" ] || fail "test.instructions names paths that do not exist:$missing"
  pass "every concrete path the test instructions name exists"
}

test_nm_has_no_deterministic_test_command
test_nm_keeps_test_evidence_local
test_nm_test_instruction_paths_exist
