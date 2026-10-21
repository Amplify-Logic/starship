---
name: outward-no-block
description: >-
  Switch this home's worker outward check off (No Block) when the captain invokes /outward-no-block or explicitly asks for no block.
  Every worker then sends, replies, answers invites, changes the calendar, runs Zapier and controls the browser whenever its instructions say to.
user-invocable: true
metadata:
  internal: true
---

# outward-no-block

`docs/configuration.md` "Worker outward actions" owns what each style allows.

1. Act only on the captain's own current words; a worker never runs this, and nothing else implies it.
2. Run `bin/fm-outward-style.sh no-block` once.
3. Reply to the captain with the one sentence it printed, in your own plain words if needed.
   Say that `/outward-fine-print` or `/outward-broad` turns the check back on, and that narrow standing permissions are kept for then.
4. If it fails, report its error plainly and do not edit the permissions file by hand.
