#!/usr/bin/env node
// Narrow shell classifier for the Claude watcher-continuity PreToolUse gate.
//
// The shared Lexer, program splitter, and command-position resolver remain owned
// by fm-arm-command-policy.mjs. This policy only identifies executed firstmate
// fleet scripts and divides them into recovery commands (session start, wake
// drain, watcher arm, fail-closed teardown, and the explicit host-sentinel
// re-enable) versus every other bin/fm-*.sh command. Unparseable or opaque
// dynamic commands fail open so this gate can never become a blanket shell block.
//
// The session-start allowance is scoped to a genuine first run by the caller's
// --session-lock relation (bin/fm-primary-scope-lib.sh fm_session_lock_relation):
// "free" keeps fm-session-start.sh a recovery command, while "ancestry" (this
// session already acquired the home lock, so session start already ran here)
// and "foreign" (another live session owns the home) both deny it with the
// midsession-session-start code. An absent or unrecognized relation is treated
// as "free" so a caller that predates the flag keeps today's behavior.
//
// Classification is lexical: only a statically visible executed command word is
// matched against RECOVERY_SCRIPTS. A bin/fm-bootstrap.sh command word therefore
// stays denied wherever it executes, including when it is bundled after
// fm-session-start.sh. The fm-bootstrap.sh that fm-session-start.sh runs as its
// own subprocess is not a command word here and is allowed along with its
// composing script, whose header documents that it acquires the per-home session
// lock before those mutating sweeps run.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { Lexer, commandPosition, splitProgram } from "./fm-arm-command-policy.mjs";

const RECOVERY_SCRIPTS = new Set([
  "fm-session-start.sh",
  "fm-wake-drain.sh",
  "fm-watch-arm.sh",
  "fm-teardown.sh",
  "fm-supervision-sentinel.sh",
]);

function parseArguments(argv) {
  const result = { command: "", root: "", "session-lock": "" };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name !== "--command" && name !== "--root" && name !== "--session-lock") {
      throw new Error(`unknown argument: ${name}`);
    }
    if (index + 1 >= argv.length) throw new Error(`${name} requires a value`);
    result[name.slice(2)] = argv[index + 1];
    index += 1;
  }
  return result;
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function fleetScript(value, root) {
  const normalized = path.normalize(value);
  const name = basename(normalized);
  if (!/^fm-[A-Za-z0-9._-]+\.sh$/.test(name)) return "";
  const relative = `bin/${name}`;
  if (normalized === relative || normalized === path.join(root, relative) || normalized.endsWith(`/${relative}`)) return name;
  return "";
}

function literalShellPayload(position) {
  if (!position.command || !["sh", "bash", "zsh"].includes(basename(position.command.value))) return null;
  const words = position.words;
  let noExecute = false;
  for (let index = position.index + 1; index < words.length; index += 1) {
    const word = words[index];
    if (/^-[A-Za-z]*n[A-Za-z]*$/.test(word.value)) noExecute = true;
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(word.value)) {
      const payload = words[index + 1];
      if (!payload || !payload.literal || payload.subs.length > 0) return null;
      return { kind: noExecute ? "none" : "command", value: payload.value };
    }
    if (/^[-+]O$/.test(word.value)) {
      index += 1;
      continue;
    }
    if (word.value === "--" || /^[-+]/.test(word.value)) continue;
    return { kind: noExecute ? "none" : "script", value: word.value, index };
  }
  return { kind: noExecute ? "none" : "stdin", value: "" };
}

function literalEvalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return "";
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return "";
  return payloads.map((payload) => payload.value).join(" ");
}

function isLiteralWord(word, value) {
  return Boolean(word) && word.literal && word.subs.length === 0 && word.value === value;
}

function fleetScriptRecord(name, position, scriptIndex) {
  const argumentsAfterScript = position.words.slice(scriptIndex + 1);
  const unsafeTeardown = name === "fm-teardown.sh"
    && argumentsAfterScript.some((argument) => argument.value === "--force" || !argument.literal);
  // The session-start disarm banner names exactly one recovery command, so only
  // that literal `enable` passes. Bare invocation, arm, disarm, check,
  // scheduled-check, extra arguments, and any dynamically built argument stay
  // denied while supervision is unhealthy.
  const unsafeSentinel = name === "fm-supervision-sentinel.sh"
    && !(argumentsAfterScript.length === 1 && isLiteralWord(argumentsAfterScript[0], "enable"));
  return { name, unsafeTeardown, unsafeSentinel };
}

function collectExecutedFleetScripts(command, root, depth = 0) {
  if (depth > 12) return [];
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return [];
  const scripts = [];
  const program = splitProgram(lexed.tokens);

  for (const tokens of program.nodes) {
    const position = commandPosition(tokens);
    const direct = fleetScript(position.command?.value || "", root);
    if (direct) scripts.push(fleetScriptRecord(direct, position, position.index));

    for (const token of tokens) {
      if (token.type === "group") scripts.push(...collectExecutedFleetScripts(token.content, root, depth + 1));
      if (token.type !== "word") continue;
      for (const substitution of token.subs) {
        scripts.push(...collectExecutedFleetScripts(substitution.content, root, depth + 1));
      }
    }

    const shell = literalShellPayload(position);
    if (shell?.kind === "command") scripts.push(...collectExecutedFleetScripts(shell.value, root, depth + 1));
    if (shell?.kind === "script") {
      const script = fleetScript(shell.value, root);
      if (script) scripts.push(fleetScriptRecord(script, position, shell.index));
    }
    if (shell?.kind === "stdin") {
      for (const token of tokens) {
        if (token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string") {
          scripts.push(...collectExecutedFleetScripts(token.heredoc, root, depth + 1));
        }
      }
    }

    const sourcedIndex = position.index + 1;
    const sourced = position.command && [".", "source"].includes(position.command.value)
      ? fleetScript(position.words[sourcedIndex]?.value || "", root)
      : "";
    if (sourced) scripts.push(fleetScriptRecord(sourced, position, sourcedIndex));
    const evaluated = literalEvalPayload(position);
    if (evaluated) scripts.push(...collectExecutedFleetScripts(evaluated, root, depth + 1));
  }

  return scripts;
}

export function classifyContinuityCommand(command, root, sessionLock = "free") {
  const lockHeld = sessionLock === "ancestry" || sessionLock === "foreign";
  const scripts = collectExecutedFleetScripts(command, root);
  const blocked = scripts.find(({ name, unsafeTeardown, unsafeSentinel }) =>
    !RECOVERY_SCRIPTS.has(name) || unsafeTeardown || unsafeSentinel
      || (name === "fm-session-start.sh" && lockHeld));
  if (!blocked) return { decision: "allow", script: "" };
  let code = "other-fleet";
  if (blocked.unsafeTeardown) code = "unsafe-teardown";
  else if (blocked.unsafeSentinel) code = "unsafe-sentinel";
  else if (blocked.name === "fm-session-start.sh") code = "midsession-session-start";
  return { decision: "deny", script: blocked.name, code };
}

function main() {
  const args = parseArguments(process.argv.slice(2));
  if (!args.command || !args.root) return;
  const result = classifyContinuityCommand(args.command, args.root, args["session-lock"]);
  if (result.decision === "deny") process.stdout.write(`deny\t${result.script}\t${result.code}\n`);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch {
    process.exitCode = 0;
  }
}
