#!/usr/bin/env bash
# fm-call-captions.sh - poll a Google Meet page's visible captions through
# chrome-devtools-axi and append them to the call transcript.
#
# Usage:
#   fm-call-captions.sh --find-meet
#   fm-call-captions.sh --page <id> [--once|--dump]
#
# Turn captions on in the Meet tab first; this reads only what Meet shows on
# screen and records no audio. Meet names each speaker; "You" is written as the
# speaker_name setting. Paths and settings come from bin/fm-call-lib.sh.
# Environment overrides: CHROME_DEVTOOLS_AXI_BIN, MEET_CAPTIONS_POLL_SECONDS,
# MEET_CAPTIONS_STABLE_SECONDS, CALL_COMPANION_TRANSCRIPT.

set -euo pipefail

# shellcheck source=bin/fm-call-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-call-lib.sh"
TRANSCRIPT=${CALL_COMPANION_TRANSCRIPT:-$FM_CALL_DATA/transcript.txt}
AXI_BIN=${CHROME_DEVTOOLS_AXI_BIN:-chrome-devtools-axi}
POLL_SECONDS=${MEET_CAPTIONS_POLL_SECONDS:-2.5}
STABLE_SECONDS=${MEET_CAPTIONS_STABLE_SECONDS:-6}
LOCAL_SPEAKER=$(fm_call_setting speaker_name me)

usage() {
  cat <<'EOF' >&2
usage: fm-call-captions.sh --find-meet
       fm-call-captions.sh --page <id> [--once|--dump]

Poll a selected Google Meet page for visible caption rows. Normal mode appends
[HH:MM:SS] Speaker: text lines to the call transcript.
EOF
}

require_tools() {
  command -v "$AXI_BIN" >/dev/null 2>&1 || {
    printf 'fm-call-captions: %s is not installed or not on PATH\n' "$AXI_BIN" >&2
    exit 127
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-call-captions: jq is required\n' >&2
    exit 127
  }
}

find_meet_pages() {
  local pages matches
  pages=$("$AXI_BIN" pages)
  matches=$(printf '%s\n' "$pages" | awk 'index($0, "meet.google.com") { print }')
  if [ -n "$matches" ]; then
    printf '%s\n' "$matches"
  else
    printf 'No meet.google.com pages found.\n' >&2
  fi
}

decode_axi_result() {
  local raw=$1 payload
  payload=$(printf '%s\n' "$raw" | sed -n 's/^result: //p' | head -n 1)
  [ -n "$payload" ] || return 1
  printf '%s\n' "$payload" | jq -er '.'
}

