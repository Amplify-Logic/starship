# Calm mode

Calm is a Pi primary presentation toggle.
It hides tool-call noise behind a small moving boat so the terminal shows the conversation rather than the machinery.

`.pi/extensions/fm-calm.ts` owns when the presentation is installed and removed.
`.pi/extensions/lib/fm-calm-working-ship.ts` owns the boat's geometry, cadence, and freeze/resume state.
`.pi/extensions/lib/fm-calm-visibility.ts` owns which transcript rows Calm hides.
`docs/configuration.md` owns the `config/calm` preference file.
This document owns the captain-facing behavior and the verification record.

Calm was ported from upstream, whose `fm-calm.ts` and its four library modules this fork carries with the minimum adaptation needed to load beside `fm-primary-turnend-guard.ts` and `fm-primary-pi-watch.ts`.

## What the captain sees

`/calm` toggles the presentation and the choice persists for the home, so the next Pi primary starts the way the last one ended.

With Calm on:

- Tool calls, tool results, collapsed thinking, and mid-turn assistant working notes are hidden.
- Operational input rows - the session-start, watcher, turn-end-guard, away-supervisor, and launch-brief messages Firstmate delivers to itself - are hidden.
- The captain's own prompts and the agent's genuine replies stay exactly as they were.
- While a run is active, Pi's stock `Working...` row is replaced by a boat sailing a rippling waterline. The water ripples every 220ms and the boat moves one column every fourth ripple, so it reads as calm rather than busy.

With Calm off, every row renders the way Pi renders it.

Two bounds are worth knowing:

- The first toggle in a session is not retroactive for tool rows Pi restored before Calm claimed the built-ins. Rows drawn after the toggle follow the new preference.
- `/export` and `/share` render the stock transcript for that one export, so a shared session is never missing the work Calm was hiding. The stored preference is untouched.

## Preference file

The preference lives in this home's gitignored `config/calm`, holding `on` or `off`.
A home upgraded from the removed third presentation level still holds `max`; that restores as `on` rather than silently dropping to `off`.
An absent file means Calm is off.

## Built-in tool ownership

Pi registers one tool definition per name and the first registration wins, with no merge and no unregister.
Calm presents the seven built-ins - `read`, `bash`, `edit`, `write`, `grep`, `find`, `ls` - by re-registering them with its own render slots.

A Calm-on home claims all seven synchronously at load, because restored rows capture the registry before `session_start` and a deferred claim would leave them rendering stock.
A Calm-off home registers nothing, so a session that never turns Calm on creates no collision exposure at all.
The first activation in a session that started off claims only the built-ins no other extension already owns, and says in a notice which ones it had to leave alone.

## Presentation adapters degrade alone

Collapsed thinking and the operational-input row are presented by patching two exact Pi APIs.
Each adapter probes the method it patches and, if a future Pi removes it, prints a diagnostic and skips only itself.
Calm and Pi keep working; that one presentation reverts to stock.

## Verification record

### Live Pi session, 2026-09-13, Pi 0.80.10

Run in a throwaway project directory outside any Firstmate checkout, against an isolated `PI_CODING_AGENT_DIR` so the captain's own Pi state was untouched.
The directory held exactly the tracked `.pi/extensions/` tree plus `bin/fm-operational-input.sh`, and one throwaway extension registering a local slow endpoint so a run stayed active long enough to watch the working row.

Pi's startup banner listed every project extension loading together:

```
[Extensions]
  fm-calm.ts, fm-primary-pi-watch.ts, fm-primary-status-bar.ts, fm-primary-turnend-guard.ts,
zz-verify-provider.ts
```

`/calm` was offered with its own description:

```
→ calm        [p] Toggle Firstmate's supported conversation-only transcript presentation.
```

Running it wrote `on` to the home's `config/calm`.
A run with Calm off showed Pi's stock working row:

```
 ⠴ Working...
```

The same run with Calm on showed the boat instead, advancing along the waterline between frames:

```
  <|
~\__/~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~

    <|
-~~\__/~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~

       <|
-~~~-~\__/~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~
```

Toggling `/calm` a second time wrote `off` and restored the stock row.

The turn-end guard and watcher extensions stayed live in the same session, each writing its own load marker from the same Pi process id 18777:

```
$ head -c 78 state/.pi-turnend-extension-loaded
sha256:499b3412a3de0c9e3f8cae3570323575f5c1f1a95c334103c5bf24b0745d9b15
$ head -c 78 state/.pi-watch-extension-loaded
sha256:206db8a9a3c7ea10c31efab13b8e474bc0923a2398f3399d999e8276059fd147
```

### Strict typecheck, 2026-09-13, TypeScript 5.9.3

`tests/fm-pi-primary-types.test.sh` typechecks every tracked Pi extension, including the five ported Calm files, against the installed Pi declarations.
It skips below TypeScript 5, and this machine's `tsc` is 4.9.5, so the same compiler options were run once by hand under TypeScript 5.9.3 against Pi 0.80.10 and reported no errors.

### Behavior tests

`tests/fm-calm-extension.test.sh` drives the real extension factory through a minimal host, and the visibility and working-boat modules directly, against the installed Pi package.
