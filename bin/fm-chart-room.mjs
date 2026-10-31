#!/usr/bin/env node
// Data and rendering engine for fm-chart-room.sh.
// The shell wrapper owns the operator-facing commands and the loopback-only launch.
//
// Every route is derived and rendered at the moment it is requested: this engine
// holds no cache, writes no page, and regenerates nothing in the background, so a
// link followed hours after it was printed still shows the records as they are now.
// It is strictly read-only - it never writes to the backlog, task metadata,
// decisions, reports, or any project.
//
// Sources joined per request:
//   data/projects.md         the project registry
//   tasks-axi                task identity, state, kind, hold, dependency edges
//   state/<id>.meta          human outcome= titles and pr= links
//   data/goals/<project>.md  the optional goal charter (see docs/chart-room.md)
//   data/<id>/report.md      finished investigation reports
//   data/done-archive.md     shipped history beyond the recent backlog window
//
// Commands:
//   fm-chart-room.mjs serve  --home <dir> --port <n>
//   fm-chart-room.mjs render --home <dir> --path </p/beta>
//   fm-chart-room.mjs data   --home <dir>
//
// `render` and `data` exist so the derivation can be tested without a socket.

import { createServer } from "node:http";
import { existsSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { render as renderMarkdown } from "./fm-read.mjs";

const LOOPBACK = "127.0.0.1";
const SHOW_CONCURRENCY = 8;
// A child that never answers must not hold a request open forever: one page is
// one read of the records, so a read that stalls is a failure, not a wait.
const CHILD_TIMEOUT_MS = 15000;
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const HOLD_REASON_LIB = path.join(path.dirname(fileURLToPath(import.meta.url)), "fm-hold-reason-lib.sh");

function fail(message, code = 1) {
  console.error(`fm-chart-room: ${message}`);
  process.exit(code);
}

function parseArgs(argv) {
  const command = argv.shift() || "";
  const values = { command };
  while (argv.length > 0) {
    const name = argv.shift();
    if (!name?.startsWith("--")) fail(`unexpected argument: ${name}`, 2);
    if (argv.length === 0) fail(`${name} requires a value`, 2);
    values[name.slice(2).replaceAll("-", "_")] = argv.shift();
  }
  return values;
}

// --- reading the records ----------------------------------------------------

function runCapture(command, args, cwd, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, encoding: "utf8" });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timer = null;
    const settle = (action, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      action(value);
    };
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      settle(reject, new Error(`${command} ${args.join(" ")} did not answer within ${CHILD_TIMEOUT_MS / 1000}s`));
    }, CHILD_TIMEOUT_MS);
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.stdin.on("error", () => {});
    child.stdin.end(input);
    child.on("error", (error) => settle(reject, new Error(`${command} could not run: ${error.message}`)));
    child.on("close", (status) => {
      if (status !== 0) settle(reject, new Error(`${command} ${args.join(" ")} failed: ${(stderr || stdout).trim()}`));
      else settle(resolve, stdout);
    });
  });
}

async function mapPool(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index]);
    }
  });
  await Promise.all(runners);
  return results;
}

function parseYamlScalar(value) {
  const trimmed = value.trim();
  if (!trimmed.startsWith('"')) return trimmed;
  try {
    return JSON.parse(trimmed);
  } catch {
    return trimmed;
  }
}

function parseShow(output) {
  const task = {};
  for (const line of output.split("\n")) {
    const match = line.match(/^  ([a-z_]+): (.*)$/);
    if (match) task[match[1]] = parseYamlScalar(match[2]);
  }
  return task.id ? task : null;
}

function taskIdsFromList(output) {
  const ids = [];
  for (const line of output.split("\n")) {
    const match = line.match(/^ {2}([A-Za-z0-9][A-Za-z0-9._-]*),/);
    if (match) ids.push(match[1]);
  }
  return [...new Set(ids)];
}

function splitList(value) {
  if (!value || value === "none" || value === "-") return [];
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function blank(value) {
  return !value || value === "-" || value === "none";
}

// A record that was enumerated but cannot be read is still a piece of work the
// captain has. Dropping it would make the chart quietly disagree with the
// records, which is the one thing this surface exists to prevent, so it comes
// back as itself with its standing marked unknown and every other record renders.
function unreadableTask(id) {
  return { id, title: id, unreadable: true };
}

// Captain-hold reasons are stored encoded; bin/fm-hold-reason-lib.sh owns decoding them.
async function taskShow(home, id) {
  const shown = await runCapture("tasks-axi", ["show", id, "--full"], home);
  return runCapture("bash", ["-c", '. "$1" && fm_hold_reason_decode_stream', "bash", HOLD_REASON_LIB], home, shown);
}

async function loadTasks(home) {
  const listed = taskIdsFromList(await runCapture("tasks-axi", ["list"], home));
  return mapPool(listed, SHOW_CONCURRENCY, async (id) => {
    try {
      return parseShow(await taskShow(home, id)) || unreadableTask(id);
    } catch {
      return unreadableTask(id);
    }
  });
}

function loadRegistry(home) {
  const file = path.join(home, "data", "projects.md");
  if (!existsSync(file)) return [];
  const projects = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const match = line.match(/^- ([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*-\s*(.*)$/);
    if (!match) continue;
    const [, name, rawDescription] = match;
    const description = rawDescription.replace(/\s*\((?:added|registered)[^)]*\)\s*$/i, "").trim();
    const remotes = [...rawDescription.matchAll(/(?:github|gitlab)\.com\/([A-Za-z0-9._/-]+)/g)]
      .map((found) => found[1].replace(/[.,;)]+$/, ""));
    projects.push({ name, description, remotes });
  }
  return projects;
}

function loadMeta(home) {
  const dir = path.join(home, "state");
  const meta = new Map();
  if (!existsSync(dir)) return meta;
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith(".meta")) continue;
    const id = entry.slice(0, -".meta".length);
    const fields = {};
    for (const line of readFileSync(path.join(dir, entry), "utf8").split("\n")) {
      const at = line.indexOf("=");
      if (at > 0) fields[line.slice(0, at)] = line.slice(at + 1);
    }
    meta.set(id, fields);
  }
  return meta;
}

// data/done-archive.md keeps shipped work after it leaves the recent backlog
// window. Only the headline of each archived entry is read; the indented
// resolution body below it belongs to the report, not to a lane card.
function loadArchive(home) {
  const file = path.join(home, "data", "done-archive.md");
  if (!existsSync(file)) return [];
  const entries = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const match = line.match(/^- \[x\] ([A-Za-z0-9][A-Za-z0-9._-]*) - (.*)$/);
    if (!match) continue;
    const [, id, rest] = match;
    const repo = rest.match(/\(repo: ([^)]*)\)/)?.[1] || "";
    const kind = rest.match(/\(kind: ([^)]*)\)/)?.[1] || "";
    const closed = rest.match(/\((?:done|reported|archived) (\d{4}-\d{2}-\d{2})\)/)?.[1] || "";
    // An archived headline carries its delivery link inline. Lift it out so the
    // card reads as a sentence and the link becomes something to click.
    const pr = rest.match(/(https:\/\/[^\s)]+)/)?.[1] || "";
    const title = rest
      .replace(/\s*blocked-by:.*$/, "")
      .replace(/\s*https:\/\/\S+/g, "")
      .replace(/\s*\([^)]*\)\s*$/g, "")
      .split(" (repo:")[0]
      .trim();
    entries.push({ id, title, repo, kind, closed, pr, archived: true });
  }
  return entries;
}

