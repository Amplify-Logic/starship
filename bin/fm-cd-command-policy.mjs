#!/usr/bin/env node
// Semantic policy for the cd-guard: does a shell command persistently change the
// PRIMARY firstmate shell's own working directory?
//
// A stray persistent top-level `cd projects/<clone>` silently relocates the
// primary shell, so the next firstmate-owned command (a backlog write, an
// fm-* lifecycle call, tasks-axi) runs inside a project clone instead of the
// home. This policy blocks exactly that class of command; the environmental
// scoping to the real primary checkout lives in the bin/fm-cd-pretool-check.sh
// transport, not here. See docs/cd-guard.md for the full contract.
//
// One target is exempt: a `cd` whose single literal absolute argument resolves
// to exactly the home passed as --home under both path rules: logical (`..`
// collapsed lexically, Bash's default) and physical (symlinks followed component
// by component, as under `set -P`). Either rule leaving the home, or failing to
// resolve, denies. That cd cannot move the shell out of the home, so it is allowed. A relative, expanded, tilde,
// glob, or option-bearing target is never resolved and stays denied, as does
// every pushd and popd. Without --home no target is exempt.
//
// --resets-outside declares that the harness itself returns the shell to its
// start folder after any command that ends outside its working folders (the
// transport passes it only for a harness verified to do so). A literal absolute
// cd whose target resolves, under every path rule, outside the home and outside
// every --working-dir folder is then allowed too, because it cannot persist.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only, and resolves the one literal
// absolute path it compares against the home.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REASONS = {
  "persistent-cd":
    "a persistent top-level directory change in the primary firstmate checkout is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. Reach the target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...).",
};

// Directory-changing builtins that mutate the calling shell's own cwd.
const CD_BUILTINS = new Set(["cd", "pushd", "popd"]);

// Wrappers that fork or exec a child before reaching the builtin, so a cd behind
// them never persists to the parent shell (and generally just fails, since cd is
// a builtin with no external program). `command` is deliberately NOT here: it
// runs the builtin in the current shell, so `command cd x` still persists.
const FORKING_WRAPPERS = new Set(["env", "sudo", "nohup", "timeout", "gtimeout", "exec"]);

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// A top-level command-list node persists its cwd change to the parent shell
// unless it runs in a subshell context: backgrounded with a trailing `&`, or a
// stage of a pipeline (bash runs every pipeline stage in a subshell).
function nodePersists(separators, index) {
  if (separators[index] === "&") return false;
  if (isPipe(separators[index]) || isPipe(separators[index - 1])) return false;
  return true;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function hasPathQualifiedCommandPrefix(position) {
  return position.words
    .slice(position.prefixAssignments, position.index)
    .some((word) => word.value.includes("/") && word.value.split("/").at(-1) === "command");
}

function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

function resolvedPaths(path) {
  try {
    return [realpathSync(path), realpathSync.native(path)];
  } catch {
    return null;
  }
}

// The only cd shape this policy ever resolves is exactly `cd <literal-absolute-path>`,
// optionally after `--`. A word carrying an expansion, substitution, glob, or
// tilde has a value this policy cannot know without evaluating it, so it is
// never resolved. Returns that literal target, or null.
function literalAbsoluteCdTarget(command, position, wordIndex) {
  if (command.value !== "cd") return null;
  const args = position.words.slice(wordIndex + 1);
  if (args[0]?.value === "--" && args[0].literal) args.shift();
  if (args.length !== 1) return null;
  const [target] = args;
  if (!target.literal || target.subs.length > 0 || target.unquotedExpansion) return null;
  if (!target.value.startsWith("/")) return null;
  return target.value;
}

function cdTargetsHome(target, home) {
  if (!home) return false;
  const resolvedTarget = resolvedPaths(target);
  const resolvedHome = resolvedPaths(home);
  if (resolvedTarget === null || resolvedHome === null) return false;
  return resolvedTarget.every((path) => path === resolvedHome[1]);
}

function isWithin(path, root) {
  return path === root || path.startsWith(root === "/" ? "/" : `${root}/`);
}

// Every form a folder can take: its lexical path plus both resolved paths.
function pathForms(path) {
  return [resolve(path), ...(resolvedPaths(path) ?? [])];
}

// True only when the target exists and every form of it lies outside every form
// of the home and of each declared working folder, so the harness is certain to
// treat the shell as having left its working folders.
function cdLeavesWorkingFolders(target, home, workingDirs) {
  if (!home || resolvedPaths(home) === null) return false;
  if (resolvedPaths(target) === null) return false;
  const roots = [home, ...workingDirs].flatMap(pathForms);
  return pathForms(target).every((path) => !roots.some((root) => isWithin(path, root)));
}

function decision(command, { home = "", resetsOutside = false, workingDirs = [] } = {}) {
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The cd-guard's threat
  // model is agent mistakes - an accidental bare `cd projects/foo` always
  // tokenizes - so we prioritize zero false blocks over catching malformed or
  // deliberately obfuscated bypasses, which stay out of scope by design.
  if (lexed.error) return { decision: "allow" };

  const { nodes, separators } = splitProgram(lexed.tokens);
  for (let index = 0; index < nodes.length; index += 1) {
    if (!nodePersists(separators, index)) continue;
    // commandPosition ignores subshell/brace groups, quoted data, comments, and
    // substitutions (they contribute no top-level command word), and skips
    // leading assignments and wrappers to find the executed command word.
    const position = commandPosition(nodes[index]);
    if (hasPathQualifiedCommandPrefix(position)) continue;
    if (hasCommandQueryPrefix(position)) continue;
    let command = position.command;
    let wordIndex = position.index;
    while (command && (command.value === "builtin" || command.value === "command")) {
      wordIndex += 1;
      command = position.words[wordIndex];
    }
    if (!command) continue;
    if (!CD_BUILTINS.has(command.value)) continue;
    if (position.wrappers.some((wrapper) => FORKING_WRAPPERS.has(wrapper))) continue;
    const target = literalAbsoluteCdTarget(command, position, wordIndex);
    if (target !== null && cdTargetsHome(target, home)) continue;
    if (target !== null && resetsOutside && cdLeavesWorkingFolders(target, home, workingDirs)) continue;
    return deny("persistent-cd");
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, home: "", resetsOutside: false, workingDirs: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name === "--home") {
      if (i + 1 >= argv.length) throw new Error("--home requires a value");
      result.home = argv[i + 1];
      i += 1;
      continue;
    }
    if (name.startsWith("--home=")) {
      result.home = name.slice("--home=".length);
      continue;
    }
    if (name === "--resets-outside") {
      result.resetsOutside = true;
      continue;
    }
    if (name === "--working-dir") {
      if (i + 1 >= argv.length) throw new Error("--working-dir requires a value");
      result.workingDirs.push(argv[i + 1]);
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, {
        home: args.home,
        resetsOutside: args.resetsOutside,
        workingDirs: args.workingDirs,
      });
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
