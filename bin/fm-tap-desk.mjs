#!/usr/bin/env node
// Data, routing, and default engine for fm-tap-desk.sh.
// The shell wrapper owns the operator-facing commands and the per-task control
// lock around every body write; this engine never writes a task body itself
// except through `body-write`, which only the wrapper's locked `body` command runs.

import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { optionsFrom, parseShow, recommendationFrom, taskIdsFromList } from "./fm-decision-surface.mjs";

const CARDS_SCHEMA = "fm-tap-cards.v1";
const PAGE_PLACEHOLDER = "__FM_TAP_CARDS__";
const SLUG = /^[A-Za-z0-9._-]+$/;
const HEAD = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const DECISION_CHOICES = ["option", "keep", "drop", "you-decide"];
const MERGE_CHOICES = ["merge", "not-yet"];
const REASON_MAX = 500;
const OPTION_MAX = 300;
const DAY_MS = 24 * 60 * 60 * 1000;
const MARK_LABELS = {
  marks: "Tap marks for: ",
  option: "Tap option: ",
  recommended: "Tap recommended: ",
  easy: "Tap easy to undo: ",
};

// The safety net under the explicit easy-to-undo field: a decision whose words
// touch any class the default must never decide is refused even when marked.
// It only ever refuses; it never marks anything easy to undo.
const NEVER_DEFAULT = [
  ["destructive", /\b(?:delet\w*|destroy\w*|destructive|wipe\w*|purg\w*|discard\w*|remov\w*|drop\s+(?:the\s+)?(?:database|table|data|branch)|reset\s+--hard|force[- ]?push\w*|teardown|tear\s+down)\b/i],
  ["irreversible", /\b(?:irreversib\w*|irrevocab\w*|permanent\w*|cannot\s+be\s+undone|can't\s+be\s+undone|one[- ]way)\b/i],
  ["security-sensitive", /\b(?:secur\w*|secret\w*|credential\w*|password\w*|passkey\w*|token\w*|api\s*keys?|ssh|private\s+keys?|permission\w*|access\s+control|auth\w*|login\w*|2fa|mfa)\b/i],
  ["money", /(?:[$€£¥]\s?\d|\b(?:money|pay\w*|invoice\w*|billing|bills?|subscri\w*|pric\w*|purchas\w*|buy\w*|refund\w*|spend\w*|budget\w*|costs?|costly|fees?|charg\w*|tax\w*|salar\w*|wages?|bank\w*|finance\w*|financial|usd|eur|gbp)\b)/i],
  ["outward-to-people", /\b(?:send\w*|sent|emails?|e-mails?|mail\w*|messag\w*|texts?\s+(?:to|him|her|them)|post\w*|publish\w*|tweet\w*|repl(?:y|ies|ied)|invit\w*|outreach|announc\w*|contact\w*|call\s+(?:him|her|them)|share\s+with|customers?|clients?|colleagues?|public\w*)\b/i],
  ["merge", /\b(?:merg\w*|land\s+the\s+pr|pull\s+requests?|prs?)\b/i],
];

function fail(message, code = 1) {
  console.error(`fm-tap-desk: ${message}`);
  process.exit(code);
}

function parseArgs(argv) {
  const command = argv.shift() || "";
  const values = { command, flags: new Set(), options: [] };
  const booleans = new Set(["--apply", "--easy-undo", "--clear"]);
  while (argv.length > 0) {
    const name = argv.shift();
    if (booleans.has(name)) {
      values.flags.add(name.slice(2));
      continue;
    }
    if (!name?.startsWith("--")) fail(`unexpected argument: ${name}`, 2);
    if (argv.length === 0) fail(`${name} requires a value`, 2);
    const value = argv.shift();
    if (name === "--option") values.options.push(value);
    else values[name.slice(2).replaceAll("-", "_")] = value;
  }
  return values;
}

function context(args) {
  for (const key of ["home", "root", "data", "state"]) {
    if (!args[key]) fail(`${args.command} requires --${key}`, 2);
  }
  const deskDir = path.join(args.data, "tap-desk");
  return {
    home: args.home,
    root: args.root,
    data: args.data,
    state: args.state,
    deskDir,
    ledger: path.join(deskDir, "ledger.jsonl"),
    env: {
      ...process.env,
      FM_HOME: args.home,
      FM_ROOT_OVERRIDE: args.root,
      FM_DATA_OVERRIDE: args.data,
      FM_STATE_OVERRIDE: args.state,
    },
  };
}

function runSync(ctx, command, args, input) {
  const result = spawnSync(command, args, { env: ctx.env, encoding: "utf8", input, maxBuffer: 32 * 1024 * 1024 });
  if (result.error) return { status: 127, stdout: "", stderr: result.error.message };
  return { status: result.status ?? 1, stdout: result.stdout || "", stderr: result.stderr || "" };
}

function runAsync(ctx, command, args) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { env: ctx.env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => resolve({ status: 127, stdout, stderr: error.message }));
    child.on("close", (status) => resolve({ status: status ?? 1, stdout, stderr }));
  });
}

