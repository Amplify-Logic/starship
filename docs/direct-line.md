# Direct-line second mates

A direct-line second mate is a local second mate the captain may talk to directly, instead of only through the first mate.
It is opt-in per mate and off by default.
It exists so a page such as a crew chat can show the mate's own conversation and type into it, while the first mate keeps supervising.
`bin/fm-direct-line.sh` owns the commands and their JSON shapes, `bin/fm-direct-line-lib.sh` owns the opt-in and the "talking with the captain" state, and `bin/fm-pane-writer-lib.sh` owns the pane-writer lock; read their headers before changing them.

## Opting in

Opting in takes two records, so a mate can never opt itself in.
Scaffold the charter with `bin/fm-brief.sh <id> --secondmate --direct-line <projects>` and seed it as usual (the `secondmate-provisioning` skill); the charter then holds the exact line `Direct line: on` and the rules below.
Then the parent home runs `bin/fm-direct-line.sh enable <id>`, which checks the registry entry, the mate's identity, its local binding to this parent, and its charter before it records the opt-in in the parent's own state.
`bin/fm-direct-line.sh disable <id>` turns it off again.
A mate missing either record has no direct line, and every direct-line command refuses it.
A remote second mate has no direct line yet.

## The rules a direct-line mate follows

- It answers the captain in its own chat.
  Every outcome the parent-channel contract names still goes to the parent channel too, so the first mate's supervision is unchanged ([secondmate-parent-channel.md](secondmate-parent-channel.md)).
- The captain's word outranks the first mate's.
  When the two conflict, the mate follows the captain and appends a `needs-decision` line naming the conflict.
- A call held for the captain closes only through a direct-line message that names it: the caller passes `--answers <task> --hold-identity <identity>`, and the send path closes the call by compare-and-answer, so a call that changed or closed since the captain saw it is never answered.
  The message reaches the mate after `[direct line message <id> answers <task>]`.
  The mate never closes a held call from its own reading of the chat; its one way is `bin/fm-direct-line.sh answered <task> --client-id <id>`, which finishes that message's own answer while it is young.
  An answer given any other way, such as at the pane's keyboard, goes to the first mate as a `needs-decision` line for it to record.
- While it is talking with the captain, the first mate never nudges, interrupts, or relaunches it.

## Talking with the captain

A mate is talking with the captain while its primary is alive and either the captain's last direct-line message is under `FM_DIRECT_LINE_TALK_SECS` old (default 30 minutes; the stamp lives in the parent home), or the mate has declared that it is waiting on the captain with `bin/fm-direct-line.sh waiting` (at most four hours).
A stamp from the future is ignored, so neither record can stretch the state past its bound.
While that lasts:

- a parent steering-inbox doorbell younger than `FM_DIRECT_LINE_DEFER_MAX_SECS` (default one hour) is deferred and its re-ring ladder does not advance; an older one rings and escalates as usual;
- the watcher neither nudges the mate to drain its wake queue nor raises a stall for it;
- `bin/fm-control.sh` refuses interrupt, exit, and relaunch, with no override: the state ends only through the mate's own `bin/fm-direct-line.sh waiting --clear` or the bounds above;
- the bearings row for the mate carries `talking_with_owner: true` and says so in its summary.

A mate whose primary is dead is not talking, so the ordinary liveness recovery still relaunches it.

## Sending

`bin/fm-direct-line.sh send` runs from the parent home and resolves the mate only through `data/secondmates.md`, with the same assertions as `enable` plus the opt-in itself.
The text is at most 8000 characters.
It then, under a per-mate send lock:

1. records the caller's client id with a digest of the text, images, and held call, so a retry with the same id is delivered once and a reused id with different words is refused;
2. copies the message to the mate's parent channel as a `note:` line, and types nothing unless that copy is recorded;
3. marks the mate as talking with the captain, so no lifecycle action lands between the check and the words, and puts the earlier mark back if delivery fails;
4. hands the words to `bin/fm-desk-voice.sh send` with the mate's home, the same `--client-id`, and `--expect-home`, with every home override, pane variable, and submit knob cleared;
5. answers the named held call, if any.