// --- goal charters ----------------------------------------------------------

// The charter format is owned by docs/chart-room.md. Anything this parser cannot
// recognise is ignored rather than guessed at, and a project with no charter
// renders flat.
function parseCharter(text) {
  const charter = { title: "", draft: false, endState: "", aliases: [], goals: [] };
  let section = "";
  let goal = null;
  let planned = false;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    const heading1 = line.match(/^# (.*)$/);
    if (heading1) { charter.title = heading1[1].trim(); continue; }
    const heading2 = line.match(/^## (.*)$/);
    if (heading2) {
      section = heading2[1].trim().toLowerCase();
      goal = null;
      planned = false;
      continue;
    }
    const heading3 = line.match(/^### ([a-z][a-z0-9-]*)\s*[-.:]\s*(.*)$/i);
    if (heading3) {
      goal = { id: heading3[1].toLowerCase(), title: heading3[2].trim(), onIce: "", planned: [], covers: [] };
      charter.goals.push(goal);
      planned = false;
      continue;
    }
    if (/^status:/i.test(line)) {
      charter.draft = /draft/i.test(line);
      continue;
    }
    if (/^aliases:/i.test(line)) {
      charter.aliases = splitList(line.replace(/^aliases:/i, "").trim());
      continue;
    }
    if (goal) {
      const ice = line.match(/^on ice:\s*(.*)$/i);
      if (ice) { goal.onIce = ice[1].trim(); continue; }
      const covers = line.match(/^covers:\s*(.*)$/i);
      if (covers) { goal.covers.push(...splitList(covers[1])); planned = false; continue; }
      if (/^planned:$/i.test(line)) { planned = true; continue; }
      const bullet = line.match(/^-\s+(.*)$/);
      if (bullet && planned) { goal.planned.push(bullet[1].trim()); continue; }
      continue;
    }
    if (section.startsWith("port of arrival") && line) {
      charter.endState = charter.endState ? `${charter.endState} ${line}` : line;
    }
  }
  return charter;
}

function loadCharter(home, project) {
  const file = path.join(home, "data", "goals", `${project}.md`);
  if (!existsSync(file)) return null;
  const charter = parseCharter(readFileSync(file, "utf8"));
  return charter.goals.length > 0 || charter.endState ? charter : null;
}

// --- derivation -------------------------------------------------------------

function normalizeRepo(repo) {
  if (blank(repo)) return "";
  return repo.replace(/\/+$/, "").split("/").filter(Boolean).at(-1) || "";
}

// A task names its project in whatever form the worker recorded: the registry
// name, a remote slug, or an absolute checkout path. Each registered project
// claims its own name, the basename of every remote in its registry line, and
// any extra name its charter declares.
function projectIndex(projects, charters) {
  const index = new Map();
  // A project's own registered name always wins, so a sibling whose remote
  // happens to share that basename cannot claim its work.
  for (const project of projects) index.set(project.name.toLowerCase(), project.name);
  for (const project of projects) {
    const aliases = [
      ...project.remotes,
      ...(charters.get(project.name)?.aliases || []),
    ].map((alias) => normalizeRepo(alias).toLowerCase());
    for (const alias of aliases) if (alias && !index.has(alias)) index.set(alias, project.name);
  }
  return index;
}

function projectOf(index, repo) {
  const normalized = normalizeRepo(repo).toLowerCase();
  return (normalized && index.get(normalized)) || "";
}

function goalTokenOf(task) {
  return task.body?.match(/(?:^|\n)\s*goal:\s*([a-z][a-z0-9-]*)\s*(?:\n|$)/i)?.[1]?.toLowerCase() || "";
}

function originOf(task) {
  return task.body?.match(/(?:^|\n)Origin: ([A-Za-z0-9][A-Za-z0-9._-]*)(?:\n|$)/)?.[1] || "";
}

function bucketOf(task) {
  if (task.unreadable) return "unreadable";
  if (task.state === "done") return "shipped";
  if (task.state === "in_flight") return "underway";
  if (task.held === "yes") return task.hold_kind === "captain" ? "decision" : "iced";
  return "next";
}

const STANDING = {
  shipped: "Shipped",
  underway: "Under way",
  next: "Charted next",
  decision: "Your call",
  iced: "On ice",
  unreadable: "Could not be read",
};

function daysSince(date, today) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date || "")) return null;
  const started = Date.parse(`${date}T00:00:00Z`);
  const now = Date.parse(`${today}T00:00:00Z`);
  if (Number.isNaN(started) || Number.isNaN(now)) return null;
  return Math.max(0, Math.round((now - started) / 86400000));
}

function waitedPhrase(days) {
  if (days === null) return "";
  if (days === 0) return "raised today";
  if (days === 1) return "waiting 1 day";
  return `waiting ${days} days`;
}

function unblocksPhrase(count) {
  if (count === 0) return "nothing waiting on it yet";
  return count === 1 ? "unblocks 1 piece of work" : `unblocks ${count} pieces of work`;
}

function reportFor(home, id) {
  const file = path.join(home, "data", id, "report.md");
  if (!existsSync(file)) return null;
  return { id, file, updated: statSync(file).mtime.toISOString().slice(0, 10) };
}