async function pool(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  async function lane() {
    while (next < items.length) {
      const index = next++;
      results[index] = await worker(items[index]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, lane));
  return results;
}

function tasksAxi(ctx) {
  return path.join(ctx.root, "bin/fm-tasks-axi.sh");
}

function captainHold(ctx) {
  return path.join(ctx.root, "bin/fm-captain-hold.sh");
}

function lastLine(text) {
  return text.trim().split("\n").filter(Boolean).at(-1) || "";
}

function oneLine(value, max) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function digestOf(value) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

function writePrivate(file, text) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const staging = `${file}.${process.pid}.tmp`;
  writeFileSync(staging, text, { mode: 0o600 });
  renameSync(staging, file);
}

function readShow(output) {
  try {
    return parseShow(output);
  } catch {
    return null;
  }
}

function showTaskSync(ctx, id) {
  const shown = runSync(ctx, tasksAxi(ctx), ["show", id, "--full"]);
  return shown.status === 0 ? readShow(shown.stdout) : null;
}

// bin/fm-captain-hold.sh owns what an open captain call is and its lifecycle
// identity; this engine only asks.
function identityResult(result) {
  if (result.status === 0) return { open: true, identity: result.stdout.trim() };
  if (result.status === 1 || result.status === 3) return { open: false };
  return { error: lastLine(result.stderr) || `exit ${result.status}` };
}

function identitySync(ctx, id) {
  return identityResult(runSync(ctx, captainHold(ctx), ["open", id, "--identity", "--distinguish-absent"]));
}

