# The desktop companion

A scoped visual helper running in the ChatGPT desktop app, alongside the terminal Firstmate rather than instead of it.
It exists for work the terminal cannot do: looking at a native app window, checking something on screen, confirming a panel actually renders.

This page is the reusable setup: a shared folder, a first prompt, and a way to hand it a task and get an answer back.
It is a template with placeholders, not a record of one machine - fill in your own paths and thread names locally, and keep thread identifiers, account data, and personal paths out of anything tracked.

## What it is not

- **Not a second Firstmate.**
  The companion never starts a Firstmate session, takes its session lock, spawns or steers workers, merges anything, or edits shared configuration.
- **Not a managed second mate.**
  Nothing here provisions a persistent home, a charter, or supervised work; a companion is a chat you talk to on purpose.
- **Not a selectable runtime backend.**
  `codex-app` is still not a backend Firstmate can dispatch on - [codex-app-backend.md](codex-app-backend.md) owns that contract and the lifecycle pieces that remain unverified.

## Laptop-local setup

None of this arrives by `git pull`, and none of it can be automated from another machine.
Do it on the laptop itself, in this order.

1. **Install or update the desktop app** through its own updater, and the CLIs through their established owners.
   `bin/fm-bootstrap.sh` owns Firstmate's toolchain detection; do not maintain a second install list.
2. **Enable the Computer Use plugin** in the app's plugin settings, including its server and skill toggles.
   Developer mode is not part of Computer Use; that is for adding a custom MCP connection.
3. **Grant macOS Accessibility and Screen Recording** to the app when prompted.
   These are per-machine, per-app permissions and a fresh grant often needs the app relaunched before it takes effect.
4. **Sign in to each account separately.**
   Codex and any Claude accounts keep their own logins; a subscription does not create a separate allowance per device, so a second machine draws down the same windows as the first.
5. **Choose a shared folder** the companion and the terminal can both reach, and use it for every handoff.

Official references: <https://learn.chatgpt.com/docs/app>, <https://learn.chatgpt.com/docs/computer-use>, <https://learn.chatgpt.com/docs/import>.
Nothing here imports credentials, hooks, or history from another tool; if a product import is wanted, run it deliberately rather than as a side effect of setup.

## The shared folder and the return path

Pick one folder, write the brief into it, and ask for the answer back as a named file in the same place.
A file the companion writes and reads back is the only handoff verified end to end; treat a claim made only in chat as unconfirmed.

```
<shared folder>/START-HERE.md      what the companion is and is not allowed to do
<shared folder>/<request>.md       one task, with its own request id
<shared folder>/<request>-answer.md  what the companion observed, written and read back
```

Give every request an id of your own making and require it to appear in the answer file.
That is what ties an answer to the request that caused it rather than to some earlier turn.

## First companion prompt (template)

Copy this, replace the angle-bracket placeholders, and paste it into a new desktop chat.

```text
Act as the desktop companion to the Firstmate already running in my terminal.
Do not start another Firstmate session, take its session lock, spawn or steer its workers,
merge anything, or change shared configuration.

Your first task is a read-only capability check.
Confirm that <shared folder>/START-HERE.md is readable.
Report whether Computer Use tools are actually available to you, naming the tools you can call.
If they are, use them to inspect <the app or window you want looked at>, without clicking,
changing settings, signing in or out, or restarting anything.

Report what you actually observe. If a tool errors, quote the exact error and stop -
do not retry in a loop and do not describe an expected result as an observation.

With this explicit permission, write your result to <shared folder>/<request>-answer.md,
including request id <request id>, the real timestamp, the folder you are working in,
which capabilities you actually exercised, and whether the thing was observed.
Then read that file back and confirm what it contains.
Do not include credentials or account identifiers.
```

## Handing it a task without switching windows

The installed Codex CLI can queue a message into an existing desktop session:

```sh
codex queue --thread "<session uuid or exact session name>" --message "<text>"
```

`codex queue --help` on the installed build is authoritative for the flags.
`--thread` takes a session UUID or an exact session name, so naming a session deliberately is easier to live with than copying a UUID around.

A message queued this way reached an existing thread and started a new turn on it after several minutes of inactivity, and that turn still had the app's native Computer Use tools available - it was the same desktop session continuing, not a headless process.
That was observed on individual deliveries; it is not established for every future delivery, nor after the app restarts.

### Accepted is not completed

`codex queue` prints its receipt as soon as the message is enqueued.
Three stages are worth keeping apart, because only the third one means the work happened:

| Stage | What the receipt proves | How you confirm it |
| --- | --- | --- |
| Accepted | The CLI wrote the message into the session's queue. Exit 0 means enqueued, whether or not anything ever drains it. | The command's own output. |
| Picked up | The live app dequeued it into a turn. | The companion visibly starts a turn. |
| Completed | The turn ran and produced the work you asked for. | Your answer file exists, carries your request id, and says what was actually observed. |

So a queued command is a request, not a result.
Pair every queued message with an explicit file acknowledgement and wait for the file:

```sh
codex queue --thread "<session name>" --message \
  "Request <request id>: read <shared folder>/<request>.md and follow it. \
When done, write <shared folder>/<request>-answer.md including request id <request id>, \
the real timestamp, and exactly which tools you called. Then read that file back."
```

If the answer file never appears, the message was accepted and nothing more; the app may be closed, the session archived, or the turn still running.
Do not read the receipt as delivery, and do not infer a result from the absence of an error.

### What this transport is and is not

Sending into an existing session and getting a file back are the verified parts.
Reading a session's live transcript or state, stopping or interrupting a turn, surviving an app restart, and having the companion report into Firstmate's own status records are all unverified, so there is no supervised desktop worker, no managed second mate, and no `codex-app` backend.
Building any of those on undocumented local databases is not an option: those files are private, versioned, and carry no stability contract.

## Known app-access limit

Selecting Baby Menu through Computer Use timed out (`getApp`, server error `-10005`), on a run where the tool's own inventory reported the app as not running and on a later retry - so the quota panel was never observed by the tool.
That is a limit of reaching that particular app, not of the command transport, which worked in the same turns.

If you need the panel looked at, open it by hand first - the app opens its popover only on a real click of its menu-bar icon - and then queue the request while it is on screen, asking for one bounded attempt and the exact tool error if it fails.
An app-selection call may itself try to launch the app, which is not the same as a visible window; require the answer file to say whether the panel was actually seen.

## Related owners

- Baby Menu quota panel: [baby-menu-quota-widget.md](baby-menu-quota-widget.md)
- Codex App backend contract and the lifecycle pieces still missing: [codex-app-backend.md](codex-app-backend.md)
- Second-machine setup overall: [porting.md](porting.md)
- Toolchain detection: `bin/fm-bootstrap.sh`
