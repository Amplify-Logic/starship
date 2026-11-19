<h1 align="center">Starship</h1>

<h3 align="center">A new way to run your computer: you talk, an AI first mate and its crew do the work.</h3>

## What it is

Starship is a set of tools that lets you operate your computer by talking to one AI first mate.
You say what you want in plain words, by typing or by voice.
The first mate hands each job to its own AI worker, keeps an eye on all of them, and brings back finished pull requests, written reports, or the next decision that is yours to make.
Around that sit a workspace you can see at a glance, a floating control on your desk, cards that walk you through the steps only you can do, and intake that notices what is waiting for you.

It is a folder of instructions, skills and scripts that you clone and launch, not an app: everything runs on your own machine and your own Claude plan.

### The first mate and its crew

- **One first mate** - Claude Code turned into the one agent you talk to. It plans, delegates and reports; it does not lose track when a window closes, because everything that matters is kept on disk.
- **A crew of workers** - each job runs as its own AI worker in its own isolated copy of the project, so several run side by side. A ship job ends in a pull request; a scout job ends in a written report. The [handbook](../docs/handbook.md) explains both.
- **Second mates** - when one area of work grows big, the first mate can run a persistent helper first mate for it, while you still talk only to your own.

### The workspace

- **The desk** - one command, `starship`, opens your whole workspace in [Herdr](https://herdr.dev): the first mate, its workers, and the views below ([desk](../docs/desk.md)).
- **The Factory pane** - a glance across every area of your work, with the decisions waiting for you and what each crew is doing ([Factory pane](../docs/factory-pane.md)).
- **The bridge strip** - a slim strip across the top showing who is busy, your most urgent call, and any alarm ([bridge strip](../docs/bridge-strip.md)).
- **The status bar** - one line under the first mate with its model, usage, workers and whether it is watching ([status bar](../docs/status-bar.md)).
- **Watchable workers** - every worker shows in Herdr's sidebar (or as a tmux window), and you can type into any of them.

### On your desk

- **The desk floater** - an always-on-top control on the [Mac](../docs/desk-floater.md) and on [Windows](../docs/desk-floater-windows.md): hold a key to talk to the first mate, hear its replies spoken, dictate into any text box, or send a quick screenshot.
- **The step card** - when a page needs you to fill it in by hand, such as a form in a web console, the first mate opens it in a new browser tab and floats a card of numbered steps over it, with a Copy button for every value and Done and Stuck buttons that answer in the chat (Mac, `bin/fm-screen-steps.sh`).

### Optional intake

- **Daily and channel intake** - a morning read of your channels, checks through the day, and a to-do page of what you still owe, each line saying when it was last checked ([daily intake](../docs/fork-configuration.md#daily-intake-and-to-do-page-configmorning-intake-configchannel-intake)).
- **Meeting intake** - after a meeting or call, the first mate reads its notes once, starts the clear follow-ups, and holds the rest for your decision ([meetings](../docs/meetings.md)).

Every intake is off until you switch it on.

### Mothership

Mothership is Starship's team counterpart: shared rooms where a team posts requests and keeps cards of work.
A Starship that has joined a room can listen to it, hold each request to it as a decision for you, and tell the card how the work goes once you take it on ([Mothership monitoring](../docs/fork-configuration.md#mothership-monitoring-configmothership-monitor)).

## Who it is for

Starship is for anyone who wants several pieces of work done at once - fixes, investigations, plans, reviews, and the steps around them - without juggling a separate AI session for each.
You need code on GitHub and a paid Claude plan; you do not need to know how the crew works inside.
Your setup stays yours: a fresh copy holds only the public files, and your preferences, task list, projects and sign-ins stay private on your own machine.

## Start here

| Your computer | Start with |
| --- | --- |
| Mac | [ONBOARDING.md](../ONBOARDING.md) |
| Windows PC (through WSL 2) | [ONBOARDING-windows.md](../ONBOARDING-windows.md) |
| Rented Linux server | [ONBOARDING-linux-server.md](../ONBOARDING-linux-server.md) |

Each guide takes you from a blank machine to a first mate that has added one of your projects and brought back a worker's report, and [the handbook](../docs/handbook.md) covers everything after that.
The desk floater runs on a Mac or a Windows PC, and the step card on a Mac.
Working with a team, or with a private team add-on? Read [Working with Starship as a team](../docs/teams-and-add-ons.md).
To move to the latest shared instructions and scripts, say "update starship"; your private files are left alone.

## Safety

The first mate runs Claude Code with its permission prompts turned off, so it can run its own scripts without asking at every step.
What keeps it safe instead are its house rules: workers change your projects only in isolated copies, and nothing is merged, sent or destroyed without your word unless you allow it.
[What Starship must never become](../docs/never-become.md) lists the lines it must not cross, and [SECURITY.md](../SECURITY.md) says how to report a problem.

## What it costs

Starship itself is free and MIT licensed.
Running it needs a paid Claude plan for Claude Code: the starter settings are sized for Claude Pro or Max 5x, and daily heavy use is happier on a Max plan.
A few optional extras, such as the push-to-talk desk floater, need their own paid service, and [the handbook](../docs/handbook.md#optional-extras-off-until-you-switch-them-on) says which.

## Contributing

Bug reports go to [Issues](https://github.com/Amplify-Logic/starship/issues), and pull requests must go through the `no-mistakes` review pipeline, as [CONTRIBUTING.md](../CONTRIBUTING.md) explains.

## Credit

Built on [Firstmate](https://github.com/kunchenguid/firstmate) by Kun Chen.
Starship keeps Firstmate's engine, its `fm-` scripts and its skills, and like Firstmate it is MIT licensed - see [LICENSE](../LICENSE).
The [original Firstmate introduction](../README.md) describes that engine in full.