function heldSince(identity, created) {
  const stamp = String(identity || "").split("#")[0];
  const value = stamp || created || "";
  const parsed = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00Z` : value);
  return Number.isFinite(parsed) ? new Date(parsed) : null;
}

function bodyLines(body) {
  return String(body ?? "").split("\n");
}

function isMarkLine(line) {
  return Object.values(MARK_LABELS).some((label) => line.startsWith(label));
}

// The tap fields are explicit body lines bound to one lifecycle identity, so a
// re-held question never inherits an earlier question's marks.
function marksFrom(body) {
  const lines = bodyLines(body);
  const marks = { identity: "", options: [], recommended: "", easyUndo: false };
  for (const line of lines) {
    if (line.startsWith(MARK_LABELS.marks)) marks.identity = line.slice(MARK_LABELS.marks.length).trim();
    else if (line.startsWith(MARK_LABELS.option)) marks.options.push(line.slice(MARK_LABELS.option.length).trim());
    else if (line.startsWith(MARK_LABELS.recommended)) marks.recommended = line.slice(MARK_LABELS.recommended.length).trim();
    else if (line.startsWith(MARK_LABELS.easy)) marks.easyUndo = line.slice(MARK_LABELS.easy.length).trim() === "yes";
  }
  return marks;
}

function currentMarks(task, identity) {
  const marks = marksFrom(task.body);
  if (!marks.identity) return { present: false };
  if (marks.identity !== identity) return { present: false, stale: true };
  return { present: true, ...marks };
}

function decisionShape(task, identity) {
  const reason = task.hold_reason && task.hold_reason !== "-" ? task.hold_reason : "";
  const marks = currentMarks(task, identity);
  const parsedRecommendation = recommendationFrom(reason);
  const options = marks.present && marks.options.length > 0
    ? marks.options
    : optionsFrom(task.title || "", reason, parsedRecommendation);
  const recommended = marks.present && marks.recommended && options.includes(marks.recommended)
    ? marks.recommended
    : "";
  return {
    reason,
    options,
    recommended,
    recommendationText: recommended || parsedRecommendation,
    easyUndo: Boolean(marks.present && marks.easyUndo),
    staleMarks: Boolean(marks.stale),
  };
}

function neverDefaultClass(...texts) {
  const joined = texts.filter(Boolean).join("\n");
  for (const [label, pattern] of NEVER_DEFAULT) {
    if (pattern.test(joined)) return label;
  }
  return "";
}

// Why a decision never gets the seven-day default, or "" when only its age
// decides; export and defaults both ask here.
function defaultRefusal(task, identity, shape, ledger) {
  if (!shape.easyUndo) return "it is not marked easy to undo";
  if (!shape.recommended) return "no recorded recommendation is one of its options";
  const holdUntil = task.hold_until && task.hold_until !== "-" ? task.hold_until : "";
  if (holdUntil) return `the owner deferred it until ${holdUntil}`;
  if (latestOutcome(ledger, "decision", task.id, identity, "kept")) return "the owner tapped keep on this question";
  const sensitive = neverDefaultClass(task.title, shape.reason, ...shape.options);
  if (sensitive) return `it reads as ${sensitive}, which a default never decides`;
  return "";
}

function readLedger(ctx) {
  if (!existsSync(ctx.ledger)) return [];
  const entries = [];
  for (const line of readFileSync(ctx.ledger, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      entries.push(JSON.parse(line));
    } catch {
      // A torn final line from an interrupted append is skipped, never fatal.
    }
  }
  return entries;
}

function appendLedger(ctx, entry) {
  mkdirSync(ctx.deskDir, { recursive: true, mode: 0o700 });
  appendFileSync(ctx.ledger, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
}

function latestOutcome(ledger, kind, id, identity, outcome) {
  let found = null;
  for (const entry of ledger) {
    if (entry.kind === kind && entry.id === id && entry.identity === identity && entry.outcome === outcome) found = entry;
  }
  return found;
}

function appendLearning(ctx, entry) {
  if (!entry.reason) return;
  const file = path.join(ctx.data, "learnings.md");
  const heading = "## Tap rule candidates";
  const existing = existsSync(file) ? readFileSync(file, "utf8") : "";
  let prefix = "";
  if (!existing.split("\n").includes(heading)) {
    prefix = `${existing && !existing.endsWith("\n") ? "\n" : ""}${existing ? "\n" : ""}${heading}\n\n`;
  } else if (existing && !existing.endsWith("\n")) {
    prefix = "\n";
  }
  const day = entry.at.slice(0, 10);
  const line = `- Rule candidate from a tap on ${day} (${entry.id}, ${entry.choice_label}): ${entry.reason}\n`;
  mkdirSync(path.dirname(file), { recursive: true });
  appendFileSync(file, `${prefix}${line}`);
}

function parseMeta(file) {
  const meta = {};
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const index = line.indexOf("=");
    if (index > 0) meta[line.slice(0, index)] = line.slice(index + 1);
  }
  return meta;
}

function githubPull(url) {
  const match = /^https:\/\/([^/\s]+)\/([^/\s]+)\/([^/\s]+)\/pull\/(\d+)$/.exec(url || "");
  return match ? { host: match[1], owner: match[2], repo: match[3], number: match[4] } : null;
}

function livePull(result, url) {
  if (result.status !== 0) return { error: `could not read ${url}: ${lastLine(result.stderr) || `exit ${result.status}`}` };
  try {
    return { pr: JSON.parse(result.stdout) };
  } catch {
    return { error: `could not read ${url}: the forge answer was not JSON` };
  }
}

// The paths bin/fm-pr-merge.sh treats as Starship's own rules; that script owns
// the list, and a merge tap's --captain-approved skips its check, so the card
// names them instead.
function rulesFile(name) {
  return name === "AGENTS.md" || name.endsWith("/AGENTS.md") || name === "CLAUDE.md"
    || name === ".claude/settings.json" || name.startsWith(".agents/skills/")
    || name.startsWith(".agents/opt-in-skills/") || name.startsWith("hooks/");
}

// bin/fm-fleet-status-lib.sh owns whether a task's work waits on the captain;
// only its `ready` reading makes a merge card.
function fleetBucket(ctx, id) {
  return runAsync(ctx, "bash", ["-c", '. "$0" && fm_fleet_task_bucket "$1" "$2"', path.join(ctx.root, "bin/fm-fleet-status-lib.sh"), ctx.state, id]);
}

async function loadDecisions(ctx) {
  const listed = runSync(ctx, tasksAxi(ctx), ["list", "--state", "held", "--fields", "hold_kind", "--limit", "100000"]);
  if (listed.status !== 0) fail(`could not list held tasks: ${lastLine(listed.stderr || listed.stdout)}`);
  const { ids } = taskIdsFromList(listed.stdout.replace(/^count: (\d+) of \d+ total$/m, "count: $1"));
  const notShown = [];
  const rows = await pool(ids, 8, async (id) => {
    const [shown, opened] = await Promise.all([
      runAsync(ctx, tasksAxi(ctx), ["show", id, "--full"]),
      runAsync(ctx, captainHold(ctx), ["open", id, "--identity", "--distinguish-absent"]),
    ]);
    const task = shown.status === 0 ? readShow(shown.stdout) : null;
    const open = identityResult(opened);
    if (!task) return { id, error: "could not be read" };
    if (task.hold_kind !== "captain") return null;
    if (open.error) return { id, error: `could not tell whether it is still waiting: ${open.error}` };
    if (!open.open) return null;
    return { task, identity: open.identity };
  });
  const decisions = [];
  for (const row of rows) {
    if (!row) continue;
    if (row.error) notShown.push({ id: row.id, reason: row.error });
    else decisions.push(row);
  }
  return { decisions, notShown };
}

function decisionCard(row, ledger, now, days) {
  const { task, identity } = row;
  const shape = decisionShape(task, identity);
  const since = heldSince(identity, task.created);
  const ageDays = since ? Math.floor((now - since.getTime()) / DAY_MS) : null;
  const kept = latestOutcome(ledger, "decision", task.id, identity, "kept");
  const holdUntil = task.hold_until && task.hold_until !== "-" ? task.hold_until : "";
  const defaults = ageDays !== null && !defaultRefusal(task, identity, shape, ledger);
  return {
    key: `d.${task.id}`,
    kind: "decision",
    id: task.id,
    identity,
    title: task.title || task.id,
    reason: shape.reason,
    repo: task.repo && task.repo !== "-" ? task.repo.replace(/\/$/, "").split("/").at(-1) : "",
    held_since: since ? since.toISOString() : "",
    age_days: ageDays,
    deferred_until: holdUntil,
    options: shape.options,
    recommendation: shape.recommendationText,
    recommended_option: shape.recommended,
    easy_undo: shape.easyUndo,
    default_in_days: defaults ? Math.max(0, days - ageDays) : null,
    closes_on_answer: task.kind === "captain",
    kept: kept ? { at: kept.at, reason: kept.reason || "" } : null,
  };
}

async function loadMergeCards(ctx, ledger) {
  const cards = [];
  const notShown = [];
  const logins = new Map();
  const ownLogin = (host) => {
    if (!logins.has(host)) {
      logins.set(host, runAsync(ctx, "gh", ["api", "--hostname", host, "user", "--jq", ".login"])
        .then((result) => (result.status === 0 ? result.stdout.trim() : "")));
    }
    return logins.get(host);
  };
  if (!existsSync(ctx.state)) return { cards, notShown };
  const metas = readdirSync(ctx.state).filter((name) => name.endsWith(".meta")).sort();
  const candidates = [];
  for (const name of metas) {
    const id = name.slice(0, -".meta".length);
    if (!SLUG.test(id)) continue;
    let meta;
    try {
      meta = parseMeta(path.join(ctx.state, name));
    } catch {
      continue;
    }
    if (!meta.pr) continue;
    candidates.push({ id, meta });
  }
  const read = await pool(candidates, 6, async ({ id, meta }) => {
    const shown = await runAsync(ctx, tasksAxi(ctx), ["show", id, "--full"]);
    const task = shown.status === 0 ? readShow(shown.stdout) : null;
    if (task && task.state === "done") return null;
    const parts = githubPull(meta.pr);
    if (!parts) return { id, error: `${meta.pr} is not a GitHub pull request, so it has no tap card yet` };
    const bucket = await fleetBucket(ctx, id);
    if (bucket.status !== 0) return { id, error: `could not read whether ${meta.pr} is ready: ${lastLine(bucket.stderr) || `exit ${bucket.status}`}` };
    if (bucket.stdout.trim() !== "ready") return null;
    const { pr, error } = livePull(await runAsync(ctx, "gh", ["pr", "view", meta.pr, "--json", "state,isDraft,title,headRefOid,author"]), meta.pr);
    if (error) return { id, error };
    if (pr.state !== "OPEN") return null;
    if (pr.isDraft) return { id, error: `${meta.pr} is still a draft` };
    if (!HEAD.test(pr.headRefOid || "")) return { id, error: `${meta.pr} reported no head commit` };
    const author = typeof pr.author?.login === "string" ? pr.author.login : "";
    const login = await ownLogin(parts.host);
    if (!author || !login) return { id, error: `could not read who opened ${meta.pr}, so its card could not say what a tap approves` };
    const files = await runAsync(ctx, "gh", ["api", "--hostname", parts.host, "--paginate", `repos/${parts.owner}/${parts.repo}/pulls/${parts.number}/files`, "--jq", ".[] | .filename, (.previous_filename // empty)"]);
    if (files.status !== 0) return { id, error: `could not read which files ${meta.pr} changes, so its card could not say what a tap approves` };
    const rulesFiles = [...new Set(files.stdout.split("\n").map((name) => name.trim()).filter(rulesFile))].sort();
    const notYet = latestOutcome(ledger, "merge", id, pr.headRefOid, "not-yet");
    return {
      card: {
        key: `m.${id}`,
        kind: "merge",
        id,
        identity: pr.headRefOid,
        title: pr.title || (task && task.title) || id,
        repo: meta.project ? meta.project.replace(/\/$/, "").split("/").at(-1) : "",
        pr_url: meta.pr,
        opened_by: author,
        opened_by_other: author.toLowerCase() !== login.toLowerCase(),
        rules_files: rulesFiles,
        held_for_captain: Boolean(task && task.held === "yes" && task.hold_kind === "captain"),
        not_yet: notYet ? { at: notYet.at, reason: notYet.reason || "" } : null,
      },
    };
  });
  for (const row of read) {
    if (!row) continue;
    if (row.error) notShown.push({ id: row.id, reason: row.error });
    else cards.push(row.card);
  }
  return { cards, notShown };
}

function scriptJson(value) {
  return JSON.stringify(value).replaceAll("<", "\\u003c").replaceAll(">", "\\u003e").replaceAll("&", "\\u0026");
}

async function commandExport(args) {
  const ctx = context(args);
  const output = args.output || path.join(ctx.deskDir, "cards.json");
  const pageOut = args.page || path.join(path.dirname(output), "page.html");
  const template = args.template;
  if (!template || !existsSync(template)) fail("export requires the page --template");
  const days = Number(args.days || 7);
  if (!Number.isInteger(days) || days < 7) fail("--days must be a whole number of at least 7", 2);
  const ledger = readLedger(ctx);
  const now = Date.now();
  const [decisions, merges] = await Promise.all([loadDecisions(ctx), loadMergeCards(ctx, ledger)]);
  const decisionCards = decisions.decisions
    .map((row) => decisionCard(row, ledger, now, days))
    .sort((left, right) => (left.held_since || "").localeCompare(right.held_since || "") || left.id.localeCompare(right.id));
  const cards = {
    schema: CARDS_SCHEMA,
    generated_at: new Date(now).toISOString(),
    default_after_days: days,
    cards: [...merges.cards, ...decisionCards],
    not_shown: [...merges.notShown, ...decisions.notShown],
  };
  const html = readFileSync(template, "utf8");
  if (!html.includes(PAGE_PLACEHOLDER)) fail(`the page template lacks ${PAGE_PLACEHOLDER}`);
  writePrivate(output, `${JSON.stringify(cards, null, 2)}\n`);
  writePrivate(pageOut, html.replace(PAGE_PLACEHOLDER, () => scriptJson(cards)));
  const kept = decisionCards.filter((card) => card.kept).length;
  console.log(`decisions: ${decisionCards.length} (kept for later: ${kept}; easy to undo: ${decisionCards.filter((card) => card.easy_undo).length})`);
  console.log(`merges: ${merges.cards.length}`);
  for (const item of cards.not_shown) console.log(`not shown: ${item.id}: ${item.reason}`);
  console.log(`cards: ${output}`);
  console.log(`page: ${pageOut}`);
}

function normalizeTap(raw, source) {
  let value = raw;
  if (value && typeof value === "object" && !("choice" in value) && value.data && typeof value.data === "object") value = value.data;
  if (!value || typeof value !== "object") return { error: `${source}: not a tap object` };
  const tap = {
    card: String(value.card ?? ""),
    kind: String(value.kind ?? ""),
    id: String(value.id ?? ""),
    identity: String(value.identity ?? ""),
    choice: String(value.choice ?? ""),
    option: value.option == null ? "" : String(value.option),
    pr: value.pr == null ? "" : String(value.pr),
    reason: oneLine(value.reason, REASON_MAX + 1),
    tapped_at: String(value.tapped_at ?? ""),
  };
  if (!SLUG.test(tap.id)) return { error: `${source}: the tap names no valid task` };
  if (tap.kind === "decision") {
    if (tap.card !== `d.${tap.id}`) return { error: `${source}: the card key does not match the task` };
    if (!DECISION_CHOICES.includes(tap.choice)) return { error: `${source}: ${tap.choice || "no choice"} is not a decision choice` };
    if (tap.choice === "option" && (!tap.option.trim() || tap.option.length > OPTION_MAX * 4)) return { error: `${source}: the chosen option is empty or too long` };
    if (tap.choice !== "option") tap.option = "";
    tap.pr = "";
  } else if (tap.kind === "merge") {
    if (tap.card !== `m.${tap.id}`) return { error: `${source}: the card key does not match the task` };
    if (!MERGE_CHOICES.includes(tap.choice)) return { error: `${source}: ${tap.choice || "no choice"} is not a merge choice` };
    if (!HEAD.test(tap.identity)) return { error: `${source}: the merge card carries no head commit` };
    if (!githubPull(tap.pr)) return { error: `${source}: the merge card names no GitHub pull request` };
    tap.option = "";
  } else {
    return { error: `${source}: unknown card kind ${tap.kind || "(none)"}` };
  }
  if (!tap.identity || /[\n\r]/.test(tap.identity)) return { error: `${source}: the tap carries no card identity` };
  if (tap.reason.length > REASON_MAX) return { error: `${source}: the reason is longer than ${REASON_MAX} characters` };
  return { tap };
}

function readTaps(input) {
  if (!input || !existsSync(input)) fail(`taps input does not exist: ${input || "(none)"}`);
  const found = [];
  const errors = [];
  const files = statSync(input).isDirectory()
    ? readdirSync(input).filter((name) => name.endsWith(".json")).sort().map((name) => path.join(input, name))
    : [input];
  for (const file of files) {
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(file, "utf8"));
    } catch (error) {
      errors.push(`${path.basename(file)}: not JSON (${error.message})`);
      continue;
    }
    const list = Array.isArray(parsed)
      ? parsed
      : Array.isArray(parsed?.documents) ? parsed.documents
        : [parsed];
    list.forEach((item, index) => {
      const label = list.length > 1 ? `${path.basename(file)}#${index + 1}` : path.basename(file);
      const { tap, error } = normalizeTap(item, label);
      if (error) errors.push(error);
      else found.push(tap);
    });
  }
  // The page overwrites one document per card, but a combined input may still
  // carry two taps for one card: only the newest is the owner's current word.
  const newest = new Map();
  for (const tap of found) {
    const current = newest.get(tap.card);
    if (!current || tap.tapped_at > current.tapped_at) newest.set(tap.card, tap);
  }
  return { taps: [...newest.values()].sort((left, right) => left.card.localeCompare(right.card)), errors };
}

