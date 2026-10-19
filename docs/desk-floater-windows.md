# Desk floater on Windows (WSL 2)

The Windows desk floater gives a teammate whose Starship runs inside WSL 2 ([ONBOARDING-windows.md](../ONBOARDING-windows.md)) the same floater the Mac has ([desk-floater.md](desk-floater.md)).
Talk to the first mate by holding a key or the button, hear its replies, dictate into any Windows app, and send screenshots.

It is mouth and ears only, like the Mac floater.
It never spawns workers, merges, edits config or acts as a second first mate.

## How it works

The floater is a small Windows app, `StarshipFloater.exe`, that does only what has to happen on Windows: the floating control, the hotkeys, recording the microphone, taking screenshots, playing spoken replies and pasting dictated text into the app you are typing in.
Everything else happens inside Ubuntu, in the same scripts the Mac floater uses, reached through `wsl.exe` and `bin/fm-desk-floater-windows.sh bridge`:

- `bin/fm-deepgram-stt.sh` turns a recording into words.
- `bin/fm-desk-voice.sh send` types the words into the first mate's own chat, with every safety check the Mac has: only the chat of the first mate holding this home's session lock, never into a question or a permission prompt, your half-typed draft set aside and put back, and the mailbox in `state/desk-voice/inbox/` whenever the chat cannot take it.
- `bin/fm-desk-voice.sh` keeps unsent recordings and stores screenshots in `state/desk-voice/shots/`.
- `bin/fm-speak.sh` decides what is spoken; `bin/fm-desk-play-windows.sh` plays it through the Windows speakers.

## Install

You need Starship set up in Ubuntu as [ONBOARDING-windows.md](../ONBOARDING-windows.md) describes, on Windows 10 or 11.

1. Put `DEEPGRAM_API_KEY=...` in this home's `.env`, as on a Mac ([desk-floater.md](desk-floater.md#enablement)).
2. For spoken replies, put `enabled = true` in this home's `config/speak`.
3. In your Ubuntu window, from `~/starship`:

   ```sh
   bin/fm-desk-floater-windows.sh install
   ```

The floater appears at the bottom right of your screen, a microphone icon appears in the system tray, and it starts by itself whenever you sign in to Windows.
If its talk button shows an orange `!` and "Mic off - click !", Windows' privacy settings keep apps off the microphone: click it to open those settings and turn on microphone access for desktop apps.

Install needs no download, no admin rights and no developer tools.
It builds the floater on your PC with the C# compiler that is part of Windows (it comes with .NET Framework 4), into `%LOCALAPPDATA%\Starship\Floater`, and adds it to your own startup list only.
Because the floater is built on your PC rather than downloaded, Windows SmartScreen never asks about it.

## Controls

The controls match the Mac floater's ([desk-floater.md](desk-floater.md#controls)).
Drag the floater by its dark plate.

| Control | What it does |
| --- | --- |
| Large round button | Talk to your first mate: hold, speak, release; or click once to start and again to send. |
| Stop (square) | Stops the reply being spoken, and any queued after it. |
| Repeat (circular arrows) | Speaks the last reply again; "Voice muted" while muted. |
| Mute (speaker) | Voice off and on; orange while muted. Right-click it for the voice volume. |
| Camera | A screenshot for your first mate; a blue number counts the shots waiting to be sent. |
| Arrow (right edge) | The last 10 spoken replies; click one to hear it again. |
| Tray icon | Right-click to hide or show the floater, or to quit it. |

The voice volume runs from 0 to 100% of the Windows volume.
Windows cannot play the voice louder than its own volume, so the Mac's levels above 100% play at 100% here.

## Hotkeys

The keys sit where the Mac's do on the keyboard.

| Key | What it does |
| --- | --- |
| Right Alt, held | Talks to your first mate for as long as it is held; releasing sends. A brush under about a third of a second sends nothing. |
| Right Ctrl, tapped | Starts dictation; tap again to finish and type the text where the cursor is. |
| Right Shift, tapped while you are not typing | Screenshot of the display under the mouse pointer. |

They follow the Mac's rules: a key used as part of a shortcut is ignored, Right Shift brushed while typing takes no screenshot, and a key or click in the first third of a second of holding Right Alt cancels the capture.
On keyboard layouts where Right Alt is AltGr, typing an AltGr character (such as `€` or `@`) is a shortcut too and sends nothing.
Holding Right Alt no longer opens an app's menu bar when you let go.
Windows keeps the keys of a window started with "Run as administrator" from other apps, so the hotkeys do nothing while such a window is in front; use the buttons.

