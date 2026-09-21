# Desk floater (Deepgram ears + mouth)

A Mac-native always-on-top push-to-talk control for **this** Firstmate home.
It recreates the *feel* of a floating desk mic without depending on the
ChatGPT/Codex desktop app.

The floater is mouth and ears only. It does not spawn workers, merge, edit
config, or act as a second Firstmate. Exactly one fleet brain remains: the
primary already running in this home.

## What you get

- Always-on-top, draggable floating button (SwiftUI).
- Push-to-talk (hold or click-to-toggle). Not always-listening. No wake word.
- Speech-to-text via Deepgram (`bin/fm-deepgram-stt.sh`).
- Transcript delivery into a durable mailbox under the home
  (`state/desk-voice/inbox/`), plus a wake so the primary can see it.
- Optional speak-back of Firstmate outcome lines through `bin/fm-speak.sh`,
  which speaks through macOS `say` when `config/speak` names a `voice` and
  through Deepgram Aura otherwise, each the fallback for the other.

## Enablement

1. Put `DEEPGRAM_API_KEY=...` in this home's gitignored `.env` (or export it).
   Never commit the key. Scripts never log it.
2. Opt the home into desk voice-out with private `config/speak`:

   ```
   enabled = true
   ```

3. Launch the floater:

   ```
   bin/fm-desk-floater.sh
   ```

   First launch builds the Swift package under `desk-floater/` into
   `desk-floater/.build/` (gitignored) and opens the floating control.
   Grant microphone permission when macOS asks.

4. Hold the button (or click to toggle), speak, release. The transcript is
   written to `state/desk-voice/inbox/<utc>-<id>.json` and a wake is queued.

## How transcripts reach Firstmate

v1 delivery is **write transcript + wake**, not composer injection:

| Path | Role |
| --- | --- |
| `state/desk-voice/inbox/*.json` | Pending captain-input transcripts |
| `state/desk-voice/processed/` | After `bin/fm-desk-voice.sh drain` |
| wake `check desk-voice` | Nudges the primary that something landed |

The primary (or you) drains with:

```
bin/fm-desk-voice.sh pending
bin/fm-desk-voice.sh drain
```

Drain prints each transcript as plain text (or `--print` for JSON) and moves
the file to `processed/`. Treat the drained text as captain input in the
primary conversation. Do not paste blindly into random terminals.

## Desk speak-out bound

The register owner truncates the shaped line before any speaker sees it, and
its own default budget is the ~8s one tuned for the glasses, which cuts an
ordinary two- or three-sentence desk outcome mid-message.
So `bin/fm-speak.sh` points that owner at
[`docs/examples/desk-speak-register.toml`](examples/desk-speak-register.toml)
(via `GLASSES_ANNOUNCE_CONFIG`, unless already set) for every desk line.
That example keeps the same URL/path/id and decision refusals but raises the
spoken budget to **30 seconds** (about 78 words at 2.6 wps).
The budget belongs to the desk rather than to the speaker, so it is the same
whichever speaker plays the line, macOS `say` or Deepgram Aura.
Two lines in one turn play one after another rather than overlapping.
`bin/fm-speak.sh`'s header owns that serial lock.

Override the example path with `FM_SPEAK_DEEPGRAM_REGISTER`, or keep the short
glasses cut by exporting `FM_SPEAK_DEEPGRAM_REGISTER=` (empty).
The variable keeps its historical name because it is the published opt-out; it
has never been a Deepgram gate.

TTS model default: `aura-2-thalia-en` (`DEEPGRAM_TTS_MODEL`).
STT model default: `nova-2` (`DEEPGRAM_STT_MODEL`).

## Non-goals

- Always-on open mic / wake word.
- Screen observation / computer use.
- Replacing glasses voice or the ElevenLabs glasses path.
- Building inside the OpenAI Codex app.

## Related scripts

| Script | Role |
| --- | --- |
| `bin/fm-desk-floater.sh` | Build/launch the floating control |
| `bin/fm-desk-voice.sh` | Inbox deliver / pending / drain |
| `bin/fm-deepgram-stt.sh` | Audio file → transcript |
| `bin/fm-deepgram-tts.sh` | Text → Deepgram Aura audio |
| `bin/fm-speak.sh` | Captain-facing speak-out (a named `voice` selects `say`, else Deepgram Aura; each the other's fallback) |
