# Firstmate web page

A calm localhost page that mirrors the terminal workspace for someone who does not want a terminal: the first mate's chat, the Starship band, the projects and each project's own tab.
`bin/fm-web.sh` and `bin/fm-web.py` own the commands, bind, token, guards, transcript reading, mirror reading and send mechanics; read the script headers before changing them.

## What it is

The page is the workspace's regions in the same places, in plain words and with buttons where the terminal has keys.
It adds nothing the terminal does not show.

| In the terminal | On the page |
| --- | --- |
| The tabs across the top | One slim header: the Starship mark, the same tabs (Control Centre, then one per factory, called a project here), then the band |
| The bridge strip ([bridge-strip.md](bridge-strip.md)) | The band in that header: three lamps, the alert, the night shift, the battery; the most urgent call is the first card in Needs you, marked Most urgent |
| The first mate's chat, left | First mate, left |
| The Factory pane's overview, right ([factory-pane.md](factory-pane.md)) | Factories, right, "each project's work, start to finish": the counts, Needs you, Right now, Since you last looked |
| A factory's own tab: its page, and its workers beside it | The project's tab: its page, and Workers at work beside it |
| The pane's keys line | The same keys, and a line of them at the bottom |

The line between two side-by-side panels can be dragged to make either one as big as you like, as in the terminal; a double-click puts it back, and with the line focused the arrow keys move it.
Each browser remembers where you left it.
In a narrow window the two sides stack, Control Centre gets a switch between First mate and Factories, and a project's tab can be resized between its page and its workers the same way.

### The chat

The chat shows the primary session's conversation as you would read it: only your messages and the first mate's replies, as chat bubbles with Markdown rendered.
Everything the first mate did between two messages folds into one quiet line, such as `Looked at 4 things`, that opens on a plain list of those steps.
Notices typed into the chat by the machinery, such as the desk voice's mailbox ring, are steps in that line, never your messages.
A picture you pasted, or a screenshot the desk voice sent, shows as a small picture you can click to see in full, never as its file path.
A compaction shows as a divider whose summary you can expand.
The header says whether the first mate is working, ready, or not running.

A message box at the bottom sends to the same first mate.
Enter sends and Shift+Enter starts a new line.
You can paste or drop images onto the page; they are attached to the next message.

The page is another window onto the one primary session, not a second first mate.

### The band and the projects

The band and both project views are drawn from what the terminal's own regions show: `bin/fm-factory.py --screen` for the Factory pane and `bin/fm-bridge-strip.sh fields` for the strip.
The page chooses no call, counts nothing and orders nothing itself, so it cannot disagree with the terminal; a worker whose checks are running counts as busy in the lamps and the counts, as it does on the worker's own row ([factory-pane.md](factory-pane.md)).
It reads them again about every three seconds while visible. Opening the page is not a look for Since you last looked; pressing one of its buttons or keys on Factories is, as a key press in the pane is, and one on a project tab is not, as a key in a factory's own tab is not.
A worker shows the step it is on and the one line it says about what it is doing, not a copy of its terminal.
A long title shows on one or two lines; click it to read the rest.
A web address in a title or the feed reads as a short label, such as `the pull request`, that opens the link.

Words that are already plain are the terminal's own.
Only these change, and only where the pane or the strip wrote them; a job's title, and what a worker says it is doing, are never reworded:

| Terminal | Page |
| --- | --- |
| ready to merge, PR ready, has its PR ready | ready for your OK |
| landed | went live |
| land it | make it live |
| queued | waiting to start |
| deferred | put off |
| failed, in the alert | hit a problem |
| factory | project |
| NEEDS YOU, RIGHT NOW, SINCE YOU LAST LOOKED | Needs you, Right now, Since you last looked |

### The buttons

Each button is one of the Factory pane's writing keys and sends the note that key sends, through `bin/fm-factory.py act`:

