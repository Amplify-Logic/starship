# Starship bridge view

The captain's phone-first fleet page.
`bin/fm-bridge-view.sh` and `bin/fm-bridge-view.py` own commands, bind, auth, snapshot, photo-drop, and hold-to-speak mechanics; read the script header before first use.

## What it is

A glance of what needs the captain, what is under way, what just finished, and what is waiting.
It is an observation of durable fleet records, not a place to approve, merge, or spawn.
Hold-to-speak is a second voice channel into firstmate; it does not answer Needs-you items from this page.
Tapping a GitHub pull-request link is the only outbound jump, and those URLs are allowlisted.
The same authenticated page also accepts photo drops from the captain's phone, including several photos in one picker session, and a hold-to-speak control that forwards audio into the local glasses mailbox.

The page is served from the Mac on IPv4 loopback and published on the tailnet with **Tailscale Serve HTTPS**.
It never uses Tailscale Funnel and never binds `0.0.0.0`.
The server requires Python 3.12 and uses only the standard library.

Bookmark: `https://your-mac.your-tailnet.ts.net/` after Serve is pointed at the loopback port.

## Auth

There is one captain, so there is no account system.
The first visit shows Log in.
A dedicated high-entropy passcode, not the glasses relay token, sets an HttpOnly, Secure, SameSite=Strict, host-only session cookie with about a seven-day lifetime.
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

Keep the process alive across reboot with launchd, same KeepAlive pattern as `com.firstmate.glasses-voice-mailbox`.
Render a local plist and install it by hand; this is a machine-local setup action, not tracked captain state:

```sh
FM_HOME=/path/to/home bin/fm-bridge-view.sh render-plist > ~/Library/LaunchAgents/com.firstmate.bridge-view.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.firstmate.bridge-view.plist
```

## Observation

The page calls `bin/fm-bearings-snapshot.sh --json --passive-view --all-in-flight --all-decisions --all-queued` so the waiting list is complete.
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
Waiting is a set of per-project count chips for Atelier, Journey, Finances, Fleet, Glasses, and any other observed project, not a global wall of items.
Each chip expands to that project's complete list in one tap.
Item lines are short captain-facing titles; internal ids, paths, and repro strings are not used as the primary line.
If the first observation request fails, the buckets replace "Loading…" with "Cannot reach the desk" immediately and the full-page overlay appears.
If refreshes stop for 90 seconds after a successful load, the already-open tab overlays "Cannot reach the desk" from the client clock.
Last-good on the server cannot save a tab that never hears back.

The mailbox indicator is a local listen or launchd check.
It must never call `GET /v1/announcements`, because that call marks announcements delivered.

## Writes

Login and logout POSTs remain the authentication writes.
The other write paths are an authenticated photo drop and authenticated hold-to-speak.

`POST /upload` requires the same session cookie plus Host and CSRF checks as login.
The body may be `multipart/form-data` with a `photo` file field, or a raw image body whose `Content-Type` is one of `image/jpeg`, `image/png`, `image/webp`, `image/heic`, or `image/heif`.
The server accepts those declared types only after magic-byte sniffing (JPEG, PNG, WebP, HEIC/HEIF); a matching header is not enough.
The request is capped at 15 MB and returns 413 when larger or 415 when the type or magic bytes are not an allowed image.
The per-session rolling-hour limit counts authenticated, non-empty attempts within that cap, including attempts later rejected as unsupported, and returns 429 after 30 such attempts.

Files land under `data/bridge-inbox/` (created mode 0700) with a unique timestamped name such as `20260819T113530Z-<hex>.jpg` and a sibling `.json` sidecar recording `received_at`, `original_name`, `size`, and `content_type`.
Names never overwrite; the directory is quarantined storage only.
The server does not execute, decode, or otherwise parse image contents beyond the magic-byte sniff.
The photo path writes only to `bridge/` and this inbox; hold-to-speak sends requests through the loopback mailbox API instead of writing mailbox state directly.

The glance page exposes a phone-first file input (`accept` images, `multiple` so several photos can be chosen in one picker, no `capture` attribute so iOS Safari offers Photo Library as well as Take Photo) and submit control, a success or failure message that reports partial failures, and the count of photos received today (UTC date of `received_at`, falling back to the timestamped sidecar filename when that field is absent or unreadable).
The client posts selected photos one after another and shows progress such as `3 of 5 sent`.

`POST /speak` requires the same session cookie plus Host and CSRF checks as login and upload.
The body may be `multipart/form-data` with an `audio` file field, or a raw `audio/*` body.
Safari on iPhone typically records `audio/mp4` (m4a); the server sniffs ftyp/mp4, webm, wav, and mpeg/aac magic bytes and rejects anything else.
The request is capped at 10 MB to match the mailbox audio limit.
The bridge process reads the glasses relay token from `data/glasses-voice-runtime/relay-token` under the home and POSTs a `voice-question` to `http://127.0.0.1:8765/v1/questions` with that bearer token.
The token is never written into HTML, JavaScript, or a response body.
The audio filename is `bridge.m4a` (or `bridge.webm` / `bridge.wav`) so mailbox records are distinguishable from VoiceLoop captures.
`GET /api/answer/<request_id>` is session-authenticated, polls `GET /v1/answers/<id>` on the mailbox, and returns JSON `{pending:true}` or `{text:"..."}` without audio bytes.
The glance page has a press-and-hold microphone control; after send it shows `Sent` and renders answer text when it arrives.
iPhone Safari `MediaRecorder` flushes `audio/mp4` in timeslice chunks; the page accumulates every `dataavailable` blob and builds the uploaded file in `onstop` after a final flush so a release cannot send only the last slice.
A capture smaller than about 1 KB per second held (1 KB floor) stays in the failure state and never shows `Sent`.
The bridge log records `speak audio bytes=` for each `/speak` request so a truncated upload is visible without opening the file.

Existing `form-action 'self'` and `connect-src 'self'` CSP directives cover the form and `fetch`; scripts and styles stay nonce-based.

There is still no approve, merge, or spawn control on this page.
