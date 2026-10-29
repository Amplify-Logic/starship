<h1 align="center">Starship</h1>

<h3 align="center">Talk to one AI first mate. It runs a crew of coding agents for you.</h3>

## What it is

Starship turns Claude Code into a first mate that runs a crew of AI coding workers for you.
You ask for work in plain words, and the first mate hands each task to its own AI worker in its own isolated copy of the project, keeps an eye on all of them, and brings back finished pull requests or written reports.
You only answer the real decisions: what to build, what to merge, and anything that cannot be undone.

It is a folder of instructions, skills and scripts that you clone and launch, not an app: everything runs in your terminal, on your own machine and your own Claude plan.

- **A guided start** - a step-by-step setup from a blank computer to a first mate that has done one piece of real work, plus [a handbook](../docs/handbook.md) for everything after that.
- **Mac, Windows and Linux** - a Mac, a Windows PC inside WSL 2, or a rented Linux server you reach over SSH.
- **Workers you can watch** - every worker shows up in [Herdr](https://herdr.dev)'s sidebar (or as a tmux window), with whether it is working or waiting, and you can type into any of them.
- **A desk floater you can talk to** - an optional always-on-top control on the [Mac](../docs/desk-floater.md) and on [Windows](../docs/desk-floater-windows.md): hold a key to talk to the first mate.
- **Restart-proof** - everything that matters is kept on disk, so a closed window or a restart picks up where it stopped.
- **Easy updates** - say "update starship" and it pulls the latest shared instructions and scripts without touching your private files.

## Who it is for

Starship is for anyone who wants several pieces of software work done at once - fixes, investigations, plans, reviews - without juggling a separate AI session for each.
You need code on GitHub and a paid Claude plan; you do not need to know how the crew works inside.
Your setup stays yours: a fresh copy holds only the public files, and your preferences, task list, projects and sign-ins stay private on your own machine.

## Start here

| Your computer | Start with |
| --- | --- |
| Mac | [ONBOARDING.md](../ONBOARDING.md) |
| Windows PC (through WSL 2) | [ONBOARDING-windows.md](../ONBOARDING-windows.md) |
| Rented Linux server | [ONBOARDING-linux-server.md](../ONBOARDING-linux-server.md) |

Each guide takes you from a blank machine to a first mate that has added one of your projects and brought back a worker's report.

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
