#!/usr/bin/env node
// Data and rendering engine for fm-decision-surface.sh.
// The shell wrapper owns the operator-facing commands and loopback-only Lavish launch.

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const MARKER = "FM_DECISION_ANSWER_V1:";
const MANIFEST_START = '<script id="fm-decision-data" type="application/json">';
const MANIFEST_END = "</script>";

function fail(message, code = 1) {
  console.error(`fm-decision-surface: ${message}`);
  process.exit(code);
}

function parseArgs(argv) {
  const command = argv.shift() || "";
  const values = { command, apply: false };
  while (argv.length > 0) {
    const name = argv.shift();
    if (name === "--apply") {
      values.apply = true;
      continue;
    }
    if (!name?.startsWith("--")) fail(`unexpected argument: ${name}`, 2);
    if (argv.length === 0) fail(`${name} requires a value`, 2);
    values[name.slice(2).replaceAll("-", "_")] = argv.shift();
  }
  return values;
}

function run(command, args, cwd, extraEnv = {}) {
  const result = spawnSync(command, args, {
    cwd,
    env: { ...process.env, ...extraEnv },
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) fail(`${command} could not run: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || `exit ${result.status}`).trim();
    fail(`${command} ${args.join(" ")} failed: ${detail}`);
  }
  return result.stdout;
}

function parseYamlScalar(value) {
  const trimmed = value.trim();
  if (trimmed.startsWith('"')) {
    try {
      return JSON.parse(trimmed);
    } catch {
      fail(`tasks-axi returned an invalid quoted scalar: ${trimmed}`);
    }
  }
  return trimmed;
}

function parseShow(output) {
  const task = {};
  for (const line of output.split("\n")) {
    const match = line.match(/^  ([a-z_]+): (.*)$/);
    if (match) task[match[1]] = parseYamlScalar(match[2]);
  }
  if (!task.id) fail("tasks-axi show returned no task id");
  return task;
}

function taskShow(home, id) {
  return parseShow(run("tasks-axi", ["show", id, "--full"], home));
}

function taskIdsFromList(output) {
  const countMatch = output.match(/^count: (\d+)$/m);
  if (!countMatch) fail("tasks-axi list returned no count");
  const ids = [];
  for (const line of output.split("\n")) {
    const match = line.match(/^  ([A-Za-z0-9._-]+),/);
    if (match) ids.push(match[1]);
  }
  const count = Number(countMatch[1]);
  if (ids.length !== count) {
    fail(`tasks-axi count ${count} did not match ${ids.length} listed identities`);
  }
  if (new Set(ids).size !== ids.length) fail("tasks-axi listed a duplicate identity");
  return { count, ids };
}

function splitBlockedBy(value) {
  if (!value || value === "none" || value === "-") return [];
  return value.split(",").map((item) => item.trim()).filter(Boolean);
}

function normalizeRepo(repo) {
  if (!repo || repo === "-") return "Unassigned";
  const clean = repo.replace(/\/$/, "");
  return clean.split("/").filter(Boolean).at(-1) || "Unassigned";
}

function sentences(text) {
  return text.match(/[^.!?]+[.!?]?/g)?.map((item) => item.trim()).filter(Boolean) || [];
}

function recommendationFrom(reason) {
  const explicit = reason.match(/\bRecommendation:\s*(.*?)(?=(?:\s+(?:Report|Evidence|Follow-on|See)\b)|$)/i);
  if (explicit) return explicit[1].trim();
  const recommended = sentences(reason).find((sentence) => /\b(recommend(?:s|ed|ation)?|advises?)\b/i.test(sentence));
  return recommended || "";
}

function cleanOption(value) {
  return value
    .trim()
    .replace(/^(?:options?|choose|captain must choose)\s*:\s*/i, "")
    .replace(/^(?:[a-z]|\d+)[.)]\s+/i, "")
    .replace(/[.;,]\s*$/, "")
    .trim();
}

function splitExplicitOptions(value) {
  const pieces = value
    .split(/\s*;\s*(?:OR\s+|or\s+)?|\s+\bOR\b\s+|\s+\b[vV][sS]\.?\s+/)
    .map(cleanOption)
    .filter((item) => item.length > 1);
  return [...new Set(pieces)];
}

function splitTitleOptions(value) {
  const pieces = value
    .split(/\s+\b(?:or|vs\.?)\s+/i)
    .map(cleanOption)
    .filter((item) => item.length > 1);
  return [...new Set(pieces)];
}

function optionsFrom(title, reason, recommendation) {
  let source = "";
  const explicit = reason.match(/\b(?:Options?|Choose|Captain must choose)\s*:\s*(.*)/i);
  if (explicit) source = explicit[1];
  if (!source && /^Choose\b/i.test(reason)) source = reason.replace(/^Choose\s*/i, "");
  if (!source) {
    const choosePhrase = reason.match(/\b(?:captain chooses|choose)\s+(.+)/i);
    if (choosePhrase) source = choosePhrase[1];
  }
  if (source) {
    source = source.split(/\bRecommendation:\s*/i)[0];
    source = source.split(/\b(?:Report|Evidence|Follow-on|See)\b\s*:/i)[0];
    const parsed = splitExplicitOptions(source);
    if (parsed.length >= 2) return parsed;
  }
  const alternativePhrase = reason.match(/\b(?:whether to|alternatives? (?:are|is))\s+([^.;]+?\s+or\s+[^.;]+)/i);
  if (alternativePhrase) {
    const parsed = splitTitleOptions(alternativePhrase[1]);
    if (parsed.length >= 2) return parsed;
  }
  const versusSentence = sentences(reason).find((sentence) => /\bvs\.?\b/i.test(sentence));
  if (versusSentence) {
    const beforeSemicolon = versusSentence.split(";")[0];
    const afterColon = beforeSemicolon.includes(":") ? beforeSemicolon.slice(beforeSemicolon.indexOf(":") + 1) : beforeSemicolon;
    const parsed = splitTitleOptions(afterColon);
    if (parsed.length >= 2) return parsed;
  }
  if (/\b(?:vs\.?|or)\b/i.test(title) || title.includes(" / ")) {
    const parsed = title.replace(/\?$/, "").split(/\s+\/\s+/).flatMap((part) => splitTitleOptions(part));
    if (parsed.length >= 2) return [...new Set(parsed)];
  }
  return recommendation ? [recommendation] : [];
}

function identityFrom(task) {
  const origin = task.body?.match(/(?:^|\n)Origin: ([A-Za-z0-9._-]+)(?:\n|$)/)?.[1] || "";
  const key = task.body?.match(/(?:^|\n)Decision key: ([A-Za-z0-9._-]+)(?:\n|$)/)?.[1] || "";
  if (!origin || !key || `${origin}-decision-${key}` !== task.id) return { origin: "", key: "" };
  return { origin, key };
}

function loadTasks(home) {
  const heldOutput = run(
    "tasks-axi",
    ["list", "--state", "held", "--kind", "captain", "--fields", "hold_reason,blocked_by,body,created"],
    home,
  );
  const listed = taskIdsFromList(heldOutput);
  const tasks = listed.ids.map((id) => taskShow(home, id));
  for (const task of tasks) {
    if (task.state !== "queued" || task.held !== "yes" || task.kind !== "captain" || task.hold_kind !== "captain") {
      fail(`listed captain hold ${task.id} did not retain the structured held state`);
    }
  }

  const dependentMap = new Map(tasks.map((task) => [task.id, []]));
  const blockedOutput = run("tasks-axi", ["list", "--blocked", "--fields", "blocked_by"], home);
  const blocked = taskIdsFromList(blockedOutput);
  for (const id of blocked.ids) {
    const dependent = taskShow(home, id);
    for (const blocker of splitBlockedBy(dependent.blocked_by)) {
      if (dependentMap.has(blocker)) {
        dependentMap.get(blocker).push({ id: dependent.id, title: dependent.title, state: dependent.state });
      }
    }
  }

  return {
    count: listed.count,
    tasks: tasks.map((task) => {
      const recommendation = recommendationFrom(task.hold_reason || "");
      const identity = identityFrom(task);
      return {
        id: task.id,
        title: task.title,
        reason: task.hold_reason,
        repo: task.repo,
        group: normalizeRepo(task.repo),
        created: task.created,
        options: optionsFrom(task.title, task.hold_reason || "", recommendation),
        recommendation,
        origin: identity.origin,
        key: identity.key,
        dependents: dependentMap.get(task.id) || [],
      };
    }),
  };
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function scriptJson(value) {
  return JSON.stringify(value).replaceAll("<", "\\u003c").replaceAll(">", "\\u003e").replaceAll("&", "\\u0026");
}

function optionMarkup(decision) {
  const choices = decision.options.map((option, index) => `
                <label class="option-row">
                  <input type="radio" name="answer-${escapeHtml(decision.id)}" value="${escapeHtml(option)}">
                  <span><strong>Option ${index + 1}</strong>${escapeHtml(option)}</span>
                </label>`).join("");
  const empty = decision.options.length === 0
    ? '<p class="missing">No explicit options were separable from the backlog without guessing. Write the exact decision below.</p>'
    : "";
  return `${choices}
                <label class="option-row custom-row">
                  <input type="radio" name="answer-${escapeHtml(decision.id)}" value="__custom__">
                  <span><strong>Exact answer</strong>Write a different or more precise decision.</span>
                </label>
                <textarea class="custom-answer" rows="2" maxlength="8192" placeholder="Captain's exact chosen option or instruction"></textarea>
                ${empty}`;
}

function cardMarkup(decision) {
  const blocked = decision.dependents.length > 0
    ? `<div class="blocking"><strong>Blocks ${decision.dependents.length} item${decision.dependents.length === 1 ? "" : "s"}</strong><ul>${decision.dependents.map((item) => `<li><code>${escapeHtml(item.id)}</code> - ${escapeHtml(item.title)}</li>`).join("")}</ul></div>`
    : '<p class="not-blocking">No dependent work is currently blocked by this decision.</p>';
  const recommendation = decision.recommendation
    ? `<p>${escapeHtml(decision.recommendation)}</p>`
    : '<p class="missing">No explicit recommendation is recorded in the backlog.</p>';
  const routeability = decision.origin
    ? '<span class="badge routeable">Lifecycle route ready</span>'
    : '<span class="badge legacy">Needs lifecycle identity before routing</span>';
  return `<article class="decision-card" id="${escapeHtml(decision.id)}" data-search="${escapeHtml(`${decision.title} ${decision.reason} ${decision.group}`.toLowerCase())}">
          <header>
            <div class="eyebrow"><span>${escapeHtml(decision.group)}</span>${routeability}${decision.dependents.length > 0 ? '<span class="badge blocker">Blocking work</span>' : ""}</div>
            <h3>${escapeHtml(decision.title)}</h3>
            <code class="identity">${escapeHtml(decision.id)}</code>
          </header>
          <section class="reason"><h4>Why this needs a decision</h4><p>${escapeHtml(decision.reason)}</p></section>
          <aside class="recommendation"><span>Firstmate recommendation - advisory, not decided</span>${recommendation}</aside>
          ${blocked}
          <form class="answer-form" data-decision-id="${escapeHtml(decision.id)}" data-lavish-question="${escapeHtml(decision.id)}">
            <fieldset>
              <legend>Choose one option</legend>
              ${optionMarkup(decision)}
            </fieldset>
            <div class="answer-actions"><button type="submit">Queue this answer</button><output aria-live="polite"></output></div>
          </form>
        </article>`;
}

function renderHtml(manifest) {
  const groups = new Map();
  for (const decision of manifest.decisions) {
    if (!groups.has(decision.group)) groups.set(decision.group, []);
    groups.get(decision.group).push(decision);
  }
  const groupMarkup = [...groups.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([group, decisions]) => `<section class="domain" data-domain="${escapeHtml(group)}">
      <div class="domain-heading"><div><p>Domain</p><h2>${escapeHtml(group)}</h2></div><span>${decisions.length} decision${decisions.length === 1 ? "" : "s"}</span></div>
      <div class="decision-list">${decisions.map(cardMarkup).join("\n")}</div>
    </section>`).join("\n");
  const blockingCount = manifest.decisions.filter((decision) => decision.dependents.length > 0).length;
  return `<!doctype html>
<html lang="en" data-lavish-live-reload-root>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Captain's decision register</title>
  <style>
    :root { color-scheme: dark; --ink:#f4f0e7; --muted:#a8b4b9; --panel:#12232b; --panel2:#172d37; --line:#31505c; --gold:#f1c46c; --sea:#71d6c2; --danger:#ffad8f; }
    * { box-sizing: border-box; }
    body { margin:0; background:#08161c; color:var(--ink); font:16px/1.6 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    body::before { content:""; position:fixed; inset:0; pointer-events:none; opacity:.2; background-image:linear-gradient(rgba(113,214,194,.06) 1px,transparent 1px),linear-gradient(90deg,rgba(113,214,194,.06) 1px,transparent 1px); background-size:32px 32px; }
    main { position:relative; width:min(1180px,calc(100% - 32px)); margin:0 auto; padding:48px 0 96px; min-width:0; }
    h1,h2,h3,h4,p { overflow-wrap:anywhere; }
    h1 { max-width:800px; margin:.15em 0; padding-bottom:.08em; font-size:clamp(2.5rem,7vw,5.8rem); line-height:1.12; letter-spacing:-.035em; }
    h2 { margin:0; font-size:2rem; line-height:1.2; }
    h3 { margin:.5rem 0 .2rem; font-size:clamp(1.4rem,3vw,2rem); line-height:1.22; }
    h4 { margin:0 0 .35rem; font-size:.78rem; text-transform:uppercase; letter-spacing:.12em; color:var(--sea); }
    .kicker,.domain-heading p { margin:0; color:var(--gold); text-transform:uppercase; letter-spacing:.18em; font-size:.76rem; font-weight:800; }
    .intro { max-width:760px; color:var(--muted); font-size:1.08rem; }
    .stats { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:12px; margin:28px 0; }
    .stat { padding:18px; border:1px solid var(--line); background:rgba(18,35,43,.88); border-radius:14px; min-width:0; }
    .stat strong { display:block; padding-bottom:.08em; color:var(--gold); font-size:2rem; line-height:1.2; }
    .stat span { color:var(--muted); font-size:.85rem; }
    .toolbar { position:sticky; top:0; z-index:5; display:flex; gap:10px; align-items:center; margin:24px 0 42px; padding:12px; background:rgba(8,22,28,.94); border:1px solid var(--line); border-radius:14px; backdrop-filter:blur(12px); }
    .toolbar input { width:100%; min-width:0; border:1px solid var(--line); border-radius:9px; background:#0c1d24; color:var(--ink); padding:11px 13px; font:inherit; }
    .domain { margin-top:54px; }
    .domain-heading { display:flex; justify-content:space-between; gap:16px; align-items:end; border-bottom:1px solid var(--line); padding-bottom:13px; }
    .domain-heading > * { min-width:0; }
    .domain-heading > span { color:var(--muted); white-space:nowrap; }
    .decision-list { display:grid; grid-template-columns:minmax(0,1fr); gap:20px; margin-top:20px; }
    .decision-card { min-width:0; padding:24px; border:1px solid var(--line); border-radius:18px; background:linear-gradient(145deg,rgba(23,45,55,.96),rgba(14,31,38,.96)); box-shadow:0 20px 55px rgba(0,0,0,.18); }
    .eyebrow { display:flex; gap:8px; flex-wrap:wrap; align-items:center; color:var(--sea); font-size:.75rem; font-weight:800; text-transform:uppercase; letter-spacing:.09em; }
    .badge { display:inline-flex; border:1px solid var(--line); border-radius:999px; padding:2px 8px; letter-spacing:.03em; text-transform:none; }
    .routeable { color:var(--sea); }.legacy { color:var(--danger); }.blocker { color:var(--gold); }
    .identity { display:block; color:var(--muted); font-size:.72rem; white-space:normal; overflow-wrap:anywhere; }
    .reason { margin:22px 0; padding-top:18px; border-top:1px solid var(--line); }
    .reason p,.recommendation p { margin:.2rem 0; }
    .recommendation { margin:18px 0; padding:16px 18px; border-left:4px solid var(--gold); background:rgba(241,196,108,.09); }
    .recommendation > span { color:var(--gold); font-size:.76rem; font-weight:900; letter-spacing:.08em; text-transform:uppercase; }
    .blocking { margin:18px 0; padding:14px 16px; background:rgba(255,173,143,.08); border:1px solid rgba(255,173,143,.35); border-radius:12px; }
    .blocking strong { color:var(--danger); }.blocking ul { margin:.4rem 0 0; padding-left:1.2rem; }.blocking li { overflow-wrap:anywhere; }
    .not-blocking { color:var(--muted); font-size:.86rem; }
    fieldset { min-width:0; margin:24px 0 0; padding:0; border:0; }
    legend { margin-bottom:10px; font-weight:900; }
    .option-row { display:grid; grid-template-columns:22px minmax(0,1fr); gap:11px; align-items:start; margin:8px 0; padding:13px; border:1px solid var(--line); border-radius:11px; background:#0d2028; cursor:pointer; }
    .option-row:has(input:checked) { border-color:var(--sea); box-shadow:inset 0 0 0 1px var(--sea); }
    .option-row input { margin-top:5px; accent-color:var(--sea); }
    .option-row strong { display:block; color:var(--sea); font-size:.72rem; letter-spacing:.08em; text-transform:uppercase; }
    .custom-answer { display:none; width:100%; min-width:0; resize:vertical; margin-top:8px; padding:12px; border:1px solid var(--line); border-radius:10px; background:#091a21; color:var(--ink); font:inherit; }
    .answer-form:has(input[value="__custom__"]:checked) .custom-answer { display:block; }
    .missing { color:var(--danger); font-size:.85rem; }
    .answer-actions { display:flex; gap:12px; align-items:center; flex-wrap:wrap; margin-top:14px; }
    button { border:0; border-radius:9px; padding:11px 15px; background:var(--sea); color:#082019; font:800 .9rem/1 ui-sans-serif,system-ui,sans-serif; cursor:pointer; }
    button:hover { filter:brightness(1.08); }.answer-actions output { color:var(--sea); font-size:.85rem; }
    .hidden { display:none !important; }
    @media (max-width:700px) { main{width:min(100% - 20px,1180px);padding-top:28px}.stats{grid-template-columns:1fr}.decision-card{padding:18px}.domain-heading{align-items:start}.toolbar{top:6px} }
  </style>
</head>
<body>
  <main>
    <p class="kicker">Private loopback register</p>
    <h1>Decisions, all on one deck.</h1>
    <p class="intro">Each answer stays local until it is queued and sent through Lavish. A recommendation is advice, never a preselected answer. Exact custom answers are preserved verbatim.</p>
    <section class="stats" aria-label="Decision totals"><div class="stat"><strong>${manifest.count}</strong><span>captain decisions</span></div><div class="stat"><strong>${groups.size}</strong><span>domains</span></div><div class="stat"><strong>${blockingCount}</strong><span>blocking other work</span></div></section>
    <div class="toolbar"><input id="filter" type="search" placeholder="Filter decisions, reasons, or domains" aria-label="Filter decisions"><span id="visible-count">${manifest.count} shown</span></div>
    ${groupMarkup}
  </main>
  ${MANIFEST_START}${scriptJson(manifest)}${MANIFEST_END}
  <script>
    const marker = ${JSON.stringify(MARKER)};
    const manifest = JSON.parse(document.getElementById("fm-decision-data").textContent);
    const byId = new Map(manifest.decisions.map((item) => [item.id, item]));
    function encodePayload(value) {
      const bytes = new TextEncoder().encode(JSON.stringify(value));
      let binary = "";
      for (const byte of bytes) binary += String.fromCharCode(byte);
      return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
    }
    for (const form of document.querySelectorAll(".answer-form")) {
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        const decision = byId.get(form.dataset.decisionId);
        const selected = new FormData(form).get("answer-" + decision.id);
        const output = form.querySelector("output");
        if (!selected) { output.textContent = "Select an option first."; return; }
        const custom = form.querySelector(".custom-answer").value.trim();
        const answer = selected === "__custom__" ? custom : selected;
        if (!answer) { output.textContent = "Write the exact answer first."; return; }
        const payload = { version:1, hold_id:decision.id, origin_id:decision.origin, decision_key:decision.key, answer, answer_type:selected === "__custom__" ? "custom" : "option" };
        const encoded = encodePayload(payload);
        window.lavish.queuePrompt("Captain decision answer: " + answer + "\\n" + marker + encoded, { tag:"decision-answer", text:decision.title + ": " + answer, queueKey:decision.id, element:form });
        output.textContent = "Answer queued. Use Send to Agent when your batch is ready.";
      });
    }
    document.getElementById("filter").addEventListener("input", (event) => {
      const query = event.target.value.trim().toLowerCase();
      let count = 0;
      for (const card of document.querySelectorAll(".decision-card")) {
        const visible = !query || card.dataset.search.includes(query);
        card.classList.toggle("hidden", !visible);
        if (visible) count += 1;
      }
      for (const domain of document.querySelectorAll(".domain")) domain.classList.toggle("hidden", !domain.querySelector(".decision-card:not(.hidden)"));
      document.getElementById("visible-count").textContent = count + " shown";
    });
  </script>
</body>
</html>\n`;
}

function manifestFromPage(page) {
  const html = readFileSync(page, "utf8");
  const start = html.indexOf(MANIFEST_START);
  const end = html.indexOf(MANIFEST_END, start + MANIFEST_START.length);
  if (start < 0 || end < 0) fail(`decision manifest is absent from ${page}`);
  try {
    return JSON.parse(html.slice(start + MANIFEST_START.length, end));
  } catch (error) {
    fail(`decision manifest is invalid: ${error.message}`);
  }
}

function decodeMarker(encoded) {
  const normalized = encoded.replaceAll("-", "+").replaceAll("_", "/");
  const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
  return JSON.parse(Buffer.from(normalized + padding, "base64").toString("utf8"));
}

function readPoll(page, pollFile, output) {
  const manifest = manifestFromPage(page);
  const current = new Map(manifest.decisions.map((item) => [item.id, item]));
  const raw = readFileSync(pollFile, "utf8");
  const matches = [...raw.matchAll(new RegExp(`${MARKER}([A-Za-z0-9_-]+)`, "g"))];
  const candidates = [];
  const ambiguous = [];
  const seenPayloads = new Set();
  for (const match of matches) {
    if (seenPayloads.has(match[1])) continue;
    seenPayloads.add(match[1]);
    let payload;
    try {
      payload = decodeMarker(match[1]);
    } catch (error) {
      ambiguous.push({ marker: match[1].slice(0, 24), reason: `invalid answer payload: ${error.message}` });
      continue;
    }
    const decision = current.get(payload.hold_id);
    if (!decision) {
      ambiguous.push({ hold_id: payload.hold_id || "", reason: "answer does not match a decision on this generated surface" });
      continue;
    }
    if (payload.version !== 1 || payload.origin_id !== decision.origin || payload.decision_key !== decision.key) {
      ambiguous.push({ hold_id: decision.id, reason: "answer identity does not match the generated decision" });
      continue;
    }
    if (!decision.origin || !decision.key) {
      ambiguous.push({ hold_id: decision.id, reason: "decision lacks the lifecycle identity required by fm-decision-hold resolve" });
      continue;
    }
    if (typeof payload.answer !== "string" || !payload.answer.trim() || Buffer.byteLength(payload.answer, "utf8") > 8192) {
      ambiguous.push({ hold_id: decision.id, reason: "answer text is empty or exceeds 8192 bytes" });
      continue;
    }
    if (payload.answer_type === "option" && !decision.options.includes(payload.answer)) {
      ambiguous.push({ hold_id: decision.id, reason: "selected option is not present on the generated surface" });
      continue;
    }
    if (payload.answer_type !== "option" && payload.answer_type !== "custom") {
      ambiguous.push({ hold_id: decision.id, reason: "answer type is not recognized" });
      continue;
    }
    candidates.push({
      hold_id: decision.id,
      origin_id: decision.origin,
      decision_key: decision.key,
      title: decision.title,
      repo: decision.repo,
      chosen_option: payload.answer,
      answer_type: payload.answer_type,
    });
  }

  const grouped = new Map();
  for (const answer of candidates) {
    if (!grouped.has(answer.hold_id)) grouped.set(answer.hold_id, []);
    grouped.get(answer.hold_id).push(answer);
  }
  const accepted = [];
  for (const [holdId, answers] of grouped) {
    const choices = [...new Set(answers.map((answer) => answer.chosen_option))];
    if (choices.length !== 1) {
      ambiguous.push({ hold_id: holdId, choices, reason: "multiple different answers were submitted; no answer was selected" });
      continue;
    }
    accepted.push(answers[0]);
  }
  accepted.sort((left, right) => left.hold_id.localeCompare(right.hold_id));
  const result = { schema: "fm-decision-surface-answers.v1", page: path.resolve(page), accepted, ambiguous };
  mkdirSync(path.dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  console.log(`captured: ${accepted.length} unambiguous answer${accepted.length === 1 ? "" : "s"}`);
  for (const answer of accepted) console.log(`  ${answer.hold_id}: ${answer.chosen_option}`);
  console.log(`ambiguous: ${ambiguous.length}`);
  for (const item of ambiguous) console.log(`  ${item.hold_id || item.marker || "feedback"}: ${item.reason}`);
  console.log(`answers: ${output}`);
}

function safeRouteId(holdId) {
  return `decision-route-${createHash("sha256").update(holdId).digest("hex").slice(0, 16)}`;
}

function showExists(home, id) {
  const result = spawnSync("tasks-axi", ["show", id, "--full"], { cwd: home, encoding: "utf8" });
  if (result.status !== 0) return null;
  return parseShow(result.stdout);
}

function currentDependents(home, holdId) {
  const listed = taskIdsFromList(run("tasks-axi", ["list", "--blocked", "--fields", "blocked_by"], home));
  const dependents = [];
  for (const id of listed.ids) {
    const task = taskShow(home, id);
    if (splitBlockedBy(task.blocked_by).includes(holdId)) dependents.push(task.id);
  }
  return dependents.sort();
}

function recordedRouteIds(body) {
  const match = body?.match(/(?:^|\n)Routed identities: ([A-Za-z0-9._,-]+)(?:\n|$)/);
  return match ? match[1].split(",").filter(Boolean).sort() : [];
}

function routeAnswers({ home, root, page, answersFile, apply }) {
  const manifest = manifestFromPage(page);
  const current = new Map(manifest.decisions.map((item) => [item.id, item]));
  const answers = JSON.parse(readFileSync(answersFile, "utf8"));
  if (answers.schema !== "fm-decision-surface-answers.v1" || !Array.isArray(answers.accepted)) {
    fail("answers file does not use fm-decision-surface-answers.v1");
  }
  if (path.resolve(answers.page || "") !== path.resolve(page)) fail("answers file belongs to a different generated page");
  const skippedAmbiguous = Array.isArray(answers.ambiguous) ? answers.ambiguous : [];
  const results = [];
  const routeDir = path.join(path.dirname(page), "decision-routes");
  if (apply) mkdirSync(routeDir, { recursive: true, mode: 0o700 });

  for (const answer of answers.accepted) {
    const decision = current.get(answer.hold_id);
    if (!decision || answer.origin_id !== decision.origin || answer.decision_key !== decision.key) {
      fail(`answer identity drifted from the generated surface: ${answer.hold_id}`);
    }
    if (answer.chosen_option !== String(answer.chosen_option).trim() || !answer.chosen_option) {
      fail(`answer text is invalid for ${answer.hold_id}`);
    }
    if (answer.answer_type === "option" && !decision.options.includes(answer.chosen_option)) {
      fail(`selected option is no longer present on the generated surface: ${answer.hold_id}`);
    }
    if (answer.answer_type !== "option" && answer.answer_type !== "custom") {
      fail(`answer type is invalid for ${answer.hold_id}`);
    }
    const hold = taskShow(home, answer.hold_id);
    const alreadyResolved = hold.state === "done" && hold.body.includes("Resolution recorded by fm-decision-hold.");
    if (!alreadyResolved && (hold.state !== "queued" || hold.held !== "yes" || hold.kind !== "captain" || hold.hold_kind !== "captain")) {
      fail(`captain decision is no longer actively held: ${answer.hold_id}`);
    }
    const generatedRouteId = safeRouteId(answer.hold_id);
    const routeTitle = `Act on captain decision: ${decision.title}`;
    const repo = decision.repo && decision.repo !== "-" ? decision.repo : "firstmate";
    const decisionText = `Chosen option: ${answer.chosen_option}\n`;
    const routeBody = `Captain decision source: ${answer.hold_id}\n\n${decisionText}`;
    const decisionFile = path.join(routeDir, `${answer.hold_id}.decision.txt`);
    const routeBodyFile = path.join(routeDir, `${answer.hold_id}.route.txt`);
    const blockedDependents = currentDependents(home, answer.hold_id);
    const recordedRoutes = recordedRouteIds(hold.body);
    const existingGeneratedRoute = showExists(home, generatedRouteId);
    const needsGeneratedRoute = recordedRoutes.length === 0 && blockedDependents.length === 0;
    const routedIds = recordedRoutes.length > 0 ? recordedRoutes : (needsGeneratedRoute ? [generatedRouteId] : blockedDependents);
    const resolveArgs = routedIds.flatMap((id) => ["--routed-to", id]);
    const plan = {
      hold_id: answer.hold_id,
      chosen_option: answer.chosen_option,
      routed_to: routedIds,
      would_create: needsGeneratedRoute && !existingGeneratedRoute,
      resolve: `bin/fm-decision-hold.sh resolve ${decision.origin} ${decision.key} --decision-file ${decisionFile} ${resolveArgs.join(" ")}`,
    };
    if (!apply) {
      results.push({ ...plan, status: "dry-run" });
      continue;
    }
    writeFileSync(decisionFile, decisionText, { mode: 0o600 });
    writeFileSync(routeBodyFile, routeBody, { mode: 0o600 });
    if (needsGeneratedRoute && !existingGeneratedRoute) {
      run("tasks-axi", ["add", generatedRouteId, routeTitle, "--kind", "ship", "--repo", repo, "--body-file", routeBodyFile, "--blocked-by", answer.hold_id], home);
    } else if (needsGeneratedRoute && (existingGeneratedRoute.title !== routeTitle || existingGeneratedRoute.kind !== "ship")) {
      fail(`existing routed identity ${generatedRouteId} does not match this decision`);
    }
    run(
      path.join(root, "bin/fm-decision-hold.sh"),
      ["resolve", decision.origin, decision.key, "--decision-file", decisionFile, ...resolveArgs],
      home,
      { FM_ROOT_OVERRIDE: root, FM_HOME: home, FM_STATE_OVERRIDE: path.join(home, "state"), FM_DATA_OVERRIDE: path.join(home, "data"), FM_CONFIG_OVERRIDE: path.join(home, "config") },
    );
    const closed = taskShow(home, answer.hold_id);
    const routed = routedIds.map((id) => taskShow(home, id));
    if (closed.state !== "done" || routed.some((task) => task.blocked !== "no")) {
      fail(`resolution did not complete cleanly for ${answer.hold_id}`);
    }
    results.push({ ...plan, status: "resolved", hold_state: closed.state, routed_blocked: routed.map((task) => ({ id: task.id, blocked: task.blocked })) });
  }
  console.log(JSON.stringify({ schema: "fm-decision-surface-route.v1", applied: apply, results, skipped_ambiguous: skippedAmbiguous }, null, 2));
}

function showDecision(page, id) {
  const manifest = manifestFromPage(page);
  const decision = manifest.decisions.find((item) => item.id === id);
  if (!decision) fail(`decision is not on the page: ${id}`);
  console.log(`Title: ${decision.title}`);
  console.log(`Reason: ${decision.reason}`);
  console.log("Options:");
  if (decision.options.length === 0) console.log("  - Exact answer required; source options were not separable without guessing.");
  else decision.options.forEach((option) => console.log(`  - ${option}`));
  console.log(`Recommendation: ${decision.recommendation || "No explicit recommendation is recorded in the backlog."}`);
  console.log(`Blocking: ${decision.dependents.length} dependent item${decision.dependents.length === 1 ? "" : "s"}`);
}

const args = parseArgs(process.argv.slice(2));
switch (args.command) {
  case "generate": {
    if (!args.home || !args.output) fail("generate requires --home and --output", 2);
    const loaded = loadTasks(args.home);
    const manifest = {
      schema: "fm-decision-surface.v1",
      generated_at: new Date().toISOString(),
      count: loaded.count,
      decisions: loaded.tasks,
    };
    mkdirSync(path.dirname(args.output), { recursive: true, mode: 0o700 });
    writeFileSync(args.output, renderHtml(manifest), { mode: 0o600 });
    const grouped = new Set(manifest.decisions.map((item) => item.group)).size;
    const blocking = manifest.decisions.filter((item) => item.dependents.length > 0).length;
    const lifecycle = manifest.decisions.filter((item) => item.origin && item.key).length;
    console.log(`generated: ${manifest.count} captain decisions (tasks-axi count: ${loaded.count})`);
    console.log(`groups: ${grouped}; blocking other work: ${blocking}; lifecycle-routable: ${lifecycle}`);
    console.log(`page: ${args.output}`);
    break;
  }
  case "read-poll":
    if (!args.page || !args.poll_file || !args.output) fail("read-poll requires --page, --poll-file, and --output", 2);
    readPoll(args.page, args.poll_file, args.output);
    break;
  case "route":
    if (!args.home || !args.root || !args.page || !args.answers) fail("route requires --home, --root, --page, and --answers", 2);
    routeAnswers({ home: args.home, root: args.root, page: args.page, answersFile: args.answers, apply: args.apply });
    break;
  case "show":
    if (!args.page || !args.id) fail("show requires --page and --id", 2);
    showDecision(args.page, args.id);
    break;
  default:
    fail(`unknown engine command: ${args.command}`, 2);
}
