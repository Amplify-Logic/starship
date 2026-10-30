#!/usr/bin/env python3
"""Private composition helper for fm-todo-render.sh; its header owns the contract."""
import datetime
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import sys
import time

STORE, MORNING, DAY, NOW, ZONE, HOME, MORNING_JSON, INTAKE, SOURCES, NAMES, SECTIONS = sys.argv[1:]
NOW = int(NOW)
# Every spelling of the captain a closure actor may carry: the internal label
# and the configured captain_names, singly and as one full name.
ME = {'captain'} | {w.lower() for w in NAMES.split()} | ({' '.join(NAMES.lower().split())} if NAMES.split() else set())
if ZONE:
    os.environ['TZ'] = ZONE
    time.tzset()
RANK = {name: n for n, name in enumerate(('outage', 'urgent', 'deadline', 'obligation'))}
RETIRED = ('closed', 'dropped')
# The sort-last sentinel for a partner ask with no recorded ask epoch.
UNDATED = 253402300799


def esc(value):
    return html.escape(str(value), quote=True)


def number(value):
    try:
        return max(0, int(value))
    except (ValueError, TypeError):
        return 0


def stamp(epoch, fmt='%H:%M %Z'):
    return time.strftime(fmt, time.localtime(int(epoch)))


def when(epoch):
    """A read time, with the day added whenever it is not the page's day."""
    epoch = number(epoch)
    if not epoch:
        return 'an unrecorded time'
    if stamp(epoch, '%Y-%m-%d') == DAY:
        return stamp(epoch)
    return stamp(epoch, '%a %-d %b %H:%M %Z')


def day_start(epoch):
    t = time.localtime(int(epoch))
    return int(time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1)))


class Fragment(HTMLParser):
    """Normalize old document wrappers without guessing actionable content."""
    VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}

    def __init__(self, text):
        super().__init__(convert_charrefs=False)
        self.root = ['', {}, []]
        self.stack = [self.root]
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        node = [tag, dict(attrs), []]
        self.stack[-1][2].append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break

    def handle_data(self, value):
        self.stack[-1][2].append(value)

    def handle_entityref(self, name):
        self.handle_data('&' + name + ';')

    def handle_charref(self, name):
        self.handle_data('&#' + name + ';')

    def blocks(self, nodes=None):
        for node in self.root[2] if nodes is None else nodes:
            if isinstance(node, str):
                yield node
                continue
            tag, attrs, children = node
            classes = (attrs.get('class') or '').split()
            if tag in {'head', 'header', 'h1', 'script', 'style'} or 'legend' in classes:
                continue
            if tag in {'html', 'body'} or 'wrap' in classes:
                yield from self.blocks(children)
            else:
                yield node

    def render(self, node):
        if isinstance(node, str):
            return node
        tag, attrs, children = node
        attributes = ''.join(' ' + k + (f'="{esc(v)}"' if v is not None else '') for k, v in attrs.items())
        content = ''.join(self.render(n) for n in children)
        return f'<{tag}{attributes}>' + content + ('' if tag in self.VOID else f'</{tag}>')

    def heading_text(self, node):
        """A heading's own leading text, before any nested qualifier such as <small>."""
        own = []
        for child in node[2]:
            if not isinstance(child, str):
                break
            own.append(child)
        return ''.join(own).strip()

    def has_content(self, nodes):
        return any(not isinstance(n, str) or n.strip() for n in nodes)

    def drop(self, heading):
        """Remove every h2 whose own heading text matches, with what follows it up to the next h2, at any depth."""
        self.dropped = False
        self._drop(heading, self.root[2], False)
        return self.dropped

    def _drop(self, heading, nodes, dropping):
        kept = []
        for node in nodes:
            if isinstance(node, str):
                if not dropping:
                    kept.append(node)
                continue
            if node[0] == 'h2':
                dropping = bool(re.match(heading, self.heading_text(node), re.I))
                self.dropped = self.dropped or dropping
                if dropping:
                    continue
            else:
                inside = dropping
                had = self.has_content(node[2])
                dropping = self._drop(heading, node[2], dropping)
                if (inside or had) and not self.has_content(node[2]):
                    continue
            kept.append(node)
        nodes[:] = kept
        return dropping

    def html(self):
        return ''.join(self.render(n) for n in self.root[2])

    def sections(self):
        groups = []
        for node in self.blocks():
            if not isinstance(node, str) and node[0] == 'h2':
                groups.append([])
            if not groups:
                groups.append([])
            groups[-1].append(node)
        return [''.join(self.render(n) for n in group) for group in groups]