function choiceLabel(tap, chosen) {
  if (tap.choice === "option") return `chose "${chosen}"`;
  if (tap.choice === "you-decide") return chosen ? `said you decide, firstmate chose "${chosen}"` : "said you decide";
  if (tap.choice === "not-yet") return "not yet";
  return tap.choice;
}

function decisionText(tap, chosen, extraLines) {
  const lines = [];
  if (chosen) lines.push(`Chosen option: ${chosen}`);
  lines.push(...extraLines);
  if (tap.reason) lines.push(`Reason: ${tap.reason}`);
  lines.push(`Answered by the owner's tap on the phone tap page${tap.tapped_at ? ` at ${oneLine(tap.tapped_at, 40)}` : ""}.`);
  return `${lines.join("\n")}\n`;
}

function answerTask(ctx, id, identity, text, release, label) {
  const file = path.join(ctx.deskDir, "answers", `${id}.${digestOf({ id, identity, text }).slice(0, 12)}.txt`);
  writePrivate(file, text);
  const args = ["answer", id, "--decision-file", file, "--expect-identity", identity];
  if (release) args.push("--release");
  const result = runSync(ctx, captainHold(ctx), args);
  if (result.status === 0) return { final: true, outcome: label };
  if (result.status === 3) return { final: true, outcome: "stale", detail: "the question changed or closed before the answer landed" };
  return { final: false, outcome: "refused", detail: lastLine(result.stderr || result.stdout) || `exit ${result.status}` };
}