Desk-voice types only into the pane of the session that holds the mate's session lock and runs for the mate's home, under that home's pane-writer lock, and otherwise saves the message to the mate's mailbox.
While the mailbox still holds an undrained message, later messages go to the mailbox too (`desk-voice send --mailbox`), so they arrive in the order sent.
A caller whose request timed out polls `bin/fm-direct-line.sh delivery <mate> <client-id>` instead of sending again; both reads adopt desk-voice's own record of the id and close the held call a delivered message names (a poll does so only when the send lock is free, and never waits for it), and a send that stopped before typing is resumed only within a few minutes and otherwise expires.
A send that finds the per-mate lock still busy after `FM_DIRECT_LINE_LOCK_WAIT` seconds prints the id's record with that record's own exit code when the id is recorded (4 while it is still sending), and otherwise prints state `busy` and exits 2, with nothing recorded or typed.
Desk-voice gets `FM_DIRECT_LINE_SEND_TIMEOUT` seconds plus a 60-second grace before it is killed, so words it is already typing get their Enter.
A caller runs a send detached and polls it rather than killing it; desk-voice finishes the words and their Enter even when its caller is stopped.

## Words, not keys

Desk-voice types the captain's words as one plain line: every control character, escape included, becomes a space and runs of whitespace collapse, so nothing can submit early or act as a key.
A line that would start with `!`, `/`, or `#` is typed after `Message: `, so it never reaches the harness as a shell command, a slash command, or a memory note.
The parent-channel copy is one cleaned line as well, so a message cannot forge a second status line.

## One lock for every typist

A second mate's pane has several typists: desk-voice in its home (the desk floater, the web page, captain inbox rings, and the direct line), the parent's steering-inbox doorbell (fm-send, the watcher's re-ring ladder, and its drain nudge), and the parent's control plane.
Each of them holds the home's pane-writer lock across its check, type, and Enter.
Desk-voice falls back to the mailbox, a ring leaves its queued wake, and a doorbell is deferred to the next re-ring rather than wait; the control plane waits up to `FM_CONTROL_PANE_WAIT` seconds (default 15) and then refuses.
The captain typing at the keyboard cannot take a lock; the composer checks each typist already makes cover that case.

## Reads for a page

Every read prints one JSON document whose `schema` field names its version:

| Read | Schema |
|---|---|
| `bin/fm-direct-line.sh list` | `fm-direct-line-mates.v1` |
| `bin/fm-direct-line.sh send`, `delivery`, and `answered` | `fm-direct-line-delivery.v1` |
| `bin/fm-direct-line.sh talking`, `waiting`, `enable`, and `disable` | `fm-direct-line-talking.v1` |
| `bin/fm-direct-line.sh conversation <mate>`, or `bin/fm-web.sh conversation` for a home | `fm-web-conversation.v1` |
| `bin/fm-desk-voice.sh delivery <client-id>` | `fm-desk-voice-delivery.v1` |
| `bin/fm-secondmate-pin.sh show` | `fm-secondmate-pin.v1` |

The conversation read is the web page's own transcript reading ([web.md](web.md)), so its item HTML is already escaped; a page that inserts it should still serve a strict content security policy.
`bin/fm-secondmate-pin.sh set` changes one mate's model pin without hand-editing `config/secondmate-harness`, and changes nothing unless the new pin reads back exactly; relaunching the mate is a separate step.

## Limits

Any local process that can run scripts as the captain's user can run `send`; the direct line records which message closed a call, not who typed it.
Delivery records are kept until the mate is removed.

## Regression coverage

`tests/fm-direct-line.test.sh` drives these commands against lab homes and the real desk-voice, parent-channel, captain-hold, steering-inbox, and control-plane scripts, including a stand-in primary pane for the typed path.
`tests/fm-deepgram-desk.test.sh` covers desk-voice's client id, home assertion, plain-line typing, and a stopped caller, `tests/fm-secondmate-pin.test.sh` the pin command, and `tests/fm-web.test.sh` the conversation read.