# --- inputs -----------------------------------------------------------------

items = []
items_dir = Path(STORE) / 'items'
if items_dir.is_dir():
    for path in sorted(items_dir.glob('*.json')):
        if path.is_file() and not path.is_symlink():
            items.append(json.loads(path.read_text()))
def epochs(name):
    path = Path(STORE) / name
    return sorted(number(x) for x in path.read_text().split() if 0 < number(x) <= NOW) if path.is_file() else []


sweeps = epochs('sweeps')
# The freshness floor is this build's verification sweep or intake pass, never
# earlier than the page's own day. A line whose recorded check predates it, or
# checked a different revision than the one shown, is labelled not re-checked.
FLOOR = max([day_start(NOW)] + [s for s in sweeps + epochs('passes') if stamp(s, '%Y-%m-%d') == DAY])
# Closed since: the sweep before this one, else the start of the day. Stable
# through the day, so background rebuilds never shrink it.
# An intake pass never moves it: the boundary is the morning sweep's.
MORNING_FLOOR = max([day_start(NOW)] + [s for s in sweeps if stamp(s, '%Y-%m-%d') == DAY])
earlier = [s for s in sweeps if s < MORNING_FLOOR]
SINCE = earlier[-1] if earlier else day_start(NOW)
sidecar = json.loads(Path(MORNING_JSON).read_text()) if MORNING_JSON else {}


def current(rec):
    """A pass makes current only what it can re-read at its source; anything else,
    a held decision or a Firstmate-internal line, answers to the morning sweep."""
    v = rec.get('verification') or {}
    floor = FLOOR if rec.get('rereadable') else MORNING_FLOOR
    return number(v.get('at')) >= floor and v.get('rev') == rec.get('rev')


def partner_first(rec):
    """A partner-facing ask awaiting the captain sorts ahead of every class, oldest
    ask first, though `tier` still puts a live outage above it in the Needs you
    list; an undated ask is not the oldest, so it sorts after every
    dated one."""
    if not rec.get('partner_first'):
        return (1, 0)
    return (0, number(rec.get('awaiting_since')) or UNDATED)


def asked(rec):
    """When the ask was made: an awaiting partner's own ask, else the item's ask time."""
    return ((rec.get('partner_first') and number(rec.get('awaiting_since')))
            or number(rec.get('asked_at')) or number(rec.get('first_seen')) or UNDATED)


def partner(rec):
    """Partner- or customer-facing: an awaiting partner, or a line the orchestrator
    or the morning sweep marked (a colleague relaying a partner question, a
    customer's own message)."""
    return bool(rec.get('partner_first') or rec.get('partner'))


def tooling(rec):
    """An ask whose source is Firstmate itself, or that the morning sweep flagged as
    its tooling; never a partner or customer ask."""
    own = rec.get('label') == 'firstmate' or any(
        a.startswith(('firstmate:', 'firstmate-backlog:')) for a in rec.get('aliases') or [])
    return bool(rec.get('tooling') or own) and not partner(rec)


def sortkey(rec):
    return (partner_first(rec), RANK.get(rec.get('class'), 99),
            -number((rec.get('verification') or {}).get('at')), rec.get('id', ''))


# --- rows -------------------------------------------------------------------

def brief(text, limit=240):
    """One readable line; the full text stays in the hover title."""
    text = ' '.join(str(text).split())
    if len(text) <= limit:
        return esc(text)
    return f'<span title="{esc(text)}">{esc(text[:limit].rsplit(" ", 1)[0])}…</span>'


def link_to(url, label):
    if re.match(r'^https?://', url or '', re.I):
        return f'<a href="{esc(url)}" target="_blank" rel="noreferrer">{esc(label)}</a>'
    return esc(label)


def link(url):
    if re.match(r'^https?://', url or '', re.I):
        return link_to(url, 'Open')
    return '<span class="nolink">no link recorded</span>'


