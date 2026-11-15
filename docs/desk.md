# Desk

The desk is your whole Starship workspace in Herdr, opened by one command: `starship`.
It starts Herdr or attaches to the session already running, fills in whatever your desk layout names that is missing, and opens the Terminal windows that show the session.
Run it again and it changes nothing, so it is safe to run whenever you sit down.
`bin/fm-desk.py` owns the commands, and its header is the exact reference; the [desk layout](configuration.md#desk-layout-configdesk-layout) owns what the desk holds.

## Set it up

1. Put the command on your PATH: `bin/fm-desk.py install-command` links `~/.local/bin/starship` to it, and leaves an existing `starship` command alone.
2. Write your layout: with your desk open the way you like it, `starship layout > config/desk-layout` reads it from the running Herdr session, then fill in the first mate's launch command, such as `firstmate claude-opus`, which a reading cannot tell.
3. Run `starship`; it names each thing it opens and notes anything it left alone.

## What it opens

- Your workspace, made when no workspace carries its label.
- In the main tab, the one the layout names as `main` or else the workspace's first: the first mate, the [bridge strip](bridge-strip.md) across the top, and the [Factory pane](factory-pane.md) beside the first mate.
- Every other tab the layout names, in order; a factory tab opens through the Factory pane's own tab opener, so pressing `enter` on that factory later finds the same tab, and the desk finds it again by that opener's record even when its label differs from the layout's.
- One Terminal window per view, each attached to the same session with its own Terminal profile and font size, until as many Herdr clients show the session as the layout names views.
- With `sidebar` set, Herdr's sidebar starts collapsed or open in every window the desk opens.

Each window is a full Herdr client of the same session, so they mirror each other and you can switch between them, for example a large font for showing someone the setup and a small one for working.

## What it never does

It never closes, restarts or moves a pane, tab or workspace, never renames one it did not just create, and never touches another workspace, including the workers' own.
It starts something in a pane only when that pane is an idle shell: the shell itself is waiting there and Herdr records no agent in it.
A tab or pane running anything else is left as it is and named in a note.
Tabs it adds go at the end; it does not reorder tabs you moved.

## After a restart

When Herdr's server stops, as at a reboot, Herdr restores the saved layout itself but brings every pane back as a plain shell, except agent panes it resumes through its own agent integration, such as the first mate under Claude Code.
The desk starts the server, then starts the bridge strip, the Factory pane and each factory page again inside their own panes, and starts the first mate only when its pane came back as an idle shell with no agent to resume.
It starts the server before any view attaches, because a Herdr client attaching to an empty session makes a workspace of its own.

## Limits

- The views open in macOS Terminal; with Terminal's "prefer tabs" setting they open as tabs of one window.
- The desk fills in one workspace, the one the layout names.
- A view opens only when fewer Herdr clients show the session than the layout names views, whatever app those clients run in.
