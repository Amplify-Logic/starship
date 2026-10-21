# Starship bridge view

The captain's phone-first fleet page.
`bin/fm-bridge-view.sh` and `bin/fm-bridge-view.py` own commands, bind, auth, snapshot, photo-drop, and hold-to-speak mechanics; read the script header before first use.

## What it is

A glance of what needs the captain, what is under way, what just finished, and what is waiting.
It is an observation of durable fleet records, not a place to approve, merge, or spawn.
Hold-to-speak is a second voice channel into firstmate; it does not answer Needs-you items from this page.
Outbound jumps are allowlisted GitHub pull-request links plus captain-configured HTTPS pinned links below the header; [`docs/configuration.md`](configuration.md#bridge-pinned-links-configbridge-links) owns the pinned-link schema.
The same authenticated page also accepts photo drops from the captain's phone, including several photos in one picker session, and a hold-to-speak control that forwards audio into the local voice mailbox that [`config/bridge-mailbox`](configuration.md#bridge-voice-mailbox-configbridge-mailbox) names, when the home has one.
Those two controls sit at the top of the authenticated page, above the fleet glance, so they are reachable without scrolling on a phone.
A Machines page beside the glance shows whether the captain's machines and background services are up; it observes and changes no machine.

The page is served from the Mac on IPv4 loopback and published on the tailnet with **Tailscale Serve HTTPS**.
It never uses Tailscale Funnel and never binds `0.0.0.0`.
The server requires Python 3.12 and uses only the standard library.

Bookmark: `https://your-mac.your-tailnet.ts.net/` after Serve is pointed at the loopback port.

On the Mac itself, [web.md](web.md) is the localhost chat page with this glance as its side panel.

## Auth

There is one captain, so there is no account system.
The first visit shows Log in.
A dedicated high-entropy passcode, not the mailbox relay token, sets an HttpOnly, Secure, SameSite=Strict, host-only session cookie with about a seven-day lifetime.
The salted scrypt hash lives at `bridge/passcode.hash` inside a mode-0700 `bridge/` directory.
Sessions live in `bridge/sessions.json`.
Logs go to `bridge/bridge.log`, not into `state/`.

`config/bridge-view` may contain `host=<magicdns-name>` for Host and POST CSRF checks.
`FM_BRIDGE_VIEW_HOST` overrides that file.
Login and other POST writes require CSRF proof on top of Host.
When the browser sends `Origin`, it must match `https://<host>` (or that host on port 443) exactly.
iPhone Safari omits `Origin` on this same-origin form POST, or sends the literal string `null` as privacy masking.
Both are treated as absent and accepted only when `Sec-Fetch-Site` is `same-origin` or `none`, or when `Referer` is an `https` URL whose host matches the expected Serve name.
A present but wrong Origin is always rejected.
Error responses drain a bounded unread request body (or close the connection) so a keep-alive socket does not treat leftover POST bytes as the next request line.

Initialize once:

```sh
FM_HOME=/path/to/home bin/fm-bridge-view.sh init-passcode
```

That writes the hash and a one-shot plaintext envelope at `data/bridge-view-passcode.txt` (mode 0600) so firstmate can hand the passcode to the captain.
Delete the envelope after it has been delivered.
Never put the passcode in a URL.

Lost phone: run `FM_HOME=/path/to/home bin/fm-bridge-view.sh revoke-sessions`, and if needed remove the phone from the tailnet.

A VoiceLoop compromise can still read fleet files because both processes run as the same Mac user.
Separate passcodes only limit token leakage, not a full process break.

## Serving

Listen only on `127.0.0.1:8766` (override the port with `FM_BRIDGE_VIEW_PORT`).
Publish with Serve, never Funnel:

```sh
tailscale serve --bg --https=443 http://127.0.0.1:8766
```

`bin/fm-bridge-view.sh check-funnel` refuses if Funnel is on.
The server also refuses to start while Funnel is on.
A tailnet-only Serve HTTPS proxy is Funnel off and is the supported publish path.

Keep the process alive across reboot with a launchd KeepAlive agent.
Render a local plist and install it by hand; this is a machine-local setup action, not tracked captain state:

```sh
FM_HOME=/path/to/home bin/fm-bridge-view.sh render-plist > ~/Library/LaunchAgents/com.firstmate.bridge-view.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.firstmate.bridge-view.plist
```

## Observation

The page calls `bin/fm-bearings-snapshot.sh --json --passive-view --all-in-flight --all-decisions --all-queued` so the waiting list is complete.
The title, repo, hold kind, and hold reason the page reads are added to that model by `bin/fm-bridge-fields.sh` after the projection.
When that script is absent the page receives the bare projection and its buckets degrade to the fields upstream emits.
That named Bearings mode is allowed while away mode is on; ordinary `/bearings` chat still refuses until return catch-up finishes.
The server caches one observation for about 30 seconds, runs one refresh at a time, and caps subprocess time and output size.
The snapshot child keeps a scrubbed environment (no parent secrets) but resolves tool directories at server start from HOME and the parent PATH, including `~/.local/bin` and a discovered nvm node bin, so CLIs such as herdr and tasks-axi are found without a version-specific hardcoded path.
A missing session-provider CLI must fail immediately rather than polling; the snapshot either returns glance data or a 503 with a clear error within seconds.
It never takes the session lock, never drains wakes, and never writes backlog or state.
Photo drops and hold-to-speak are the write paths documented below; observation GETs still only read.
A 503 still includes today's photo count from inbox sidecars so the counter does not depend on glance data loading.

The client refreshes every 30 seconds and also refreshes on `pageshow` and when a hidden tab becomes visible.
The four buckets are Needs you, Under way, Waiting, and Just finished.
Needs you shows at most five items that need the captain now.
Blocked, failed, or gate-parked live work leads the list.
Parked holds, recorded duplicates, and retire candidates are excluded from that list by their backlog hold kind and hold reason, not by guessing from titles, and they remain reachable under Waiting.
If more Needs-you items remain, a quiet "N more waiting on you - show all" control reveals the rest in one tap.
Waiting is a set of per-project count chips, one per observed project, not a global wall of items.
A chip is named from the home's `data/projects.md`: a row's `label=<word>` token when it has one, otherwise its registered name in plain words.
A row matches when that name or any `alias=` name equals the item's repository name (the part after any `owner/` prefix) as a whole; an item with no repository matches only by whole dash-separated words of its task id, and an unregistered repository is named from its own name.
Each chip expands to that project's complete list in one tap.
Item lines are short captain-facing titles; internal ids, paths, and repro strings are not used as the primary line.
If the first observation request fails, the buckets replace "Loading…" with "Cannot reach the desk" immediately and the full-page overlay appears.
If refreshes stop for 90 seconds after a successful load, the already-open tab overlays "Cannot reach the desk" from the client clock.
Last-good on the server cannot save a tab that never hears back.

## Routing

Near its end the glance has a read-only Routing section: which model each kind of job goes to, the latest Jev routing decisions, a graph of the running workers, and the live workers with model, effort, age, and state.
It rides the same 30-second observation as the buckets above, so it never adds a request or a refresh of its own.

The server reads it from `bin/fm-routing-snapshot.sh --json`, whose header owns the `fm-routing.v1` fields, and joins it to the bearings read the glance already made:

- The model roster is every rule in `config/crew-dispatch.json`, as a short label cut from its `when` text, beside its model and effort, then the default.
- The decisions are the newest few lines of the local dispatch decision record ([`docs/configuration.md`](configuration.md#typed-dispatch-resolution-env-typesafe_api_key) owns it): outcome, probability, rule, and chosen profile.
- The live workers are the bearings `in_flight` rows, so they list exactly the work Under way, Waiting, and Needs you already show, each with its record's kind, model, effort, and spawn time.
- The graph shows the same rows under firstmate, plus each second mate from the bearings `secondmates` rows with its own workers hanging beneath it.

A task is named only by the title the glance already shows for it, and a decision whose task the glance no longer shows reads "Earlier task"; task ids, a record's outcome line, and brief text never reach the page.
The section reads local files only: it makes no Jev call, changes no routing or model, and sends nothing off the machine.
If the routing read fails, the buckets still render and the section says why in place.

The mailbox indicator is a local listen or launchd check against the mailbox `config/bridge-mailbox` names, and reads off when the home names none.
It must never call `GET /v1/announcements`, because that call marks announcements delivered.

## What I remember

After Routing, a read-only What I remember section shows exactly what this home keeps about the captain, so Starship's memory is legible rather than hidden.
It rides the same 30-second observation and redraws only when a file changed, so a fold the captain opened stays open.

The server reads these files under the home's `data/` and nothing else: `captain.md`, `captain-shared.md`, `learnings.md`, and each goal charter directly inside `goals/` ([`chart-room.md`](chart-room.md) owns charters).
Each source is one fold with its last-changed date and its entries as plain text under the file's own headings; an absent source still appears as nothing kept.
A symlink is skipped rather than followed.
The harness memory store under `~/.claude`, `.env` and key files, task and project data folders, and the backlog are never read.

Any line with a word starting gift, surpris, or present is withheld so the captain's private gift exchange never reaches the screen.
A matching line of any kind (an ATX or Setext heading, a bold label, a paragraph, a bullet, or a table row) withholds its whole entry and everything after it, blank lines and tables included, up to the next ATX heading of the same or higher level than the heading it sits under; a matching heading counts as under its own level.
A matching line under no heading withholds everything up to the next ATX heading or the end of the file.
Only an ATX heading ends a withheld block; a Setext underline inside one is withheld with it.
A goal charter whose name matches is withheld whole, name included.
The page footer says how many lines were withheld.

The section is shown only to the captain's logged-in devices on the private network and is never sent to any outside service; there is no editing from the page and no new storage.
If the read fails, the buckets still render and the section says why in place.
`read_memory` in `bin/fm-bridge-view.py` owns the exact parsing.

## Machines (`/machines`)

`/machines` is a read-only map of the captain's machines, on the same server, session cookie, Host check, security headers and loopback-plus-Serve publish path as the glance; `/api/machines` answers 401 without a session.
The glance, the deck and this page link to each other through the page nav, and the glance's Machines entry carries a coloured dot and the current alert count, or says unreadable when the read fails.

The server reads it from `bin/fm-machines.py --json`, whose header owns the `fm-machines.v1` fields, as one scrubbed, bounded child like the bearings snapshot; the ssh agent socket is the one extra variable passed through so a configured ssh alias can log in.
It collects only on request, through the same 30-second cache, so nothing runs while no page is open and there is no background daemon.
Every check runs at once and the whole read ends within 15 seconds, inside the bridge's 20-second child limit; a check still running then is shown as timed out in its own place while the rest of the page stands.
A failing read answers 503 with the collector's reason and the page says so in place.

What it shows, from real sources only; a value that cannot be read is shown as unknown, never invented:

- Every machine on the tailnet from `tailscale status --json`, with its OS, live or offline state, last seen time, and tailnet IP; a machine that joins the tailnet appears on its own, and Mullvad exit nodes are left out.
- This Mac, marked as this machine, with its load, memory, disk, and uptime, and the Firstmate background services here: the bridge page and the desk floater, each listed only when it is installed or answering, plus any loopback services named in the config, such as a voice mailbox's health address.
- For each machine named in the config with an ssh alias, the same numbers over ssh (BatchMode, a four-second connect timeout), read only when the tailnet does not report it offline; Linux machines also list failed systemd units.
- Each HTTPS probe named in the config, with its status and latency.

Health counts checks passing out of the total: each watched machine reachable, each service up, and each probe passing.
Alerts name a watched machine offline or unreachable, a watched machine whose numbers cannot be read, a service down, a probe failing, failed systemd units, a disk over 90 percent full, or a tailnet that cannot be read.
Only machines named in the config are watched, so a phone or laptop that sleeps shows offline on its card without raising an alert.
The map is the hub card for this Mac with its services, then the tailnet machines, any machines reached only over ssh, and the web probes, each group joined to the hub by its link.

[`docs/configuration.md`](configuration.md#bridge-machines-configbridge-machines) owns the optional `config/bridge-machines` file; without it the page still shows the tailnet and this Mac.
There is no button on the page that acts on a machine.

## Writes

Login and logout POSTs remain the authentication writes.
The other write paths are an authenticated photo drop and authenticated hold-to-speak.

`POST /upload` requires the same session cookie plus Host and CSRF checks as login.
The body may be `multipart/form-data` with a `photo` file field, or a raw image body whose `Content-Type` is one of `image/jpeg`, `image/png`, `image/webp`, `image/heic`, or `image/heif`.
The server accepts those declared types only after magic-byte sniffing (JPEG, PNG, WebP, HEIC/HEIF); a matching header is not enough.
The request is capped at 15 MB and returns 413 when larger or 415 when the type or magic bytes are not an allowed image.
The per-session rolling-hour limit counts authenticated, non-empty attempts within that cap, including attempts later rejected as unsupported, and returns 429 after 30 such attempts.

Files land under `data/bridge-inbox/` (created mode 0700) with a unique timestamped name such as `20260819T113530Z-<hex>.jpg` and a sibling `.json` sidecar recording `received_at`, `original_name`, `size`, and `content_type`.
A write here wakes the watcher at once only when a watcher hook of the home's private add-on provides that wait ([`watcher-continuity.md`](watcher-continuity.md#add-on-watcher-hooks)); otherwise it is picked up on the ordinary check cadence.
Names never overwrite; the directory is quarantined storage only.
The server does not execute, decode, or otherwise parse image contents beyond the magic-byte sniff.
The photo path writes only to `bridge/` and this inbox; hold-to-speak sends requests through the loopback mailbox API instead of writing mailbox state directly.

The glance page exposes a phone-first file input (`accept` images, `multiple` so several photos can be chosen in one picker, no `capture` attribute so iOS Safari offers Photo Library as well as Take Photo) and submit control, a success or failure message that reports partial failures, and the count of photos received today (UTC date of `received_at`, falling back to the timestamped sidecar filename when that field is absent or unreadable).
The client posts selected photos one after another and shows progress such as `3 of 5 sent`.

`POST /speak` requires the same session cookie plus Host and CSRF checks as login and upload.
The body may be `multipart/form-data` with an `audio` file field, or a raw `audio/*` body.
Safari on iPhone typically records `audio/mp4` (m4a); the server sniffs ftyp/mp4, webm, wav, and mpeg/aac magic bytes and rejects anything else.
The request is capped at 10 MB to match the mailbox audio limit.
The bridge process reads the relay token from the file `config/bridge-mailbox` names under the home and POSTs a `voice-question` to `/v1/questions` on the loopback port it names, with that bearer token; without that file `/speak` answers 503 `mailbox is not configured`.
The token is never written into HTML, JavaScript, or a response body.
The audio filename is `bridge.m4a` (or `bridge.webm` / `bridge.wav`) so mailbox records are distinguishable from VoiceLoop captures.
`GET /api/answer/<request_id>` is session-authenticated, polls `GET /v1/answers/<id>` on the mailbox, and returns JSON `{pending:true}` or `{text:"..."}` without audio bytes.
The glance page has a press-and-hold microphone control; after send it shows `Sent` and renders answer text when it arrives.
iPhone Safari `MediaRecorder` flushes `audio/mp4` in timeslice chunks; the page accumulates every `dataavailable` blob and builds the uploaded file in `onstop` after a final flush so a release cannot send only the last slice.
A capture smaller than about 1 KB per second held (1 KB floor) stays in the failure state and never shows `Sent`.
The bridge log records `speak audio bytes=` for each `/speak` request so a truncated upload is visible without opening the file.

Existing `form-action 'self'` and `connect-src 'self'` CSP directives cover the form and `fetch`; scripts and styles stay nonce-based.

There is still no approve, merge, or spawn control on this page or on `/deck`.

## Action Deck page (`/deck`)

`/deck` is the private web rendering of the captain's Action Deck, on the same server, session cookie, Host check, security headers and loopback-plus-Serve publish path as the glance.
The glance, the deck, and the Machines page link to each other through a small page nav under each header.
An unauthenticated `/deck` shows Log in; `/api/deck` answers 401.

The page renders the `fm-deck.v1` model that `bin/fm-deck.sh --json` emits, so the web deck and the terminal pane read the same records through the same selection rules and can never answer "what needs you" differently.
The server runs that read as a scrubbed, bounded child exactly like the bearings snapshot, caches one model for about 30 seconds, and returns 503 with the collector's own reason when the read fails; the page then shows "Cannot reach the desk" in the header and every region with that reason beneath, and does not raise the full-page overlay over it (the overlay is only for a tab whose refreshes stop after a successful load).
`bin/fm-deck.sh`'s header owns what each section reads; `bin/fm-deck-render.py` owns the model's fields.

What the page shows, and in this order: ready to run, staged actions that need approval, live asks that need the captain, held backlog decisions, work under way, recent completions, and the loose-ends sweep.
Live asks (answer, unblock, review, check) are the headline; held backlog decisions are a separate collapsed queue with their own count, so standing holds never read as obligations due today.
Finished workers and completed backlog items are folded away from the actionable lists.
Loose ends are a collapsed fold labelled as manual inbox items, kept apart from automatable actions.

The page acts on nothing.
It carries no approve, run, or merge control, and "Ready to run" is honest about why it is empty: the action gateway records approvals and decisions but has no executor, and approval needs the captain secret on the desk.
Each staged card says so beside its next step rather than showing a disabled or fake control.
Wiring approval or execution into the page is a separate slice that must go through the gateway's own choke point and privilege separation, never through a new endpoint on this server.

Outward links follow one rule for every row: an ordinary `https://` URL with a host and no whitespace is a clickable link that opens in a new tab with `noopener noreferrer`; anything else (a tray target such as `device://…`, a report path under `data/`, a bare token) is shown as text.
The server applies that rule before the model reaches the browser, so the page can open nothing on the Mac's filesystem and nothing over another scheme.
Every string in the model passes the same control-character scrub the terminal renderer applies.

## Watcher check

The home-local registered watcher check is existence-only.
It determines whether any mailbox row is unanswered with a read-only local database query, prints only `glasses question waiting` when one exists, and leaves transcription to the firstmate turn that handles the wake.
It must not invoke `glasses-voice-pending`, OpenAI, or any other external transcription API inside the watcher check.
This keeps the check compatible with glasses CLI versions both before and after an existence-only CLI flag is available.

The mailbox half of the generated check is:

```bash
HOME_DIR=/absolute/path/to/firstmate-home
MAILBOX="$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
if [ -f "$MAILBOX" ] && command -v sqlite3 >/dev/null 2>&1 \
  && [ "$(sqlite3 -readonly "$MAILBOX" "SELECT 1 FROM requests WHERE state != 'answered' LIMIT 1;" 2>/dev/null)" = 1 ]; then
  printf '%s\n' 'glasses question waiting'
  exit 0
fi
```

The same registered check may then apply the existing seen-marker comparison for `data/bridge-inbox/*.json`.
After creating or changing the private mode-`0700` `state/<id>.check.sh`, bind its exact bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Documentation-only delivery satisfies this repository task; swapping the live private check is a later operational step outside this repository.