def freshness(rec):
    v = rec.get('verification') or {}
    if current(rec):
        return f'<span class="prov obs">read {esc(when(v.get("at")))}</span>'
    if number(v.get('at')):
        return f'<span class="prov unv">not re-checked since {esc(when(v.get("at")))}</span>'
    return '<span class="prov unv">cannot verify - no source read recorded</span>'


def reply_form(rec):
    """Hidden full-width note row; the queued text names the id and the revision shown."""
    iid = rec.get('id') or ''
    rev = rec.get('rev') or ''
    title_raw = rec.get('title') or 'untitled item'
    js = (
        "event.preventDefault();"
        "var f=event.currentTarget,v=f.note.value.trim();if(!v)return;"
        "if(!window.lavish||!window.lavish.queuePrompt){f.querySelector('.ack').textContent="
        "'review session not connected';return;}"
        "var at=Math.floor(Date.now()/1000);"
        "window.lavish.queuePrompt("
        f"'Update on to-do item '+{json.dumps(iid)}+' rev '+{json.dumps(rev)}+' at '+at+' ('+{json.dumps(title_raw)}+'): '+v,"
        "{tag:'item-update',"
        f"text:{json.dumps(title_raw[:70])}+': '+v,"
        "element:f,"
        f"queueKey:{json.dumps('todo-item-' + iid)},"
        f"data:{{item_id:{json.dumps(iid)},rev:{json.dumps(rev)},title:{json.dumps(title_raw)},note:v,at:at}}}});"
        "f.note.value='';f.querySelector('.ack').textContent='queued';"
    )
    return (f'<tr class="replyrow" id="note-{esc(iid)}"><td colspan="3">'
            f'<form class="reply" data-lavish-question="todo-item-{esc(iid)}" onsubmit="{esc(js)}">'
            f'<input type="text" name="note" autocomplete="off" '
            f'placeholder="drop, done, park til Friday, mine, you: what to do, dig, or anything else">'
            f'<button type="submit">Queue</button><span class="ack"></span>'
            f'</form></td></tr>')


def note_toggle(rec):
    iid = esc(rec.get('id') or '')
    js = ("var r=document.getElementById('note-" + iid + "');"
          "var o=r.classList.toggle('open');"
          "this.setAttribute('aria-expanded',o);"
          "if(o){r.querySelector('input').focus();}")
    return f'<button type="button" class="notetoggle" aria-expanded="false" onclick="{esc(js)}">note</button>'


# A click anywhere else on a card works its note toggle, so the note opens and
# closes without aiming at the button. Links and buttons keep their own click,
# and a click that ends a text selection toggles nothing.
CARD_CLICK = ("if(event.target.closest('a,button'))return;"
              "if(String(window.getSelection()).trim())return;"
              "var b=this.querySelector('button.notetoggle');if(b)b.click();")


def audit(rec):
    """Where the line came from and how it was read, kept off the visible row for audit."""
    how = (rec.get('verification') or {}).get('how') or 'no verification recorded'
    return f' data-source="{esc(rec.get("label", ""))}" data-how="{esc(how)}"'


# Where a line came from, shown as a small marker under its severity pill. The
# first source token that names a known system wins; anything else is "Other".
SOURCE_ICONS = {
    'slack': '<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/>',
    'email': '<path d="M2 4h12v8H2zM2 4l6 5 6-5"/>',
    'calendar': '<path d="M2.5 3.5h11v10h-11zM2.5 6.5h11M5.5 2v3M10.5 2v3"/>',
    'asana': '<circle cx="8" cy="5" r="2.2"/><circle cx="4.5" cy="10.5" r="2.2"/><circle cx="11.5" cy="10.5" r="2.2"/>',
    'firstmate': '<circle cx="8" cy="3.2" r="1.3"/><path d="M8 4.5v9M5 7h6M3 10a5 3.5 0 0 0 10 0"/>',
    'you': '<circle cx="8" cy="5.5" r="2.5"/><path d="M3 13.5a5 4 0 0 1 10 0"/>',
    'other': '<circle cx="8" cy="8" r="2.5"/>',
}
SOURCE_NAMES = (('slack', 'slack', 'Slack'), ('mail', 'email', 'Email'),
                ('calendar', 'calendar', 'Calendar'), ('asana', 'asana', 'Asana'),
                ('backlog', 'firstmate', 'Firstmate'))


