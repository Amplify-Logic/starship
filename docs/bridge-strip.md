# Starship bridge strip

A slim strip across the top of a Herdr workspace that makes it read as Starship rather than a plain terminal skin.
It shows the STARSHIP wordmark, three lamps for the crew, the owner's most urgent call by name, a red alert when something breaks, the night shift, and the Mac's battery.
`bin/fm-bridge-strip.sh` owns the commands and mechanics; read its header before first use.
`herdr-plugins/starship-bridge/` is the Herdr plugin that carries it.

## What it shows

```text
 S T A R S H I P  │  ■ 2 busy   ■ 1 decision for you   ■ 1 ready to merge  │  ▸ Decide: Harvest chart      ■ 1 failed   night shift from 23:30   battery 57%, 3:12 left
```

| Lamp | Colour when lit | Counts |
| --- | --- | --- |
| `busy` | amber | Workers busy on a task, plus work the validation pipeline is carrying. |
| `decisions for you` | red | Decisions held for the owner that wait on him now, not aged, deferred to a date, or waiting on other work; `decision for you` when there is one. |
| `ready to merge` | green | PRs and ready branches waiting for the merge word, unless the task carries an open captain hold, plus the PRs a second mate has ready for it. |

A lamp with nothing to count stays unlit, so the row keeps its shape.
`decisions for you` and `ready to merge` are the owner's calls, the one count the [Factory pane](factory-pane.md) and the tap page also show; `fm_owner_calls` in `bin/fm-fleet-status-lib.sh` owns it.
A worker's question, an ask-user review finding, a worker's pause, and an aged, deferred, or blocked hold are never counted there.
The counts are the status bar's figures in the status bar's words, and the Factory pane's count line shows the same ones; [status-bar.md](status-bar.md#fleet-words) owns the words, what each figure means, and how the reading is taken.
The strip reads that same cached reading, so it costs the fleet nothing extra.
The strip redraws every 5 seconds, and within a second of the owner's calls changing.
A decision answered, parked, released, closed or added changes no worker, so the owner's calls do not wait for the slow worker reading: whenever their change signal moves, they are read again on their own and the strip shows the next call within about two seconds.
`bin/fm-owner-calls-signal-lib.sh` owns that signal and `bin/fm-fleet-status-lib.sh` owns how the calls are read again.
Before the first reading it says `reading the crew` rather than showing zeros, and a reading that is no longer current carries its age, such as `(10m ago)`.
When no first reading arrives within one bounded refresh, or a reading it had is lost, it says `cannot read the crew (since 09:12)` instead, so a strip that cannot read never looks like one still reading.
A running strip keeps up with updates: before each frame it checks whether its own script or a library it loads changed, and re-runs itself in place, in the same pane, once every new file is non-empty and parses.

The battery comes from `pmset -g batt`.
On battery it turns amber below 25% and red below 10%, where it says `plug in now`.
On mains power it stays quiet, and a machine with no battery, or one that is not a Mac, shows none.

The colours are the flight deck tokens: the strip is painted in the hull colour, the wordmark is cyan, and each lamp colour means only one thing.

### The most urgent call

After the lamps the strip names the owner's most urgent call: the first of his calls as `fm_owner_calls` lists them, his held decisions before work ready to land.
A decision reads `Decide: <title>` and work ready to land `Merge: <title>`, with the title of its work item, else the task's recorded outcome, else its id.
The title is made plain text, so a dash, a quote, or an ellipsis becomes its plain form and any other run of characters outside plain text becomes one `?`.
Clicking the name opens the [Factory pane](factory-pane.md) beside the pane below the strip with its highlight on that call; a Factory pane already showing in the tab moves its highlight there instead.
When the pane cannot be opened, the strip says so in place of the name for a few seconds.
The strip asks the terminal for mouse reports to see the click, so Herdr's own text selection does not work inside the strip.

### The red alert

