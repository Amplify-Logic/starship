# Desk floater (Deepgram ears + mouth)

A Mac-native always-on-top push-to-talk control for **this** Firstmate home.
It recreates the *feel* of a floating desk mic without depending on the
ChatGPT/Codex desktop app.

The floater is mouth and ears only, plus a dictation keyboard you drive yourself.
It does not spawn workers, merge, edit config, or act as a second Firstmate.
Exactly one fleet brain remains: the primary already running in this home.

## What you get

- Always-on-top, draggable floating control (SwiftUI): a small talk button with five smaller controls beside it, and a dropdown arrow for recent replies.
- Push-to-talk (hold or click-to-toggle), or hold Right Option anywhere. Not always-listening. No wake word.
- Speech-to-text via Deepgram (`bin/fm-deepgram-stt.sh`).
- Transcripts typed straight into the primary Firstmate chat and submitted, with a durable mailbox under the home (`state/desk-voice/inbox/`) as the fallback.
- Optional speak-back of Firstmate outcome lines through `bin/fm-speak.sh`,
  which speaks through macOS `say` when `config/speak` names a `voice` and
  through Deepgram Aura otherwise, each the fallback for the other.
- Stop, Repeat and Mute controls for that spoken voice, and a list of the recent spoken replies to hear any of them again.
- A dictation mode that types what you say into whatever text box has the cursor, instead of sending it to Firstmate.
- Quick screenshots sent to Firstmate on their own or together with a voice message (see [Screenshots](#screenshots)).

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
   macOS also asks for the Accessibility and Screen Recording permissions, once for each new build (see [Permissions](#permissions)); the buttons work without Accessibility, the hotkeys and typing into other apps do not, and screenshots need Screen Recording.

4. Hold the button (or click to toggle), speak, release.
   The transcript is typed into the primary Firstmate chat and submitted, or saved to the mailbox when that chat cannot be reached.

## Controls

Drag the floater by its dark backing plate or the status line under the buttons.

| Control | What it does |
| --- | --- |
| Large round button | Talk to Firstmate: hold, speak, release; or click once to start and click again to send. Double-click also toggles. |
| Stop (square) | Stops the reply being spoken now, and drops any reply queued to be spoken after it. Runs `bin/fm-speak.sh --stop`. |
| Repeat (circular arrow) | Speaks the last spoken reply again. Runs `bin/fm-speak.sh --repeat`; the status line says "Nothing to repeat" when nothing has been spoken yet, and "Voice muted" (without repeating) while the voice is muted. |
| Recent replies (dropdown arrow, right edge) | Opens a list of the last 10 spoken replies, newest first, each with its time and the start of its text; hover over one to read all of it. Click a reply to hear it again. Stop and Mute work on it as on Repeat, and while muted a click stays silent and the status line says "Voice muted". Click the arrow again to close the list. Runs `bin/fm-speak.sh --history` and `--replay <number>`. |
| Mute (speaker) | Toggles voice off and on. While muted the icon is a crossed-out speaker on an orange circle, every reply stays text-only, and a reply playing at the moment you mute stops. Runs `bin/fm-speak.sh --mute` / `--unmute`; the setting is per home and survives restarting the floater. |
| Type (text cursor) | Dictation: click once to start, click again to finish. See [Dictation](#dictation). |
| Camera | Takes a screenshot for Firstmate. See [Screenshots](#screenshots). A number on it counts the shots waiting to be sent; an orange "!" means the Screen Recording permission is missing, and clicking it asks again. |

Repeat and the recent list play a reply as soon as you click, from the audio kept when it was first spoken, rather than waiting for Deepgram to make it again.
A reply with no kept audio, such as one spoken by macOS `say`, is spoken again the ordinary way.
The last 10 replies and their audio are kept in this home's private `state/`, readable only by your own account on the Mac; older ones are removed as new ones arrive.

Muting affects voice only.
Firstmate's text replies stay the authoritative ones, and nothing about how Firstmate handles your transcripts changes.
`bin/fm-speak.sh`'s header owns how stop, repeat, the reply history and mute behave.

## Hotkeys

| Key | What it does |
| --- | --- |
| Right Option, held | Walkie-talkie: talks to Firstmate for as long as it is held, exactly like holding the large button. Releasing sends. A brief brush of the key (under about a third of a second) sends nothing. |
| Right Command, tapped | Starts dictation; tap it again to finish and type the text. |
| Right Shift, tapped | Takes a screenshot of the display under the mouse pointer. See [Screenshots](#screenshots). |

Only the right-hand keys are watched, so the left Option, Command and Shift keys keep working as usual.
Right Shift follows the same tap rules as Right Command: held with a letter to type a capital, or held longer than half a second, it is an ordinary Shift press and takes no screenshot.
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

## Screenshots

Tap Right Shift, or click the Camera control, to take a screenshot of the whole display under the mouse pointer.
Take several in a row, moving the pointer to another display in between if you like: they stack, and about three seconds after the last one they are sent to Firstmate together as one message, with nothing more to press.
The camera shows how many are stacked, the status line reads "2 shots stacked", then "Sent" once they are delivered.

The message names each image by its full path, for example `Screenshots: /…/state/desk-voice/shots/<time>-<id>.png /…/<time>-<id>.png`, so Firstmate can open them.
A message with screenshots, with or without words, travels the same way as a voice message: typed into the Firstmate chat, or saved to the mailbox when that chat cannot be reached, see [How transcripts reach Firstmate](#how-transcripts-reach-firstmate).

Screenshots combine with talk-to-Firstmate:

- Shots taken while Right Option is held, or while the large button is recording, go with that voice message.
- Shots still stacking when you start talking wait and go with the voice message too.
- Shots taken after you finish talking, while the message is still being transcribed, join it; the message then waits until three seconds after the last shot.
- Talking again while a message waits for its shots ("Adding shots…" on the status line) adds the new words after the first ones, and the wait starts over from the end of that talk.

The words and the image paths arrive as one message, the transcript first, then the `Screenshots:` paths (on one typed line in the chat, on a line of their own in the mailbox).
A voice message with no shots stacked is sent as soon as it is transcribed, so a shot taken after it has already gone is sent on its own.
Dictation never takes screenshots along: shots taken while dictating are sent to Firstmate on their own.

Screenshots are kept in this home's `state/desk-voice/shots/`, which is gitignored and readable only by you.
Only the newest 30 are kept; each new shot removes the oldest beyond that.
`bin/fm-desk-voice.sh shot` takes them and its header owns that limit.
Nothing is sent anywhere but to this home's Firstmate.

## Permissions

| Permission | Needed for | Where |
| --- | --- | --- |
| Microphone | Every capture | Asked the first time you talk. |
| Accessibility | The Right Option, Right Command and Right Shift hotkeys, and pasting dictated text into other apps | Asked on the first launch of each new build. Grant it in System Settings, Privacy & Security, Accessibility, by switching on DeskFloater. |
| Screen Recording | Screenshots | Asked on the first launch of each new build. Grant it in System Settings, Privacy & Security, Screen & System Audio Recording, by switching on DeskFloater. |

The floater checks the permission every few seconds and turns the hotkeys on as soon as it is granted, with no restart.
Until then the hotkeys and the paste are off: an orange "!" badge sits on the talk button, the status line reads "Keys off - click !" in orange, and the on-screen buttons work as normal.
Clicking the badge asks macOS again and opens the Accessibility settings.

macOS ties the grant to the exact app build, so every time `bin/fm-desk-floater.sh` rebuilds the floater (after any change to its code) the old grant stops counting and the badge comes back.
The rebuilt floater asks once more on its first launch.
If DeskFloater already shows as switched on in that list, switch it off and on again, or remove it with the minus button and click the badge to add it back.

Screen Recording works the same way, with its own orange "!" on the Camera control.
Until it is granted, screenshots are off and the Camera control and Right Shift take none; clicking the Camera control asks macOS again and opens the Screen Recording settings.
macOS may only notice a new Screen Recording grant after the floater restarts, so choose "Quit & Reopen" if it offers, or restart it with `bin/fm-desk-floater.sh`.

## How transcripts reach Firstmate

The floater hands each message, with or without screenshots, to `bin/fm-desk-voice.sh send`, which types it into the primary Firstmate session's own chat pane and presses Enter.
The words arrive at once, even while Firstmate is mid-task, and that pane does not need focus.
Only the session holding this home's session lock is ever typed into, and only after its pane is proven to host that session; the script header owns the resolution and the supported runtime backends.
The pane must also show its chat input, read as empty or holding a draft.
A pane showing a shell or a screen that cannot be read counts as unreachable, because typed words there would become keypresses.
So does a pane showing a selection dialog, such as a permission prompt, a question, or a picker: a pointer on a numbered option, or an `Enter to select` or `Esc to cancel` footer, sends the transcript to the mailbox so it cannot pick an option.

The transcript is sent as the captain's plain words, with no label or marker.
Line breaks and control characters become spaces, so a transcript cannot submit early or press keys.

A voice message that lands while a half-typed draft sits in the Firstmate chat joins that draft and is submitted with it.

When the chat pane cannot be reached, is not showing its chat input, or refuses the text, the transcript goes to the mailbox instead:

| Path | Role |
| --- | --- |
| `state/desk-voice/inbox/*.json` | Pending captain-input transcripts |
| `state/desk-voice/processed/` | After `bin/fm-desk-voice.sh drain` |
| wake `check desk-voice` | Nudges the primary that something landed |

A transcript reaches Firstmate one way only.
Text that was typed and submitted, even when the submit could not be confirmed, is never also saved to the mailbox.
The floater shows which way it went: `Sent`, `Sent, unconfirmed`, or `Saved to mailbox`.

The primary (or you) drains the mailbox with:

```
bin/fm-desk-voice.sh pending
bin/fm-desk-voice.sh drain
```

Drain prints each transcript as plain text (or `--print` for JSON) and moves the file to `processed/`.
Treat the drained text as captain input in the primary conversation.
`bin/fm-desk-voice.sh deliver` writes to the mailbox directly, without trying the chat pane.
Dictation types text only where you put the cursor, and talk-to-Firstmate types only into the primary Firstmate chat.

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
- Watching the screen continuously, or computer use: a screenshot is only taken when you ask for one.
- Choosing a window or region: a screenshot is always the whole display under the pointer.
- Replacing glasses voice or the ElevenLabs glasses path.
- Building inside the OpenAI Codex app.

## Related scripts

| Script | Role |
| --- | --- |
| `bin/fm-desk-floater.sh` | Build/launch the floating control; the controls, hotkeys, dictation and screenshot stacking live in `desk-floater/Sources/DeskFloater.swift` |
| `bin/fm-desk-voice.sh` | Send into the primary chat, screenshot capture, and mailbox deliver / pending / drain |
| `bin/fm-deepgram-stt.sh` | Audio file → transcript |
| `bin/fm-deepgram-tts.sh` | Text → Deepgram Aura audio |
| `bin/fm-speak.sh` | Captain-facing speak-out (a named `voice` selects `say`, else Deepgram Aura; each the other's fallback), plus `--stop`, `--repeat`, `--history`, `--replay`, `--mute`, `--unmute` and `--muted` |