def source_kind(token):
    token = token.strip()
    if token.lower() == 'captain':
        return 'you', 'You'
    for needle, icon, name in SOURCE_NAMES:
        if needle in token.lower():
            return icon, name
    # A bare Slack conversation id (channel, DM or group) is a Slack source.
    if re.fullmatch(r'[CDG][A-Z0-9]{8,11}', token):
        return 'slack', 'Slack'
    return None


def source_marker(rec):
    label = rec.get('label') or ''
    tokens = [label] + re.findall(r'\(([^()]*)\)', label)
    found = next((k for k in map(source_kind, tokens) if k), None)
    icon, name = found or ('other', 'Other')
    title = f'From {name}' if found else f'From {label or "an unrecorded source"}'
    return (f'<span class="src" title="{esc(title)}" aria-label="{esc(title)}">'
            f'<svg viewBox="0 0 16 16" aria-hidden="true">{SOURCE_ICONS[icon]}</svg>{esc(name)}</span>')


def context(rec):
    """At most one short line under the ask: a reopen note, else the why, else the ask's wording."""
    note = rec.get('note') or ''
    for label in {s.get('label') for s in (rec.get('slots') or {}).values() if s.get('label')}:
        changed = re.fullmatch(re.escape(f'reopened: {label} changed after it was closed ') + r'(\([^()]*\))', note)
        if changed:
            note = f'reopened: its source changed after it was closed {changed.group(1)}'
            break
        if note == f'reopened at {label}':
            note = 'reopened at its source'
            break
    for text in (note, rec.get('why'), rec.get('ask') if rec.get('ask') != rec.get('title') else ''):
        if text:
            return f'<span class="ctx">{brief(text, 160)}</span>'
    return ''


def age(rec):
    """How long the ask has waited, computed now; stored titles never carry it."""
    at = asked(rec)
    if at == UNDATED or at > NOW:
        return ''
    days = (datetime.date.fromtimestamp(NOW) - datetime.date.fromtimestamp(at)).days
    if days < 1:
        return ''
    return f'<span class="prov inf">asked {esc(stamp(at, "%a %-d %b"))}, {days} day{"s" if days > 1 else ""} ago</span>'


def marks(rec):
    """The lines an add-on put on the row (fm-todo.sh mark), in name order."""
    return ''.join(f'<span class="prov unv">{brief((m or {}).get("text") or "", 120)}</span>'
                   for _, m in sorted((rec.get('marks') or {}).items()) if (m or {}).get('text'))


def row(rec, reply=True):
    title = esc(rec.get('title') or 'untitled item')
    severity = rec.get('class', 'obligation')
    pill = {'outage': 'bad', 'urgent': 'warn', 'deadline': 'warn'}.get(severity, 'info')
    toggle = note_toggle(rec) if reply else ''
    card = f' onclick="{esc(CARD_CLICK)}"' if reply else ''
    main = (f'<tr class="item" id="item-{esc(rec.get("id", ""))}"{audit(rec)}{card}><td class="who"><span class="pill {pill}">{esc(severity)}</span>{source_marker(rec)}</td>\n'
            f'<td class="what">{title}{freshness(rec)}{age(rec)}{marks(rec)}{context(rec)}</td>\n'
            f'<td class="links">{link(rec.get("link"))}{toggle}</td></tr>')
    return main + '\n' + reply_form(rec) if reply else main


def table(rows):
    return '<div class="tablewrap"><table><tbody>\n' + '\n'.join(rows) + '\n</tbody></table></div>'


def disclosure(title, content):
    return f'<details><summary>{esc(title)}</summary>\n{content}\n</details>'


def listing(recs, note):
    return '<ul class="done">' + ''.join(
        f'<li id="item-{esc(r["id"])}"{audit(r)}><b>{esc(r.get("title"))}</b> - {brief(note(r))}<span class="why">{freshness(r)}{marks(r)}</span></li>'
        for r in recs) + '</ul>'


