# Starship bridge strip

A slim strip across the top of a Herdr workspace that makes it read as Starship rather than a plain terminal skin.
It shows the STARSHIP wordmark, three lamps for the crew, and the Mac's battery.
`bin/fm-bridge-strip.sh` owns the commands and mechanics; read its header before first use.
`herdr-plugins/starship-bridge/` is the Herdr plugin that carries it.

## What it shows

```text
 S T A R S H I P  │  ■ 2 busy   ■ 1 waiting for you   ■ 1 ready to merge          battery 57%, 3:12 left
```

| Lamp | Colour when lit | Counts |
| --- | --- | --- |
| `busy` | amber | Workers busy on a task, plus work the validation pipeline is carrying. |
| `waiting for you` | red | Decisions a human owes. |
| `ready to merge` | green | PRs and ready branches waiting for the merge word. |

A lamp with nothing to count stays unlit, so the row keeps its shape.
The counts are the status bar's figures: `busy` is its `working` plus `checking`, and `waiting for you` plus `ready to merge` together are its `waiting for you`.
[status-bar.md](status-bar.md#fleet-fields) owns what each figure means and how the reading is taken.
The strip reads that same cached reading, so it costs the fleet nothing extra.
Before the first reading it says `reading the crew` rather than showing zeros, and a reading that is no longer current carries its age, such as `(10m ago)`.

The battery comes from `pmset -g batt`.
On battery it turns amber below 25% and red below 10%, where it says `plug in now`.
On mains power it stays quiet, and a machine with no battery, or one that is not a Mac, shows none.

The colours are the flight deck tokens: the strip is painted in the hull colour, the wordmark is cyan, and each lamp colour means only one thing.

## Read only

The strip never steers, changes, or drains anything.
Its only writes are its own record of the pane it runs in, kept in the plugin's Herdr config directory, and the shared fleet reading's cache that the status bar also refreshes.

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

Herdr splits a pane only right or down, so the strip opens below the pane, is swapped into the top place, and is then shrunk to Herdr's smallest split share.
Herdr keeps every split share between a tenth and nine tenths of the pane, so the strip is about a tenth of the pane's height rather than exactly one row.
The strip paints every row of its pane in the hull colour and puts its content on the middle row.
A strip covers the width of the pane it was opened above, because Herdr has no split across a whole tab.

On a narrow pane it drops words before lamps: the wordmark loses its letter spacing, the lamp words shorten to `for you` and `to merge`, then only the numbers remain.
A low battery is never dropped while anything else is shown.

## Verification

`tests/fm-bridge-strip.test.sh` renders fixture fleets and fixture battery readings and checks every row word for word and colour by colour, at every width, and checks the Herdr calls behind `open`, `install`, and `remove` against a stand-in Herdr.