// The captain's calendar day, not UTC: backlog dates are written in local time,
// so a UTC "today" would report work as a day older than he filed it.
function today() {
  const now = new Date();
  const local = new Date(now.getTime() - now.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

// A record whose own title is missing still has to be actionable, so its
// identity is the name of last resort. No row can render without one.
function named(id, ...candidates) {
  return candidates.find((candidate) => !blank(candidate)) || id;
}

// One derived model per request. Everything the routes render is computed here,
// so the page, the goal map, and a node overlay can never disagree with each other.
export function buildModel({ home, tasks, projects, meta, archive, charters }) {
  const now = today();
  const index = projectIndex(projects, charters);
  const dependents = new Map();
  for (const task of tasks) {
    for (const blocker of splitList(task.blocked_by)) {
      if (!dependents.has(blocker)) dependents.set(blocker, []);
      dependents.get(blocker).push({ id: task.id, title: task.title });
    }
  }

  const seen = new Set(tasks.map((task) => task.id));
  const items = [];
  for (const task of tasks) {
    const fields = meta.get(task.id) || {};
    const bucket = bucketOf(task);
    const origin = originOf(task);
    items.push({
      id: task.id,
      title: named(task.id, fields.outcome, task.title),
      backlogTitle: named(task.id, task.title),
      project: projectOf(index, task.repo),
      repo: blank(task.repo) ? "" : task.repo,
      bucket,
      standing: STANDING[bucket],
      isScout: task.kind === "scout",
      reason: blank(task.hold_reason) ? "" : task.hold_reason,
      until: blank(task.hold_until) ? "" : task.hold_until,
      note: blank(task.body) ? "" : task.body,
      goal: goalTokenOf(task),
      created: blank(task.created) ? "" : task.created,
      closed: blank(task.closed) ? "" : task.closed,
      waitingDays: daysSince(task.created, now),
      dependents: dependents.get(task.id) || [],
      waitingOn: splitList(task.blocked_by).filter((id) => seen.has(id)),
      origin,
      report: reportFor(home, task.id),
      originReport: origin ? reportFor(home, origin) : null,
      pr: fields.pr && /^https:\/\//.test(fields.pr) ? fields.pr : "",
      archived: false,
    });
  }

  for (const entry of archive) {
    if (seen.has(entry.id)) continue;
    seen.add(entry.id);
    items.push({
      id: entry.id,
      title: named(entry.id, entry.title),
      backlogTitle: named(entry.id, entry.title),
      project: projectOf(index, entry.repo),
      repo: entry.repo,
      bucket: "shipped",
      standing: STANDING.shipped,
      isScout: entry.kind === "scout",
      reason: "",
      until: "",
      note: "",
      goal: "",
      created: "",
      closed: entry.closed,
      waitingDays: null,
      dependents: [],
      waitingOn: [],
      origin: "",
      report: reportFor(home, entry.id),
      originReport: null,
      pr: [(meta.get(entry.id) || {}).pr, entry.pr].find((link) => /^https:\/\//.test(link || "")) || "",
      archived: true,
    });
  }

  const byProject = new Map(projects.map((project) => [project.name, []]));
  const unregistered = [];
  // A record that could not be read names no project, so it always lands here
  // rather than under one: this bucket is the single place it surfaces.
  for (const item of items) {
    if (item.project && byProject.has(item.project)) byProject.get(item.project).push(item);
    else unregistered.push(item);
  }

  const decisionOrder = (left, right) =>
    right.dependents.length - left.dependents.length ||
    (right.waitingDays ?? 0) - (left.waitingDays ?? 0) ||
    left.id.localeCompare(right.id);

  const built = projects.map((project) => {
    const owned = byProject.get(project.name) || [];
    const charter = charters.get(project.name) || null;
    return {
      name: project.name,
      label: charter?.title || titleCase(project.name),
      description: project.description,
      charter,
      items: owned,
      decisions: owned.filter((item) => item.bucket === "decision").sort(decisionOrder),
      counts: countBuckets(owned),
      lanes: charter ? lanesFor(charter, owned) : null,
    };
  });

  return {
    home,
    generated: new Date().toISOString(),
    date: now,
    projects: built,
    unregistered: { items: unregistered, counts: countBuckets(unregistered) },
    decisions: items.filter((item) => item.bucket === "decision").sort(decisionOrder),
    iced: items.filter((item) => item.bucket === "iced"),
    unreadable: items.filter((item) => item.bucket === "unreadable"),
    byId: new Map(items.map((item) => [item.id, item])),
  };
}

function titleCase(name) {
  return name.split(/[-_]/).filter(Boolean).map((word) => word[0].toUpperCase() + word.slice(1)).join(" ");
}

function countBuckets(items) {
  const counts = { shipped: 0, underway: 0, next: 0, decision: 0, iced: 0, unreadable: 0 };
  for (const item of items) counts[item.bucket] += 1;
  return counts;
}

// A charter "Covers:" entry is either an exact identity or a trailing-* family,
// which is how work filed before a chart existed reaches its goal without anyone
// editing the backlog to add a token to it after the fact. Naming one piece of
// work outright always beats a family that happens to include it, so a single
// exception needs no rewrite of the family it sits in.
function coversExact(goal, id) {
  return goal.covers.includes(id);
}

function coversFamily(goal, id) {
  return goal.covers.some((pattern) => pattern.endsWith("*") && id.startsWith(pattern.slice(0, -1)));
}

// Charter goals become lanes. A task's own goal token wins; otherwise the
// charter's own mapping is consulted; anything still unclaimed lands in the
// trailing "Other work" lane, so nothing can hide by being untagged.
function lanesFor(charter, items) {
  const known = new Set(charter.goals.map((goal) => goal.id));
  const assign = (item) => {
    if (item.goal && known.has(item.goal)) return item.goal;
    const exact = charter.goals.find((goal) => coversExact(goal, item.id));
    return (exact || charter.goals.find((goal) => coversFamily(goal, item.id)))?.id || "";
  };
  const assigned = new Map(items.map((item) => [item.id, assign(item)]));
  const lanes = charter.goals.map((goal) => ({
    id: goal.id,
    title: goal.title,
    onIce: goal.onIce,
    planned: goal.planned,
    items: items.filter((item) => assigned.get(item.id) === goal.id),
    other: false,
  }));
  const unmapped = items.filter((item) => !assigned.get(item.id));
  if (unmapped.length > 0) {
    lanes.push({
      id: "other",
      title: "Other work",
      onIce: "",
      planned: [],
      items: unmapped,
      other: true,
    });
  }
  for (const lane of lanes) {
    lane.counts = countBuckets(lane.items);
    const total = lane.items.length + lane.planned.length;
    lane.progress = total === 0 ? 0 : Math.round((lane.counts.shipped / total) * 100);
    lane.total = total;
  }
  return lanes;
}

export async function loadModel(home) {
  const projects = loadRegistry(home);
  const charters = new Map();
  for (const project of projects) {
    const charter = loadCharter(home, project.name);
    if (charter) charters.set(project.name, charter);
  }
  const tasks = await loadTasks(home);
  return buildModel({ home, tasks, projects, meta: loadMeta(home), archive: loadArchive(home), charters });
}

// --- rendering --------------------------------------------------------------

// Cards carry the headline; the full recorded text is one click away in the
// detail view, so a long note never has to be shortened before it is stored.
function clamp(value, limit) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  if (text.length <= limit) return text;
  const cut = text.slice(0, limit);
  const space = cut.lastIndexOf(" ");
  return `${(space > limit * 0.6 ? cut.slice(0, space) : cut).replace(/[,;:.\s]+$/, "")}…`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const CSS = `
:root{--paper:#f6f1e6;--paper-deep:#efe7d5;--ink:#1d2733;--ink-soft:#5a6675;--line:#d8cdb4;--teal:#0e7c86;--teal-soft:#e3f0f1;--gold:#9a7b2d;--signal:#b33a3a;--signal-soft:#f7e8e6;--done:#4a7c59}
*{box-sizing:border-box}html,body{margin:0;padding:0}
body{background:var(--paper);color:var(--ink);font:15px/1.55 -apple-system,"SF Pro Text","Segoe UI",sans-serif;min-height:100vh}
a{color:inherit}
header{display:flex;align-items:baseline;gap:18px;flex-wrap:wrap;padding:18px 28px 12px;border-bottom:2px solid var(--ink)}
header h1{font:700 21px/1.34 Georgia,"Times New Roman",serif;letter-spacing:.12em;text-transform:uppercase;margin:0;padding-bottom:3px}
header h1 a{text-decoration:none}header h1 .anchor{color:var(--gold)}
nav.projects{display:flex;gap:4px;flex-wrap:wrap;margin-left:auto}
nav.projects a{text-decoration:none;color:var(--ink-soft);padding:5px 12px;border-radius:16px;font-size:13.5px;border:1px solid transparent}
nav.projects a.active{color:var(--paper);background:var(--ink);font-weight:600}
nav.projects a:not(.active):hover{border-color:var(--line);background:var(--paper-deep)}
nav.projects a .n{display:inline-block;min-width:17px;text-align:center;background:var(--signal);color:#fff;border-radius:9px;font-size:11px;font-weight:700;margin-left:5px;padding:0 4px}
section.call{padding:16px 28px 6px}
.call-head{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;font:700 13px/1.34 Georgia,serif;letter-spacing:.14em;text-transform:uppercase;color:var(--signal);padding-bottom:8px}
.call-head .sub{font:400 13px/1.4 -apple-system,sans-serif;color:var(--ink-soft);letter-spacing:0;text-transform:none}
.decisions{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(300px,100%),1fr));gap:10px}
.decision{background:var(--signal-soft);border:1px solid #e4c8c2;border-left:4px solid var(--signal);border-radius:8px;padding:12px 14px;cursor:pointer;display:flex;flex-direction:column;gap:6px;min-width:0;text-align:left;font:inherit;color:inherit;width:100%}
.decision:hover{box-shadow:0 2px 8px rgba(29,39,51,.10)}
.decision .q{font-weight:650;line-height:1.4;overflow-wrap:anywhere}
.decision .why{color:var(--ink-soft);font-size:13.5px;overflow-wrap:anywhere}
.decision .meta{display:flex;gap:12px;flex-wrap:wrap;font-size:12.5px;color:var(--signal);font-weight:600}
main{padding:20px 28px 8px}
.map-title{font:700 15px/1.34 Georgia,serif;letter-spacing:.14em;text-transform:uppercase;padding-bottom:4px}
.map-sub{color:var(--ink-soft);font-size:13.5px;margin-bottom:16px;overflow-wrap:anywhere}
.draft{margin:0 0 16px;background:#fffdf7;border:1px dashed var(--gold);border-radius:8px;padding:10px 14px;color:var(--gold);font-weight:600;font-size:13.5px}
.lanes{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(280px,100%),1fr));gap:14px;align-items:start}
.lane{background:#fffdf7;border:1px solid var(--line);border-radius:10px;padding:14px 14px 10px;min-width:0}
.lane.iced{background:var(--paper-deep);opacity:.9}
.lane.other{border-style:dashed}
.lane-head h2{font:650 16.5px/1.34 Georgia,serif;margin:0;padding-bottom:3px;overflow-wrap:anywhere}
.lane-progress{margin:6px 0 4px;height:6px;border-radius:3px;background:var(--paper-deep);overflow:hidden}
.lane-progress i{display:block;height:100%;background:var(--done);border-radius:3px}
.lane-count{font-size:12px;color:var(--ink-soft);margin-bottom:10px}
.iced-note{font-size:12.5px;color:var(--ink-soft);background:#fff;border:1px dashed var(--line);border-radius:6px;padding:6px 9px;margin-bottom:10px;overflow-wrap:anywhere}
.bucket{margin-bottom:10px}
.bucket h3{font:700 11.5px/1.4 -apple-system,sans-serif;letter-spacing:.1em;text-transform:uppercase;margin:0 0 5px;color:var(--ink-soft)}
.bucket.done h3{color:var(--done)}.bucket.underway h3{color:var(--teal)}
ul.items{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:4px}
ul.items li{display:flex;gap:8px;align-items:baseline;padding:5px 8px;border-radius:6px;min-width:0}
ul.items li.clickable{cursor:pointer}ul.items li.clickable:hover{background:var(--paper-deep)}
ul.items li .dot{flex:0 0 auto;font-size:12px}
ul.items li .t{min-width:0;overflow-wrap:anywhere}
ul.items li .state{margin-left:auto;flex:0 0 auto;font-size:11.5px;font-weight:700;letter-spacing:.05em}
li.done-i{color:var(--ink-soft)}li.done-i .dot{color:var(--done)}
li.underway-i{background:var(--teal-soft)}li.underway-i:hover{background:#d5e8ea}li.underway-i .dot,li.underway-i .state{color:var(--teal)}
li.next-i{color:var(--ink)}li.next-i .dot{color:var(--ink-soft)}
li.planned-i{color:var(--ink-soft);font-style:italic}li.planned-i .dot{color:var(--line)}
li.gate-i{background:var(--signal-soft);font-weight:600}li.gate-i .dot,li.gate-i .state{color:var(--signal)}
li.iced-i{color:var(--ink-soft)}li.iced-i .dot{color:var(--ink-soft)}
li.unreadable-i{background:var(--signal-soft);border:1px dashed #e4c8c2}li.unreadable-i .dot,li.unreadable-i .state{color:var(--signal)}
.more{font-size:12.5px;color:var(--teal);padding:4px 8px;cursor:pointer;font-weight:600}
.more:hover{text-decoration:underline}
ul.items li.folded{display:none}
.bucket.open ul.items li.folded{display:flex}
.rows{display:flex;flex-direction:column;gap:10px}
.row{display:block;text-decoration:none;border:1px solid var(--line);border-radius:10px;background:#fffdf7;padding:14px 16px;min-width:0}
.row:hover{background:var(--paper-deep)}
.row h2{font:650 17px/1.34 Georgia,serif;margin:0 0 3px;overflow-wrap:anywhere}
.row .stands{color:var(--ink-soft);font-size:13.5px;overflow-wrap:anywhere}
.row .tally{display:flex;gap:14px;flex-wrap:wrap;margin-top:8px;font-size:12.5px;color:var(--ink-soft)}
.row .tally b{font-weight:700;color:var(--ink)}
.row .tally .yours{color:var(--signal)}
section.port{margin:22px 28px 26px}
.port-inner{border:2px solid var(--ink);border-radius:10px;background:#fffdf7;padding:14px 20px;display:flex;gap:16px;align-items:baseline;flex-wrap:wrap}
.port-label{font:700 12px/1.4 Georgia,serif;letter-spacing:.16em;text-transform:uppercase;color:var(--gold);flex:0 0 auto}
.port-text{font:400 16px/1.5 Georgia,serif;min-width:0;overflow-wrap:anywhere}
footer{padding:0 28px 24px;color:var(--ink-soft);font-size:12.5px}
.backdrop{position:fixed;inset:0;background:rgba(29,39,51,.45);display:none;align-items:center;justify-content:center;padding:24px;z-index:10}
.backdrop.open{display:flex}
.sheet{background:var(--paper);border-radius:12px;max-width:600px;width:100%;max-height:85vh;overflow:auto;box-shadow:0 12px 40px rgba(0,0,0,.35);border-top:6px solid var(--teal)}
.sheet.kind-decision{border-top-color:var(--signal)}
.sheet-pad{padding:20px 24px 22px}
.detail h2{font:650 19px/1.34 Georgia,serif;margin:0 0 4px;padding-bottom:3px;overflow-wrap:anywhere}
.detail .kind{font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--teal)}
.detail.is-decision .kind{color:var(--signal)}
.detail p{margin:10px 0;overflow-wrap:anywhere}
.detail .links{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}
.detail .links a{text-decoration:none;font-size:13.5px;padding:7px 13px;border-radius:7px;border:1px solid var(--line);background:#fffdf7}
.detail .links a:hover{background:var(--paper-deep)}
.detail .note{font-size:12.5px;color:var(--ink-soft);margin-top:14px}
.sheet-pad .close{float:right;border:0;background:none;font-size:20px;cursor:pointer;color:var(--ink-soft);padding:4px 8px}
.standalone{max-width:640px;margin:24px auto;padding:0 24px}
.report{padding:8px 28px 40px}
.report main{padding:0}
.empty{color:var(--ink-soft);padding:6px 0}
@media(max-width:640px){header,section.call,main,footer{padding-left:16px;padding-right:16px}section.port{margin-left:16px;margin-right:16px}}
`;

// Compass rose on parchment: gold north-south, teal east-west. Three chart-room
// colors, geometric so the mark stays crisp at 16x16 on a dark browser tab.
const FAVICON_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="3" fill="#efe7d5"/><path fill="#9a7b2d" d="M8 1.5 9.4 8 8 14.5 6.6 8Z"/><path fill="#0e7c86" d="M1.5 8 8 6.6 14.5 8 8 9.4Z"/><circle cx="8" cy="8" r="1.25" fill="#efe7d5"/></svg>`;
const FAVICON_HREF = `data:image/svg+xml,${encodeURIComponent(FAVICON_SVG)}`;

function shell({ title, body, nav = "", script = "" }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<link rel="icon" type="image/svg+xml" href="${FAVICON_HREF}">
<style>${CSS}</style>
</head>
<body>
<header>
  <h1><a href="/"><span class="anchor">&#9875;</span> The Chart Room</a></h1>
  ${nav}
</header>
${body}
<footer>Read straight from the live records the moment you asked for this page - nothing here is a saved copy.</footer>
${script}
</body>
</html>
`;
}

function navMarkup(model, active) {
  const links = model.projects.map((project) => {
    const yours = project.counts.decision;
    const badge = yours > 0 ? `<span class="n">${yours}</span>` : "";
    const current = project.name === active ? ' class="active"' : "";
    return `<a${current} href="/p/${encodeURIComponent(project.name)}">${escapeHtml(project.label)} ${badge}</a>`;
  });
  return `<nav class="projects">${links.join("")}</nav>`;
}

function decisionCard(item) {
  const why = item.reason || plainNote(item) || "No background was recorded with this one.";
  const parts = [waitedPhrase(item.waitingDays), unblocksPhrase(item.dependents.length)].filter(Boolean);
  return `<button class="decision" type="button" data-node="${escapeHtml(item.id)}" data-project="${escapeHtml(item.project)}">
      <span class="q">${escapeHtml(clamp(item.title, 130))}</span>
      <span class="why">${escapeHtml(clamp(why, 220))}</span>
      <span class="meta">${parts.map((part) => `<span>${escapeHtml(part)}</span>`).join("")}</span>
    </button>`;
}

// The home strip shows the ones an answer would move furthest; the rest are on
// their own project pages in full, so a long queue is never silently truncated.
function callSection(decisions, subtitle, limit = 0) {
  if (decisions.length === 0) {
    return `<section class="call"><div class="call-head">Captain&#8217;s call <span class="sub">nothing is waiting on you here.</span></div></section>`;
  }
  const shown = limit > 0 && decisions.length > limit ? decisions.slice(0, limit) : decisions;
  const rest = decisions.length - shown.length;
  const more = rest > 0
    ? `<div class="map-sub" style="margin-top:10px">The ${rest} further answer${rest === 1 ? "" : "s"} you owe sit on their own project pages, in full.</div>`
    : "";
  return `<section class="call">
    <div class="call-head">Captain&#8217;s call <span class="sub">${escapeHtml(subtitle)}</span></div>
    <div class="decisions">${shown.map(decisionCard).join("")}</div>
    ${more}
  </section>`;
}

function standsPhrase(project) {
  const { counts } = project;
  const parts = [];
  if (counts.underway > 0) parts.push(counts.underway === 1 ? "1 piece of work under way" : `${counts.underway} pieces of work under way`);
  if (counts.decision > 0) parts.push(counts.decision === 1 ? "1 answer wanted from you" : `${counts.decision} answers wanted from you`);
  if (counts.next > 0) parts.push(`${counts.next} charted next`);
  if (counts.iced > 0) parts.push(`${counts.iced} on ice`);
  if (parts.length === 0) return counts.shipped > 0 ? "All quiet - everything filed here is finished." : "Nothing filed here yet.";
  return `${parts.join(", ")}.`;
}

function homePage(model) {
  const subtitle = model.decisions.length === 1
    ? "one answer would move the fleet forward."
    : `${model.decisions.length} answers would move the fleet forward.`;
  const rows = model.projects.map((project) => `<a class="row" href="/p/${encodeURIComponent(project.name)}">
      <h2>${escapeHtml(project.label)}</h2>
      <div class="stands">${escapeHtml(standsPhrase(project))}</div>
      <div class="tally">
        <span><b>${project.counts.shipped}</b> shipped</span>
        <span><b>${project.counts.underway}</b> under way</span>
        <span><b>${project.counts.next}</b> charted next</span>
        <span class="yours"><b>${project.counts.decision}</b> your call</span>
        <span><b>${project.counts.iced}</b> on ice</span>
      </div>
    </a>`).join("");

  const strays = model.unregistered.items.length > 0
    ? `<div class="map-title" style="margin-top:26px">Not filed under a project</div>
       <div class="map-sub">${model.unregistered.items.length} piece${model.unregistered.items.length === 1 ? "" : "s"} of work whose project could not be matched. Shown so nothing hides.</div>
       <ul class="items">${model.unregistered.items.map((item) => itemRow(item, "")).join("")}</ul>`
    : "";

  const unreadableNote = model.unreadable.length > 0
    ? `<div class="map-sub" style="margin-top:18px">${model.unreadable.length} piece${model.unreadable.length === 1 ? " of work could not be read" : "s of work could not be read"} from the records just now, so ${model.unreadable.length === 1 ? "it is listed" : "they are listed"} by name only rather than left out.</div>`
    : "";

  const icedNote = model.iced.length > 0
    ? `<div class="map-sub" style="margin-top:18px">${model.iced.length} further piece${model.iced.length === 1 ? " is" : "s are"} on ice with a reason - they keep their place inside each project.</div>`
    : "";

  return shell({
    title: "The Chart Room",
    nav: navMarkup(model, ""),
    body: `${callSection(model.decisions, subtitle, 8)}
<main>
  <div class="map-title">Where each project stands</div>
  <div class="map-sub">Read from the live records on ${escapeHtml(model.date)}. Open a project for its goal map.</div>
  <div class="rows">${rows}</div>
  ${icedNote}
  ${unreadableNote}
  ${strays}
</main>
${overlayMarkup()}`,
    script: overlayScript(),
  });
}

const DOTS = { shipped: "&#10004;", underway: "&#9679;", next: "&#9675;", decision: "&#9873;", iced: "&#10073;&#10073;", unreadable: "&#9888;" };
const ROW_CLASS = { shipped: "done-i", underway: "underway-i", next: "next-i", decision: "gate-i", iced: "iced-i", unreadable: "unreadable-i" };

function itemRow(item, project, folded = false) {
  const state = item.bucket === "underway"
    ? `<span class="state">${item.isScout ? "DIGGING" : "WORKING"}</span>`
    : item.bucket === "decision" ? '<span class="state">YOURS</span>'
      : item.bucket === "unreadable" ? '<span class="state">UNREADABLE</span>' : "";
  return `<li class="${ROW_CLASS[item.bucket]} clickable${folded ? " folded" : ""}" role="button" tabindex="0" data-node="${escapeHtml(item.id)}" data-project="${escapeHtml(project)}"><span class="dot">${DOTS[item.bucket]}</span><span class="t">${escapeHtml(clamp(item.title, 110))}</span>${state}</li>`;
}

// Long buckets are folded, never truncated: every row is rendered and the extras
// are only hidden, so the "more" row opens them in place instead of being a
// label that leads nowhere.
function bucketBlock(label, cssClass, items, project, limit) {
  if (items.length === 0) return "";
  const folded = limit > 0 && items.length > limit;
  const rows = items.map((item, position) => itemRow(item, project, folded && position >= limit));
  const rest = items.length - limit;
  const more = folded
    ? `<li class="more" role="button" tabindex="0" data-expand="1" data-fewer="Show fewer">&#8230;show ${rest} more ${label.toLowerCase()}</li>`
    : "";
  const heading = label === "Shipped" ? `Shipped &#183; ${items.length}` : label;
  return `<div class="bucket ${cssClass}"><h3>${heading}</h3><ul class="items">${rows.join("")}${more}</ul></div>`;
}

// A goal is a node in its own right, so its heading and its planned rows open a
// detail like any card does rather than being the one thing that does not react.
function goalNodeId(lane) {
  return `goal:${lane.id}`;
}

function goalDetailMarkup(lane) {
  const tally = [
    [lane.counts.shipped, "shipped"],
    [lane.counts.underway, "under way"],
    [lane.counts.next, "charted next"],
    [lane.counts.decision, "waiting on your answer"],
    [lane.counts.iced, "on ice"],
  ].filter(([count]) => count > 0).map(([count, label]) => `${count} ${label}`);
  const paragraphs = [];
  if (lane.other) {
    paragraphs.push("<p>Work filed under this project that no goal on the chart claims yet. It is shown here rather than hidden, so the chart can be corrected instead of quietly disagreeing with the records.</p>");
  }
  if (lane.onIce) paragraphs.push(`<p><b>On ice:</b> ${escapeHtml(lane.onIce)} Everything under it keeps its place.</p>`);
  paragraphs.push(`<p><b>Where it stands:</b> ${tally.length > 0 ? escapeHtml(tally.join(", ")) : "nothing filed under it yet"}.</p>`);
  if (lane.planned.length > 0) {
    paragraphs.push(`<p><b>Planned, not yet filed as work:</b></p><ul>${lane.planned.map((entry) => `<li>${escapeHtml(entry)}</li>`).join("")}</ul>`);
    paragraphs.push('<p class="note">Planned lines are intent recorded on the chart, not work under way. Say the word and any of them becomes real work.</p>');
  }
  return `<div class="detail">
    <div class="kind">Goal</div>
    <h2>${escapeHtml(lane.title)}</h2>
    ${paragraphs.join("")}
  </div>`;
}

function laneMarkup(lane, project) {
  const shipped = lane.items.filter((item) => item.bucket === "shipped");
  const underway = lane.items.filter((item) => item.bucket === "underway");
  const next = lane.items.filter((item) => item.bucket === "next");
  const decisions = lane.items.filter((item) => item.bucket === "decision");
  const iced = lane.items.filter((item) => item.bucket === "iced");
  const node = `data-node="${escapeHtml(goalNodeId(lane))}" data-project="${escapeHtml(project)}"`;
  const planned = lane.planned.length > 0
    ? `<ul class="items">${lane.planned.map((entry) => `<li class="planned-i clickable" role="button" tabindex="0" ${node}><span class="dot">&#9676;</span><span class="t">Planned: ${escapeHtml(entry)}</span></li>`).join("")}</ul>`
    : "";
  const iceNote = lane.onIce
    ? `<div class="iced-note">&#10073;&#10073; On ice: ${escapeHtml(lane.onIce)} Everything here keeps its place.</div>`
    : "";
  const nextBlock = [
    bucketBlock(lane.onIce ? "Waiting with the ice" : "Charted next", "", next, project, 8),
    decisions.length > 0 ? `<div class="bucket"><h3>Your call</h3><ul class="items">${decisions.map((item) => itemRow(item, project)).join("")}</ul></div>` : "",
    iced.length > 0 ? bucketBlock("On ice", "", iced, project, 8) : "",
    planned ? `<div class="bucket"><h3>Planned, not yet filed</h3>${planned}</div>` : "",
  ].join("");
  const body = shipped.length + underway.length + next.length + decisions.length + iced.length + lane.planned.length === 0
    ? '<div class="empty">Nothing filed under this goal yet.</div>'
    : `${bucketBlock("Shipped", "done", shipped, project, 3)}${bucketBlock("Under way", "underway", underway, project, 8)}${nextBlock}`;
  return `<div class="lane${lane.onIce ? " iced" : ""}${lane.other ? " other" : ""}">
    <div class="lane-head clickable" role="button" tabindex="0" ${node}><h2>${escapeHtml(lane.title)}</h2></div>
    <div class="lane-progress"><i style="width:${lane.progress}%"></i></div>
    <div class="lane-count">${lane.counts.shipped} of ${lane.total} done</div>
    ${iceNote}
    ${body}
  </div>`;
}

function flatProjectMarkup(project) {
  const buckets = [
    bucketBlock("Under way", "underway", project.items.filter((item) => item.bucket === "underway"), project.name, 0),
    bucketBlock("Charted next", "", project.items.filter((item) => item.bucket === "next"), project.name, 0),
    bucketBlock("On ice", "", project.items.filter((item) => item.bucket === "iced"), project.name, 0),
    bucketBlock("Shipped", "done", project.items.filter((item) => item.bucket === "shipped"), project.name, 8),
  ].join("");
  return `<div class="lanes"><div class="lane">${buckets || '<div class="empty">Nothing is filed under this project yet.</div>'}</div></div>`;
}

function projectPage(model, project) {
  const subtitle = project.decisions.length === 1
    ? `one answer would move ${project.label} forward.`
    : `${project.decisions.length} answers would move ${project.label} forward.`;
  const draft = project.charter?.draft
    ? '<div class="draft">Proposed chart - drafted from the record and waiting for your approval. Say the word and it becomes the real one; say what is wrong and it gets redrawn.</div>'
    : "";
  const map = project.lanes
    ? `<div class="lanes">${project.lanes.map((lane) => laneMarkup(lane, project.name)).join("")}</div>`
    : flatProjectMarkup(project);
  const sub = project.lanes
    ? "Every card comes from the live records - click anything for the story behind it."
    : `${escapeHtml(project.description)} No chart has been drawn for this one yet, so the work is listed as it stands.`;
  const port = project.charter?.endState
    ? `<section class="port"><div class="port-inner"><div class="port-label">&#8982; Port of arrival</div><div class="port-text">${escapeHtml(project.charter.endState)}</div></div></section>`
    : "";
  return shell({
    title: `The Chart Room - ${project.label}`,
    nav: navMarkup(model, project.name),
    body: `${callSection(project.decisions, subtitle)}
<main>
  <div class="map-title">${project.lanes ? "Goal map" : "The work"}</div>
  <div class="map-sub">${sub}</div>
  ${draft}
  ${map}
</main>
${port}
${overlayMarkup()}`,
    script: overlayScript(),
  });
}

function plainState(item) {
  if (item.bucket === "unreadable") {
    return "Its record could not be read just now, so where it stands is unknown. It is shown here rather than dropped, so the chart never quietly disagrees with the records.";
  }
  if (item.bucket === "shipped") return item.isScout ? "Finished - the findings are written up." : "Shipped.";
  if (item.bucket === "underway") return item.isScout ? "Being investigated right now." : "Being built right now.";
  if (item.bucket === "decision") return "Waiting on your answer.";
  if (item.bucket === "iced") return "On ice, with its place kept.";
  return "Charted next - not started.";
}

// A note carries bookkeeping lines alongside its prose - the identity of the
// investigation it came from, the goal token, the resolution stamp. The link and
// the lane already say all of that, so only the prose is worth reading here.
const BOOKKEEPING = /^(?:origin|decision key|decision digest|state|routed identities|goal|resolution recorded|captain decision)\b\s*:?/i;

function plainNote(item) {
  return item.note
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !BOOKKEEPING.test(line))
    .join(" ");
}

function detailMarkup(model, item) {
  const links = [];
  if (item.report) links.push(`<a href="/report/${encodeURIComponent(item.id)}">Read the full story</a>`);
  if (item.originReport) links.push(`<a href="/report/${encodeURIComponent(item.origin)}">Read the evidence behind it</a>`);
  if (item.pr) links.push(`<a href="${escapeHtml(item.pr)}" rel="noreferrer">See the change on GitHub</a>`);
  const paragraphs = [`<p><b>Where it stands:</b> ${escapeHtml(plainState(item))}</p>`];
  if (item.reason) paragraphs.push(`<p>${escapeHtml(item.reason)}</p>`);
  if (item.until) paragraphs.push(`<p>Comes back around ${escapeHtml(item.until)}.</p>`);
  const note = plainNote(item);
  if (note && note !== item.reason) paragraphs.push(`<p>${escapeHtml(clamp(note, 900))}</p>`);
  if (item.dependents.length > 0) {
    paragraphs.push(`<p><b>${unblocksPhrase(item.dependents.length)}:</b> ${item.dependents.map((dependent) => escapeHtml(model.byId.get(dependent.id)?.title || dependent.title)).join("; ")}.</p>`);
  }
  if (item.waitingOn.length > 0) {
    paragraphs.push(`<p><b>Waiting on:</b> ${item.waitingOn.map((id) => escapeHtml(model.byId.get(id)?.title || id)).join("; ")}.</p>`);
  }
  if (item.originReport) {
    paragraphs.push(`<p class="note">The evidence this rests on was last written on ${escapeHtml(item.originReport.updated)} - worth a glance before you answer if that feels long ago.</p>`);
  }
  const answer = item.bucket === "decision"
    ? '<p class="note">Answer it on the decisions page or just say it in chat - both land in the same records, and the waiting work starts on its own.</p>'
    : "";
  return `<div class="detail${item.bucket === "decision" ? " is-decision" : ""}">
    <div class="kind">${item.bucket === "decision" ? "Your call" : "Work"}</div>
    <h2>${escapeHtml(item.title)}</h2>
    ${paragraphs.join("")}
    ${links.length > 0 ? `<div class="links">${links.join("")}</div>` : ""}
    ${answer}
  </div>`;
}

function overlayMarkup() {
  return `<div class="backdrop" id="backdrop"><div class="sheet" id="sheet"><div class="sheet-pad" id="sheet-content"></div></div></div>`;
}

// The overlay fetches its content when it is opened rather than carrying a copy
// of every card, so what the captain reads is as fresh as the click.
function overlayScript() {
  return `<script>
(function () {
  var backdrop = document.getElementById("backdrop");
  var content = document.getElementById("sheet-content");
  function close() { backdrop.classList.remove("open"); }
  function open(project, node) {
    var url = "/p/" + encodeURIComponent(project || "-") + "/node/" + encodeURIComponent(node) + "?fragment=1";
    content.innerHTML = "<p>Reading the record\\u2026</p>";
    backdrop.classList.add("open");
    fetch(url, { cache: "no-store" }).then(function (response) {
      if (!response.ok) throw new Error("unavailable");
      return response.text();
    }).then(function (html) {
      content.innerHTML = '<button class="close" type="button" data-close="1">\\u2715</button>' + html;
    }).catch(function () { window.location.href = url.replace("?fragment=1", ""); });
  }
  function expand(row) {
    var bucket = row.closest(".bucket");
    if (!bucket) return;
    bucket.classList.toggle("open");
    var previous = row.textContent;
    row.textContent = row.dataset.fewer;
    row.dataset.fewer = previous;
  }
  function act(event) {
    if (event.target.closest("[data-close]")) { close(); return; }
    if (event.target === backdrop) { close(); return; }
    var row = event.target.closest("[data-expand]");
    if (row) { event.preventDefault(); expand(row); return; }
    var trigger = event.target.closest("[data-node]");
    if (trigger) { event.preventDefault(); open(trigger.dataset.project, trigger.dataset.node); }
  }
  document.addEventListener("click", act);
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") { close(); return; }
    if ((event.key === "Enter" || event.key === " ") && event.target.closest("[data-expand],[data-node]")) act(event);
  });
})();
</script>`;
}

function nodeShell(model, project, title, detail) {
  return shell({
    title: `The Chart Room - ${title}`,
    nav: navMarkup(model, project),
    body: `<main class="standalone">${detail}<p class="note"><a href="${project ? `/p/${encodeURIComponent(project)}` : "/"}">Back to the chart</a></p></main>`,
  });
}

function reportPage(model, id, file) {
  return shell({
    title: `The Chart Room - ${id}`,
    nav: navMarkup(model, ""),
    body: `<div class="report"><main>${renderMarkdown(readFileSync(file, "utf8"))}</main></div>`,
  });
}

function notFoundPage(model, message) {
  return shell({
    title: "The Chart Room - not here",
    nav: navMarkup(model, ""),
    body: `<main class="standalone"><div class="detail"><h2>Nothing at that address</h2><p>${escapeHtml(message)}</p><div class="links"><a href="/">Back to the chart room</a></div></div></main>`,
  });
}

// --- routing ----------------------------------------------------------------

export function renderRoute(model, rawPath, query = {}) {
  let segments;
  try {
    segments = rawPath.split("/").filter(Boolean).map(decodeURIComponent);
  } catch {
    return { status: 404, body: notFoundPage(model, "The chart room has no view at that address.") };
  }
  if (segments.length === 0) return { status: 200, body: homePage(model) };

  if (segments[0] === "report" && segments.length === 2) {
    const id = segments[1];
    if (!ID_PATTERN.test(id)) return { status: 404, body: notFoundPage(model, "That is not a record this fleet keeps.") };
    const report = model.byId.get(id)?.report || reportFor(model.home, id);
    if (!report) return { status: 404, body: notFoundPage(model, "There is no written-up story for that piece of work.") };
    return { status: 200, body: reportPage(model, id, report.file) };
  }

  if (segments[0] === "p" && segments.length >= 2) {
    // "-" stands in for a node opened from the fleet home or from work whose
    // project could not be matched, so those cards still open their detail.
    const anyProject = segments[1] === "-";
    const project = anyProject ? null : model.projects.find((candidate) => candidate.name === segments[1]);
    if (!project && !anyProject) return { status: 404, body: notFoundPage(model, "No project of that name is on the register.") };

    if (segments.length === 2 && project) return { status: 200, body: projectPage(model, project) };

    if (segments.length === 4 && segments[2] === "node") {
      const goalId = segments[3].startsWith("goal:") ? segments[3].slice("goal:".length) : "";
      if (goalId) {
        const lane = project?.lanes?.find((candidate) => candidate.id === goalId);
        if (!lane) return { status: 404, body: notFoundPage(model, "No goal of that name is on this chart.") };
        const detail = goalDetailMarkup(lane);
        if (query.fragment === "1") return { status: 200, body: detail, fragment: true };
        return { status: 200, body: nodeShell(model, project.name, lane.title, detail) };
      }
      const item = model.byId.get(segments[3]);
      if (!item) return { status: 404, body: notFoundPage(model, "That piece of work is no longer in the records.") };
      if (query.fragment === "1") return { status: 200, body: detailMarkup(model, item), fragment: true };
      return { status: 200, body: nodeShell(model, project?.name || "", item.title, detailMarkup(model, item)) };
    }
  }

  return { status: 404, body: notFoundPage(model, "The chart room has no view at that address.") };
}

async function serve(home, port) {
  const server = createServer((request, response) => {
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405, { "content-type": "text/plain; charset=utf-8", allow: "GET, HEAD" });
      response.end("the chart room only reads\n");
      return;
    }
    const url = new URL(request.url, `http://${LOOPBACK}`);
    if (url.pathname === "/favicon.ico") {
      response.writeHead(200, {
        "content-type": "image/svg+xml; charset=utf-8",
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
      });
      response.end(request.method === "HEAD" ? undefined : FAVICON_SVG);
      return;
    }
    // Load and derive per request: no cache, so a link followed hours later is
    // still the current record rather than a saved copy of an old one.
    loadModel(home).then((model) => {
      const query = Object.fromEntries(url.searchParams.entries());
      const { status, body } = renderRoute(model, url.pathname, query);
      response.writeHead(status, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store, max-age=0",
        "referrer-policy": "no-referrer",
        "x-content-type-options": "nosniff",
      });
      response.end(request.method === "HEAD" ? undefined : body);
    }).catch((error) => {
      response.writeHead(500, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
      response.end(`the records could not be read: ${error.message}\n`);
    });
  });
  server.on("error", (error) => fail(error.code === "EADDRINUSE" ? `port ${port} is already in use` : error.message));
  await new Promise((resolve) => server.listen(port, LOOPBACK, resolve));
  console.log(`chart room: http://${LOOPBACK}:${port}`);
  console.log("every page is read from the live records when you open it; stop with Ctrl-C");
}