def capped(recs, more, reply=True, limit=0):
    """At most `limit` rows and a count of the rest; limit 0 shows every row."""
    shown = recs[:limit] if limit else recs
    body = table([row(r, reply=reply) for r in shown])
    if len(recs) > len(shown):
        body += f'\n<p class="sub">{len(recs) - len(shown)} {esc(more)}</p>'
    return body


def stale_fold(recs, reply=True, limit=0):
    """The one labelled fold for routine lines this build did not re-check."""
    if limit and len(recs) > limit:
        recs = sorted(recs, key=lambda r: (number((r.get('verification') or {}).get('at')), r.get('id', '')))
        summary = f'{len(recs)} not re-checked in this build, oldest {limit} shown'
    else:
        summary, limit = f'{len(recs)} not re-checked in this build - each shows its last check', 0
    return disclosure(summary, capped(recs, 'more not re-checked, not shown here.', reply, limit))


def split(recs):
    return sorted((r for r in recs if current(r)), key=sortkey), sorted((r for r in recs if not current(r)), key=sortkey)


# --- action order -----------------------------------------------------------

# Tier 0 is a live outage, as the source classed it. Tier 1 is a partner- or
# customer-facing ask awaiting the captain, tier 2 any other partner- or
# customer-facing ask, even one that is also due today. Tier 3 is a hard
# deadline, which includes every calendar meeting with an end time. Everything
# else follows. Inside every tier the oldest ask comes first, whatever was read
# last. An urgent class earned only by waiting long never lifts a line.
def tier(rec):
    if rec.get('class') == 'outage':
        return 0
    if rec.get('partner_first'):
        return 1
    if partner(rec):
        return 2
    return 3 if rec.get('class') == 'deadline' else 4


def actionkey(rec):
    """Tier, then the oldest ask first, then class."""
    return tier(rec), asked(rec), RANK.get(rec.get('class'), 99), rec.get('id', '')


# --- morning detail fragment ------------------------------------------------

# Each add-on section is read on every render, so a morning copy of a section
# headed the same is always older and never shown.
def addon_headings():
    if not SECTIONS.strip():
        return []
    parsed = Fragment(SECTIONS)
    return [re.escape(parsed.heading_text(n)) + r'(?!\w)' for n in parsed.blocks()
            if not isinstance(n, str) and n[0] == 'h2' and parsed.heading_text(n)]


ADDON_HEADINGS = addon_headings()


def drop_addon_sections(fragment):
    dropped = False
    for heading in ADDON_HEADINGS:
        dropped = fragment.drop(heading) or dropped
    return dropped


reference = ''
details = ''
if MORNING:
    path = Path(MORNING)
    if MORNING_JSON:
        # A structured fragment contains detail only, never another document shell.
        details = path.read_text()
        if re.search(r'<(?:html|head|body|header|h1)\b', details, re.I):
            raise ValueError('structured morning HTML must be a details-only fragment')
        parsed = Fragment(details)
        if drop_addon_sections(parsed):
            details = parsed.html()
    else:
        # Old arbitrary prose has no reliable action identity or per-item read
        # time. Never promote it to an open action or pretend a rebuild verified it.
        legacy = Fragment(path.read_text())
        drop_addon_sections(legacy)
        for part in legacy.sections():
            reference += part
        reference = disclosure('Earlier morning reference - not re-verified by this update',
                               '<p class="sub">Historical snapshot. Re-check sources before treating these lines as open.</p>'
                               + reference) if reference.strip() else ''

# --- partition ----------------------------------------------------------------

today = DAY
snoozed, mine, handoffs, live = [], [], [], []
for rec in items:
    if rec.get('state') != 'open':
        continue
    until = max(rec.get('snoozed_until') or '', rec.get('source_snooze') or '')
    if until > today:
        snoozed.append(rec)
    elif rec.get('pending'):
        handoffs.append(rec)
    elif rec.get('owner') == 'captain':
        mine.append(rec)
    else:
        live.append(rec)


def held(rec):
    """A captain-held backlog task: a hold time is never a source read, so it is never current."""
    return any(slot.startswith('backlog:') for slot in (rec.get('slots') or {}))


