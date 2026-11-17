# Changelog

Changes that affect a Starship home set up before they shipped, and what to do about each.
A new home needs none of this: [ONBOARDING.md](ONBOARDING.md) already covers it.

New entries go under `## Unreleased` at the top.
Before a release is cut, that heading becomes the release's name, such as `## starship-2026.11`, or `## starship-2026.11.1` for a fix release, above a fresh empty `## Unreleased`.
A release's notes are exactly its own section here, and a home on the [release channel](docs/fork-configuration.md#update-channel-configupdate-channel) reads the sections of the releases it moves past.

## Unreleased

- **A Mothership card now hears when an investigation, guide or draft it asked for is finished.** Work that ends in a report rather than a change used to leave its card at "Work has started."; cleaning up its scout with the report kept now settles the card with one fixed line that it finished with a report you hold, never the report's words, and a project in `config/private-projects` still tells no room anything.
  A scout whose task is still held for your decision when it is cleaned up does not settle its card yet: that card stays at "Work has started." even after your answer closes the task.
  To give the room a link to the report, name it as `mothership-report: <https-url>` in the task's body ([configuration](docs/fork-configuration.md#mothership-monitoring-configmothership-monitor)).
- **A home with a Mothership link now shows its work on the room's Ships view.** Work for a project you shared with a room, through that room's allow-list, appears there as it starts, waits, is blocked or fails, is about to land and lands, and leaves the view when it is dropped; work for any other project, or for a project in `config/private-projects`, never leaves your home, whatever a room's allow-list says.
  Nothing changes for a home with no Mothership link, and to share less, take the project out of that room's allow-list ([configuration](docs/fork-configuration.md#mothership-monitoring-configmothership-monitor)).
- **Your first mate can watch a Mothership room for you.** Nothing changes until you switch a room on: say "turn on Mothership monitoring for <room>", or run `bin/fm-procevent-mothership.sh on <room>`, and a new request to your ship, an answer or a message in that room reaches you within about a minute.
  It needs a Mothership link new enough to keep its own place in the room; `on` says so when yours needs updating ([configuration](docs/fork-configuration.md#mothership-monitoring-configmothership-monitor)).
- **"update starship" can follow named monthly releases.** By default nothing changes: your home still takes the newest Starship.
  To move only to a named monthly release with notes, `echo release > ~/starship/config/update-channel`; your next update then moves your home forward onto the latest release, and a home already newer than it stays where it is until a newer release passes it, since an update never moves a home back; `bin/fm-update.sh --step-back` takes it back to the latest release ([configuration](docs/fork-configuration.md#update-channel-configupdate-channel)).
- **Thinking level follows your plan.** With no `config/primary-effort`, the first mate now thinks at your plan's level ([ONBOARDING.md step 3](ONBOARDING.md#3-get-starship-and-start-your-first-mate)), so a Pro home drops from `xhigh` to `medium`.
  To keep the old depth, `echo xhigh > ~/starship/config/primary-effort`, then start it again; on Pro that uses your allowance much faster.
- **Your home may still run in tmux.** Homes set up before Herdr became the default stay on tmux, and the guide's `herdr` steps do not apply to them.
  Keep using tmux as before, or switch when no worker is running: in `~/starship` run `bin/fm-herdr-setup.sh` and `echo herdr > config/backend`, then open Herdr and start your first mate there ([ONBOARDING.md step 3](ONBOARDING.md#3-get-starship-and-start-your-first-mate)).
- **Starter settings are not copied in.** Only a brand-new home gets them; copy them yourself with the lines under [starter settings](ONBOARDING.md#optional-starter-settings-and-the-call-recorder).
- **"update starship" skips a home with stray or changed files.** A file of yours inside `~/starship`, outside its private folders, or a change to a Starship file, makes the update skip your home as a "dirty working tree".
  `git -C ~/starship status --short` lists them.
  A line starting with `??` is a file of yours: move it out of `~/starship`.
  A line starting with `M` is a Starship file you changed: save a copy elsewhere if you want it, then `git -C ~/starship restore <path>`.
  Then say "update starship" again.
