# Desk floater (Deepgram ears + mouth)

A Mac-native always-on-top push-to-talk control for **this** Firstmate home.
It recreates the *feel* of a floating desk mic without depending on the
ChatGPT/Codex desktop app.

The floater is mouth and ears only, plus a dictation keyboard you drive yourself.
It does not spawn workers, merge, edit config, or act as a second Firstmate.
Exactly one fleet brain remains: the primary already running in this home.

## What you get

- Always-on-top, draggable floating control (SwiftUI): a small talk button with four smaller controls beside it.
- Push-to-talk (hold or click-to-toggle), or hold Right Option anywhere. Not always-listening. No wake word.
- Speech-to-text via Deepgram (`bin/fm-deepgram-stt.sh`).
- Transcript delivery into a durable mailbox under the home
  (`state/desk-voice/inbox/`), plus a wake so the primary can see it.
- Optional speak-back of Firstmate outcome lines through `bin/fm-speak.sh`,
  which speaks through macOS `say` when `config/speak` names a `voice` and
  through Deepgram Aura otherwise, each the fallback for the other.
- Stop, Repeat and Mute controls for that spoken voice.
- A dictation mode that types what you say into whatever text box has the cursor, instead of sending it to Firstmate.

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
   macOS also asks for the Accessibility permission, once for each new build (see [Permissions](#permissions)); the buttons work without it, the hotkeys and typing into other apps do not.

4. Hold the button (or click to toggle), speak, release. The transcript is
   written to `state/desk-voice/inbox/<utc>-<id>.json` and a wake is queued.

## Controls

Drag the floater by its dark backing plate or the status line under the buttons.

| Control | What it does |
| --- | --- |
| Large round button | Talk to Firstmate: hold, speak, release; or click once to start and click again to send. Double-click also toggles. |
| Stop (square) | Stops the reply being spoken now, and drops any reply queued to be spoken after it. Runs `bin/fm-speak.sh --stop`. |
| Repeat (circular arrow) | Speaks the last spoken reply again. Runs `bin/fm-speak.sh --repeat`; the status line says "Nothing to repeat" when nothing has been spoken yet, and "Voice muted" (without repeating) while the voice is muted. |
| Mute (speaker) | Toggles voice off and on. While muted the icon is a crossed-out speaker on an orange circle, every reply stays text-only, and a reply playing at the moment you mute stops. Runs `bin/fm-speak.sh --mute` / `--unmute`; the setting is per home and survives restarting the floater. |
| Type (text cursor) | Dictation: click once to start, click again to finish. See [Dictation](#dictation). |

Muting affects voice only.
Firstmate's text replies stay the authoritative ones, and nothing about how Firstmate handles your transcripts changes.
`bin/fm-speak.sh`'s header owns how stop, repeat and mute behave.

## Hotkeys

| Key | What it does |
| --- | --- |
| Right Option, held | Walkie-talkie: talks to Firstmate for as long as it is held, exactly like holding the large button. Releasing sends. A brief brush of the key (under about a third of a second) sends nothing. |
| Right Command, tapped | Starts dictation; tap it again to finish and type the text. |

Only the right-hand keys are watched, so the left Option and Command keys keep working as usual.
A hotkey used as part of a shortcut is ignored: pressing a letter or clicking the mouse while Right Option is held (to type a special character, or Option-click) cancels that capture without sending anything, and Right Command pressed with another key or a click, or held longer than half a second, is an ordinary Command press. System shortcuts that macOS keeps to itself, such as a quick Right Command-Tab or Right Command-Space, are hidden from the floater and can read as a tap; use the left Command key for those.

## Dictation

Dictation types what you say into whatever text box has the cursor: this terminal, a browser field, a chat window, any app.

1. Put the cursor where the text should go.
2. Tap Right Command, or click the Type control.
   The large button and the Type control turn purple and the status line reads "Dictating…" while it listens.
3. Speak, then tap Right Command or click Type again.
   The audio is transcribed through the same Deepgram path, and the text is pasted where the cursor is.

The paste puts the text on the clipboard, sends Command-V to the app you are typing in, then puts back whatever the clipboard held before.
The dictated text is marked transient so clipboard-history tools skip it, and anything a password manager marked concealed or transient is not put back: the clipboard is left without it, so the password manager's own clear-after timer still applies.
If something else is copied during that moment, the floater leaves the new clipboard contents alone.
Without the Accessibility permission the text is left on the clipboard instead and the status line reads "Copied - press ⌘V".
Dictated text never goes to Firstmate's mailbox and never wakes Firstmate.
Clicking a floater control does not take keyboard focus from the app you are typing in.

## Permissions

| Permission | Needed for | Where |
| --- | --- | --- |
| Microphone | Every capture | Asked the first time you talk. |
| Accessibility | The Right Option and Right Command hotkeys, and pasting dictated text into other apps | Asked on the first launch of each new build. Grant it in System Settings, Privacy & Security, Accessibility, by switching on DeskFloater. |

The floater checks the permission every few seconds and turns the hotkeys on as soon as it is granted, with no restart.
Until then the hotkeys and the paste are off: an orange "!" badge sits on the talk button, the status line reads "Keys off - click !" in orange, and the on-screen buttons work as normal.
Clicking the badge asks macOS again and opens the Accessibility settings.

macOS ties the grant to the exact app build, so every time `bin/fm-desk-floater.sh` rebuilds the floater (after any change to its code) the old grant stops counting and the badge comes back.
The rebuilt floater asks once more on its first launch.
If DeskFloater already shows as switched on in that list, switch it off and on again, or remove it with the minus button and click the badge to add it back.

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
Dictation is the only path that types text into another app, and only where you put the cursor.

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
- Sending dictated text anywhere but the text box that has the cursor.
- Screen observation / computer use.
- Replacing glasses voice or the ElevenLabs glasses path.
- Building inside the OpenAI Codex app.

## Related scripts

| Script | Role |
| --- | --- |
| `bin/fm-desk-floater.sh` | Build/launch the floating control; the controls, hotkeys and dictation live in `desk-floater/Sources/DeskFloater.swift` |
| `bin/fm-desk-voice.sh` | Inbox deliver / pending / drain |
| `bin/fm-deepgram-stt.sh` | Audio file → transcript |
| `bin/fm-deepgram-tts.sh` | Text → Deepgram Aura audio |
| `bin/fm-speak.sh` | Captain-facing speak-out (a named `voice` selects `say`, else Deepgram Aura; each the other's fallback), plus `--stop`, `--repeat`, `--mute`, `--unmute` and `--muted` |