# A captain-held backlog task no read made current stays off the page: the
# backlog holds it, and a hold is never evidence that it needs the captain today.
asks = sorted((r for r in live if r.get('kind') in ('decision', 'approval', 'reply')
               and not (held(r) and not current(r))), key=actionkey)
# Approvals about Firstmate's own tooling get their own fold below every
# partner and customer ask, unless one is a live outage.
tools = [r for r in asks if tooling(r) and r.get('class') != 'outage']
asks = [r for r in asks if r not in tools]
activity = [r for r in live if r.get('kind') == 'info']
updates = sorted((r for r in live if r.get('kind') == 'update'),
                 key=lambda r: (-number(r.get('posted')), r.get('id', '')))
waiting = sorted([r for r in items if r.get('state') == 'waiting'] + handoffs, key=sortkey)


def intake_retired(rec):
    """Routine chatter or a team update the intake dropped from its ledger; it was never an ask to close."""
    c = rec.get('closure') or {}
    return rec.get('kind') in ('info', 'update') and c.get('reason') == 'superseded' and c.get('actor') == 'source'


closed = [r for r in items if r.get('state') == 'closed' and not intake_retired(r)
          and number((r.get('closure') or {}).get('at')) >= SINCE]
closed.sort(key=lambda r: (-number(r['closure'].get('at')), r['id']))
# Counted as handled without you only with a named actor other than the
# captain and a fulfilled close; unknown actors, dismissals and releases never count.
def by_you(actor):
    return str(actor or '').strip().lower() in ME


handled = [r for r in closed if r['closure'].get('reason') == 'fulfilled'
           and not by_you(r['closure'].get('actor')) and r['closure'].get('actor') not in ('source', 'unknown', '')]

# --- page -------------------------------------------------------------------

print('<h2>Needs you now<small>live problems first, then partners and customers (those awaiting you first), then deadlines, oldest ask first</small></h2>')
if asks:
    print(table([row(r) for r in asks]))
else:
    print('<div class="note"><b>Nothing open.</b> Nothing recorded is waiting on you.</div>')
if tools:
    print(disclosure(f'Firstmate tooling approvals ({len(tools)})', table([row(r) for r in tools])))

if updates:
    # Information, not asks: what changed in the team channels, newest post first.
    print(disclosure(f'Updates ({len(updates)})', table([
        f'<tr id="item-{esc(r["id"])}"{audit(r)}><td>{brief(r.get("title"))}</td>'
        f'<td><span class="prov inf">posted {esc(when(r["posted"])) if number(r.get("posted")) else "time not recorded"}'
        f' · {esc(r.get("label") or "")}</span></td><td>{link(r.get("link"))}</td></tr>'
        for r in updates])))

if waiting:
    def waiting_note(r):
        if r.get('pending'):
            return f'handoff requested, not yet accepted: {r["pending"].get("what")}'
        return (f'{r.get("owner")} has it: ' if r.get('owner') else 'handed over: ') + (r.get('handover') or 'no hand-over note recorded')
    print(disclosure(f'Waiting on others ({len(waiting)})', listing(waiting, waiting_note)))

if activity:
    fresh, older = split(activity)
    body = table([row(r, reply=False) for r in fresh]) if fresh else '<p class="sub">None re-checked in this build.</p>'
    if older:
        body += '\n' + stale_fold(older, reply=False, limit=10)
    print(disclosure('Other channel activity', body))

if closed:
    who = {'source': 'at the source', 'unknown': 'actor not recorded'}
    label = 'Closed today' if SINCE == day_start(NOW) else f'Closed since {when(SINCE)}'
    count = f'{len(closed)}' + (f', {len(handled)} handled without you' if handled else '')
    print(disclosure(f'{label} ({count})', table([
        f'<tr class="closed" id="item-{esc(r["id"])}"{audit(r)}><td>{esc(r.get("title"))}</td><td>{brief(r["closure"].get("evidence") or "no closing evidence recorded")}{marks(r)}</td>'
        f'<td>{esc(r["closure"].get("reason", ""))} {esc("by you" if by_you(r["closure"].get("actor")) else who.get(r["closure"].get("actor"), "by " + str(r["closure"].get("actor"))))} · {esc(when(r["closure"].get("at")))}</td></tr>'
        for r in closed])))

