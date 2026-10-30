#!/usr/bin/env python3
"""Private item-store core for fm-todo.sh; that script's header owns the contract."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

RANK = ('outage', 'urgent', 'deadline', 'obligation')
KINDS = ('decision', 'approval', 'reply', 'info')
WEEKDAYS = ('monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday')
SLOT_FIELDS = ('title', 'link', 'class', 'kind', 'ask', 'why', 'label', 'since', 'partner_first', 'awaiting_since',
               'ends_at', 'posted', 'asked_at', 'partner', 'tooling')
# Records that were never an ask: the intake retires them and nobody closes them.
UNOWED_KINDS = ('info', 'update')
RETIRED_TTL = 30 * 86400


class Refusal(Exception):
    pass


def number(value):
    try:
        return max(0, int(value))
    except (ValueError, TypeError):
        return 0


def local_day(epoch):
    return time.strftime('%Y-%m-%d', time.localtime(int(epoch)))


def digest(*parts):
    return hashlib.sha256('\x1f'.join(str(p) for p in parts).encode()).hexdigest()[:16]


def when(epoch):
    return time.strftime('%Y-%m-%d %H:%M %Z', time.localtime(int(epoch)))


# Relative times rot the day after they are written ("yesterday", "WAITING 14
# DAYS"), so a stored title or why never keeps one; the page computes ages. Only
# a waiting or age phrasing loses its days: a duration the ask is about stays.
RELATIVE = re.compile(r'\b(waiting)\s+\d+\s+days?\b|\b\d+\s+days?\s+ago\b|\(\s*\d+\s+days?\s*\)'
                      r'|\b(?:today|yesterday)\b', re.I)


def strip_relative(text):
    text = RELATIVE.sub(lambda m: m.group(1) or '', str(text or ''))
    text = re.sub(r'\(\s*\)', '', text)
    text = re.sub(r'\s+([,.;:)])', r'\1', text)
    text = re.sub(r'([(])\s+', r'\1', text)
    text = ' '.join(text.split())
    return re.sub(r'^[\s,;:-]+|[\s,;:-]+$', '', text)


class Store:
    """data/todo: items/<id>.json, sweeps, journal; one lock serializes every write."""

    def __init__(self, root):
        self.root = Path(root)
        self.items_dir = self.root / 'items'

    def __enter__(self):
        self.items_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        self.lock = open(self.root / '.lock', 'a')
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()

    def load(self):
        items = {}
        for path in sorted(self.items_dir.glob('*.json')):
            if path.is_symlink() or not path.is_file():
                continue
            rec = json.loads(path.read_text())
            items[rec['id']] = rec
        return items

    def remove(self, iid):
        path = self.items_dir / (iid + '.json')
        if path.is_file() and not path.is_symlink():
            path.unlink()

    def save(self, rec):
        rec['rereadable'] = rereadable(rec)
        body = json.dumps(rec, indent=1, sort_keys=True, ensure_ascii=False) + '\n'
        path = self.items_dir / (rec['id'] + '.json')
        if path.is_file() and path.read_text() == body:
            return
        fd, tmp = tempfile.mkstemp(dir=self.items_dir, prefix='.item.')
        with os.fdopen(fd, 'w') as fh:
            fh.write(body)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)

    def sweeps(self, name='sweeps'):
        path = self.root / name
        if not path.is_file():
            return []
        return sorted(number(x) for x in path.read_text().split() if number(x))

    def add_sweep(self, epoch, name='sweeps'):
        """A morning sweep (`sweeps`) or an intake pass (`passes`); both bound freshness."""
        kept = sorted(set(self.sweeps(name) + [int(epoch)]))[-60:]
        (self.root / name).write_text(''.join(f'{e}\n' for e in kept))

    def journal(self, entry):
        with open(self.root / 'journal', 'a') as fh:
            fh.write(json.dumps(entry, sort_keys=True, ensure_ascii=False) + '\n')


# --- source readers: each returns observations and never mutates a source -----

def kv_records(folder):
    result = []
    if not folder.is_dir():
        return result
    for path in sorted(folder.glob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        rec = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
        rec.setdefault('key', path.name)
        result.append(rec)
    return result


def ledger_observations(intake_dir, labels):
    """The channel ledger, or None when there is no readable ledger to scan.

    Only an open record's change time is a source read.
    """
    root = Path(intake_dir) if intake_dir else None
    if not root or not root.is_dir() or root.is_symlink():
        return None
    obs = []
    for folder in ('items', 'archive'):
        for rec in kv_records(Path(intake_dir) / folder):
            cls = rec.get('class', '')
            if cls == 'automation-candidate':
                continue
            source = rec.get('source', 'unattributed')
            label = labels.get(source, source)
            aliases = ([f'{source}:{rec["ref"]}'] if rec.get('ref') else []) + [f'ledger:{rec["key"]}']
            aliases += rec.get('provenance', '').split()
            state = {'archived': 'closed', 'waiting': 'waiting'}.get(rec.get('state'), 'open')
            o = {
                'slot': 'ledger:' + rec['key'], 'aliases': aliases,
                # An edit after resolution lands in edited_digest, never in digest.
                'rev': rec.get('edited_digest') or rec.get('digest', ''),
                'title': rec.get('title', ''), 'link': rec.get('link', ''), 'class': cls or 'obligation',
                'kind': 'reply' if cls in RANK else ('update' if cls == 'update' else 'info'),
                'label': label, 'state': state,
            }
            # A team announcement sorts by when it was posted, not when it was read.
            if cls == 'update':
                o['posted'] = number(rec.get('source_epoch')) or number(rec.get('created'))
            # Partner- or customer-facing as the orchestrator marked it
            # (`observe --partner`), and awaiting the captain since an epoch
            # (`observe --partner-awaiting-since`).
            o['partner'] = rec.get('partner_hint') == '1'
            o['awaiting_since'] = number(rec.get('awaiting_since'))
            o['partner_first'] = bool(o['awaiting_since'])
            # When the ask was made, which orders the page; never a read time.
            o['asked_at'] = number(rec.get('source_epoch')) or number(rec.get('created'))
            if state == 'closed':
                o['closed_at'] = number(rec.get('resolved_at')) or number(rec.get('updated'))
                o['evidence'] = rec.get('resolution') or 'resolved on the channel ledger, no reason recorded'
            elif state == 'waiting':
                o['handover'] = rec.get('resolution', '')
            else:
                # `resolve --waiting` advances `updated` without a read, so only
                # an open record's change time counts as reading the source.
                changed = number(rec.get('updated')) or number(rec.get('created'))
                o['verified'] = {'at': changed, 'how': f'read by the channel intake on {label}'}
            obs.append(o)
    return obs


def morning_observations(doc, day, now):
    """Morning action metadata (version 1 or 2); invalid metadata refuses."""
    if doc is None:
        return []
    if not isinstance(doc, dict) or doc.get('version') not in (1, 2) or doc.get('date') != day:
        raise Refusal('morning metadata must have version 1 or 2 and the rendered date')
    obs = []
    for raw in doc.get('actions', []):
        key = str(raw.get('key', ''))
        read = number(raw.get('updated'))
        if (not key or not raw.get('source') or not raw.get('ref') or raw.get('class') not in RANK
                or not read or local_day(read) != day or read > now):
            raise Refusal('morning actions need key, source, ref, ranked class and same-day read epoch')
        kind = raw.get('kind', 'decision')
        if kind not in KINDS:
            raise Refusal(f'morning action kind must be one of {", ".join(KINDS)}: {kind}')
        awaiting = raw.get('partner_awaiting', False)
        since = raw.get('awaiting_since')
        if not isinstance(awaiting, bool) or (since is not None and (
                not isinstance(since, int) or isinstance(since, bool) or not 0 < since < 10 ** 11)):
            raise Refusal('morning action partner_awaiting must be a JSON boolean '
                          'and awaiting_since an epoch second')
        for flag in ('partner', 'tooling'):
            if not isinstance(raw.get(flag, False), bool):
                raise Refusal(f'morning action {flag} must be a JSON boolean')
        asked = raw.get('asked_at')
        if asked is not None and (not isinstance(asked, int) or isinstance(asked, bool) or not 0 < asked < 10 ** 11):
            raise Refusal('morning action asked_at must be an epoch second')
        ends_at = 0
        if raw.get('ends_at') is not None:
            try:
                end = datetime.datetime.fromisoformat(re.sub(r'[Zz]$', '+00:00', raw['ends_at']))
            except (TypeError, ValueError):
                end = None
            if end is None or end.tzinfo is None:
                raise Refusal('morning action ends_at must be an ISO timestamp with a zone')
            ends_at = int(end.timestamp())
        ident = f'{raw["source"]}:{raw["ref"]}'
        aliases = [ident, f'ledger:{key}'] + [a for a in raw.get('aliases', []) if isinstance(a, str) and ':' in a]
        obs.append({
            'slot': 'morning:' + ident, 'aliases': aliases,
            # The key and wording change daily; only an explicit fingerprint of
            # the underlying ask is a meaningful revision.
            'rev': str(raw.get('digest', '')),
            'title': raw.get('title', ''), 'link': raw.get('link', ''), 'class': raw['class'], 'kind': kind,
            'ask': raw.get('ask', ''), 'why': raw.get('why', ''), 'label': raw['source'], 'state': 'open',
            'partner_first': awaiting,
            'awaiting_since': number(since),
            'partner': raw.get('partner', False), 'tooling': raw.get('tooling', False),
            'asked_at': number(asked),
            'ends_at': ends_at,
            # The sidecar is the morning sweep's own verification record.
            'verified': {'at': read, 'how': raw.get('verified_how') or 'morning verification sweep'},
        })
    return obs


def balanced_tail(line):
    """Split trailing `(key: value)` annotations, which may nest parentheses."""
    notes = {}
    rest = line.rstrip()
    while rest.endswith(')'):
        depth = 0
        for i in range(len(rest) - 1, -1, -1):
            depth += {')': 1, '(': -1}.get(rest[i], 0)
            if depth == 0:
                break
        else:
            break
        match = re.match(r'^([a-z][a-z-]*)(?::\s*|\s+)(.*)$', rest[i + 1:-1], re.S)
        if not match or match.group(1) not in ('repo', 'kind', 'priority', 'since', 'hold', 'hold-kind',
                                               'hold-until', 'blocked-by', 'pr'):
            break
        notes[match.group(1)] = match.group(2).strip()
        rest = rest[:i].rstrip()
    return rest, notes


def day_epoch(day):
    """The local start of a YYYY-MM-DD day, or 0 when it is not one."""
    try:
        d = datetime.date.fromisoformat(day)
    except (TypeError, ValueError):
        return 0
    return int(time.mktime((d.year, d.month, d.day, 0, 0, 0, 0, 0, -1)))


def backlog_observations(path):
    """Captain-held tasks in the markdown backlog; None when there is no readable file."""
    backlog = Path(path) if path else None
    if not backlog or not backlog.is_file() or backlog.is_symlink():
        return None
    obs = []
    for line in backlog.read_text().splitlines():
        match = re.match(r'^- \[ \] (\S+) - (.*)$', line)
        if not match:
            continue
        title, notes = balanced_tail(match.group(2))
        if notes.get('hold-kind') != 'captain':
            continue
        until = notes.get('hold-until', '')
        since = notes.get('since', '')
        obs.append({
            'slot': 'backlog:' + match.group(1), 'aliases': [f'firstmate-backlog:{match.group(1)}'],
            # The hold's reason and date are its revision; how long it has been
            # queued orders the page and must never reopen a closed item.
            'rev': digest(notes.get('hold', ''), until),
            'title': title, 'link': '', 'class': 'obligation', 'kind': 'decision',
            'ask': notes.get('hold', ''), 'label': 'firstmate-backlog', 'state': 'open',
            'since': since if re.match(r'^\d{4}-\d{2}-\d{2}$', since) else '',
            'asked_at': day_epoch(since),
            'snoozed_until': until if re.match(r'^\d{4}-\d{2}-\d{2}$', until) else '',
        })
    return obs


# --- folding ------------------------------------------------------------------

PRIORITY = {'ledger': 0, 'morning': 1, 'backlog': 2}


def rev_of(rec):
    """The item's meaningful revision: every source's own revision, in order."""
    return digest(*sorted(f'{slot}={s["rev"]}' for slot, s in rec['slots'].items() if s.get('rev')))[:10]


def transition(store, rec, at, state, actor, reason, evidence='', **extra):
    store.journal({'at': at, 'item': rec['id'], 'from': rec['state'], 'to': state, 'actor': actor,
                   'reason': reason, 'evidence': evidence, 'rev': rec['rev']})
    rec['state'] = state
    rec['closure'] = ({'reason': reason, 'actor': actor, 'evidence': evidence, 'at': at}
                      if state == 'closed' else {})
    rec.pop('source_change', None)
    rec.update(extra)


def present(rec):
    """Presentation fields come from the slots; nothing here changes state."""
    slots = sorted(rec['slots'].values(), key=lambda s: PRIORITY.get(s['slot'].split(':', 1)[0], 9))
    for field in SLOT_FIELDS:
        rec[field] = next((s[field] for s in slots if s.get(field)), '')
    # The morning sweep's curated kind outranks a channel default.
    rec['kind'] = next((s['kind'] for s in slots if s['slot'].startswith('morning:')), rec['kind'] or 'info')
    for field in ('title', 'why'):
        rec[field] = strip_relative(rec[field])
    # The ask was made when its earliest source saw it, whichever source presents it.
    rec['asked_at'] = min([number(s.get('asked_at')) for s in slots if number(s.get('asked_at'))] or [0])
    rec['source_snooze'] = next((s['snoozed_until'] for s in slots if s.get('snoozed_until')), '')
    rec['rev'] = rev_of(rec)


def own_change(rec, o):
    """The source change an add-on recorded making, as this source reports its revision.

    The intake ledger keeps the sha256 of what a pass observed; a morning action
    carries its digest as written.
    """
    change = rec.get('source_change') or ''
    if change and o['slot'].startswith('ledger:'):
        return hashlib.sha256(change.encode()).hexdigest()
    return change


def fold(store, items, observations, now, backlog_seen, ledger_seen):
    """Apply observation CHANGES to items, so repeated syncs of the same inputs are no-ops."""
    index = {a: r['id'] for r in items.values() for a in r['aliases']}
    seen = set()
    reads = []
    for o in observations:
        iid = next((index[a] for a in o['aliases'] if a in index), None)
        fresh = iid is None
        if fresh:
            iid = 't-' + digest(o['aliases'][0])[:12]
            items[iid] = {'id': iid, 'aliases': [], 'slots': {}, 'first_seen': now, 'state': 'open',
                          'owner': '', 'snoozed_until': '', 'pending': {}, 'verification': {}, 'closure': {},
                          'handover': '', 'note': '', 'rev': '', 'kind': ''}
        rec = items[iid]
        for alias in o['aliases']:
            if alias not in rec['aliases']:
                rec['aliases'].append(alias)
            index.setdefault(alias, iid)
        seen.add((iid, o['slot']))
        before = rec['slots'].get(o['slot'])
        rec['slots'][o['slot']] = dict({k: v for k, v in o.items() if k not in ('aliases', 'verified')})
        present(rec)
        if before is None:
            # A first sighting sets the state only for a brand-new item; a new
            # alias of a closed item is not a reason to reopen it.
            if fresh and o['state'] == 'closed':
                transition(store, rec, o['closed_at'] or now, 'closed', 'source', 'resolved', o['evidence'])
            elif fresh and o['state'] == 'waiting':
                transition(store, rec, now, 'waiting', 'source', 'handed over', handover=o['handover'])
        elif (o['rev'] and before.get('rev', '') != o['rev'] and o['rev'] != own_change(rec, o)
              and (rec['state'] == 'closed' or ('source_change' in rec and o['state'] == 'open'))):
            # A closed item, or one an add-on handed over whose source is still
            # open, comes back when its source changes again; the add-on's own
            # recorded change does not count.
            if rec['state'] == 'closed':
                transition(store, rec, now, 'open', 'source', 'reopened',
                           note=f'reopened: {o["label"]} changed after it was closed ({rec["closure"].get("reason")})')
            else:
                transition(store, rec, now, 'open', 'source', 'reopened', owner='', handover='',
                           note=f'reopened: {o["label"]} changed after it was handed to {rec.get("owner")}')
        elif before.get('state') != o['state']:
            if o['state'] == 'closed' and rec['state'] != 'closed':
                transition(store, rec, o['closed_at'] or now, 'closed', 'source', 'resolved', o['evidence'])
            elif o['state'] == 'waiting' and rec['state'] == 'open':
                transition(store, rec, now, 'waiting', 'source', 'handed over', handover=o['handover'])
            elif o['state'] == 'open' and rec['state'] == 'closed':
                transition(store, rec, now, 'open', 'source', 'reopened', note=f'reopened at {o["label"]}')
        if o.get('verified'):
            reads.append((rec, o['verified']))
    # Verification is its own fact: only a newer source read replaces it, and it
    # binds to the revision this sync settles on, after every slot has folded.
    for rec, v in reads:
        if v['at'] > number(rec['verification'].get('at')):
            rec['verification'] = {'at': v['at'], 'how': v['how'], 'rev': rec['rev']}
    # A task no longer held for the captain releases only its own ask; an
    # unreadable backlog releases nothing.
    if backlog_seen:
        for rec in items.values():
            for slot, s in rec['slots'].items():
                if slot.startswith('backlog:') and (rec['id'], slot) not in seen and s['state'] == 'open':
                    s['state'] = 'closed'
                    if rec['state'] != 'closed':
                        transition(store, rec, now, 'closed', 'source', 'released',
                                   'no longer held for you in the backlog')
    # The intake retires a routine record past the brief horizon to its inactive
    # set. An open routine item nothing asserts any more has no ask left; an
    # unreadable ledger is not an absence and closes nothing. A line the captain
    # marked is his to clear, never the intake's, however routine it started.
    if ledger_seen:
        for rec in items.values():
            gone = [s for slot, s in rec['slots'].items()
                    if slot.startswith('ledger:') and (rec['id'], slot) not in seen and s['state'] == 'open']
            if (not gone or rec['state'] != 'open' or rec.get('kind') not in UNOWED_KINDS
                    or rec.get('owner') or rec.get('snoozed_until') or rec.get('pending')
                    or any((rec['id'], slot) in seen for slot in rec['slots'])):
                continue
            for s in gone:
                s['state'] = 'closed'
            transition(store, rec, now, 'closed', 'source', 'superseded',
                       'no longer on the channel ledger; the intake retired it as routine')
    return items


def expire(store, items, now):
    """Close each open item whose known end time has passed, once per end time.

    A line the captain marked is his to clear, never the clock's; a lapsed park
    no longer marks it. A reopen after expiry stays open until a source moves
    the end time, and an expired item a source moves into the future or clears
    the end of comes back on its own.
    """
    for rec in items.values():
        end = number(rec.get('ends_at'))
        if end == number(rec.get('expired_ends_at')):
            continue
        if (end and end <= now and rec['state'] == 'open'
                and not (rec.get('owner') or rec.get('pending')
                         or (rec.get('snoozed_until') or '') > local_day(now))):
            transition(store, rec, now, 'closed', 'auto-expiry', 'superseded', f'ended at {when(end)}',
                       expired_ends_at=end)
        elif ((not end or end > now) and rec['state'] == 'closed'
              and (rec.get('closure') or {}).get('actor') == 'auto-expiry'):
            transition(store, rec, now, 'open', 'auto-expiry', 'reopened',
                       note=f'reopened: now ends at {when(end)}' if end else 'reopened: no longer has an end time',
                       expired_ends_at=0)


# --- commands ---------------------------------------------------------------

def parse_when(text, now):
    text = text.strip().lower()
    today = datetime.date.fromisoformat(local_day(now))
    if re.match(r'^\d{4}-\d{2}-\d{2}$', text):
        return datetime.date.fromisoformat(text).isoformat()
    if text in ('today', 'tomorrow'):
        return (today + datetime.timedelta(days=int(text == 'tomorrow'))).isoformat()
    if text == 'next week':
        return (today + datetime.timedelta(days=7 - today.weekday())).isoformat()
    for n, name in enumerate(WEEKDAYS):
        if text in (name, name[:3]):
            return (today + datetime.timedelta(days=(n - today.weekday()) % 7 or 7)).isoformat()
    raise Refusal(f'park needs a real date (YYYY-MM-DD, today, tomorrow, a weekday or next week): {text}')


def parse_line(line, targeted, now):
    """(verb, words, extra), or None for a line with no leading verb."""
    match = re.match(r'^\s*(drop|done|park|mine|you|dig)\b\s*(.*)$', line, re.I | re.S)
    if not match:
        return None
    verb, rest = match.group(1).lower(), match.group(2).strip()
    extra = {}
    if verb == 'park':
        split = re.match(r'^(.*?)\s*\b(?:til|till|until)\b\s*(.+)$', rest, re.I)
        if split:
            rest, extra['until'] = split.group(1).strip(), parse_when(split.group(2), now)
        elif targeted:
            rest, extra['until'] = '', parse_when(rest, now)
        else:
            raise Refusal('park needs "til <when>"')
    elif verb == 'you':
        words, sep, what = rest.partition(':')
        rest, what = (words.strip(), what.strip()) if sep else (('', rest) if targeted else (rest, ''))
        if not what:
            raise Refusal('you needs "<words>: <what to do>"')
        extra['what'] = what
    return verb, rest, extra


def match_item(items, words):
    if words in items:
        return items[words]
    needle = words.lower()
    hits = [r for r in items.values() if r['state'] != 'closed' and needle
            and needle in (r.get('title', '') + ' ' + r.get('ask', '')).lower()]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise Refusal(f'no open item matches "{words}"')
    raise Refusal(f'"{words}" matches {len(hits)} items: ' + ', '.join(r['id'] for r in hits[:6]))


def apply_command(store, items, line, target, shown_rev, now):
    parsed = parse_line(line, bool(target), now)
    if parsed is None:
        return f'not-a-command {line.strip()}'
    verb, words, extra = parsed
    rec = one(items, target) if target else match_item(items, words)
    if shown_rev and shown_rev != rec['rev']:
        raise Refusal(f'the page showed revision {shown_rev} but {rec["id"]} is now {rec["rev"]}; refresh the page first')
    refs = ' '.join(a for a in rec['aliases'] if not a.startswith('ledger:'))
    tail = f' :: {extra["what"]}' if 'what' in extra else (f' until {extra["until"]}' if 'until' in extra else '')
    result = f'{verb} {rec["id"]} [{refs}] {rec["title"]}{tail}'
    if verb in ('done', 'drop'):
        if rec['state'] == 'closed':
            return 'already ' + result
        transition(store, rec, now, 'closed', 'captain', 'fulfilled' if verb == 'done' else 'dismissed',
                   f'you wrote "{line.strip()}" on the page', pending={}, note='')
        if any(a.startswith('firstmate-backlog:') for a in rec['aliases']):
            result += ' (held decision: record the answer through fm-captain-hold.sh)'
    else:
        field, value = {'park': ('snoozed_until', extra.get('until')), 'mine': ('owner', 'captain')}.get(
            verb, ('pending', {'verb': verb, 'what': extra.get('what', 'investigate and come back with findings')}))
        if rec[field] == value:
            return 'already ' + result
        rec[field] = value
        store.journal({'at': now, 'item': rec['id'], field: value, 'actor': 'captain', 'rev': rec['rev']})
    store.save(rec)
    return result


# --- entry points -------------------------------------------------------------

def load_labels(path):
    labels = {}
    if path and Path(path).is_file() and not Path(path).is_symlink():
        for line in Path(path).read_text().splitlines():
            fields = line.split('\t')
            if len(fields) >= 2:
                labels[fields[0]] = f'{fields[1]} ({fields[0]})'
    return labels


def sync(args, store, now):
    doc = None
    if args.morning_json and Path(args.morning_json).is_file() and not Path(args.morning_json).is_symlink():
        try:
            doc = json.loads(Path(args.morning_json).read_text())
        except ValueError as exc:
            raise Refusal(f'morning metadata is not valid JSON: {exc}')
    # Every input is read and validated before anything is written.
    ledger = ledger_observations(args.intake, load_labels(args.sources))
    observations = list(ledger or [])
    observations += morning_observations(doc, local_day(now), now)
    held = backlog_observations(args.backlog)
    observations += held or []
    items = fold(store, store.load(), observations, now, held is not None, ledger is not None)
    expire(store, items, now)
    started = number(doc.get('sweep_started')) if doc else 0
    if started and started <= now and local_day(started) == local_day(now):
        store.add_sweep(started)
    # Retired routine chatter renders nowhere, so past its retention the record
    # is only cost on a path that runs on every intake pass. The journal keeps it.
    for iid in [i for i, rec in items.items() if prunable(rec, now)]:
        store.remove(iid)
        del items[iid]
    for rec in items.values():
        store.save(rec)
    return items


def prunable(rec, now):
    """Only an intake-retired routine record or team update past its retention; it was never an ask."""
    c = rec.get('closure') or {}
    return (rec.get('state') == 'closed' and rec.get('kind') in UNOWED_KINDS
            and c.get('reason') == 'superseded' and c.get('actor') == 'source'
            and 0 < number(c.get('at')) <= now - RETIRED_TTL)


# Aliases that name no external source to re-read: the store's own ledger key,
# a Firstmate-held decision, a Firstmate-internal morning line.
NOT_A_SOURCE = re.compile(r'^(?:ledger|firstmate-backlog|firstmate):')


def source_refs(rec):
    return [a for a in rec['aliases'] if not NOT_A_SOURCE.search(a)]


def rereadable(rec):
    """An ask a pass can re-read at its source; routine activity and team updates were never asks."""
    return bool(source_refs(rec)) and rec.get('kind') not in UNOWED_KINDS


def recheck_listed(items, now):
    """Every open or waiting item a pass can re-read at its source."""
    for rec in sorted(items.values(), key=lambda r: r['id']):
        if rec['state'] not in ('open', 'waiting') or (rec.get('snoozed_until') or '') > local_day(now):
            continue
        if rereadable(rec):
            yield rec


def recheck(args, items, now):
    if not args.since:
        for rec in recheck_listed(items, now):
            print('\t'.join(['recheck: ' + rec['id'], rec['rev'], rec['state'], rec.get('label', ''),
                             ' '.join(source_refs(rec)), rec.get('link', ''), rec.get('title', '')]))
        return 0
    # Re-read means a verify or a close at or after the claim that listed it.
    missed = [i for i in args.lines if i in items and items[i]['state'] != 'closed'
              and number(items[i]['verification'].get('at')) < args.since]
    gone = [i for i in args.lines if i not in items]
    print(f'TODO_RECHECK: {len(missed)} of {len(args.lines)} listed not re-read'
          + (': ' + ' '.join(missed) if missed else '') + (f' ({len(gone)} no longer in the store)' if gone else ''))
    return 0


MARK_NAME = re.compile(r'^[a-z0-9][a-z0-9._-]{0,39}$')


def mark(store, rec, args, now):
    """An add-on's own line on the row, under one slug name; it never changes state or revision."""
    if not MARK_NAME.match(args.name or ''):
        raise Refusal('mark needs --name, a lowercase slug of [a-z0-9._-] up to 40 characters')
    if args.clear == bool(args.text):
        raise Refusal('mark needs exactly one of --text TEXT and --clear')
    text = ' '.join(args.text.split())
    marks = rec.setdefault('marks', {})
    if args.clear:
        if marks.pop(args.name, None) is None:
            return
    elif (marks.get(args.name) or {}).get('text') == text:
        return
    else:
        marks[args.name] = {'text': text, 'at': now}
    store.journal({'at': now, 'item': rec['id'], 'mark': args.name, 'text': '' if args.clear else text,
                   'actor': 'add-on', 'rev': rec['rev']})


