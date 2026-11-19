# Firstmate web page

A calm localhost page that mirrors the terminal workspace for someone who does not want a terminal: the first mate's chat, the Starship band, the projects and each project's own tab.
`bin/fm-web.sh` and `bin/fm-web.py` own the commands, bind, token, guards, transcript reading, mirror reading and send mechanics; read the script headers before changing them.

## What it is

The page is the workspace's regions in the same places, in plain words and with buttons where the terminal has keys.
It adds nothing the terminal does not show.

| In the terminal | On the page |
| --- | --- |
| The tabs across the top | The same tabs: Control Centre, then one per factory, called a project here |
| The bridge strip ([bridge-strip.md](bridge-strip.md)) | The Starship band: three lamps, the most urgent call as a button, the alert, the night shift, the battery |
| The first mate's chat, left | First mate, left |
| The Factory pane's overview, right ([factory-pane.md](factory-pane.md)) | All projects, right: the counts, Needs you, Right now, Since you last looked |
| A factory's own tab: its page, and its workers beside it | The project's tab: its page, and Workers at work beside it |

In a narrow window the two sides stack, and Control Centre gets a switch between First mate and All projects.

### The chat

The chat shows the primary session's conversation.
Your messages and the first mate's replies are chat bubbles with Markdown rendered.
Each tool call and its result collapse into one quiet line you can expand, and hook notices become quiet notes.
A compaction shows as a divider whose summary you can expand.
The header says whether the first mate is working, ready, or not running.

A message box at the bottom sends to the same first mate.
Enter sends and Shift+Enter starts a new line.
You can paste or drop images onto the page; they are attached to the next message.

The page is another window onto the one primary session, not a second first mate.

### The band and the projects

The band and both project views are drawn from what the terminal's own regions show: `bin/fm-factory.py --screen` for the Factory pane and `bin/fm-bridge-strip.sh fields` for the strip.
The page chooses no call, counts nothing and orders nothing itself, so it cannot disagree with the terminal.
It reads them again about every three seconds while visible. Opening the page is not a look for Since you last looked; pressing one of its buttons on All projects is, as a key press in the pane is, and a button on a project tab is not, as a key in a factory's own tab is not.
A worker shows the step it is on and the one line it says about what it is doing, not a copy of its terminal.

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
A click and a key press on the same question are one answer, because both carry the same request id.
A card the terminal has settled or asked again since the page drew it sends nothing.
The page decides nothing and merges nothing: every button is a note to the first mate, who acts on it as it does from the terminal.
There are no merge or spawn buttons.

### Settings

The Settings button opens one small panel:

- **Text size**: five steps, Small to Largest; the whole layout scales with it.
- **Style**: Calm, the default, or Lively, the same page with stronger colours.
- **Light or dark**: Auto follows the system setting; Light is a warm cream.
- **Reduce motion**: turns off the page's few animations, as the system setting also does.

Settings are kept in the browser's own storage, so each browser has its own, and a browser that blocks storage gets the defaults.

## Starting it

```
FM_HOME=/path/to/home bin/fm-web.sh start
```

`start` prints the sign-in link, `http://127.0.0.1:8767/?token=...`; open it in a browser.
The first visit swaps the token for a cookie and drops it from the address bar, so bookmark the clean address afterwards.
`bin/fm-web.sh url` prints the link again, `status` reports whether it runs, and `stop` stops it.
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
- Every request must carry a Host of `127.0.0.1:<port>`, so a page using DNS rebinding cannot reach it.
- Every POST also needs the page's CSRF header, a same-origin Origin when the browser sends one, and no cross-site fetch metadata.
  A custom header cannot be sent cross-origin without a preflight the server never answers.
- Pages carry a strict Content-Security-Policy with per-response nonces, and all transcript text is escaped before Markdown is applied; only http and https links become links.
- The request log, `state/web/web.log`, records paths only, never the token, and leaves out the page's successful polls.
- A button reaches the same guards as a send, then only `bin/fm-factory.py act`, with only the fields the pane's keys take; the server writes no note itself.
- The server never takes the session lock, never drains wakes, and never writes backlog or fleet state.
  Its only writes are its own `state/web/` files and the pasted images; a button's note, and the look that pressing it records, are written by `bin/fm-factory.py` as they are for the pane.

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