## Dictation

Put the cursor where the text should go, tap Right Ctrl, speak, and tap Right Ctrl again.
The button turns purple while it listens.
The text is pasted with Ctrl+V and your clipboard is put back afterwards; the dictated text is kept out of Windows' clipboard history, and clipboard contents a password manager marked private are not put back.

With a first mate running in Herdr, the default setup, dictating into its chat types the words there like any other app, and they wait for you to press Enter.
Herdr does not report which terminal window has focus, so the floater cannot tell that its chat is the one in front.
Talking and screenshots still go straight into a Herdr first mate's chat.

With a first mate running in tmux (the fallback in [ONBOARDING.md](../ONBOARDING.md#3-get-starship-and-start-your-first-mate)), dictating into its chat sends the text the way talking does, with the same checks.
The floater treats the chat as being in front only when a terminal window (such as Windows Terminal) is the foreground window, the tmux pane of the first mate is the active one, and tmux says its terminal has focus.
tmux keeps track of focus only for a terminal that attached while its `focus-events` option was on, so install adds `set -g focus-events on` to your `~/.tmux.conf` (uninstall takes it out again) and the floater also turns the option on in your running tmux.
A tmux window that was already open before then counts once you attach to it again, for example after closing the tab and running `tmux attach -t firstmate`, or when tmux next starts.
The same holds when you turn `focus-events` on in a running tmux yourself, for example with `tmux source ~/.tmux.conf`: the floater counts only windows attached after it first sees the option on.
Anywhere else, and when it cannot tell, the text is only pasted and Enter is never pressed.

## Screenshots

Screenshots work as on the Mac ([desk-floater.md](desk-floater.md#screenshots)): they stack, go to your first mate about three seconds after the last one, and go together with a voice message recorded meanwhile.
The floater takes them on Windows at the display's full resolution and hands them to Ubuntu, where they are kept in this home's `state/desk-voice/shots/`, the newest 30 only.

## Nothing is lost

A recording stays on your PC until Ubuntu has it, then stays in Ubuntu until its words arrive.

- While Ubuntu cannot be reached, recordings wait in `%LOCALAPPDATA%\Starship\Floater\pending` and are handed over within a minute of Ubuntu answering again.
- In Ubuntu, a recording that cannot be transcribed or delivered is saved and retried exactly as on the Mac ([desk-floater.md](desk-floater.md#recordings-are-never-lost)): after about 20 seconds, a minute and five minutes for talk-to-first-mate, and by hand with `bin/fm-desk-voice.sh retry` for dictation.
- A recording handed over twice is only ever sent once.

## Updates

When Starship updates (for example after the first mate pulls new changes), the floater notices within an hour, or the next time it starts, rebuilds itself and restarts.
To update at once, run `bin/fm-desk-floater-windows.sh install` again.

## Start, stop and remove

```sh
bin/fm-desk-floater-windows.sh status
bin/fm-desk-floater-windows.sh stop
bin/fm-desk-floater-windows.sh start
bin/fm-desk-floater-windows.sh uninstall
```

`uninstall` quits the floater, removes it from your startup list, deletes `%LOCALAPPDATA%\Starship\Floater` and takes its line out of `~/.tmux.conf`.
The floater writes a short log of what it did, never your words, to `floater.log` in that folder.

## Limits

- The Mac records with echo cancellation, so a reply playing on the speakers stays out of your message; this floater does not.
  Use a headset, or press Stop before you talk while a reply is playing.
- Dictation is sent into the chat by itself only for a first mate running in tmux; in Herdr, the default, dictated words wait in the chat for you to press Enter.
- Talking and dictation need a working microphone; without one, screenshots still reach the first mate.
- Spoken replies need the same voice setup as on the Mac: a Deepgram key and the spoken-register owner `bin/fm-speak.sh` uses; without them replies stay text only.

## Related scripts

| Script | Role |
| --- | --- |
| `bin/fm-desk-floater-windows.sh` | Install, update, start, stop and remove the Windows floater, and the `bridge` it calls into Ubuntu |
| `bin/fm-desk-play-windows.sh` | Plays a spoken reply through Windows for `bin/fm-speak.sh` |
| `desk-floater-windows/` | The floater's C# sources and its self-test |