A red `■ 1 failed, 2 stopped` shows before the battery when work failed or a worker stopped, so trouble shows without the owner looking for it.
`failed` counts tasks whose current state is failed: a worker's failure or a failed validation run.
`stopped` counts tasks whose worker is gone while their record remains, except that a failed task whose worker is gone counts as failed only, so each broken task counts once; the status bar's `failed` and `stopped` are the same two figures.
It clears as soon as the reading no longer counts either.
On a narrower pane it reads `■ 3 broken`.

When the home listens to a Mothership room ([Mothership monitoring](fork-configuration.md#mothership-monitoring-configmothership-monitor)) and the listener has not reached the room for two minutes, the alert says why: `Tailscale is off on this Mac` when Tailscale is installed and not running, or, on a Mac without Tailscale's command, when the room's name does not resolve; otherwise `The <room> room is not answering`, with the room's own name.
The alert needs monitoring switched on for that room; a room with monitoring off raises no alert.
It reads the note the listener keeps while the room cannot be reached, so it costs nothing extra, and it clears as soon as the room answers again, or when the listener has stopped trying for three minutes.
On a narrower pane it reads `Tailscale off` or `room not answering`, after any `N broken`.

### The night shift

When the home has a [night shift window](fork-configuration.md#night-shift-window-confignight-shift-window), the strip says `night shift from 23:30` in the six hours before it starts and `night shift on` while it runs.
For six hours after it ends it says, in green, how much finished in it, such as `3 done overnight`.
That counts each task once: one whose finished report arrived inside the window, which for a ship is its ready report, or whose PR was first seen merged inside it.
Work that was cleaned up before the reading and left no merged PR record is not counted, so the figure can be short; when nothing was counted the morning shows no figure rather than a zero that might not be true.

## Read only

The strip never steers, changes, or drains anything.
Its only writes are its own record of the pane it runs in, kept in the plugin's Herdr config directory, and the shared fleet reading's cache that the status bar also refreshes.
Its one action is opening the Factory pane when the owner clicks the most urgent call; the pane it opens writes nothing until the owner presses one of its keys.
The call, the alert, and the night shift's count come from the same cached reading as the lamps, so they never disagree with them and cost the fleet nothing extra; a Mothership room's reach comes from its listener's note.

## Install, show, and remove

Run each from a pane inside the Herdr workspace:

```sh
bin/fm-bridge-strip.sh install   # link the plugin and show the strip above this pane
bin/fm-bridge-strip.sh remove    # close every strip and unlink the plugin
```

Set `FM_HOME` when installing for a home other than this code root; the strip remembers it.
To show the strip above another pane later, bind the plugin's `starship.bridge.open` action to a key:

```toml
[[keys.command]]
key = "prefix+b"
type = "plugin_action"
command = "starship.bridge.open"
description = "show the Starship bridge"
```

A tab shows at most one strip.
Closing the strip's pane like any other pane hides it until it is shown again.

## Size and placement

Herdr splits a pane only right or down, so the strip opens below the pane, is swapped into the top place, and is then shrunk to Herdr's smallest split share. Keyboard focus then goes back to the pane below, so typing never lands in the strip.
Herdr keeps every split share between a tenth and nine tenths of the pane, so the strip is about a tenth of the pane's height rather than exactly one row.
The strip paints every row of its pane in the hull colour and puts its content on the middle row.
A strip covers the width of the pane it was opened above, because Herdr has no split across a whole tab.

On a narrow pane it drops words before lamps: the wordmark loses its letter spacing, the lamp words shorten to `decision` or `decisions` and `to merge`, then only the numbers remain.
A low battery and the red alert are never dropped while anything else is shown.
The most urgent call and the night shift only use the columns left over, so they never change how the rest of the row narrows: the call first, cut short with `...` before it is left out, then the night shift when it fits whole.

## Verification

`tests/fm-bridge-strip.test.sh` renders fixture fleets, fixture night shifts, fixture Mothership reach notes and fixture battery readings and checks every row word for word and colour by colour, at every width, clicks the running strip under a pseudo-terminal, parks a held decision under the running strip and times how soon it names the next call, runs the strip's own loop to check that it reloads changed code within a redraw and says when it cannot read the crew, and checks the Herdr calls behind the click, `open`, `install`, and `remove` against a stand-in Herdr.