function bodyNote(ctx, id, identity, text) {
  const file = path.join(ctx.deskDir, "notes", `${id}.${digestOf({ id, identity, text }).slice(0, 12)}.txt`);
  writePrivate(file, `${text}\n`);
  const args = [path.join(ctx.root, "bin/fm-tap-desk.sh"), "body", id, "--note-file", file];
  if (identity) args.push("--expect-identity", identity);
  return runSync(ctx, "bash", args);
}

function planDecision(ctx, tap) {
  const open = identitySync(ctx, tap.id);
  if (open.error) return { final: false, outcome: "refused", detail: `could not tell whether it is still waiting: ${open.error}` };
  if (!open.open) return { final: true, outcome: "stale", detail: "it is no longer waiting for the owner" };
  if (open.identity !== tap.identity) return { final: true, outcome: "stale", detail: "the question changed since this card was shown" };
  const task = showTaskSync(ctx, tap.id);
  if (!task) return { final: false, outcome: "refused", detail: "could not read the task" };
  const shape = decisionShape(task, open.identity);
  const release = task.kind !== "captain";
  if (tap.choice === "option") {
    if (!shape.options.includes(tap.option)) return { final: true, outcome: "stale", detail: "the chosen option is no longer offered" };
    return { action: "answer", chosen: tap.option, release, label: release ? "answered, work resumes" : "answered", text: decisionText(tap, tap.option, []), identity: open.identity };
  }
  if (tap.choice === "drop") {
    return { action: "answer", chosen: "", release: false, label: "dropped", text: decisionText(tap, "", ["Dropped: the owner does not want this."]), identity: open.identity };
  }
  if (tap.choice === "you-decide") {
    if (shape.recommended) {
      return { action: "answer", chosen: shape.recommended, release, label: release ? "answered with firstmate's pick, work resumes" : "answered with firstmate's pick", text: decisionText(tap, shape.recommended, ["The owner asked firstmate to decide; firstmate's recorded recommendation was applied."]), identity: open.identity };
    }
    return { action: "answer", chosen: "", release, label: "delegated: firstmate decides and acts", text: decisionText(tap, "", ["The owner asked firstmate to decide; no recommendation was recorded, so firstmate decides next."]), identity: open.identity };
  }
  return { action: "keep", identity: open.identity };
}