if snoozed:
    snoozed.sort(key=lambda r: (max(r.get('snoozed_until') or '', r.get('source_snooze') or ''), r['id']))
    print(disclosure(f'Parked ({len(snoozed)})', listing(snoozed, lambda r: f'back on {max(r.get("snoozed_until") or "", r.get("source_snooze") or "")}')))
if mine:
    print(disclosure(f'Yours, tracked but not surfaced ({len(mine)})', listing(sorted(mine, key=sortkey), lambda r: 'you said you are on it')))

# The email agent block is DATED REFERENCE from the file the morning sidecar
# names, never a fresh obligation and never selected by guessing the newest.
email = sidecar.get('email_agent_source') or ''
email_path = Path(email if email.startswith('/') else Path(HOME) / email) if email else None
if email_path and email_path.is_file() and not email_path.is_symlink():
    blocks, heading = {}, ''
    for line in email_path.read_text().splitlines():
        if line.startswith('## '):
            heading = line[3:].strip().lower()
            continue
        entry = re.match(r'^\s*(?:[-*]|\d+\.)\s+(.*)$', line)
        if heading and entry:
            blocks.setdefault(heading, []).append(re.sub(r'[*`]', '', entry.group(1)).strip())

    def pick(prefix, limit):
        return next((v[:limit] for k, v in blocks.items() if k.startswith(prefix)), [])

    body = f'<p class="sub"><span class="prov inf">from {esc(email_path.name)}, written {esc(when(int(email_path.stat().st_mtime)))}</span></p><div class="grid2">'
    for title, lines in (('Next actions', pick('next actions', 3)), ('In flight', pick('in flight', 4)),
                         ('Landed', pick('landed', 4))):
        if lines:
            body += f'<div class="card"><h3>{esc(title)}</h3><ol>' + ''.join(f'<li>{brief(l)}</li>' for l in lines) + '</ol></div>'
    print(disclosure('Email agent replies - dated reference, not fresh obligations', body + '</div>'))

if details.strip():
    print('<section aria-label="Morning detail">' + details + '</section>')
if SECTIONS.strip():
    print(SECTIONS)

# Intake coverage is separate from item freshness: a store cannot fix a read that never ran.
enrolled = set()
if SOURCES and Path(SOURCES).is_file() and not Path(SOURCES).is_symlink():
    enrolled = {l.split('\t', 1)[0] for l in Path(SOURCES).read_text().splitlines() if l.strip()}
coverage = []
for state in sorted(Path(INTAKE).glob('sources/*/state')) if INTAKE else []:
    if state.is_symlink() or not state.is_file():
        continue
    rec = dict(l.split('=', 1) for l in state.read_text().splitlines() if '=' in l)
    if rec.get('id', state.parent.name) not in enrolled:
        continue
    ok = number(rec.get('last_ok'))
    line = f'<li><b>{esc(rec.get("id", state.parent.name))}</b> - last successful read {esc(when(ok) if ok else "never")}'
    if rec.get('error'):
        line += f'<span class="why">last attempt failed: {brief(rec["error"], 180)}</span>'
    coverage.append(line + '</li>')
# What no enrolled source reads between morning sweeps, named rather than
# implied by its absence: each family is covered by an enrolled kind prefix.
FAMILIES = (('Slack DMs', 'slack-dms'), ('Slack mentions', 'slack-mentions'), ('Calendar', 'calendar'),
            ('Gmail inbound', 'gmail'), ('Asana', 'asana'))
if coverage:
    kinds = set()
    if SOURCES and Path(SOURCES).is_file() and not Path(SOURCES).is_symlink():
        kinds = {l.split('\t')[1] for l in Path(SOURCES).read_text().splitlines()
                 if l.strip() and not l.startswith('#') and len(l.split('\t')) > 1}
    unread = [name for name, prefix in FAMILIES if not any(k.startswith(prefix) for k in kinds)]
    coverage.append('<li><b>Not read between morning sweeps</b> - '
                    + esc(', '.join(unread + ['phone, in person and any other channel no source can read'])) + '</li>')
    print(disclosure('Intake coverage', '<ul class="done">' + ''.join(coverage) + '</ul>'))
print(reference)
