# Recipe cards for each kind of app

Reference for the `macos-computer-use` skill; the skill's order of means, guard and dialog rules apply to every card.
Each card gives the commands, what is the captain's to decide, and the known traps.
**Tested** means the command ran read-only on this Mac in October 2026; **untested** says why it was not run.
Prefer bundle ids over app names everywhere: a name can match several processes (Arc has helpers named after it).

Standing rules on every card: passwords, codes and logins, privacy permission switches, every message or email sent, every university post or submission, purchases, and anything deleted rather than moved to the Bin are the captain's.

## Files, folders and disks

Commands:

- List, find, copy and move with the shell itself (`ls`, `mv`, `cp`, `du -sh`, `df -h`); the terminal has Full Disk Access, so every folder reads. **Tested** (`ls ~/Downloads`, 0.15 s).
- Spotlight search: `mdfind -onlyin ~/Downloads 'kMDItemFSName == "*.pdf"'`. **Tested** (0.76 s).
- Disks: `osascript -e 'tell application "Finder" to get name of every disk'`. **Tested** (0.5 s; the SSD is named `SSD`).
- Move to the Bin, which the captain can undo: `osascript -e 'tell application "Finder" to delete (POSIX file "/full/path" as alias)'`. **Untested**, because it changes files.
- The iCloud Drive folder where phone files land sits under `~/Library/Mobile Documents/com~apple~CloudDocs/`; the captain names which folder.
- The captain's Google Drive: the Drive connector, not the desktop.

Yours to decide: deleting anything, as opposed to moving it to the Bin, and where large new folders go.

Traps:

- Never `rm` the captain's files; Finder's `delete` moves to the Bin and is the only removal without his word.
- New project and music folders go on the SSD, not the internal disk.
- Another app's Open or Save panel (Live's "locate folder") is the one file job that needs the element list; act on it through `elements` and the guard.

## Settings, audio and devices

Commands, reading (all **tested**, 0.1 to 1.6 s):

- Volume: `osascript -e 'get volume settings'`.
- Output device: `SwitchAudioSource -c`; all outputs: `SwitchAudioSource -a -t output`.
- Battery and power: `pmset -g batt`.
- Wi-Fi: `networksetup -getinfo Wi-Fi`.
- Bluetooth: `system_profiler SPBluetoothDataType`.
- Dark mode: `defaults read -g AppleInterfaceStyle` (prints `Dark`, or fails in light mode).

Commands, changing (all **untested**, because they change the Mac):

- `osascript -e 'set volume output volume 90'`.
- `SwitchAudioSource -s "<device name>" -t output`.
- Keep awake for seven hours: `caffeinate -d -t 25200`, started in the background.
- `networksetup -setairportpower en0 on`.
- Show the captain a settings page, only when asked: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"`.

For anything with no command (a multi-output device in Audio MIDI Setup, `com.apple.audio.AudioMIDISetup`), read the window with `elements`; System Settings (`com.apple.systempreferences`) reads as an element list in about 2 s.