| Button | Pane key |
| --- | --- |
| An answer, then Send to Starship | `1`, `2`, `3`, then enter |
| Keep it, then Send to Starship | `k`, then enter |
| Ask for changes | `c` |
| Talk it through, Talk to this crew | `t`, typed |
| This is already settled | `x` |
| Read the report | `r` |
| Who steers | `s` |

An answer or a keep takes two clicks, the choice and then Send to Starship, so a stray click sends nothing, and the page says whether the note was sent.
A button on a project's tab records no look, as a key in a factory's own tab does not.
A click and a key press on the same question are one answer, because both carry the same request id.
A card the terminal has settled or asked again since the page drew it sends nothing.
The page decides nothing and merges nothing: every button is a note to the first mate, who acts on it as it does from the terminal.
There are no merge or spawn buttons.

### Keys

The page has the Factory pane's keys, and each one does exactly what its button does, so it sends the same note:

| Key | What it does |
| --- | --- |
| `↑` `↓` | Move the highlight between the calls and, on Control Centre, the projects; it starts on the first thing that needs you |
| `1`, `2`, `3` | Pick that answer for the highlighted question; `enter` sends it |
| `enter` | Open the highlighted call, or the highlighted project's tab; sends a picked answer |
| `k` | Keep the highlighted finished work; `enter` sends it |
| `c` | Ask for changes to the highlighted finished work |
| `x` | This is already settled |
| `t` | Talk the highlighted question through, or talk to the project's crew |
| `r` | Read the report |
| `s` | Switch who steers the project |
| `esc` | Back to Control Centre, or cancel |
| `?` | List every key |

The keys work only while no typing box has the keyboard, so typing a message is never taken for a key.
Each button carries its key as a small hint, and a line of keys sits at the bottom, as in the pane; both can be hidden in Settings.

### Settings

The Settings button opens one small panel:

- **Text size**: five steps, Smaller to Largest, starting on Normal in the middle; the whole layout scales with it.
- **Style**: Calm, the default, or Lively, the same page with stronger colours.
- **Light or dark**: Auto follows the system setting; Light is a warm cream.
- **Reduce motion**: turns off the page's few animations, as the system setting also does.
- **Show key hints**: the small key letters on the buttons and the line of keys at the bottom.
- **Put the panels back**: returns every divider to where it started.

Settings and the panel sizes are kept in the browser's own storage, so each browser has its own, and a browser that blocks storage gets the defaults.
A browser that kept settings from the first version of the page keeps its look and starts on Normal text.

## Starting it

```
FM_HOME=/path/to/home bin/fm-web.sh start
```

The best way in is as an app of its own, over the whole screen, with no address bar or tabs:

```
FM_HOME=/path/to/home bin/fm-web.sh open
```

`open` starts the page if it is not running and opens it as its own window, full screen where the browser allows it, through Chrome's app mode (or Chromium or Edge), else in the default browser.
It signs that window in with a link that works once, within two minutes, so the home's token never sits on a command line; `open --print` prints such a link instead, for the first mate to hand over.
Once in, the browser offers to keep it as an installed app: in Chrome, Install Starship from the menu; in Safari, File, then Add to Dock.
The page carries a web app manifest and the Starship ship as its icon for that.

`start` prints the long-lived sign-in link, `http://127.0.0.1:8767/?token=...`; the first visit swaps the token for a cookie and drops it from the address bar.
Opening the address without a sign-in shows a page saying what this is and how to get in, in the look the browser last chose; a link that no longer works says so.
`bin/fm-web.sh url` prints the token link again, `status` reports whether it runs, and `stop` stops it.
`--port <n>` or `FM_WEB_PORT` picks another port, and `serve` runs in the foreground.
Each home runs its own server against its own `FM_HOME`, on its own port.

## How it reads the conversation

