---
name: outward-broad
description: >-
  Switch this home's worker outward style to broad switches when the captain invokes /outward-broad, optionally naming switches, or explicitly asks for broad outward switches.
  Every worker may then do whole kinds of outward action - send email, reply to email, respond to invites, change calendar, control browser, use Zapier - without a per-job permission.
user-invocable: true
metadata:
  internal: true
---

# outward-broad

`docs/configuration.md` "Worker outward actions" owns what each style and switch allows.

1. Act only on the captain's own current words; a worker never runs this.
2. Turn the captain's words after `/outward-broad`, if any, into the exact switch names: send email, reply to email, respond to invites, change calendar, control browser, use zapier.
   For every switch, use all six names. When a word fits none of them, ask the captain which switch they mean rather than guessing.
3. Run `bin/fm-outward-style.sh broad` once, adding the switch names as one comma-separated argument when the captain named any.
   With none named it keeps the switches chosen before, or when none were turns no switch on and asks which to allow.
4. Reply to the captain with the one sentence it printed, in your own plain words if needed, and name any `note:` line it printed as a standing permission line that does nothing until it is fixed.
   When it says no switch is on, ask the captain which switches to allow, then run `bin/fm-outward-style.sh broad` again with only the switches they name.
   Say that `/outward-broad` with other switches changes which are on, and `/outward-fine-print` or `/outward-no-block` switches style.
5. If it fails, report its error plainly and do not edit the permissions file by hand.