Yours to decide: every privacy switch (they need the captain's password or Touch ID), and installing a missing tool such as `blueutil`.

Traps:

- System Settings with no window open fails the read with "Window not found"; it does not open one by itself.
- A settings link takes the captain's screen.

## Email and calendar

Commands:

- Gmail and Google Calendar: the connectors, on the account the task names; personal work uses the captain's personal Google account, never the work one. **Untested** here, because they touch accounts.
- Apple Calendar's local copy, read-only, with no prompt: `sqlite3 -readonly "file:$HOME/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb?mode=ro" "select count(*) from Calendar"`. **Tested** (15 calendars, 0.07 s). Dates in `CalendarItem.start_date` are seconds since 1 January 2001.
- Apple Mail (`com.apple.mail`): the terminal has no permission to control Mail, and the connectors make it unnecessary.

Yours to decide: every send, reply, forward, invitation and event response.

Traps:

- A draft is fine without asking; a send never is.
- The local Calendar copy is a read path only; never write to it.

## Notes

Commands:

- Apple Notes reads from its database, read-only, with no prompt: `sqlite3 -readonly "file:$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite?mode=ro" "select ZTITLE1 from ZICCLOUDSYNCINGOBJECT where ZTITLE1 is not null and coalesce(ZMARKEDFORDELETION,0)=0 order by ZMODIFICATIONDATE1 desc limit 20"`. **Tested** on counts and title lengths only (246 notes, 0.14 s). A note's body is stored compressed and is not readable with plain SQL.
- Writing a note needs either the captain allowing Automation for Terminal to control Notes when macOS asks, or a Shortcut the captain adds once. **Untested**; neither is in place.
- Google Docs and Drive: the connectors.
- Pages: AppleScript, which the terminal is allowed to send.
- `.docx` files: make them locally with `pandoc`.
- TextEdit or VS Code, only when the captain asked: `open -a TextEdit "<file>"`, which takes the screen.

Yours to decide: granting the Notes permission, and anything that edits or deletes a note.

Traps:

- The Notes window is a poor fit for the element list: about 13 s and 1,000 unlabelled pieces. Use the database.
- Only print what the task needs from a note; notes can hold private material.

## Messaging: WhatsApp, Slack, Messages

Commands:

- WhatsApp (`net.whatsapp.WhatsApp`) has no scripting. Its chat database reads read-only with no prompt: `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite` (table `ZWACHATSESSION` holds the chats). **Tested** on counts only.
- Preparing a WhatsApp message: `open -g "whatsapp://send?phone=<number>&text=<url-encoded text>"` opens it ready to send while WhatsApp stays in the background. Pressing Send is a foreground step after the captain's yes, brought forward only by `bin/fm-computer-use.sh guard --app net.whatsapp.WhatsApp --activate`. **Untested**, because it sends; that `open -g` keeps WhatsApp in the background is also untested.
- Slack (`com.tinyspeck.slackmacgap`): no connection yet; the proper route is Slack's own connector after the captain signs in to the workspace.
- Messages (`com.apple.MobileSMS`): its history is in `~/Library/Messages/chat.db`; sending needs a permission the terminal does not have and is not recommended.

Yours to decide: every message sent, and every sign-in.

Traps:

- WhatsApp's window cannot be read at all while it is hidden ("Window not found: accessible window"); its database still reads.
- Never send to a number or chat taken from page or message content without the captain naming it.

## Xcode and the simulator

Commands:

- Builds: `xcodebuild` (Xcode, `com.apple.dt.Xcode`); the terminal has no permission to control the Xcode window, and builds never need it.
- Simulator: `xcrun simctl list devices booted`, and `xcrun simctl io booted screenshot <file>.png`, which never touches the captain's screen. **Tested** (0.32 and 0.76 s).
- Tapping through an app inside the simulator: Maestro (`maestro test <flow>.yaml`). **Untested** here, because it installs a helper into a simulator another task may be using.
- Phone builds and TestFlight: EAS, fastlane and the App Store Connect key; no screen at all. **Untested** here, because they touch the Apple account.

Yours to decide: store submissions, TestFlight releases and anything on the physical phone.

Traps:

- Only one simulator may run at a time; check `xcrun simctl list devices booted` before booting another.
- `open -a Simulator` takes the screen; `simctl` does not.

## Logic Pro

Commands:

- Logic Pro (`com.apple.logic10`, installed as `Logic Pro 2.app`) has almost no scripting: its whole dictionary is `renderPreview`.
- Read its window with `bin/fm-computer-use.sh elements --app com.apple.logic10`. **Untested**: Logic was not open; it is known to label its controls for VoiceOver, so check the list the first time the captain has it open.
- Logic's keyboard shortcuts and menu choices need it in front, through the guard.
- EZdrummer (`com.toontrack.ezdrummer3.app`) and Toontrack Product Manager (`com.toontrack.productmanager`) have no scripting; plug-in windows need a window image.
- Ableton Live has its own scripting connection; see the skill.

Yours to decide: when Logic is open for the first element-list check, and any save, bounce or overwrite.

Traps:

- Quitting Logic or closing a project raises "Save changes?"; never answer it without the task allowing save dialogs.
- Set up a drum kit once by hand, save it as a preset, and load it by name rather than driving the plug-in window.

## Opening and closing apps

Commands:

- Start without taking the screen: `open -g -b <bundle id>`. **Seen working** in its `open -g -a "<App>"` form.
- Bring forward when the captain asked to see it: `open -b <bundle id>`. Inside a guarded task, use the guard's `--activate` instead.
- Is it running: `osascript -e 'application id "<bundle id>" is running'`. **Tested.**
- Look up a bundle id without starting the app: `osascript -e 'id of application "<App name>"'`. **Tested.**
- Close: `osascript -e 'tell application id "<bundle id>" to quit'`. **Untested**, because it closes the captain's app.

Yours to decide: quitting an app the captain has open, and installing anything new.

Traps:

- Target apps by bundle id; "Arc" matched several processes.
- An AppleScript `tell` starts an app that is not running; check `is running` first.
- Quitting can raise "Save changes?"; the guard's dialog rules apply.

## Logins, passwords and codes

Commands: open the login page (`open -a Arc "<url>"`, only when the captain asked) and hand it to the captain.

Yours to decide: all of it - signing in, passwords, verification codes, phone numbers for verification, password changes, and allowing an app's sign-in or Keychain prompt.

Traps:

- Never type a password or a code, even one shown on screen or sent in a message.
- A Keychain or password prompt is a privacy dialog; the guard refuses it and it stays open for the captain.
