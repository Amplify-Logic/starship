#!/usr/bin/env bash
# Behavior checks for the ported Pi Calm extension.
#
# Three node harnesses, all run against the INSTALLED Pi package rather than a
# stub, so a Pi upgrade that drops an API Calm depends on fails here:
#   - a minimal extension host drives the real factory, its /calm command, its
#     built-in claim, and its working presentation without a terminal;
#   - the visibility and working-boat modules are exercised directly;
#   - the operational-input classifier the operational-user row depends on is
#     round-tripped through bin/fm-operational-input.sh.
# docs/calm.md owns the captain-facing behavior and the live-session record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Pi calm extension tests"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for the Pi calm extension tests"; exit 0; }
node_strips_types() {
  local probe_dir
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-calm-ts-probe.XXXXXX") || return 1
  printf 'export const ok: number = 1;\n' >"$probe_dir/probe.ts"
  ( cd "$probe_dir" && node --input-type=module -e \
      'import("./probe.ts").then((m) => process.exit(m.ok === 1 ? 0 : 1), () => process.exit(1));' \
      >/dev/null 2>&1 )
  local status=$?
  rm -rf "$probe_dir"
  return "$status"
}
node_strips_types || {
  echo "skip: node $(node --version) cannot import .ts modules natively; the Pi calm extension tests need type stripping"
  exit 0
}
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || {
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
}
[ -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] || {
  echo "not ok - installed Pi package is missing its TUI declarations" >&2
  exit 1
}