function planMerge(ctx, tap) {
  const metaFile = path.join(ctx.state, `${tap.id}.meta`);
  if (!existsSync(metaFile)) return { final: true, outcome: "stale", detail: "the task no longer has a record" };
  const meta = parseMeta(metaFile);
  if (meta.pr !== tap.pr) return { final: true, outcome: "stale", detail: `the task no longer records ${tap.pr}` };
  const { pr, error } = livePull(runSync(ctx, "gh", ["pr", "view", tap.pr, "--json", "state,headRefOid"]), tap.pr);
  if (error) return { final: false, outcome: "refused", detail: error };
  if (pr.state !== "OPEN") return { final: true, outcome: "stale", detail: `${tap.pr} is no longer open` };
  if (pr.headRefOid !== tap.identity) return { final: true, outcome: "stale", detail: `${tap.pr} changed since this card was shown` };
  return { action: tap.choice === "merge" ? "merge" : "not-yet", pr: tap.pr };
}

function mergeBin(ctx) {
  return process.env.FM_TAP_DESK_MERGE_BIN || path.join(ctx.root, "bin/fm-pr-merge.sh");
}

function commandRoute(args) {
  const ctx = context(args);
  const apply = args.flags.has("apply");
  const { taps, errors } = readTaps(args.taps);
  const ledger = readLedger(ctx);
  const handled = new Set(ledger.filter((entry) => entry.final).map((entry) => entry.digest));
  let already = 0;
  let refusedCount = 0;
  for (const error of errors) console.log(`unreadable: ${error}`);
  for (const tap of taps) {
    tap.digest = digestOf({ card: tap.card, identity: tap.identity, choice: tap.choice, option: tap.option, reason: tap.reason, tapped_at: tap.tapped_at });
    if (handled.has(tap.digest)) {
      already += 1;
      continue;
    }
    const plan = tap.kind === "decision" ? planDecision(ctx, tap) : planMerge(ctx, tap);
    let result;
    let chosen = "";
    if (plan.outcome) {
      result = plan;
    } else if (!apply) {
      const what = plan.action === "answer"
        ? `${plan.label}${plan.chosen ? `: ${plan.chosen}` : ""}`
        : plan.action === "merge" ? `merge ${plan.pr} at ${tap.identity.slice(0, 12)}` : plan.action;
      console.log(`would ${plan.action}: ${tap.id}: ${what}${tap.reason ? ` (reason: ${tap.reason})` : ""}`);
      continue;
    } else if (plan.action === "answer") {
      chosen = plan.chosen;
      result = answerTask(ctx, tap.id, plan.identity, plan.text, plan.release, plan.label);
    } else if (plan.action === "keep") {
      const noted = bodyNote(ctx, tap.id, plan.identity, `Tap note ${new Date().toISOString().slice(0, 10)}: kept for ${plan.identity}: ${tap.reason || "no reason given"}`);
      result = noted.status === 0
        ? { final: true, outcome: "kept" }
        : noted.status === 3
          ? { final: true, outcome: "stale", detail: "the question changed before the keep was noted" }
          : { final: false, outcome: "refused", detail: lastLine(noted.stderr) || `exit ${noted.status}` };
    } else if (plan.action === "not-yet") {
      const task = showTaskSync(ctx, tap.id);
      const noted = task
        ? bodyNote(ctx, tap.id, "", `Tap note ${new Date().toISOString().slice(0, 10)}: not yet for head ${tap.identity}: ${tap.reason || "no reason given"}`)
        : { status: 0 };
      result = noted.status === 0
        ? { final: true, outcome: "not-yet" }
        : { final: false, outcome: "refused", detail: `could not note it on the task: ${lastLine(noted.stderr) || `exit ${noted.status}`}` };
    } else {
      const merged = runSync(ctx, mergeBin(ctx), [tap.id, plan.pr, "--captain-approved", "--expected-head", tap.identity]);
      result = merged.status === 0
        ? { final: true, outcome: "merged", detail: plan.pr }
        : { final: false, outcome: "refused", detail: `${plan.pr}: ${lastLine(merged.stderr || merged.stdout) || `exit ${merged.status}`}` };
    }
    if (result.outcome === "refused") refusedCount += 1;
    console.log(`${result.outcome}: ${tap.id}${result.detail ? `: ${result.detail}` : ""}${chosen ? ` (chose: ${chosen})` : ""}`);
    if (!apply) continue;
    if (!result.final) continue;
    const entry = {
      at: new Date().toISOString(),
      digest: tap.digest,
      final: true,
      kind: tap.kind,
      id: tap.id,
      identity: tap.identity,
      choice: tap.choice,
      option: tap.option,
      chosen,
      choice_label: choiceLabel(tap, chosen),
      reason: tap.reason,
      tapped_at: tap.tapped_at,
      outcome: result.outcome,
      detail: result.detail || "",
    };
    appendLedger(ctx, entry);
    ledger.push(entry);
    if (result.outcome !== "stale") appendLearning(ctx, entry);
  }
  if (already > 0) console.log(`already handled: ${already}`);
  console.log(`taps: ${taps.length}${apply ? "" : " (dry run; add --apply to route them)"}`);
  if (refusedCount > 0 || errors.length > 0) process.exitCode = 1;
}

