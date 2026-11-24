# Firstmate web page

A calm localhost page that mirrors the terminal workspace for someone who does not want a terminal: the first mate's chat, the Starship band, the projects and each project's own tab.
`bin/fm-web.sh` and `bin/fm-web.py` own the commands, bind, token, guards, transcript reading, mirror reading and send mechanics; read the script headers before changing them.

## What it is

The page is the workspace's regions, in plain words and with buttons where the terminal has keys.
It shows the same facts as the terminal and may lay them out its own way; [What the page lays out its own way](#what-the-page-lays-out-its-own-way) lists where it does.
Apart from the weekly page below, it adds nothing the terminal does not show.

| In the terminal | On the page |
| --- | --- |
| The tabs across the top | One slim header: the Starship mark, the same tabs (Control Centre, then one per factory, called a project here), then the band |
| The bridge strip ([bridge-strip.md](bridge-strip.md)) | The band in that header: three lamps, the alert, the night shift, the battery; the most urgent call is the first card in Needs you, marked First up, and a `stopped` in the alert opens the stopped job on its project's tab |
| The status bar row ([status-bar.md](status-bar.md)) | Its first mate's own part, word for word and in its colours, in a slim line under the message box: model and effort, usage, cost; the header already shows the rest |
| The first mate's chat, left | Firstmate, left |
| The Factory pane's overview, right ([factory-pane.md](factory-pane.md)) | Factories, right, "each project's work, start to finish": the three sentences, each a link to the part it speaks for, Needs you with its two shelves, Your factories |
| A factory's own tab: its page, and its workers beside it | The project's tab: its page alone, with Needs you beside the rest on a wide screen and one column on a narrow one; a worker's screen opens from Watch this worker |
| The pane's keys line | The same keys, and a line of them at the bottom |

On Control Centre the line between Firstmate and Factories can be dragged to make either one as big as you like, as in the terminal; a double-click puts it back, and with the line focused the arrow keys move it.
Each browser remembers where you left it.
In a narrow window Control Centre gets a switch between Firstmate and Factories, a project's tab is one page that scrolls as a whole, and the row of tabs scrolls sideways, bringing a newly chosen tab into sight.

### The chat

The chat shows the primary session's conversation as you would read it: only your messages and the first mate's replies, as chat bubbles with Markdown rendered.
Everything the first mate did between two messages folds into one quiet line, such as `Looked at 4 things`, that opens on a plain list of those steps.
Notices typed into the chat by the machinery, such as the desk voice's mailbox ring, are steps in that line, never your messages.
A picture you pasted, or a screenshot the desk voice sent, shows as a small picture you can click to see in full, never as its file path.
Any other image path you typed stays in your words exactly as you wrote it, with the picture shown beneath the message.
The desk floater's Front line, naming the app and window in front when you talked, is hidden from your messages; Firstmate still receives it ([desk-floater.md](desk-floater.md#the-front-line)).
A file the first mate names in a reply, home-relative such as `data/<task>/knowledge.html` or as an absolute path, is a link that opens the file in a new tab when it exists under the home's `data/` or `.lavish/` folder.
Web pages, PDFs, pictures and drawings open as themselves, and Markdown and other text files open as plain text; any other path stays plain words.
A compaction shows as a divider whose summary you can expand.
The header says whether the first mate is working, ready, or not running.
While it works, a live line at the end of the chat shows moving dots, what it is doing right now in plain words (such as `Reading a file`, its own short description of a step, or `Thinking`), and how long the turn has run (counted from when the page first saw it working, when the turn began before the part of the conversation the page reads); it goes away when the turn ends.
That line never shows a command, a path or code: a step description that holds one reads as the generic words for that kind of step instead.
When the terminal is stopped on a prompt that needs a person, such as a permission yes or no, a trust question, or a question with choices, even one Claude Code asks at start before it has written any of the conversation, the header says `Waiting for you` and the live line says `Waiting for your yes or no in the terminal` (or `Waiting for your answer in the terminal`) with the prompt's own question beneath it, instead of `Thinking`.
The same rule holds for that question. A yes or no is a permission and never shows its own words: when its heading is one of Claude Code's own permission headings (such as `Edit file` or `Bash command`) it reads as the generic words for what it asks, such as `Firstmate wants to change a file` or `Firstmate wants to run a command`, and otherwise as `Firstmate needs your yes or no`. A question with choices shows its own words only when they hold no command, path or file name, and reads as `Firstmate needs an answer` otherwise.
The page reads that prompt from the first mate's own terminal screen every second or two through `bin/fm-desk-voice.sh prompt`, which types nothing, so the line clears within a couple of seconds of the answer.
The page only shows the prompt; answer it in the terminal.
A message you send while the first mate works, from the page, the terminal or the desk floater, shows at once below that line as a faded bubble marked `Waiting, Firstmate will read it next`.
When the first mate reads it in, it becomes an ordinary message in the chat, shown once.
If it is still not read in after two minutes, or the first mate is no longer working, the mark says `Still waiting, Firstmate has not read it yet` and the bubble stays.
This only shows what is waiting; it does not change how the message is delivered.

A message box at the bottom sends to the same first mate.
A message can hold up to 200,000 characters, enough for a long pasted transcript.
Enter sends and Shift+Enter starts a new line.
When Claude Code offers a suggested next message, the grey text in the terminal's input, the empty message box shows the same words, and Tab fills them in, as in the terminal.
The page reads the suggestion from the first mate's own chat box through `bin/fm-desk-voice.sh suggestion`, only while the first mate is ready and the box holds nothing typed; it types nothing there.
Under the box, the first mate's own part of the status bar row shows its model and effort, how much of its context and quota it has used, and what the session has cost.
You can paste or drop images onto the page; they are attached to the next message.

The page is another window onto the one primary session, not a second first mate.

### The band and the projects

The band and both project views are drawn from what the terminal's own regions show: `bin/fm-factory.py --screen` for the Factory pane and `bin/fm-bridge-strip.sh fields` for the strip.
The page chooses no call and counts nothing itself, so it cannot disagree with the terminal; a worker whose checks are running counts as busy in the lamps and the counts, as it does on the worker's own row ([factory-pane.md](factory-pane.md)).
It reads them again about every three seconds while visible. Opening the page is not a look for what each factory tells as new; pressing one of its buttons or keys on Factories is, as a key press in the pane is, and one on a project tab is not, as a key in a factory's own tab is not.
A worker shows the step it is on and the one line it says about what it is doing; [Watch this worker](#watch-this-worker) opens a copy of its screen.
A long title shows on one or two lines; click it to read the rest, and a call's title shows whole once its card is open.
A web address in a title or the feed reads as a short label, such as `the pull request`, that opens the link.

### How Factories works

Factories, on the right of Control Centre, is "each project's work, start to finish": everything every worker does, told in plain words, so you can see where things stand without reading a terminal.
It shows the same facts as the terminal's Factory pane, which [factory-pane.md](factory-pane.md#the-overview) describes in full; this is how to read it on the page.

- **The three sentences** at the top say what stands: how many things need you, how many jobs are running and whether one hit a problem, and what went live or came back as a report since you last looked.
  Each sentence is a link to the part it speaks for.
- **Needs you** lists every call waiting on you, across all projects, most pressing first; the first card is marked First up.
  A question shows its answers and Starship's suggestion; finished work ready for your OK shows its In short, See it, You need to and Risk lines beside Keep it.
  Under the cards, two shelves hold the calls that wait on you but are not listed: older questions that waited two weeks with no date, each with Bring back and No longer needed, and the calls coming back on a date.
- **Your factories** tells each project in one block, as three rows:
  - **Now** is what is running or stopped there: each busy job with its title, how long it has run, the four steps (planning, building, checking, ready for your OK) and what its worker is doing this minute, or `Nothing is running.`
  - **New** is what came out since you last looked, newest first, each with its time: went live, report ready, settled with what you answered, ready for your OK, finished, hit a problem or closed. A change that went live links to the change, and a report has a Read it button.
  - **Next** is the first job in line and how many more are lined up after it, or that it starts once you answer.

  A project with nothing for you, nothing running and nothing new folds into one line under Quiet for now.

Pick a project's tab in the header, or highlight the project in Your factories and press `enter`, to open **its own page**, which reads top to bottom:

- its name, who steers it, what it is for, and one sentence of how it stands;
- **Needs you**, only this project's calls, with its own older questions shelf;
- **Happening now**, its Now, with each worker and the step it is on;
- **Lately**, its New, the eight newest outcomes;
- **Up next**, the first three in line with the rest folded into counts;
- **Coming back**, every call put off to a date, each with its date;
- **How this crew works**, the rules this project's crew follows and what it learned lately;
- **Conversation**, what you and Starship said about it, newest first, with Talk to this crew to add to it.

On a wide screen Needs you sits on the left and the rest on the right; on a narrow one it is all one column in that order.
`esc` goes back to Control Centre.

#### What the page lays out its own way

- A project's tab reads top to bottom as the pane's page does ([factory-pane.md](factory-pane.md#a-factorys-own-tab)), split into two columns on a wide screen as [its own page](#how-factories-works) describes; Up next folds the rest behind `N more lined up` and the other counts.
- A project's tab has no list of workers beside its page: its Happening now already names each worker with the step it is on, so a second list would only repeat it.
  Watch this worker, on a busy job in Your factories, opens that worker's screen ([Watch this worker](#watch-this-worker)).
- A call on its own project's tab does not repeat the project's name beside its title.
- Who steers is a quiet line under Talk to this crew on the project's own tab only, such as `Starship steers this factory. Change`; Change, or the `s` key there, asks first and changes it only on Change who steers, as an answer takes two clicks.
  A project's head in Your factories says `You steer` when you do, and nothing when Starship does; the `s` key still switches the highlighted project there, as in the pane.
- A project in Your factories sets Now, New and Next side by side with their words on the left, and on a narrow screen the words sit above what they lead.
- A project's conversation reads newest first.
- The older questions shelf lists its questions open, each with its Bring back and No longer needed buttons, instead of one line that `enter` opens.
- On a screen worked by touch, the key hints on the buttons and the line of keys at the bottom are not shown.

Words that are already plain are the terminal's own.
Only these change, and only where the pane or the strip wrote them; a job's title, and what a worker says it is doing, are never reworded:

| Terminal | Page |
| --- | --- |
| ready to merge, PR ready, has its PR ready | ready for your OK |
| land it | make it live |
| queued | waiting to start |
| deferred | put off |
| failed, in the alert | hit a problem |
| factory | project |
| NEEDS YOU, YOUR FACTORIES, QUIET FOR NOW | Needs you, Your factories, Quiet for now |

### Watch this worker

Watch this worker opens a live copy of that worker's screen, the same screen the factory tab in the terminal shows beside the factory's page.
It fills the project's tab, under the worker's title, and reads the screen again every two seconds while the page is visible.
The copy follows the end of the screen, unless you scroll up to read, and scrolls inside its own box on a narrow screen.
It is read only: the screen is plain text, without the terminal's colours, and no key, click or typing reaches the worker; talking to the worker stays with Talk to this crew.
When the job stops being at work, the copy keeps its last screen, faded, and says so; a screen that cannot be read for a moment says so and is tried again.
Back to the project, or `esc`, returns to the project's tab with the job marked in its Happening now.

### The buttons

Each button is one of the Factory pane's writing keys and sends the note that key sends, through `bin/fm-factory.py act`:

| Button | Pane key |
| --- | --- |
| An answer, then Send to Starship | `1`, `2`, `3`, then enter |
| Keep it, then Send to Starship | `k`, then enter |
| Ask for changes | `c` |
| Talk it through, Talk to this crew | `t`, typed |
| This is already settled | `x` |
| Read the report, Read it | `r` |
| Change (who steers), then Change who steers | `s` |
| Bring back, No longer needed, then Send to Starship | `b`, `n`, then enter |

An answer, a keep, or an older question's Bring back or No longer needed takes two clicks, the choice and then Send to Starship, so a stray click sends nothing, and the page says whether the note was sent.
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
Each button carries its key as a small hint, and a line of keys sits at the bottom, as in the pane; both can be hidden in Settings, and neither is shown on a screen worked by touch.

### Settings

The Settings button opens one small panel:

- **Text size**: five steps, Smaller to Largest, starting on Normal in the middle; the whole layout scales with it, except that below Normal the chat keeps Normal's width, so more words fit on a line.
- **Style**: Calm, the default, in soft pastel tints with each section of a panel as its own card, or Lively, the same grouping with stronger colours; in Light both draw the header light too.
- **Light or dark**: Auto follows the system setting; Light is a warm cream.
- **Colours**: Default is the page's own colours; Sea, Green, Warm, Slate and Paper are ready-made schemes, picked with one click from their swatches, each with its own light and dark.
  Custom opens three colour pickers, Accent, Background and Text, that change the page as you pick; it starts from the colours on screen, and keeps its picks for light and for dark apart.
  Every other colour on the page, its panels, lines and status colours, follows from those three.
  Text and accent are always kept readable: a pick too faint against its background is moved to the nearest readable shade, a mid-grey background that no text reads well on is shown a shade lighter, and the panel says so.
  **Back to default** returns to the page's own colours.
- **Reduce motion**: turns off the page's few animations, as the system setting also does.
- **Show key hints**: the small key letters on the buttons and the line of keys at the bottom.
- **Put the panels back**: returns the line between Firstmate and Factories to where it started.
- **Voice**, shown only when the home speaks its replies: the voice volume, from 0 to 200% of the computer's own volume, with Back to 100%; Mute the voice; and the recent replies, each as the desk floater's bubble shows it, with Hear again.
  These belong to the home rather than the browser: they are read and changed through `bin/fm-speak.sh` (`--volume`, `--mute`, `--unmute`, `--history`, `--caption`, `--replay`), so the floater's right-click menu and every browser see the same level ([desk-floater.md](desk-floater.md#controls)).

Every other setting and the panel size are kept in the browser's own storage, so each browser has its own, and a browser that blocks storage gets the defaults.
A browser that kept settings from the first version of the page keeps its look and starts on Normal text.

### This week

When the home has a weekly "what changed" page ([configuration](fork-configuration.md#weekly-changes-page-configweekly-changes)), a This week button in the header opens the newest one in its own window, behind the same sign-in.
With no page written yet, the button is not shown.

## Starting it

```
FM_HOME=/path/to/home bin/fm-web.sh start
```

The best way in is as an app of its own, over the whole screen, with no address bar or tabs:

```
FM_HOME=/path/to/home bin/fm-web.sh open
```

`onboard-starship` runs this once for you as part of the first start ([desk.md](desk.md)).
`open` starts the page if it is not running and opens it as its own window, full screen where the browser allows it, through Chrome's app mode (or Chromium or Edge), else in the default browser.
It signs that window in with a link that works once, within two minutes, so the home's token never sits on a command line; `open --print` prints such a link instead, for the first mate to hand over.
Once in, the browser offers to keep it as an installed app: in Chrome, Install Starship from the menu; in Safari, File, then Add to Dock.
The page carries a web app manifest and the Starship ship as its icon for that.

The server restarts itself when its own code changes on disk, so a Starship update shows on the page without restarting anything by hand: it checks every two seconds, waits until the new code reads the same twice and compiles, and keeps running the old code otherwise. A send or button press under way finishes and gets its answer before the restart.
It keeps its process and port, and an open page reloads itself once it sees the new code, unless words or pictures are waiting in its message box.

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
A message typed while the first mate works is recorded in the transcript's own queue entries (`queue-operation`) as soon as it is typed; the page shows the owner's messages among them as waiting until the transcript shows each one read in or taken out of the queue, and never shows the machinery's queued notices.
`bin/fm-web.sh conversation` prints the same reading once as versioned JSON, with no server, for another page that shows a home's conversation; [direct-line.md](direct-line.md) lists the other reads such a page uses.
The page polls about every one and a half seconds while visible.

## How it reads a worker's screen

Watch this worker reads the screen through `bin/fm-peek.sh`, the read the terminal's live copy of a worker uses, at most once a second for every open page.
It reads only a job that `bin/fm-factory.py --screen` marks `live`, the jobs the terminal keeps a live copy of a worker for; any other job is not read and the page says the worker is not at work.
Every terminal escape and control character is taken out on the server, and the page puts the text in as text, never as HTML.

## How sending works

Every message goes through `bin/fm-desk-voice.sh send --source web`, the desk floater's own path.
It types the message into the primary's own chat when that chat is safely empty, or past a Claude draft, and otherwise saves it to the durable desk-voice mailbox with a wake.
Under the box, the page says which happened: typed into the chat, typed but not confirmed, or saved to the mailbox.
Pasted images are saved where the floater saves its screenshots, `state/desk-voice/shots/`, owner-only, and passed with `--image`.
The words go to it on standard input (`--stdin`), not as an argument, because Linux refuses any single argument over 128 KiB and a long paste can be larger.
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
- A linked file is served read-only, only with the cookie, only when its path resolves, symlinks included, to an existing file of a listed type under the home's `data/` or `.lavish/` folder with no hidden part below it; a `../` or an absolute path in the address is refused.
  A linked web page or drawing runs in a sandbox with an opaque origin, so it can neither read this page nor send through it, and a file it refers to by a relative address does not load.
- Every request must carry a Host of `127.0.0.1:<port>`, so a page using DNS rebinding cannot reach it.
- Every POST also needs the page's CSRF header, a same-origin Origin when the browser sends one, and no cross-site fetch metadata.
  A custom header cannot be sent cross-origin without a preflight the server never answers.
- Pages carry a strict Content-Security-Policy with per-response nonces, and all transcript text is escaped before Markdown is applied; only http and https links become links.
- The request log, `state/web/web.log`, records paths only, never the token or a code, and leaves out the page's successful polls.
- A button reaches the same guards as a send, then only `bin/fm-factory.py act`, with only the fields the pane's keys take; the server writes no note itself.
- A worker's screen is served only with the cookie, only for a job name the screen marks `live`, and only by a GET that reads through `bin/fm-peek.sh`; nothing on the page can type into a worker.
- The server never takes the session lock, never drains wakes, and never writes backlog or fleet state.
  Its only writes are its own `state/web/` files, one-time codes included, and the pasted images; a button's note, and the look that pressing it records, are written by `bin/fm-factory.py` as they are for the pane.

To revoke access, stop the server, delete `state/web/token`, and start it again; old cookies stop working.

## Limits

- Claude Code primaries only.
  Other primary harnesses keep their transcripts elsewhere; supporting them is a follow-up.
- Local only.
  There is no remote access and no account system; the bridge view is the phone surface.
- No voice inside the page; the desk floater floats over it and keeps that role, and the talk boxes take typed words.
- A worker's screen shows as plain text, without its colours, and only to read.
- The page shows recent conversation, not the full history of a long session.
- A permission prompt or question dialog in the terminal is not shown as a control; a message sent meanwhile goes to the mailbox.
- The suggested next message shows only for a first mate running in tmux or Herdr, whose screen reads keep the grey styling that tells a suggestion from typed words.

## Related surfaces

- [factory-pane.md](factory-pane.md) and [bridge-strip.md](bridge-strip.md): the terminal regions the page mirrors, which own what is shown and what each key sends.
- [bridge-view.md](bridge-view.md): the phone fleet glance.
- [desk-floater.md](desk-floater.md): voice, dictation and screenshots into the same chat.
