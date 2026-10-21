---
name: outward-fine-print
description: >-
  Switch this home's worker outward style to fine print when the captain invokes /outward-fine-print or explicitly asks to go back to fine print or per-job outward permissions.
  Workers then act outward (send, reply, answer invites, change the calendar, run Zapier, control the browser) only with their job's own permission or a narrow standing permission.
user-invocable: true
metadata:
  internal: true
---

# outward-fine-print

Fine print is the default outward style; `docs/configuration.md` "Worker outward actions" owns what each style allows.

1. Act only on the captain's own current words; a worker never runs this.
2. Run `bin/fm-outward-style.sh fine-print` once.
3. Reply to the captain with the one sentence it printed, in your own plain words if needed, and name any `note:` line it printed as a standing permission line that does nothing until it is fixed.
   Say that `/outward-broad` or `/outward-no-block` switches again.
4. If it fails, report its error plainly and do not edit the permissions file by hand.