def captain_names(names):
    """Every spelling of the captain: the internal label and the configured names, singly and as one."""
    words = names.lower().split()
    return {'captain'} | set(words) | ({' '.join(words)} if words else set())


def hand_over(store, rec, args, now):
    """An add-on's hand-over: the item waits on a named person with its note."""
    name, note = ' '.join(args.to.split()), ' '.join(args.note.split())
    if rec['state'] == 'closed':
        raise Refusal(f'{rec["id"]} is closed; only an open or waiting item can be handed over')
    if not name:
        raise Refusal('hand-over needs --to naming who has it now')
    if name.lower() in captain_names(args.captain_names):
        raise Refusal(f'hand-over is to someone other than you: {name} is one of the captain_names')
    if not note:
        raise Refusal('hand-over needs --note saying what was handed over')
    if args.rev and args.rev != rec['rev']:
        raise Refusal(f'the page showed revision {args.rev} but {rec["id"]} is now {rec["rev"]}; refresh the page first')
    transition(store, rec, args.at or now, 'waiting', 'add-on', 'handed over', note, pending={}, owner=name,
               handover=note, source_change=args.source_change)


def one(items, iid):
    if iid not in items:
        raise Refusal(f'no item with id {iid}')
    return items[iid]


def main():
    parser = argparse.ArgumentParser(prog='fm-todo-items.py')
    parser.add_argument('command')
    parser.add_argument('lines', nargs='*')
    for flag in ('--store', '--intake', '--sources', '--morning-json', '--backlog', '--item', '--how',
                 '--evidence', '--state', '--rev', '--actor', '--reason', '--name', '--text', '--to', '--note',
                 '--source-change', '--captain-names'):
        parser.add_argument(flag, default='')
    parser.add_argument('--now', type=int, required=True)
    parser.add_argument('--at', type=int, default=0)
    parser.add_argument('--since', type=int, default=0)
    parser.add_argument('--pass', dest='pass_', action='store_true')
    parser.add_argument('--clear', action='store_true')
    args = parser.parse_intermixed_args()
    now = args.now
    try:
        with Store(args.store) as store:
            if args.command == 'sync':
                print(f'TODO_ITEMS: {len(sync(args, store, now))} items synced')
                return 0
            if args.command == 'sweep-start':
                store.add_sweep(args.at or now, 'passes' if args.pass_ else 'sweeps')
                kind = 'intake pass' if args.pass_ else 'verification sweep'
                print(f'TODO_ITEMS: {kind} started at {when(args.at or now)}')
                return 0
            items = store.load()
            if args.command == 'recheck':
                return recheck(args, items, now)
            if args.command == 'command':
                lines = args.lines or [l for l in sys.stdin.read().splitlines() if l.strip()]
                failed = False
                for line in lines:
                    try:
                        result = apply_command(store, items, line, args.item, args.rev, now)
                    except Refusal as exc:
                        result, failed = f'refused {line.strip()} :: {exc}', True
                    print(f'TODO_CMD: {result}')
                return 1 if failed else 0
            if args.command == 'list':
                for rec in sorted(items.values(), key=lambda r: r['id']):
                    if not args.state or rec['state'] == args.state:
                        print('\t'.join([rec['id'], rec['state'], rec.get('kind', ''), rec['rev'], rec.get('title', '')]))
                return 0
            rec = one(items, args.item)
            if args.command == 'verify':
                if not args.how:
                    raise Refusal('verify needs --how naming the read that re-checked it')
                if args.rev and args.rev != rec['rev']:
                    raise Refusal(f'verified revision {args.rev} is not the current {rec["rev"]}')
                rec['verification'] = {'at': args.at or now, 'how': args.how, 'rev': rec['rev']}
            elif args.command == 'close':
                if not args.evidence:
                    raise Refusal('close needs --evidence; nothing closes without it')
                reason = args.reason or 'fulfilled'
                if reason not in ('fulfilled', 'dismissed', 'superseded'):
                    raise Refusal('close --reason is fulfilled, dismissed or superseded')
                if rec['state'] != 'closed':
                    transition(store, rec, now, 'closed', args.actor or 'unknown', reason, args.evidence, pending={})
                if args.source_change:
                    rec['source_change'] = args.source_change
            elif args.command == 'hand-over':
                hand_over(store, rec, args, now)
            elif args.command == 'reopen':
                if rec['state'] == 'open':
                    raise Refusal(f'{rec["id"]} is already open; reopen takes a closed or waiting item')
                # Coming back from waiting ends the hand-over: the ask is the captain's again.
                back = {'owner': '', 'handover': ''} if rec['state'] == 'waiting' else {}
                transition(store, rec, now, 'open', args.actor or 'firstmate', 'reopened',
                           note=args.reason or 'reopened by firstmate', **back)
            elif args.command == 'mark':
                mark(store, rec, args, now)
            elif args.command == 'ack':
                if not rec['pending']:
                    raise Refusal(f'{rec["id"]} has no pending handoff')
                transition(store, rec, now, 'waiting', 'firstmate', 'handoff accepted', pending={},
                           owner='firstmate', handover=rec['pending']['what'])
            else:
                raise Refusal(f'unknown command: {args.command}')
            store.save(rec)
            print(f'TODO_ITEMS: {args.command} {rec["id"]} -> {rec["state"]}'
                  + (f' (mark {args.name})' if args.command == 'mark' else ''))
    except Refusal as exc:
        print(f'fm-todo: {exc}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
