# Call recorder (call companion)

The call recorder turns a call into a live desk and end-of-call notes for this Firstmate home.
While a call runs, a page shows where the call is, the decisions made, the next steps with their owners, and the open questions, each tied to the moment it was said.
When the call ends, it writes paraphrased notes that account for everything the desk showed and quote nobody.

## Ask first: it records only after everyone on the call has agreed

The recorder records only after every person on the call has said yes to being recorded.
Ask at the start of the call, before you start it, and start it only once everyone has agreed.
The start command refuses to run without `--everyone-agreed`, and that agreement is written as the first line of the transcript.
Nothing in this tool starts a recording on its own.
The optional call watcher only notices that a call has begun, reminds you to ask, and names the command to run.

If anyone says no, or asks later for the recording to stop, run `bin/fm-call-companion.sh delete` at once: it stops the recording without writing notes or sending anything more to a model, and deletes the call (see below).

## Platforms

macOS 14.2 or later, on Apple silicon or Intel.
Linux, Windows and WSL are not supported: recording uses macOS audio capture, and the call watcher reads which apps hold the microphone from macOS itself.
Transcription is English only.

## What it records, and where it goes

- **Microphone mode** (`start --mic`) records this Mac's microphone and, when a loopback input such as BlackHole carries the call audio, the far side as a separate track.
  Each 30-second chunk is transcribed by the engine you chose, on this Mac by whisper.cpp or by Deepgram (see [Transcription engine](#transcription-engine-on-this-mac-or-deepgram)), and its audio is deleted as soon as its line is written, so no recording outlives its text.
- **Captions mode** (`start --page <id>`) reads the captions a Google Meet tab shows and records no audio at all.
- Speech is labelled by how it was heard, never by a guess at who spoke: your `speaker_name` for speech only your microphone heard, `others` for the call audio, `unknown speaker` otherwise, or the name Meet's captions show.
- The live desk sends the last hour of transcript to Claude (`claude -p`, Sonnet by default) about once a minute, and the end-of-call notes send the whole transcript once (Opus by default).
  So the transcript text, not the audio, leaves this Mac for Anthropic under the Claude account this home uses.
- Everything stays in this home's private, gitignored folders: the transcript, desk, notes and archive under `data/calls/`, and logs, process records and short-lived audio chunks under `state/calls/`.

## Set up

1. Install the tools: `brew install ffmpeg whisper-cpp jq switchaudio-osx`.
   `whisper-cpp` is what transcribes on this Mac; a home that uses Deepgram can leave it out, but then a chunk Deepgram cannot take has nothing to fall back to and those seconds are lost (see [When Deepgram cannot be used](#transcription-engine-on-this-mac-or-deepgram)).
2. Download a speech model, for transcribing on this Mac:

   ```sh
   mkdir -p ~/.cache/whisper
   curl -L -o ~/.cache/whisper/ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
   ```

   `ggml-large-v3-turbo.bin` from the same place is more accurate and is used when present; a chunk that takes it more than 20 seconds switches the rest of the call to `base.en`.
   On a Mac that is short of memory or slow, use Deepgram instead; `bin/fm-call-companion.sh engine` says which suits your Mac (see [Transcription engine](#transcription-engine-on-this-mac-or-deepgram)).
   A Deepgram home can skip this step, but keeping `whisper-cpp` and `ggml-base.en.bin` installed is what lets a chunk Deepgram misses still be transcribed here; without them those seconds are lost.
3. To capture the far side of the call, install [BlackHole](https://existential.audio/blackhole/) and, in Audio MIDI Setup, create a Multi-Output Device that plays to both your speakers or headphones and BlackHole.
   The recorder switches the system output to it while recording and switches it back when it stops.
   Without it, only your microphone is recorded and the desk says the far side was not captured.
4. Optionally copy [`examples/call-companion`](examples/call-companion) to `config/call-companion` and edit it; set `speaker_name` to your own name.
5. Grant the microphone permission when macOS asks the first time you record.

## Use it

```sh
bin/fm-call-companion.sh start --mic --everyone-agreed     # after everyone has agreed
bin/fm-call-captions.sh --find-meet                        # captions mode: find the Meet tab's id
bin/fm-call-companion.sh start --page <id> --everyone-agreed
bin/fm-call-companion.sh status
bin/fm-call-companion.sh stop
```

`start` opens the desk page, `data/calls/glance.html`, which refreshes every 20 seconds.
Saying "Firstmate, do it", "Firstmate, build that" or "captain's order:" followed by an instruction still shows that order on the desk under "Spoken orders" and logs it, but the live desk is no longer how spoken orders are caught.
They are caught after the call by a meeting intake's scan of the finished meeting, where the home has one, which starts the clear ones.
`bin/fm-call-digest.sh`'s header owns the logs a home can watch for that.

## Transcription engine: on this Mac or Deepgram

Microphone mode transcribes each half minute of audio with one of two engines, chosen by `transcription_engine` in `config/call-companion`:

- `local` (the default) runs whisper.cpp on this Mac.
  The audio never leaves the Mac, and nothing is paid per call.
  On a Mac that is slow or short of memory the transcript falls behind the call, because each half minute takes longer than half a minute to transcribe.
- `deepgram` sends each half minute to Deepgram's speech-to-text and writes its answer a few seconds later, so the transcript keeps up on any Mac.
  The audio chunk leaves this Mac for Deepgram and is deleted here as soon as its lines are written, as with the local engine.
  Every request asks Deepgram not to keep the audio to improve its models (`mip_opt_out`); what else Deepgram retains is governed by its own terms, so read them before recording a call this way.
  Speech is labelled by track exactly as with the local engine, and the names in `config/stt-vocabulary`, where the home has one, are passed to Deepgram as hints.

Either way the transcript is about half a minute behind the call, and `start` says which engine the recording uses and writes it into the transcript under the agreement line.

**Which one suits this Mac.** Run `bin/fm-call-companion.sh engine`.
It prints the engine set, the one a recording would use now, whether a Deepgram key is in place and whether Deepgram accepts it (one free, read-only check that transcribes nothing: working, rejected, or could not check), what is installed for the local engine, this Mac's memory and chip, and a recommendation: Deepgram when the Mac has less than 16 GB of memory, is not Apple silicon, or a past recording fell behind on it; otherwise either works.
When your first mate sets the recorder up for you, it runs this and recommends the same.

**Setting Deepgram up safely.**

1. Make a Deepgram account and create an API key in its console.
   Deepgram charges by the minute of audio transcribed, at a rate its pricing page shows, so an hour's call costs an hour of its per-minute rate; a new account usually starts with some free credit.
   Check the current price there rather than relying on a figure written here.
2. Put the key in this home's gitignored `.env` yourself, so it never passes through a chat.
   In Terminal (zsh, the Mac's default shell), run this line, paste the key at the `Deepgram key:` prompt and press Return:

   ```sh
   read -rs 'k?Deepgram key: ' && printf '\nDEEPGRAM_API_KEY=%s\n' "$k" >> ~/starship/.env && unset k && chmod 600 ~/starship/.env && echo
   ```

   The key is not shown as you paste it and never becomes part of the command, so it stays out of the shell's history; the line holds only the prompt.
   Adding `DEEPGRAM_API_KEY=<the key>` to `~/starship/.env` with a text editor works too.
   Never type the key into the command itself, where the shell's history file would keep a copy, and never paste the key into a chat with your first mate, a message, or a document; the scripts read it from `.env` and never print or log it.
   This is the same key and the same file the [desk floater](desk-floater.md) uses, so a home with the floater already has it.
3. Set the engine:

   ```sh
   echo 'transcription_engine = deepgram' >> ~/starship/config/call-companion
   ```

4. Run `bin/fm-call-companion.sh engine` and check that it says `found and working` for the key and `deepgram` in use.
   `found but rejected` means Deepgram refused the key or its account is out of credit: make a new key in the console and replace the line in `.env`.
   `could not check it` means Deepgram could not be reached; run it again once online.

**When Deepgram cannot be used.** With `deepgram` set but no key found, the whole recording transcribes on this Mac, `start` says so, and the desk shows a note.
When Deepgram cannot be reached during a call, or rejects the key there (a revoked key or an account out of credit), each chunk it misses transcribes on this Mac when whisper.cpp and a model are installed, and the desk says which of the two happened until Deepgram answers again; without a local model those seconds are lost, and the transcript and the desk both say so.
Nothing is ever recorded or sent without the agreement above.

**Switching back.** Set `transcription_engine = local` in `config/call-companion`, or remove the line; the next `start` transcribes on this Mac again.
Leaving the key in `.env` changes nothing while `local` is set.

## Stop a recording

Run `bin/fm-call-companion.sh stop`.
It stops every part at once, switches the audio output back, writes "recording stopped" into the transcript, and then writes the end-of-call notes to `data/calls/notes.md` and `notes.html`, which takes a few minutes.
It then moves the call into `data/calls/archive/` under the stamp it got when it started, and prints that stamp, so the next `start` always begins a clean transcript and two calls never mix.
A stopped call cannot be resumed; start a new one.
If the notes fail, the call stays in place so `bin/fm-call-companion.sh notes` can retry them, and the next `start` archives it.
If the recorder died mid-call, for example when the Mac restarted, `stop` still closes the call out the same way.
Starting the next call while `stop` is still writing the notes is fine: the notes land in the archive with the call they belong to.
If the call watcher is installed, it also stops a running recording on its own once the call has been gone for three minutes.

## Delete a recording

Plain `delete` stops a running recording first, without notes; `delete <stamp>` and `delete --all` refuse while recording.
A `delete` while `stop` is still writing the notes also wins: `stop` discards the notes of the deleted call.

```sh
bin/fm-call-companion.sh delete              # the most recent call, such as the one stop just archived
bin/fm-call-companion.sh list                # archived calls, one stamp each
bin/fm-call-companion.sh delete <stamp>      # one archived call
bin/fm-call-companion.sh delete --all        # every call, the archive, and the decision and order logs
```

Deleting one call removes its transcript, desk, digest, live items and notes, prints its stamp and start time, and also removes its lines from the decision and spoken-order logs in `state/calls/`, which carry each call's stamp, and the notes it left on the desk.
Lines written before calls had stamps carry none, so only `delete --all` removes them.
`reset` moves the call still in place into the archive by hand.

## The call watcher (optional)

```sh
bin/fm-call-watch.sh install     # a LaunchAgent that checks every 20 seconds
bin/fm-call-watch.sh status
bin/fm-call-watch.sh remove
```

It counts as a call a Google Meet tab in the Chrome that `chrome-devtools-axi` drives, or a call app (Zoom, FaceTime, Teams, Slack, WhatsApp, Krisp, or a browser) holding the microphone.
When a call begins and nothing is recording, it shows one notification asking you to get everyone's agreement, with the exact start command.
It never starts a recording, and it leaves a recording you started with no call detected, such as an in-person meeting, for you to stop.

## Second screen (optional)

With `display_host` and `display_url` set, `start` and `desk --display` show the desk full screen on another machine you reach over ssh that runs Hyprland and Chromium, and `stop` closes it.
`display_url` must be an address that machine can open; serving the desk needs only `data/calls/public/`, which links the desk views and never the transcript.
For example, `python3 -m http.server 4179 --bind 127.0.0.1 --directory data/calls/public`, shared to your own devices over a private network such as Tailscale.

## Settings

[`examples/call-companion`](examples/call-companion) lists every `config/call-companion` key with its default, and `bin/fm-call-lib.sh`'s header owns their meaning.

## Switching from a private copy

A home that already runs its own copy of this recorder from a private folder, such as `data/call-companion/`, switches like this:

1. Stop that copy (its `companion.sh stop`) and unload its LaunchAgents, for example `launchctl bootout gui/$(id -u)/<label>` for its call watcher and its desk web server.
2. Put that copy's private values into `config/call-companion`: `speaker_name`, and `display_host` and `display_url` for a second screen.
3. Optionally copy its archive into `data/calls/archive/`; the file names already match.
4. Point anything that read its files at the new ones: a desk web server at `data/calls/public/`, and a wake check at `state/calls/triggers.log` and `state/calls/decisions-batch.log`, whose lines now start with the call's stamp (`bin/fm-call-digest.sh`'s header owns the formats).
5. Run `bin/fm-call-watch.sh install`.

One behavior changes: the shared recorder never starts on its own when a call is detected.
Start each recording yourself with `--everyone-agreed` once everyone has agreed.
The private copy can stay on disk until you delete it; the shared recorder never reads or writes it.
