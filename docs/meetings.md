# Meeting intake

The meeting intake turns every finished meeting or call into Starship work.
When a meeting is finished, Starship reads its transcript and notes once, writes a one-line outcome, starts the clear follow-ups on its own, and holds everything that needs your eye for your decision.
It is off until a home turns it on, and it acts toward no one outside Starship; [Privacy](#privacy) lists what leaves this machine.

`bin/fm-meetings.sh`'s header owns the exact rules; this page is the operator guide.

## Where meetings come from

The intake reads finished meetings from the sources `config/meetings` names:

- **The call recorder** (`source = call-recorder`, the default): every call you record with [`bin/fm-call-companion.sh`](call-companion.md) feeds the intake once it is stopped and its end-of-call notes are written, or ten minutes after it was archived without them.
  Nothing more to install.
- **Anarlog** (`source = anarlog`): [Anarlog](https://anarlog.so) is a free meeting recorder for the Mac that records any meeting, in any app or in person, and writes its transcript and summary on your Mac, in its own local database.
  Anarlog labels speakers itself and transcribes with whichever engine its own settings name.
  The call recorder's transcription engine, and what it needs on this laptop, is covered in [call-companion.md](call-companion.md).
  Starship reads it only through Anarlog's own command-line tool and never opens its database.

`bin/fm_meeting_sources.py`'s header owns the seam a further source plugs into.

## What happens after a meeting

1. A standing check notices the meeting has finished: the call recorder archived the call with its notes (or ten minutes passed without them), or Anarlog shows the meeting ended, nothing is still being saved, and its summary is in (or ten minutes have passed).
2. For an Anarlog meeting, Starship makes sure it reads the best transcript.
   Anarlog writes a live transcript during the meeting and, in some cases, rewrites it after the meeting with speaker labels.
   For every other meeting, Starship asks Anarlog to run that after-the-meeting pass by importing the meeting's own recording, which appears in Anarlog as a second meeting titled "... (speaker pass)".
   Do not delete those "(speaker pass)" entries in Anarlog.
   While any exclude word is set, `recall` checks a saved meeting against its speaker pass too, so a meeting whose speaker-pass copy is gone is withheld from `recall` from then on, and `recall` says its speaker-pass copy is missing in Anarlog.
   Only when that cannot run (no recording was kept, or the pass failed or took too long) does the intake read the live transcript, and its outcome says so.
3. The intake reads the summary, your own notes, the action items and a bounded part of the transcript in one Claude pass, and sorts what came out:
   - Clear, low-risk, internal follow-ups, such as research, planning, drafting something for you to read, or building in your own projects, go to Starship ready to start, with the snippet they came from.
   - Anything that needs your review or more thought, anything outward-facing (an instruction to send, reply, email, message, post, publish, pay, buy, sign, invite or call someone), anything destructive (delete or remove), anything that touches another person's commitment, and anything whose source cannot be found in the meeting is held for your decision.
   - When you say "Firstmate, do it", "Firstmate, build that" or "captain's order" in the meeting, the instruction that goes with it counts as a clear follow-up when the transcript shows you said it: under your `speaker_name` label in the call recorder, or under the speaker Anarlog marks as you.
     It waits for your decision when someone else said it, or when Starship could not tell who said it.
4. One spoken line on the desk says what the meeting settled and how many follow-ups started and wait for you (only when [desk voice](configuration.md#desk-voice-out-configspeak) is on).

Nothing in this layer sends, replies, invites, pays or publishes anything.
Starting a follow-up never lands it: merges and outward actions still need your word as usual, under the home's [worker outward actions](configuration.md#worker-outward-actions-configoutward-permissions).

## Keep some meetings out

A meeting whose title, participants, notes, summary or transcript contain an exclude word is never sent to a model or actioned, and Starship never asks Anarlog to run its speaker pass on it; Starship only tells you "excluded meeting, not processed".
The exclude words are each `exclude_word` line in `config/meetings` plus every line of the private `config/meeting-exclude-words` (one word or phrase per line, `#` comments).
Neither ships with any word, so list an employer, its clients and its products there yourself if those meetings must stay out.
A word added later also keeps meetings already taken in out of `recall`: while any exclude word is set, each saved meeting is checked against the whole meeting its recorder still holds, not only against what the intake saved of it.
A saved meeting that cannot be checked that way is withheld from the answer, and `recall` says how many it withheld and why.
The reason it gives is the one that stopped the check: the recorder cannot be reached, it no longer holds the meeting, the meeting's speaker-pass copy is missing in Anarlog, the recorder could not load the meeting (with its own error), `config/meetings` no longer names that recorder, or the check has no record of the meeting because `state/meetings/records.json` no longer lists it (for example after that file was deleted).
If you use Anarlog, keep its automatic meeting detection off, or limited to the calendars you want recorded, so a meeting you never meant to record is not recorded into its store in the first place.

## Set up

1. Write `config/meetings` with `enabled = true`.
   [`examples/meetings`](examples/meetings) lists every key with its default; copy it there and edit.
2. For calls recorded with Starship, nothing more: `source = call-recorder` is the default, and the recorder's `speaker_name` setting is the label that counts as you.
3. For Anarlog, add `source = anarlog`, then:
   1. Install the Anarlog app from [anarlog.so](https://anarlog.so) and let it start at login; imports need it open.
   2. Install Anarlog's command-line tool, `anarlog`, which Anarlog provides, so that `anarlog --json meetings --source local list` prints your meetings in a terminal.
   3. Under its transcription settings, choose a local model that labels speakers (a batch model) beside the live one, or a cloud provider when this laptop is too slow for local models.
   4. Under its meeting settings, keep audio recordings for at least a day; with no recording kept there is nothing to run the speaker pass on.
4. Arm the check: `bin/fm-meetings.sh arm`.
   Meetings that ended before arming are left alone; `bin/fm-meetings.sh intake <id>` takes one in by hand.
5. Start a new session, so the `meeting-intake` skill is linked in; the presence of `config/meetings` switches it on as an [opt-in skill](configuration.md#opt-in-skills-configadhd-configsecond-opinion).

## Keys, safely

The intake itself needs no key: it runs Claude through the `claude` command under the account this home is signed in to.

Anarlog's local models need no key either.
If you choose a cloud transcription provider in Anarlog, such as Deepgram, create the key in that provider's own console and paste it into Anarlog's settings on the Mac yourself.
Never paste a key into a chat with the first mate, a worker, or any agent: a chat is logged, and a key that has been in one should be treated as leaked and replaced.
Starship never reads, stores or needs that key; it reads only the transcripts Anarlog has already written.
The desk floater's own Deepgram key lives in this home's gitignored `.env`, as [configuration.md](configuration.md#desk-voice-out-configspeak) describes, and is unrelated to Anarlog's.

## Use it

```sh
bin/fm-meetings.sh status              # every meeting the check is tracking, and what is on or off
bin/fm-meetings.sh intake              # take in the meetings the check announced (Starship runs this)
bin/fm-meetings.sh intake <id>         # take one meeting in by hand, such as one that ended before arming
bin/fm-meetings.sh recall Robin        # what was said or agreed with Robin
```

## Turn it off

`bin/fm-meetings.sh disarm` stops the check; the meeting records stay.
Setting `enabled = false` in `config/meetings` also stops everything: an armed check then prints nothing, and `intake` refuses.
Delete `config/meetings` to unlink the skill at the next session as well.
Records of meetings already taken in stay in `data/meetings/` until you delete them.

## Delete a call

When someone withdraws consent and you delete a call with `bin/fm-call-companion.sh delete`, the delete also removes that call's intake record in `data/meetings/call-<stamp>/` and the inbox notes the intake created for it, and the intake never takes that call in again.
Items the first mate already filed from those notes, such as backlog items or held decisions that quote the call, stay until you ask the first mate to remove them.

## Privacy

The call recorder keeps its transcripts under this home's `data/calls/`, and Anarlog keeps meetings in its own local database, which this layer reads only through Anarlog's own command-line tool.
Two things leave this machine.
The intake sends the bounded meeting text to Claude under the account this home uses.
For an Anarlog meeting that needs a speaker pass, Starship asks Anarlog to transcribe the meeting's recording again, which goes to Anarlog's transcription provider when a cloud provider is set there.
Excluded meetings get neither.
The intake record for each meeting stays in this home's private `data/meetings/`, and the check's records in `state/meetings/`.