async function commandDefaults(args) {
  const ctx = context(args);
  const apply = args.flags.has("apply");
  const days = Number(args.days || 7);
  if (!Number.isInteger(days) || days < 7) fail("--days must be a whole number of at least 7", 2);
  const ledger = readLedger(ctx);
  const now = Date.now();
  const { decisions, notShown } = await loadDecisions(ctx);
  for (const item of notShown) console.log(`not checked: ${item.id}: ${item.reason}`);
  let due = 0;
  let refusedCount = 0;
  for (const row of decisions.sort((left, right) => left.task.id.localeCompare(right.task.id))) {
    const { task, identity } = row;
    const shape = decisionShape(task, identity);
    if (!shape.easyUndo) continue;
    const since = heldSince(identity, task.created);
    const age = since ? Math.floor((now - since.getTime()) / DAY_MS) : null;
    const skip = (why) => console.log(`skipped: ${task.id}: ${why}`);
    if (age === null) { skip("its hold time cannot be read"); continue; }
    if (age < days) continue;
    const refusal = defaultRefusal(task, identity, shape, ledger);
    if (refusal) { skip(refusal); continue; }
    due += 1;
    if (!apply) {
      console.log(`would default: ${task.id}: ${shape.recommended} (waited ${age} days)`);
      continue;
    }
    const text = [
      `Chosen option: ${shape.recommended}`,
      `Default applied: firstmate's recorded recommendation after ${age} days without an answer; this decision was marked easy to undo.`,
      "Source: fm-tap-desk defaults, not the owner's tap.",
      "",
    ].join("\n");
    const release = task.kind !== "captain";
    const result = answerTask(ctx, task.id, identity, text, release, "defaulted");
    if (result.final && result.outcome === "defaulted") {
      appendLedger(ctx, {
        at: new Date().toISOString(),
        digest: digestOf({ default: task.id, identity }),
        final: true,
        kind: "decision",
        id: task.id,
        identity,
        choice: "default",
        option: shape.recommended,
        chosen: shape.recommended,
        choice_label: "seven-day default",
        reason: "",
        outcome: "defaulted",
        detail: `waited ${age} days`,
      });
      console.log(`defaulted: ${task.id}: ${shape.recommended} (waited ${age} days; tell the owner)`);
    } else {
      if (!result.final) refusedCount += 1;
      console.log(`${result.outcome}: ${task.id}: ${result.detail}`);
    }
  }
  console.log(`due: ${due}${apply ? "" : " (dry run; add --apply to record the defaults)"}`);
  if (refusedCount > 0) process.exitCode = 1;
}