POLL_JS=$(cat <<'JAVASCRIPT'
(() => {
  const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
  const visible = el => {
    if (!el || !(el instanceof Element)) return false;
    const style = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const speakerSelector = '.NWpY1d, .zs7s8d.jxFHg, [data-self-name]';
  const textSelector = '.ygicle, .iTTPOb';
  const rowSelector = '.nMcdL';
  const blocklist = /captions? (?:are|is|have been)|subtitles? (?:are|is|have been)|you (?:joined|left)|present now|microphone|camera|raise your hand/i;

  const fromRow = row => {
    const speakerEl = row.querySelector(speakerSelector);
    const selfNameEl = row.matches('[data-self-name]') ? row : row.querySelector('[data-self-name]');
    let speaker = clean(selfNameEl?.getAttribute('data-self-name') || speakerEl?.textContent || '');
    const textEl = row.matches(textSelector) ? row : row.querySelector(textSelector);
    let text = clean(textEl?.textContent || row.innerText || row.textContent || '');
    if (speaker && text.startsWith(speaker)) text = clean(text.slice(speaker.length));
    if (!speaker) {
      const lines = String(row.innerText || '').split(/\n+/).map(clean).filter(Boolean);
      if (lines.length > 1 && lines[0].length < 80) {
        speaker = lines.shift();
        text = clean(lines.join(' '));
      }
    }
    return { speaker: speaker || 'Unknown', text };
  };

  const rowsFrom = region => {
    let rows = Array.from(region.querySelectorAll(rowSelector)).filter(visible);
    if (region.matches(rowSelector) && visible(region)) rows.unshift(region);

    if (!rows.length) {
      rows = Array.from(region.querySelectorAll('[data-participant-id], [jsname="tgaKEf"]')).filter(visible);
      if ((region.matches('[data-participant-id]') || region.matches('[jsname="tgaKEf"]')) && visible(region)) {
        rows.unshift(region);
      }
    }

    let entries = rows.map(fromRow).filter(entry => entry.text && !blocklist.test(entry.text));

    if (!entries.length) {
      const textEls = Array.from(region.querySelectorAll(textSelector)).filter(visible);
      entries = textEls.map(textEl => {
        let container = textEl.parentElement;
        for (let depth = 0; container && depth < 5 && !container.querySelector(speakerSelector); depth += 1) {
          container = container.parentElement;
        }
        return fromRow(container || textEl);
      }).filter(entry => entry.text && !blocklist.test(entry.text));
    }

    if (!entries.length) {
      const entry = fromRow(region);
      if (entry.text && !blocklist.test(entry.text)) entries = [entry];
    }

    const seen = new Set();
    return entries.filter(entry => {
      const key = `${entry.speaker}\u0000${entry.text}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  };

  const accessibilitySelectors = [
    '[aria-label*="caption" i]:not(button)',
    '[role="log"][aria-label*="caption" i]',
    '[role="region"][aria-label*="caption" i]',
    '[aria-live][aria-label*="caption" i]',
    '[role="log"]'
  ];
  for (const selector of accessibilitySelectors) {
    for (const region of Array.from(document.querySelectorAll(selector)).filter(visible)) {
      const entries = rowsFrom(region);
      if (entries.length) return entries;
    }
  }

  const knownSelectors = [
    '.a4cQT .iOzk7',
    '.a4cQT',
    '[jsname="YSxPC"]',
    '[jsname="tgaKEf"]',
    '.iOzk7',
    '.TBMuR'
  ];
  for (const selector of knownSelectors) {
    for (const region of Array.from(document.querySelectorAll(selector)).filter(visible)) {
      const entries = rowsFrom(region);
      if (entries.length) return entries;
    }
  }

  window.__callCompanionLiveState ||= new WeakMap();
  const now = Date.now();
  const liveCandidates = Array.from(document.querySelectorAll(
    '[aria-live="polite"], [aria-live="assertive"], [role="log"], [role="status"]'
  )).filter(visible).map(el => {
    const text = clean(el.innerText || el.textContent || '');
    const prior = window.__callCompanionLiveState.get(el) || { text: '', changes: 0, changedAt: 0 };
    if (text && prior.text && text !== prior.text) {
      prior.changes += 1;
      prior.changedAt = now;
    }
    prior.text = text;
    window.__callCompanionLiveState.set(el, prior);
    return { el, text, changes: prior.changes, changedAt: prior.changedAt };
  }).filter(candidate => candidate.text && candidate.text.length < 2500 && !blocklist.test(candidate.text));

  liveCandidates.sort((a, b) => {
    const aScore = a.changes * 100000 + a.changedAt + Math.min(a.text.length, 1000);
    const bScore = b.changes * 100000 + b.changedAt + Math.min(b.text.length, 1000);
    return bScore - aScore;
  });
  const changing = liveCandidates.find(candidate => candidate.changes > 0);
  return changing ? rowsFrom(changing.el) : [];
})()
JAVASCRIPT
)

DUMP_JS=$(cat <<'JAVASCRIPT'
(() => {
  const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
  const visible = el => {
    const style = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const selectors = {
    accessibility: '[aria-label*="caption" i]:not(button), [role="log"], [role="region"][aria-label*="caption" i]',
    known: '.a4cQT .iOzk7, .a4cQT, [jsname="YSxPC"], [jsname="tgaKEf"], .iOzk7, .TBMuR, .nMcdL',
    live: '[aria-live], [role="log"], [role="status"]'
  };
  const describe = el => ({
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    aria_label: el.getAttribute('aria-label') || '',
    aria_live: el.getAttribute('aria-live') || '',
    jsname: el.getAttribute('jsname') || '',
    classes: clean(el.className).slice(0, 240),
    text: clean(el.innerText || el.textContent || '').slice(0, 600)
  });
  const result = {};
  for (const [name, selector] of Object.entries(selectors)) {
    result[name] = Array.from(document.querySelectorAll(selector)).filter(visible).slice(0, 30).map(describe);
  }
  return result;
})()
JAVASCRIPT
)

poll_once() {
  local raw decoded
  raw=$("$AXI_BIN" eval "$POLL_JS") || return 1
  decoded=$(decode_axi_result "$raw") || return 1
  printf '%s\n' "$decoded" | jq -ec 'if type == "array" then . else error("caption result is not an array") end'
}

dump_candidates() {
  local raw decoded
  raw=$("$AXI_BIN" eval "$DUMP_JS") || return 1
  decoded=$(decode_axi_result "$raw") || return 1
  printf '%s\n' "$decoded" | jq '.'
}

append_line() {
  local speaker=$1 text=$2
  # Meet captions name each speaker; "You" is this browser's own account.
  case "$speaker" in
    You) speaker=$LOCAL_SPEAKER ;;
    ''|Unknown) speaker='unknown speaker' ;;
  esac
  printf '[%s] %s: %s\n' "$(date '+%H:%M:%S')" "$speaker" "$text" >> "$TRANSCRIPT"
}

active_speaker=
active_text=
active_changed=0
committed_speaker=
committed_text=

flush_active() {
  if [ -n "$active_text" ]; then
    append_line "$active_speaker" "$active_text"
    committed_speaker=$active_speaker
    committed_text=$active_text
    active_speaker=
    active_text=
    active_changed=0
  fi
}

begin_turn() {
  local speaker=$1 text=$2 suffix
  if [ "$speaker" = "$committed_speaker" ]; then
    if [ "$text" = "$committed_text" ] || [[ "$committed_text" == "$text"* ]]; then
      return 0
    fi
    if [[ "$text" == "$committed_text"* ]]; then
      suffix=${text#"$committed_text"}
      text=$(printf '%s' "$suffix" | sed 's/^[[:space:][:punct:]]*//')
      [ -n "$text" ] || return 0
    fi
  fi
  active_speaker=$speaker
  active_text=$text
  active_changed=$(date +%s)
}

process_latest() {
  local entries=$1 latest speaker text now
  latest=$(printf '%s\n' "$entries" | jq -c 'last // empty')
  [ -n "$latest" ] || return 0
  speaker=$(printf '%s\n' "$latest" | jq -r '.speaker // "Unknown"')
  text=$(printf '%s\n' "$latest" | jq -r '.text // ""')
  [ -n "$text" ] || return 0
  now=$(date +%s)

  if [ -z "$active_text" ]; then
    begin_turn "$speaker" "$text"
  elif [ "$speaker" != "$active_speaker" ]; then
    flush_active
    begin_turn "$speaker" "$text"
  elif [ "$text" = "$active_text" ] || [[ "$active_text" == "$text"* ]]; then
    :
  elif [[ "$text" == "$active_text"* ]]; then
    active_text=$text
    active_changed=$now
  else
    flush_active
    begin_turn "$speaker" "$text"
  fi

  if [ -n "$active_text" ] && [ $((now - active_changed)) -ge "$STABLE_SECONDS" ]; then
    flush_active
  fi
}

main() {
  local action='' page='' mode='loop' entries
  require_tools
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --find-meet)
        action='find'
        ;;
      --page)
        shift
        [ "$#" -gt 0 ] || { usage; exit 2; }
        page=$1
        ;;
      --once)
        mode=once
        ;;
      --dump)
        mode=dump
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 2
        ;;
    esac
    shift
  done

  if [ "$action" = find ]; then
    [ -z "$page" ] && [ "$mode" = loop ] || { usage; exit 2; }
    find_meet_pages
    exit 0
  fi
  [ -n "$page" ] || { usage; exit 2; }
  "$AXI_BIN" selectpage "$page" >/dev/null

  if [ "$mode" = dump ]; then
    dump_candidates
    exit 0
  fi
  if [ "$mode" = once ]; then
    poll_once | jq '.'
    exit 0
  fi

  mkdir -p "$(dirname "$TRANSCRIPT")"
  touch "$TRANSCRIPT"
  trap 'flush_active' EXIT
  trap 'exit 0' INT TERM
  while :; do
    if entries=$(poll_once); then
      process_latest "$entries"
    else
      printf 'fm-call-captions: caption poll failed; retrying in %s seconds\n' "$POLL_SECONDS" >&2
    fi
    sleep "$POLL_SECONDS" &
    wait "$!"
  done
}

main "$@"
