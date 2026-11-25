# House style

Simplicity and readability come first in Starship, for every home and every person who uses it.
Anything written for a person should be understood on the first read.

## Writing for a person

This applies to every report, finding, research write-up, page and PR description.

- Open with a short summary in plain words that the reader can take in within about a minute: what was found, what it means, and what they need to decide.
- Use short sentences.
  Leave out jargon and internal labels.
- Put decisions in a short numbered list, with a recommendation for each.
- Put evidence, tables and detail below the summary, under a clear heading.

## The look

Pages, reports and decision boards use the paper look by default.
It has warm paper in dark and light, with a switch between them, and a serif text face.
Small spaced capitals carry the kicker line and the owner labels.
A page has a large serif headline, a short plain intro, then a numbered list of thin ruled rows.
One muted accent marks what blocks, and the choices are gathered at the end.

The pack is in [`assets/house-style/`](../assets/house-style/):

- `paper.css` holds the colours, type, spacing, rows and switch.
- `template.html` is a small example page with placeholder content to start from.

A page that must stand alone, such as a scout's page, pastes `paper.css` into its own `<style>` block.
Text in the pack meets the usual 4.5 to 1 contrast in both light and dark.

## Where it is already the default

- The web page's colours start on Paper ([web.md](web.md#settings)).
- Report pages opened with `bin/fm-read.sh` use the pack.
- Scout instructions ask for the report and its page in this style, and ship instructions ask for PR descriptions written this way (`bin/fm-brief.sh`).

## Choosing another look

A person can pick another colour scheme for the web page in its Settings; each browser keeps its own choice.
A home that wants a different look for the pages its agents write records that preference in its `data/captain.md` ([configuration.md](configuration.md)).
The writing rules above stay the same in every home.
