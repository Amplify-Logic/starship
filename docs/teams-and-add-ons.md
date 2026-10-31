# Working with Starship as a team

This page is for a newcomer joining a team that runs Starship, and for the team lead setting that up.
It says where each kind of thing lives, where each kind of change goes, and who approves it.

## The three layers

Every person's setup is made of up to three layers, and each one has a single job.

| Layer | What it is | What lives there |
| --- | --- | --- |
| Public Starship | This repository, shared by everyone who uses Starship. | The shared instructions, skills and scripts that are useful to any user. |
| Private team add-on (optional) | One private repository a team keeps for itself, laid on top of public Starship. | Tools, skills and hooks that only this team needs. |
| Your own home | Your own copy of Starship on your own machine, with its private files. | Your settings, task list, projects, notes, sign-ins and private-word list. |

Public Starship holds nothing personal: a fresh copy has only the public files, and everything private stays in the home's gitignored folders.
A team add-on is described in [Private add-on](configuration.md#private-add-on-configaddon); without one, a home works exactly the same.

## What a team add-on must never hold

A team add-on is shared by everyone on the team, so it holds tools, not data.
It must never hold customer data, colleague data, or anything about one person: no names, contact details, messages, tickets, account ids or sign-ins.
Those stay in each person's own home, where only that person's first mate reads them.
If a tool needs such details, the add-on carries the tool and each home names its own details in its private settings.

## Where each kind of change goes

| The change | Where it goes | Who approves it |
| --- | --- | --- |
| A fix or feature useful to any Starship user | A pull request to public Starship | The repository's maintainers merge it. |
| A tool, skill or hook only your team needs | A change to the team add-on | The add-on's owner, usually the team lead. |
| Your own preferences, projects or notes | Your own home's private files | You. Nothing leaves your machine. |

When in doubt, start in the narrowest layer that works and move a tool up a layer only once it is clearly useful more widely.
An add-on keeps the public repository's layout, so moving a tool between layers means moving its files.

## Contributing to public Starship

Every contribution to public Starship needs its own approval.
A home that only uses Starship has no standing permission to publish to it, so the first mate asks before each pull request and records that one approval for that one task.
Standing publishing permission is for the repository's maintainers only; [Firstmate role](configuration.md#firstmate-role-configfirstmate-role) owns how that is set.

Before your home raises any pull request to public Starship, put your private-word list in place.
It is a short local file of the names and words that must never appear in public, such as people, customers and private projects; [Private leak words](configuration.md#private-leak-words-configleak-words) says how to write it.
With the list in place, your home checks each change and each pull request's text against it before anything is published.

Pull requests then go through the review pipeline that [CONTRIBUTING.md](../CONTRIBUTING.md) describes, and only the repository's maintainers merge them.

## One add-on per home

A home runs at most one add-on.
A person who works with two teams keeps a separate home for each, so one team's tools and settings never mix with another's.

## Never run from a fork

A teammate runs public Starship itself, never a fork of it.
A fork for daily use drifts: every update then needs a manual catch-up, and a team's own changes end up mixed into the shared code where they are hard to see and easy to lose.
Team-only tools belong in the team add-on and personal settings in your own home, so the shared code stays exactly the public version.
A fork is only for preparing a pull request, as [CONTRIBUTING.md](../CONTRIBUTING.md) describes.

## How updates reach a home

Saying "update starship" to your first mate pulls the latest public Starship and the latest of your team add-on, without touching your private files.
An update only moves forward along what was published, so it never overwrites anything of yours; the `/updatefirstmate` skill owns the procedure.
A change merged into public Starship or the team add-on reaches each home at that home's next update.