The page reads the Claude Code transcript of the session that holds this home's session lock.
The session id is the one the live lock holder's Claude process records in `sessions/<pid>.json` under the Claude config directory, which follows `/clear`; without it, `state/.lock-session`.
The transcript is found under the Claude config directory: `CLAUDE_CONFIG_DIR`, the home's pinned accounts under `data/accounts/claude/`, then `~/.claude`.
The lock and transcript are re-read on every refresh, so a restarted, cleared or compacted session is followed without restarting the page.
After `/clear` the page switches to the new conversation right away, starting with the `/clear` itself.
Only the end of the transcript is parsed, so a very large transcript stays quick; older history stays in the terminal.
`bin/fm-web.sh conversation` prints the same reading once as versioned JSON, with no server, for another page that shows a home's conversation; [direct-line.md](direct-line.md) lists the other reads such a page uses.
The page polls about every one and a half seconds while visible.

## How sending works

Every message goes through `bin/fm-desk-voice.sh send --source web`, the desk floater's own path.
It types the message into the primary's own chat when that chat is safely empty, or past a Claude draft, and otherwise saves it to the durable desk-voice mailbox with a wake.
Under the box, the page says which happened: typed into the chat, typed but not confirmed, or saved to the mailbox.
Pasted images are saved where the floater saves its screenshots, `state/desk-voice/shots/`, owner-only, and passed with `--image`.
Only PNG, JPEG, GIF and WebP images are accepted.
Typing into the chat turns line breaks into spaces, as it does for the floater; a mailbox delivery keeps them.
[desk-floater.md](desk-floater.md#how-transcripts-reach-firstmate) owns the full delivery rules.

## Security model

- The server binds the literal `127.0.0.1`; there is no flag that widens it, and it is never published on a tailnet.
- Every request needs this home's token: once in the sign-in link, then as an HttpOnly, SameSite=Strict cookie derived from it.
  The token is random, created once in `state/web/token` with owner-only permissions in an owner-only folder, so another local user cannot read it.
  `open` signs in with a one-time code instead, kept only as a hash in `state/web/codes/` (owner-only), used up by its first visit and refused after two minutes.
- Without the cookie, only the page saying how to get in, the page's look and rules, its icons and its manifest are served; none holds anything private.
- A picture is served only by an opaque id that the shown conversation handed out, only for a file or pasted image in your own messages, and only when its bytes are a PNG, JPEG, GIF or WebP image.
- Every request must carry a Host of `127.0.0.1:<port>`, so a page using DNS rebinding cannot reach it.
- Every POST also needs the page's CSRF header, a same-origin Origin when the browser sends one, and no cross-site fetch metadata.
  A custom header cannot be sent cross-origin without a preflight the server never answers.
- Pages carry a strict Content-Security-Policy with per-response nonces, and all transcript text is escaped before Markdown is applied; only http and https links become links.
- The request log, `state/web/web.log`, records paths only, never the token or a code, and leaves out the page's successful polls.
- A button reaches the same guards as a send, then only `bin/fm-factory.py act`, with only the fields the pane's keys take; the server writes no note itself.
- The server never takes the session lock, never drains wakes, and never writes backlog or fleet state.
  Its only writes are its own `state/web/` files, one-time codes included, and the pasted images; a button's note, and the look that pressing it records, are written by `bin/fm-factory.py` as they are for the pane.

To revoke access, stop the server, delete `state/web/token`, and start it again; old cookies stop working.

## Limits

- Claude Code primaries only.
  Other primary harnesses keep their transcripts elsewhere; supporting them is a follow-up.
- Local only.
  There is no remote access and no account system; the bridge view is the phone surface.
- No voice inside the page; the desk floater floats over it and keeps that role, and the talk boxes take typed words.
- A worker's own terminal is not shown; the terminal's factory tab keeps that.
- The page shows recent conversation, not the full history of a long session.
- A permission prompt or question dialog in the terminal is not shown as a control; a message sent meanwhile goes to the mailbox.

## Related surfaces

- [factory-pane.md](factory-pane.md) and [bridge-strip.md](bridge-strip.md): the terminal regions the page mirrors, which own what is shown and what each key sends.
- [bridge-view.md](bridge-view.md): the phone fleet glance.
- [desk-floater.md](desk-floater.md): voice, dictation and screenshots into the same chat.
