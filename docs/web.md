# Firstmate web page

A calm localhost page for talking to the primary first mate without the terminal.
`bin/fm-web.sh` and `bin/fm-web.py` own the commands, bind, token, guards, transcript reading and send mechanics; read the script headers before changing them.

## What it is

The page shows the primary session's conversation as a clean chat.
Your messages and the first mate's replies are chat bubbles with Markdown rendered.
Each tool call and its result collapse into one quiet line you can expand, and hook notices become quiet notes.
A compaction shows as a divider whose summary you can expand.
The header says whether the first mate is working, ready, or not running.

A message box at the bottom sends to the same first mate.
Enter sends and Shift+Enter starts a new line.
You can paste or drop images onto the page; they are attached to the next message.

A side panel shows the same fleet glance as the bridge view: what needs you, what is under way, and what recently finished.
In a narrow window the panel moves behind the Fleet button.

There are no approve, merge or spawn buttons.
Those stay as typed words in the chat, exactly as in the terminal.
The page is another window onto the one primary session, not a second first mate.

Light and dark themes follow the system setting.

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
- The server never takes the session lock, never drains wakes, and never writes backlog or fleet state.
  Its only writes are its own `state/web/` files and the pasted images.

To revoke access, stop the server, delete `state/web/token`, and start it again; old cookies stop working.

## Limits

- Claude Code primaries only.
  Other primary harnesses keep their transcripts elsewhere; supporting them is a follow-up.
- Local only.
  There is no remote access and no account system; the bridge view is the phone surface.
- No voice inside the page; the desk floater keeps that role.
- The page shows recent conversation, not the full history of a long session.
- A permission prompt or question dialog in the terminal is not shown as a control; a message sent meanwhile goes to the mailbox.

## Related surfaces

- [bridge-view.md](bridge-view.md): the phone fleet glance whose snapshot the side panel reuses.
- [desk-floater.md](desk-floater.md): voice, dictation and screenshots into the same chat.