async function main(argv) {
  const args = parseArgs(argv);
  switch (args.command) {
    case "serve": {
      if (!args.home || !args.port) fail("serve requires --home and --port", 2);
      await serve(args.home, Number(args.port));
      break;
    }
    case "render": {
      if (!args.home || !args.path) fail("render requires --home and --path", 2);
      const model = await loadModel(args.home);
      const [routePath, rawQuery] = args.path.split("?");
      const query = Object.fromEntries(new URLSearchParams(rawQuery || "").entries());
      const rendered = renderRoute(model, routePath, query);
      process.stdout.write(rendered.body);
      if (rendered.status !== 200) process.exitCode = 3;
      break;
    }
    case "data": {
      if (!args.home) fail("data requires --home", 2);
      const model = await loadModel(args.home);
      process.stdout.write(`${JSON.stringify({
        schema: "fm-chart-room.v1",
        date: model.date,
        projects: model.projects.map((project) => ({
          name: project.name,
          charter: Boolean(project.charter),
          draft: Boolean(project.charter?.draft),
          counts: project.counts,
          lanes: project.lanes?.map((lane) => ({ id: lane.id, title: lane.title, other: lane.other, onIce: Boolean(lane.onIce), planned: lane.planned.length, items: lane.items.map((item) => item.id) })) || null,
        })),
        decisions: model.decisions.map((item) => ({ id: item.id, project: item.project, unblocks: item.dependents.length, waiting_days: item.waitingDays })),
        iced: model.iced.map((item) => ({ id: item.id, project: item.project, reason: item.reason })),
        unreadable: model.unreadable.map((item) => item.id),
        unregistered: model.unregistered.items.map((item) => item.id),
      }, null, 2)}\n`);
      break;
    }
    default:
      fail(`unknown engine command: ${args.command}`, 2);
  }
}

// Run the commands only when invoked as a command; importing this module for
// buildModel, loadModel, or renderRoute must not consume argv or exit.
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main(process.argv.slice(2));
}
