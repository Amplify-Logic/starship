# Desk

The desk is your whole Starship workspace in Herdr, opened by one command: `starship`.
It starts Herdr's default session or attaches to it when it is already running, fills in whatever your desk layout names that is missing, and opens the windows that show the session, in macOS Terminal or Ghostty.
Run it again and it changes nothing, so it is safe to run whenever you sit down.
`bin/fm-desk.py` owns the commands, and its header is the exact reference; the [desk layout](fork-configuration.md#desk-layout-configdesk-layout) owns what the desk holds.

## Set it up

1. Put the command on your PATH: `bin/fm-desk.py install-command` links `~/.local/bin/starship` to it; it links nothing when a `starship` already exists there or another one, such as the starship.rs shell prompt, already runs from your PATH, since the link would hide that one or be hidden by it.
2. Write your layout: with your desk open the way you like it, `starship layout --save` reads it from the running Herdr session into `config/desk-layout`, writing the file only once the reading succeeded, then fill in the first mate's launch command, such as `firstmate claude-opus`, which a reading cannot tell.
3. Run `starship`; it names each thing it opens and notes anything it left alone.

## What it opens

- Your workspace, made when no workspace carries its label.
- In the main tab, the one the layout names as `main` or else the workspace's first: the first mate, the [bridge strip](bridge-strip.md) across the top, and the [Factory pane](factory-pane.md) beside the first mate.
  When Herdr has no plugin installed for the bridge strip or the Factory pane, as on a new home, the desk installs it first.
- Every other tab the layout names, in order; a factory tab opens through the Factory pane's own tab opener, so pressing `enter` on that factory later finds the same tab, and the desk finds it again by that opener's record even when its label differs from the layout's.
- One window per view, each attached to the same session with its own font size, until as many Herdr clients show the session as the layout names views.
  The layout's `terminal` picks the app: Terminal by default, where each view also gets its Terminal profile, or Ghostty, where each view is its own Ghostty instance that quits when its window closes.
  A view never inherits the environment of a Herdr pane you run `starship` from, since a Herdr client that does refuses to start as a nested Herdr.
- With `sidebar` set, Herdr's sidebar starts collapsed or open in every window the desk opens.

Each window is a full Herdr client of the same session, so they mirror each other and you can switch between them, for example a large font for showing someone the setup and a small one for working.

## What it never does

It never restarts or moves a pane, tab or workspace, never renames one it did not just create, and never touches another workspace, including the workers' own.
It closes only one kind of pane: an idle leftover shell in a factory tab whose page it is starting again after a restart; it never closes any other pane, tab or workspace.
It starts something in a pane, or closes one, only when that pane is an idle shell: the shell itself is waiting there, Herdr records no agent in it, and the pane's last line is the shell's prompt with nothing typed after it.
Such a pane still starting up, as every restored pane is just after a restart, gets up to 30 seconds (`FM_DESK_WAIT`) to reach its prompt, and no view opens meanwhile; panes the desk would neither start something in nor close are never waited for.
A pane with no agent that runs a command but shows nothing on screen yet, as a shell does while its startup file runs a command that has not printed anything yet, counts as still starting up too.
A pane holding typed-ahead input is left alone, and a tab or pane running anything else is left as it is; both are named in a note.
Tabs it adds go at the end; it does not reorder tabs you moved.

## After a restart

When Herdr's server stops, as at a reboot, Herdr restores the saved layout itself but brings every pane back as a plain shell, except agent panes it resumes through its own agent integration, such as the first mate under Claude Code.
The desk starts the server, then starts the bridge strip, the Factory pane and each factory page again inside their own panes, and starts the first mate only when its pane came back as an idle shell with no agent to resume.
In each factory tab whose page it starts again, it closes the other panes that came back as idle shells at an empty prompt, which are the live worker copies, and opens a fresh live copy of each worker still at work beside the page, through the Factory pane's own worker split (`docs/factory-pane.md` says which workers get one); any other pane in that tab is left open and named in a note.
It starts the server before any view attaches, because a Herdr client attaching to an empty session makes a workspace of its own.

## Limits

- The views open in macOS Terminal or Ghostty; with Terminal's "prefer tabs" setting they open as tabs of one window.
  Off macOS, `starship layout` lists no Terminal views, since there is no Terminal to ask.
- Terminal shows 24-bit color only from macOS 26 on, so on an older macOS the colored badges of the bridge strip and the Factory pane show as blank boxes; set `terminal = Ghostty` there, and the desk says so in a note when it opens a Terminal view.
- The desk fills in one workspace, the one the layout names.
- A view opens only when fewer Herdr clients show the session than the layout names views, whatever app those clients run in.
