# The Baby Menu quota widget

A menu-bar panel showing how much provider allowance is left, grouped per provider account.
This repository tracks the widget's source under `assets/baby-menu/weekly-quota/` so a second machine can install the same panel from a `git pull` instead of rebuilding it.

Baby Menu itself is a separate third-party app and is not distributed here.
Install the app first, run it once so it creates its own home, then install this widget into it.

## Install

```sh
bin/fm-install-baby-menu-quota.sh            # into ~/.baby-menu
bin/fm-install-baby-menu-quota.sh --dry-run  # report what would change, write nothing
```

`bin/fm-install-baby-menu-quota.sh --help` owns the exact flags, the backup behavior, and the refusal cases.
The app watches its own extensions directory and rebuilds a changed widget by itself, so the installer never starts, stops, or restarts the app.

The installer touches only its own extension directory and one example settings file.
Other extensions, the app bundle, preferences, credentials, and the app database are left exactly as they were, and a re-run of an unchanged install replaces no widget file and never touches your own settings file - it only re-seeds the example one until you have written your own.

## The one machine-local setting

The tracked source contains no machine's paths, so there is nothing to rewrite after a pull.
The single per-machine fact the widget needs is where a *second* Claude seat's config directory lives, and that is read at runtime from a file the installer never overwrites:

```sh
cp ~/.baby-menu/weekly-quota.local.example.json ~/.baby-menu/weekly-quota.local.json
# then edit "claudeTeamConfigDir" to the absolute path of that seat's config dir
```

`BABY_MENU_CLAUDE_TEAM_CONFIG_DIR` in the environment overrides the file, and `BABY_MENU_HOME` relocates both.
`assets/baby-menu/weekly-quota/local-settings.ts` is the authoritative owner of the resolution order and the validation.

Leaving it unset is a supported state, not a degraded one: the panel then shows the one Claude seat the machine is signed into and reports nothing about a second.
A malformed settings file or a relative path is ignored rather than allowed to take the panel down.

This setting only tells the panel where to *read* a seat that already exists.
Creating, selecting, or pinning accounts for Firstmate's own workers and primaries is a different subject with its own owner - see [porting.md](porting.md) ("Harness CLIs and logins") and the account documentation it points to, and do not duplicate that mechanism here.

## What the panel is careful about

The widget reads allowances and never invents one.
These rules are load-bearing; changing any of them changes what the captain believes about their remaining quota.

- **Windows are identified by what they are, never by where they appear.**
  The Codex payload carries `primary_window` and `secondary_window`, and which of those is the five-hour window varies by account and by plan; some plans publish only one window.
  Each window is matched against its own declared length first, and only against a name it gives itself when no length was declared, so a name substring can never relabel a window as one whose length it does not have; an unrecognised length is labelled by that length rather than forced into a known one.
  `assets/baby-menu/weekly-quota/quota-windows.ts` owns the rule for every provider reader - a length is turned into a name in one place, so a window of a given length reads the same in every block and no reader names a row after its position in a response - and `tests/fm-baby-menu-quota.test.sh` holds it against recorded response shapes including the single-weekly-window one that first exposed it.
  A unit with no fixed length, such as a month, is reported as a length the panel does not know rather than asserted as some number of days.
- **Every allowance the reader parsed is shown.**
  Each provider block renders every window its reader returned, in the order the reader set, rather than picking out the window ids the panel expects.
  Selecting by expected id drops an allowance a provider does publish and turns a read that in fact succeeded into a `no usable windows` error.
- **Two seats of one brand stay separate.**
  Their windows, resets, and account lines are never summed or averaged, both carry the same brand mark, and the seat is named in words.
- **A plan name is passed through as the provider reports it.**
  An unfamiliar plan identity is shown verbatim rather than mapped onto a familiar one.
- **A model route is availability only.**
  Codex model routes draw down the Codex windows already shown, so they render as a badged note with no meter and no percentage - never as a provider or an allowance of their own.
- **Sign-in failures and stale data say so.**
  An authentication error is shown as that error, and a cached reading is marked stale rather than presented as current.
  A reset moment already in the past reads as passed, never as an imminent reset: a cached reading can be old enough that its window has already rolled over.
- **Cursor's window is its billing cycle**, labelled `INCLUDED` rather than `WEEKLY`, so its countdown is not read as a week.
- **Credits headroom is money, not allowance**, and is deliberately not shown beside the percentages.
  A row is refused for saying it is credits in any of the identity fields a reader fills in, never for merely being an allowance this panel does not recognise.
  A label is display text, so the word only counts there when it stands on its own: an allowance labelled something like `SESSION (credit-backed)` keeps its row rather than disappearing with no row and no error.
- **Colour never carries meaning alone.**
  Every alert also says `low` or `critical` in words, and brand colour and quota colour never share a lane.

## Brand marks and licensing

Every provider mark in `components.tsx` is that vendor's own published logo, copied verbatim and inlined - nothing redrawn, generated, or approximated, and no remote URL is fetched to render the panel.
The source records each mark's origin and, for each accent colour, whether it is `official` (the value appears literally inside that vendor's own asset) or `selected` (chosen here so the blocks separate at a glance, and not presented as a vendor value).
Keep that distinction intact when editing: it is what stops a chosen tint from being mistaken for a brand specification later.

These are third-party trademarks used to identify each vendor's own service in a private status panel.
That provenance record is the licensing obligation this repository carries; do not restyle a mark, recolour it, or replace it with a lookalike, and do not add a remote asset dependency.

## Limits

- Verified on macOS only.
  The panel is a macOS menu-bar popover and the ambient Claude fallback reads the macOS Keychain; nothing here is claimed for Linux.
- The panel opens on a real click of the menu-bar icon.
  The app registers no global shortcut and no second-instance handler, so there is no supported way to open it from a script - confirm it visually.
- The second seat has one reader.
  Its rows report that the read is unavailable rather than falling back to the other seat's numbers.
- Reinstalling replaces the whole widget directory.
  Local edits are kept as a timestamped backup beside it; copy anything you want to keep back out of that directory.
