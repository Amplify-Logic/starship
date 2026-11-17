# Direct-line second mates

A direct-line second mate is a local second mate the captain may talk to directly, instead of only through the first mate.
It is opt-in per charter and off by default.
It exists so a page such as a crew chat can show the mate's own conversation and type into it, while the first mate keeps supervising.
`bin/fm-direct-line.sh` owns the commands and their JSON shapes, `bin/fm-direct-line-lib.sh` owns the opt-in and the "talking with the captain" state, and `bin/fm-pane-writer-lib.sh` owns the pane-writer lock; read their headers before changing them.

## Opting in

Scaffold the charter with `bin/fm-brief.sh <id> --secondmate --direct-line <projects>` and seed it as usual (the `secondmate-provisioning` skill).
The charter then holds the exact line `Direct line: on` and the rules below.
A charter without that line has no direct line, and every direct-line command refuses that mate.
A remote second mate has no direct line yet.

## The rules a direct-line mate follows

- It answers the captain in its own chat.
  Every outcome the parent-channel contract names still goes to the parent channel too, so the first mate's supervision is unchanged ([secondmate-parent-channel.md](secondmate-parent-channel.md)).
- The captain's word outranks the first mate's.
  When the two conflict, the mate follows the captain and appends a `needs-decision` line naming the conflict.
- A chat answer to a call held for the captain closes that hold by script, `bin/fm-captain-hold.sh answer`, so a stale card cannot later record a second, different answer.
  The send path does this itself when the caller names the call with `--answers`; the charter tells the mate to do it for any other chat answer.
- While it is talking with the captain, the first mate never nudges, interrupts, or relaunches it.

## Talking with the captain

A mate is talking with the captain while the captain's last direct-line message is under `FM_DIRECT_LINE_TALK_SECS` old (default 30 minutes), or while the mate has declared that it is waiting on the captain with `bin/fm-direct-line.sh waiting`.
While that lasts:

- the parent's steering-inbox doorbell is deferred and its re-ring ladder does not advance, so a first-mate request waits durably in the inbox;
- the watcher neither nudges the mate to drain its wake queue nor raises a stall for it;
- `bin/fm-control.sh` refuses interrupt, exit, and relaunch unless `--owner-approved` records that the captain asked;
- the bearings row for the mate carries `talking_with_owner: true` and says so in its summary.

A mate whose pane is dead is not talking, so the ordinary liveness recovery still relaunches it.

## Sending

`bin/fm-direct-line.sh send` runs from the parent home and resolves the mate only through `data/secondmates.md`.
Before anything is typed it asserts that the registry entry is local, that the mate's home names the same id and is bound to this parent, and that its charter opts in.
It then, in order:

1. claims the caller's client id in the mate's delivery record, so a retried request is delivered once;
2. copies the message to the mate's parent channel as a `note:` line, and types nothing if that copy fails;
3. hands the words to `bin/fm-desk-voice.sh send` with the mate's home, `--client-id`, and `--expect-home`, with every home override and pane variable cleared;
4. marks the mate as talking with the captain and answers any named held call.

Desk-voice types only into the pane of the session that holds the mate's session lock and runs for the mate's home, under that home's pane-writer lock, and otherwise saves the message to the mate's mailbox.
While the mailbox still holds an undrained message, later messages go to the mailbox too, so they arrive in the order sent.
A caller whose request timed out polls `bin/fm-direct-line.sh delivery <mate> <client-id>` for the outcome instead of sending again.

## One lock for every typist

A second mate's pane has several typists: desk-voice in its home (the desk floater, the web page, captain inbox rings, and the direct line) and the parent's steering-inbox doorbell (fm-send, the watcher's re-ring ladder, and its drain nudge).
Each of them holds the home's pane-writer lock across its check, type, and Enter, and none of them waits for it: desk-voice falls back to the mailbox, a ring leaves its queued wake, and a doorbell is deferred to the next re-ring.
The captain typing at the keyboard cannot take a lock; the composer checks each typist already makes cover that case.

## Reads for a page

Every read prints one JSON document whose `schema` field names its version:

| Read | Schema |
|---|---|
| `bin/fm-direct-line.sh list` | `fm-direct-line-mates.v1` |
| `bin/fm-direct-line.sh send` and `delivery` | `fm-direct-line-delivery.v1` |
| `bin/fm-direct-line.sh talking` and `waiting` | `fm-direct-line-talking.v1` |
| `bin/fm-direct-line.sh conversation <mate>`, or `bin/fm-web.sh conversation` for a home | `fm-web-conversation.v1` |
| `bin/fm-desk-voice.sh delivery <client-id>` | `fm-desk-voice-delivery.v1` |
| `bin/fm-secondmate-pin.sh show` | `fm-secondmate-pin.v1` |

The conversation read is the web page's own transcript reading ([web.md](web.md)), so its item HTML is already escaped.
`bin/fm-secondmate-pin.sh set` changes one mate's model pin without hand-editing `config/secondmate-harness`; relaunching the mate is a separate step.

## Regression coverage

`tests/fm-direct-line.test.sh` drives these commands against lab homes and the real desk-voice, parent-channel, captain-hold, steering-inbox, and control-plane scripts, including a stand-in primary pane for the typed path.
`tests/fm-deepgram-desk.test.sh` covers desk-voice's client id and home assertion, `tests/fm-secondmate-pin.test.sh` the pin command, and `tests/fm-web.test.sh` the conversation read.
