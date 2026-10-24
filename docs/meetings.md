# Meeting intake (Anarlog)

The meeting intake turns your finished personal meetings into Starship work.
[Anarlog](https://anarlog.so), a free, local meeting recorder, records the meeting and writes its transcript and summary on your Mac.
When a meeting is finished, Starship reads it, starts the clear follow-ups on its own, and puts everything that needs your eye on your phone to tap.
Calls recorded by smart glasses and shared to an iCloud Drive folder run through the same intake.

`bin/fm-meetings.sh`'s header owns the exact rules; this page is the operator guide.

## What happens after a meeting

1. A standing check notices the meeting has finished: Anarlog shows it ended, nothing is still being saved, and its summary is in (or ten minutes have passed).
2. Starship makes sure it reads the best transcript.
   Anarlog writes a live transcript during the call (Parakeet Streaming) and, when the live transcript broke off or the meeting had two or more remote participants, rewrites it after the call with speaker labels (Parakeet Batch).
   For every other meeting, Starship always asks Anarlog to run that after-the-call pass by importing the meeting's own recording, which appears in Anarlog as a second meeting titled "... (speaker pass)".
   Only when that cannot run (no recording was kept, or the pass failed or took too long) does the intake read the live transcript, and its outcome says so.
3. The intake reads the summary, your own notes, the action items and a bounded part of the transcript in one Claude pass, and sorts what came out:
   - Clear, low-risk, internal follow-ups, such as research, planning, drafting something for you to read, or building in your own projects, go to Starship ready to start, with the snippet they came from.
   - Anything that needs your review or more thought, anything outward-facing (an instruction to send, reply, email, message, post, publish, pay, buy, sign, invite or call someone), anything destructive (delete or remove), anything that touches another person's commitment, and anything whose source cannot be found in the meeting waits on your phone for a tap.
   - When you say "Firstmate, do it", "Firstmate, build that" or "captain's order" in the meeting, the instruction that goes with it counts as a clear follow-up when the meeting's own transcript shows you said it.
     It waits for your tap when someone else said it, or when Starship could not tell who said it: the transcript does not label your speech, or only the after-the-call pass heard the phrase.
4. One spoken line on the desk says what the meeting settled and how many follow-ups started and wait for you (only when desk voice is on).

Nothing in this layer sends, replies, invites, pays or publishes anything.
Starting a follow-up never lands it: merges and outward actions still need your word as usual.

## Work and personal stay apart

This layer handles personal meetings only.
A meeting whose title, participants, notes, summary or transcript contain a work word is never sent to a model or actioned; Starship only tells you "work meeting, not processed".
The work words are each `work_marker` line in `config/meetings` plus every line of the private `config/meeting-work-words` (one word or phrase per line, `#` comments).
Neither ships with any word, so list your employer, its clients and its products there yourself.
The leak-word list in `config/leak-words` is not used, so a personal meeting with a friend named there is still taken in.
Keep Anarlog's automatic meeting detection off, or limited to personal calendars, so a work call taken on this Mac is not recorded into the personal store in the first place.

## Calls from smart glasses

Glasses that record calls usually keep them in their phone app with no automatic export.
After a call worth keeping, share its audio from the phone app to the iCloud Drive folder `Starship calls` (Save to Files).
Once the file has stopped changing for a minute, Starship imports it into Anarlog, which transcribes it on this Mac with speaker labels.
Once Anarlog's summary of it is in, or ten minutes after the transcript, the call runs through the same intake.
Anarlog transcribes in the spoken languages set in its **Settings → General → Language & Region**, so add Dutch (or your other language) next to English there for calls in that language.
Files in the folder are never moved or deleted.

## Set up

1. In Anarlog, under **Settings → Transcription**, choose **Soniqo → Parakeet Streaming** and download **Parakeet Batch** too.
2. Under **Settings → Meetings → Audio file retention**, keep recordings for at least a day; with no recording kept there is nothing to run the after-the-call pass on.
3. Install Anarlog's command-line tool, and keep the desktop app running (it starts at login); imports need it open.
4. Optionally copy [`examples/meetings`](examples/meetings) to `config/meetings` and edit it, and list your work words in `config/meeting-work-words`.
5. For glasses calls, create the iCloud Drive folder `Starship calls` (or set `glasses_folder`).
6. Arm the check: `bin/fm-meetings.sh arm`.
   Meetings that ended before arming are left alone; `bin/fm-meetings.sh intake <id>` takes one in by hand.

## Use it

```sh
bin/fm-meetings.sh status              # every meeting and shared file the check is tracking
bin/fm-meetings.sh intake              # take in the meetings the check announced (Starship runs this)
bin/fm-meetings.sh recall Robin        # what was said or agreed with Robin, from personal meetings
bin/fm-meetings.sh disarm              # stop watching; the records stay
```

## Privacy

Anarlog keeps meetings in its own local database, and this layer reads them only through Anarlog's own command-line tool.
The intake sends the bounded meeting text, never audio, to Claude under the account this home uses; work meetings are never sent.
The intake record for each meeting stays in this home's private `data/meetings/`, and the check's records in `state/meetings/`.