TMP_ROOT=$(fm_test_tmproot fm-calm-extension)
FIXTURE="$TMP_ROOT/home"
mkdir -p "$FIXTURE/.pi/extensions/lib" "$FIXTURE/bin" "$FIXTURE/node_modules/@earendil-works"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$FIXTURE/.pi/extensions/"
cp "$ROOT"/.pi/extensions/lib/*.ts "$FIXTURE/.pi/extensions/lib/"
cp "$ROOT/bin/fm-operational-input.sh" "$FIXTURE/bin/"
ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
printf '{"type":"module"}\n' >"$FIXTURE/package.json"

run_node() {  # <script> [env assignments...]
  local script=$1
  shift
  ( cd "$FIXTURE" && env FM_HOME="$FIXTURE" "$@" node "$script" 2>&1 )
}

cat >"$FIXTURE/host.mjs" <<'JS'
// Minimal Pi extension host: enough ExtensionAPI and ExtensionUIContext surface
// for the Calm extension, so its toggle, persistence, built-in claim, collision
// report, and working presentation are exercised without a terminal.
import assert from "node:assert/strict";
import { readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";

const extensionPath = realpathSync(resolve("./.pi/extensions/fm-calm.ts"));
const foreign = (process.env.FM_CALM_HOST_FOREIGN || "").split(",").filter(Boolean);
const startedOn = process.env.FM_CALM_HOST_EXPECT_ON === "1";
const expectedClaim = 7 - foreign.length;

const calls = { widgets: [], workingVisible: [], thinkingLabel: [], notices: [] };
const registeredTools = [];
const handlers = new Map();
const commands = new Map();
let terminalInput;
let editorText = "";
let toolsExpanded = false;

const pi = {
  events: { emit() {} },
  registerEntryRenderer() {},
  registerTool(tool) { registeredTools.push(tool); },
  getAllTools() {
    return [
      ...foreign.map((name) => ({
        name,
        sourceInfo: { source: "extension", path: "/tmp/other-extension.ts" },
      })),
      ...registeredTools.map((tool) => ({
        name: tool.name,
        sourceInfo: { source: "extension", path: extensionPath },
      })),
    ];
  },
  on(event, handler) { handlers.set(event, handler); },
  registerCommand(name, options) { commands.set(name, options); },
};

const ui = {
  setWidget(key, factory) { calls.widgets.push([key, factory === undefined ? "cleared" : "installed"]); },
  setWorkingVisible(visible) { calls.workingVisible.push(visible); },
  setHiddenThinkingLabel(label) { calls.thinkingLabel.push(label); },
  setStatus() {},
  notify(message) { calls.notices.push(message); },
  onTerminalInput(handler) { terminalInput = handler; return () => { terminalInput = undefined; }; },
  getEditorText() { return editorText; },
  getToolsExpanded() { return toolsExpanded; },
  setToolsExpanded(value) { toolsExpanded = value; },
};

const preferencePath = `${process.env.FM_HOME}/config/calm`;
const readPreference = () => {
  try { return readFileSync(preferencePath, "utf8").trim(); } catch { return "<absent>"; }
};

const extension = (await import("./.pi/extensions/fm-calm.ts")).default;
extension(pi);

// A Calm-off home registers nothing at load; a Calm-on home claims every
// built-in synchronously, before any restored row can capture the registry.
assert.equal(
  registeredTools.length, startedOn ? 7 : 0,
  `load-time built-in registration: expected ${startedOn ? 7 : 0}, got ${registeredTools.length}`,
);
assert.ok(commands.has("calm"), "extension did not register the /calm command");

handlers.get("session_start")({}, { ui });
// No run is active at session_start, so the stock row is visible whatever the
// stored preference is: Calm only replaces it for the duration of a run.
assert.equal(calls.workingVisible.at(-1), true, "session_start hid the stock working row with no run active");

// One agent run under the preference as loaded.
handlers.get("agent_start")({}, { ui });
assert.equal(
  calls.widgets.at(-1)?.[1] === "installed", startedOn,
  "the working boat did not follow the loaded Calm preference",
);
handlers.get("agent_settled")({}, { ui });
assert.equal(calls.workingVisible.at(-1), true, "the stock working row was not restored after the run");

// Toggling writes the new preference and, from a Calm-off start, claims every
// uncontested built-in.
await commands.get("calm").handler([], { ui });
assert.equal(readPreference(), startedOn ? "off" : "on", `toggle did not persist: ${readPreference()}`);
if (!startedOn) {
  assert.equal(
    registeredTools.length, expectedClaim,
    `first activation claimed ${registeredTools.length} built-ins, expected ${expectedClaim}`,
  );
  const claimed = registeredTools.map((tool) => tool.name).sort();
  assert.deepEqual(
    claimed,
    ["bash", "edit", "find", "grep", "ls", "read", "write"].filter((name) => !foreign.includes(name)),
    `Calm claimed the wrong built-in tool set: ${claimed.join(",")}`,
  );
  assert.ok(
    registeredTools.every((tool) => tool.renderShell === "self"),
    "Calm's wrapped built-ins lost renderShell: self",
  );
  for (const name of foreign) {
    assert.ok(
      calls.notices.some((notice) => notice.includes(`"${name}"`)),
      `no notice named the contested built-in ${name}`,
    );
  }
  if (foreign.length === 0) {
    assert.equal(calls.notices.length, 0, `an uncontested activation still warned: ${calls.notices.join(" | ")}`);
  }
}
assert.equal(
  calls.thinkingLabel.at(-1), startedOn ? undefined : "",
  "the collapsed-thinking label did not follow the toggle",
);

handlers.get("agent_start")({}, { ui });
assert.equal(
  calls.widgets.at(-1)?.[1] === "installed", !startedOn,
  "the working boat did not follow the toggled Calm preference",
);
handlers.get("agent_settled")({}, { ui });
assert.equal(calls.widgets.at(-1)?.[1], "cleared", "the working boat widget outlived the run");

// Toggling back round-trips the stored preference.
await commands.get("calm").handler([], { ui });
assert.equal(readPreference(), startedOn ? "on" : "off", "toggling back did not restore the preference");

// An export forces one stock-rendered window and never changes what is stored.
editorText = "/export";
terminalInput("\r");
await new Promise((resolve) => setTimeout(resolve, 10));
assert.equal(readPreference(), startedOn ? "on" : "off", "an export changed the stored preference");

console.log("host-ok");
JS

cat >"$FIXTURE/modules.mjs" <<'JS'
// Pure-module checks for Calm's visibility rules and working-boat animation.
import assert from "node:assert/strict";
import {
  calmPresentationHides,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./.pi/extensions/lib/fm-calm-visibility.ts";
import {
  CALM_WORKING_SHIP_TICKS_PER_MOVE,
  createCalmWorkingShipAnimation,
} from "./.pi/extensions/lib/fm-calm-working-ship.ts";

const HIDDEN = [
  "assistant-tool-call",
  "tool-result",
  "assistant-thinking",
  "assistant-working-note",
  "synthetic-user",
  "system-notice",
];
const KEPT = ["genuine-user-prompt", "genuine-agent-response", "working-status"];

// Calm off hides nothing at all.
setCalmPresentation(false);
setCalmStockExportRendering(false);
for (const itemClass of [...HIDDEN, ...KEPT]) {
  assert.equal(calmPresentationHides(itemClass), false, `Calm off hid ${itemClass}`);
}

// Calm on hides tool noise and keeps the conversation.
setCalmPresentation(true);
for (const itemClass of HIDDEN) {
  assert.equal(calmPresentationHides(itemClass), true, `Calm on did not hide ${itemClass}`);
}
for (const itemClass of KEPT) {
  assert.equal(calmPresentationHides(itemClass), false, `Calm on hid the conversation row ${itemClass}`);
}

// An export renders stock even while Calm stays on.
setCalmStockExportRendering(true);
for (const itemClass of [...HIDDEN, ...KEPT]) {
  assert.equal(calmPresentationHides(itemClass), false, `export rendering still hid ${itemClass}`);
}
setCalmStockExportRendering(false);
setCalmPresentation(false);

const visible = (line) => line.replace(/\u001b\[\d+m/g, "");
// The sprite the shared module draws today; the creator's own Pi Calm suite owns
// the exhaustive geometry, so this fork suite only proves the module still loads
// and animates the same boat the fork's /calm toggle installs.
const SAIL = "\u25FF\u2502\u25E3";
const HULL = "\u2572\u2581\u2581\u2581\u2571";
const animation = createCalmWorkingShipAnimation();

// A normal width draws the sail over the hull, both riding a full-width row.
let frame = animation.render(40);
assert.equal(frame.length, 2, "a normal width did not draw a sail row and a water row");
assert.ok(visible(frame[1]).startsWith(HULL), `hull is not at the left edge: ${visible(frame[1])}`);
assert.ok(visible(frame[0]).includes(SAIL), `sail is missing over the hull: ${visible(frame[0])}`);
// The water row fills the width exactly; the sail row rides above it and never
// runs past the end of the track.
assert.equal(visible(frame[1]).length, 40, `the water row did not fill the width: ${visible(frame[1]).length}`);
assert.ok(visible(frame[0]).length <= 40, `the sail row overflowed the width: ${visible(frame[0]).length}`);

// Water ripples on every tick; the boat moves only on its slower cadence.
const phase = animation.waterPhase();
animation.tick();
assert.notEqual(animation.waterPhase(), phase, "the water did not ripple on a tick");
assert.equal(animation.position(), 0, "the boat moved on the very first tick");
for (let i = 1; i < CALM_WORKING_SHIP_TICKS_PER_MOVE; i += 1) animation.tick();
assert.equal(animation.position(), 1, "the boat did not advance one column on its cadence");

// The boat bounces at the right edge. The sprite is a fixed asymmetric sail, so
// the heading is carried by direction() and the wave, not by a mirrored glyph.
for (let i = 0; i < CALM_WORKING_SHIP_TICKS_PER_MOVE * 60; i += 1) animation.tick();
frame = animation.render(40);
assert.equal(animation.direction(), -1, "the boat did not turn at the right edge");
assert.ok(visible(frame[0]).includes(SAIL), `the boat lost its fixed sail after turning: ${visible(frame[0])}`);
assert.ok(animation.position() <= 40 - 4, "the boat sailed past the end of its track");

// Hiding the boat freezes it; the next working period resumes from there.
const frozen = animation.position();
animation.restoreLastRendered();
assert.equal(animation.position(), frozen, "hiding the boat moved it");
animation.render(40);
assert.equal(animation.position(), frozen, "the resumed boat did not continue from where it stopped");

// A fresh session starts at the normal initial position.
animation.reset();
assert.equal(animation.position(), 0, "reset did not return the boat to its initial column");
assert.equal(animation.direction(), 1, "reset did not restore the initial heading");
assert.equal(animation.waterPhase(), 0, "reset did not restore the initial water phase");

// Narrow terminals degrade deterministically instead of overflowing.
assert.equal(animation.render(0).length, 0, "a zero width still drew a row");
frame = animation.render(1);
assert.equal(frame.length, 1, "a one-column width drew more than a water row");
assert.equal(visible(frame[0]).length, 1, "a one-column frame did not fit");
frame = animation.render(3);
assert.equal(frame.length, 1, "a sail-only width drew a second row");
assert.equal(visible(frame[0]).length, 3, "a sail-only frame did not fit");

console.log("modules-ok");
JS

cat >"$FIXTURE/operational.mjs" <<'JS'
// The operational-user row asks bin/fm-operational-input.sh to classify a row
// before hiding it, so that bridge must return the bare kind.
import assert from "node:assert/strict";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "./.pi/extensions/lib/fm-operational-input.ts";

for (const kind of ["session-start", "watcher", "turn-end-guard", "away-supervisor", "launch-brief"]) {
  const encoded = encodeFirstmateOperationalInput(kind, "drain the queue");
  const classified = classifyFirstmateCurrentOperationalText(encoded);
  assert.equal(classified, kind, `${kind} did not classify back to itself: ${String(classified)}`);
}
assert.equal(
  classifyFirstmateCurrentOperationalText("an ordinary captain message"),
  undefined,
  "an ordinary message was classified as operational input",
);

console.log("operational-ok");
JS

test_calm_modules() {
  local out
  out=$(run_node modules.mjs) || fail "calm modules: $out"
  assert_contains "$out" "modules-ok" "calm module checks did not complete"
  pass "fm-calm: Calm hides tool noise, keeps the conversation, and sails a bounded boat"
}

test_calm_off_home() {
  local out
  rm -f "$FIXTURE/config/calm"
  out=$(run_node host.mjs) || fail "calm-off host: $out"
  assert_contains "$out" "host-ok" "the Calm-off host run did not complete"
  pass "fm-calm: a Calm-off home claims no built-in until the captain turns Calm on"
}

test_calm_on_home() {
  local out
  mkdir -p "$FIXTURE/config"
  printf 'on\n' >"$FIXTURE/config/calm"
  out=$(run_node host.mjs FM_CALM_HOST_EXPECT_ON=1) || fail "calm-on host: $out"
  assert_contains "$out" "host-ok" "the Calm-on host run did not complete"
  pass "fm-calm: a Calm-on home restores its preference and claims every built-in at load"
}

test_calm_legacy_max_preference() {
  local out
  mkdir -p "$FIXTURE/config"
  printf 'max\n' >"$FIXTURE/config/calm"
  out=$(run_node host.mjs FM_CALM_HOST_EXPECT_ON=1) || fail "legacy max preference: $out"
  assert_contains "$out" "host-ok" "a home upgraded from the removed max level did not restore as on"
  pass "fm-calm: a home upgraded from the removed max level restores as on, not off"
}

test_calm_contested_built_ins() {
  local out
  rm -f "$FIXTURE/config/calm"
  out=$(run_node host.mjs FM_CALM_HOST_FOREIGN=bash,grep) || fail "contested built-ins: $out"
  assert_contains "$out" "host-ok" "the contested built-in run did not complete"
  assert_contains "$out" 'skipped claiming built-in "bash"' "a contested built-in was claimed anyway"
  pass "fm-calm: a built-in another extension owns is left alone and reported"
}

test_calm_operational_classifier() {
  local out
  out=$(run_node operational.mjs) || fail "operational classifier: $out"
  assert_contains "$out" "operational-ok" "the operational classifier checks did not complete"
  pass "fm-calm: operational rows classify back to their bare kind"
}

test_calm_modules
test_calm_off_home
test_calm_on_home
test_calm_legacy_max_preference
test_calm_contested_built_ins
test_calm_operational_classifier
echo "All calm extension tests passed."