function commandMark(args) {
  const ctx = context(args);
  const id = args.id;
  if (!id || !SLUG.test(id)) fail("mark requires a valid task id", 2);
  const open = identitySync(ctx, id);
  if (open.error) fail(`could not tell whether ${id} is still waiting: ${open.error}`);
  if (!open.open) fail(`${id} is not an open captain decision`);
  const task = showTaskSync(ctx, id);
  if (!task) fail(`could not read ${id}`);
  const markFile = path.join(ctx.deskDir, "marks", `${id}.${process.pid}.json`);
  if (args.flags.has("clear")) {
    writePrivate(markFile, `${JSON.stringify({ clear: true })}\n`);
  } else {
    for (const option of args.options) {
      if (!option.trim() || /[\n\r]/.test(option) || option.length > OPTION_MAX) fail(`each --option must be one line of at most ${OPTION_MAX} characters`, 2);
    }
    const reason = task.hold_reason && task.hold_reason !== "-" ? task.hold_reason : "";
    const options = args.options.length > 0
      ? [...new Set(args.options.map((option) => option.trim()))]
      : optionsFrom(task.title || "", reason, recommendationFrom(reason));
    const recommended = (args.recommend || "").trim();
    if (recommended && !options.includes(recommended)) fail(`--recommend must be exactly one of the options: ${options.join(" | ") || "(none parsed; pass --option)"}`);
    const easyUndo = args.flags.has("easy-undo");
    if (easyUndo && !recommended) fail("--easy-undo needs --recommend, because the default applies the recommended option");
    if (easyUndo) {
      const sensitive = neverDefaultClass(task.title, reason, ...options);
      if (sensitive) fail(`${id} reads as ${sensitive}; a decision of that kind is never marked easy to undo`);
    }
    if (options.length === 0 && !recommended) fail(`no options could be read from ${id}; pass each with --option`);
    writePrivate(markFile, `${JSON.stringify({ identity: open.identity, options: args.options.length > 0 ? options : [], recommended, easyUndo })}\n`);
  }
  const result = runSync(ctx, "bash", [path.join(ctx.root, "bin/fm-tap-desk.sh"), "body", id, "--marks-file", markFile, "--expect-identity", open.identity]);
  if (result.status !== 0) fail(lastLine(result.stderr) || `could not record the marks on ${id}`, result.status === 3 ? 3 : 1);
  console.log(`marked: ${id}${args.flags.has("clear") ? " (cleared)" : ""}`);
}

// Runs only inside fm-tap-desk.sh's locked `body` command.
function commandBodyWrite(args) {
  const ctx = context(args);
  const id = args.id;
  if (!id || !SLUG.test(id)) fail("body-write requires a valid task id", 2);
  const task = showTaskSync(ctx, id);
  if (!task) fail(`could not read ${id}`);
  let lines = bodyLines(task.body === "-" ? "" : task.body);
  while (lines.length > 0 && lines.at(-1) === "") lines.pop();
  if (args.marks_file) {
    const marks = JSON.parse(readFileSync(args.marks_file, "utf8"));
    lines = lines.filter((line) => !isMarkLine(line));
    while (lines.length > 0 && lines.at(-1) === "") lines.pop();
    if (!marks.clear) {
      const block = [`${MARK_LABELS.marks}${marks.identity}`];
      for (const option of marks.options || []) block.push(`${MARK_LABELS.option}${option}`);
      if (marks.recommended) block.push(`${MARK_LABELS.recommended}${marks.recommended}`);
      block.push(`${MARK_LABELS.easy}${marks.easyUndo ? "yes" : "no"}`);
      lines.push(...(lines.length > 0 ? [""] : []), ...block);
    }
  } else if (args.note_file) {
    const note = oneLine(readFileSync(args.note_file, "utf8"), 2000);
    if (!note) fail("the note is empty");
    lines.push(...(lines.length > 0 ? [""] : []), note);
  } else {
    fail("body-write requires --marks-file or --note-file", 2);
  }
  const file = path.join(ctx.deskDir, "bodies", `${id}.${process.pid}.txt`);
  writePrivate(file, `${lines.join("\n")}\n`);
  const result = runSync(ctx, tasksAxi(ctx), ["update", id, "--body-file", file]);
  if (result.status !== 0) fail(`could not write the body of ${id}: ${lastLine(result.stderr || result.stdout)}`);
}

const args = parseArgs(process.argv.slice(2));
switch (args.command) {
  case "export":
    await commandExport(args);
    break;
  case "route":
    commandRoute(args);
    break;
  case "defaults":
    await commandDefaults(args);
    break;
  case "mark":
    commandMark(args);
    break;
  case "body-write":
    commandBodyWrite(args);
    break;
  default:
    fail(`unknown engine command: ${args.command}`, 2);
}
