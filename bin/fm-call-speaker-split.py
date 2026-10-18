#!/usr/bin/env python3
"""fm-call-speaker-split.py - label Whisper segments by which recorded source carried the speech.

The microphone track is this Mac's own microphone; the loopback track is the call's
system audio (the far side).  A segment is labelled with the local name only when the
microphone alone carried its speech, "others" only when the loopback carried it, and
"unknown speaker" whenever both did, neither clearly did, or the call shares a room.
Nothing here guesses a name: the labels describe the source, never a person's identity.

usage: fm-call-speaker-split.py --whisper mix.json --mic mic.wav [--loop loop.wav]
                                --start HH:MM:SS [--local-name me] [--shared-room]
Prints one transcript line per speaker turn: "[HH:MM:SS] label: text".
"""

import argparse
import array
import json
import math
import sys
import wave

FRAME_SECONDS = 0.05
LOOP_ACTIVE_DB = -60.0      # BlackHole is digitally silent (about -91 dB) when nobody on the far side speaks
MIC_ABOVE_FLOOR_DB = 12.0   # microphone speech must clear the chunk's own noise floor by this much
MIC_MIN_ACTIVE_DB = -66.0
MIC_ALWAYS_ACTIVE_DB = -45.0  # caps the floor so a chunk of unbroken speech still counts as speech
LOOP_CLEAR_DB = -45.0       # loopback frames this loud are used to measure how much of it leaks into the mic
DEFAULT_ECHO_DB = -15.0     # assumed leak (mic minus loopback) when the chunk has too little far-side speech to measure
EXTRA_SPEECH_DB = 10.0      # mic energy this far above the expected leak means the local side is talking too
DOMINANT_SHARE = 0.8        # a label needs this share of the segment's speech frames
MIN_SPEECH_SECONDS = 0.3
OTHERS = "others"
UNKNOWN = "unknown speaker"


def frame_levels(path):
    with wave.open(path, "rb") as handle:
        if handle.getsampwidth() != 2:
            raise SystemExit(f"fm-call-speaker-split: {path} is not 16-bit PCM")
        rate = handle.getframerate()
        channels = handle.getnchannels()
        samples = array.array("h")
        samples.frombytes(handle.readframes(handle.getnframes()))
    if sys.byteorder == "big":
        samples.byteswap()
    if channels > 1:
        samples = array.array("h", samples[::channels])
    size = max(1, int(rate * FRAME_SECONDS))
    levels = []
    for start in range(0, len(samples), size):
        frame = samples[start:start + size]
        if not frame:
            break
        power = sum(value * value for value in frame) / len(frame)
        levels.append(10 * math.log10(power / (32768.0 ** 2)) if power > 0 else -120.0)
    return levels


def percentile(values, share):
    if not values:
        return -120.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * share))]


def echo_coupling(mic, loop):
    """How far below the loopback the far side's leak into the mic sits, from the quietest-mic quarter of clear far-side frames."""
    ratios = [mic[index] - loop[index] for index in range(min(len(mic), len(loop))) if loop[index] >= LOOP_CLEAR_DB]
    if len(ratios) < 20:
        return DEFAULT_ECHO_DB
    return min(percentile(ratios, 0.25), DEFAULT_ECHO_DB)


def classify_frames(mic, loop):
    mic_threshold = min(max(percentile(mic, 0.1) + MIC_ABOVE_FLOOR_DB, MIC_MIN_ACTIVE_DB), MIC_ALWAYS_ACTIVE_DB)
    coupling = echo_coupling(mic, loop) if loop is not None else DEFAULT_ECHO_DB
    classes = []
    for index, mic_db in enumerate(mic):
        loop_db = loop[index] if loop is not None and index < len(loop) else -120.0
        mic_on = mic_db >= mic_threshold
        loop_on = loop is not None and loop_db >= LOOP_ACTIVE_DB
        if loop_on and (not mic_on or mic_db <= loop_db + coupling + EXTRA_SPEECH_DB):
            classes.append("O")
        elif mic_on and not loop_on:
            classes.append("L")
        elif mic_on and loop_on:
            classes.append("B")
        else:
            classes.append("S")
    return classes


def label_for(classes, start_ms, end_ms, have_loop, local_name, shared_room):
    first = int(start_ms / 1000 / FRAME_SECONDS)
    last = max(first + 1, int(math.ceil(end_ms / 1000 / FRAME_SECONDS)))
    window = classes[first:last]
    local = window.count("L")
    others = window.count("O")
    speech = local + others + window.count("B")
    if speech * FRAME_SECONDS < MIN_SPEECH_SECONDS:
        return None
    if not have_loop:
        return UNKNOWN
    if others >= DOMINANT_SHARE * speech:
        return OTHERS
    if local >= DOMINANT_SHARE * speech and not shared_room:
        return local_name
    return UNKNOWN


def clock(start, offset_ms):
    hours, minutes, seconds = (int(part) for part in start.split(":"))
    total = (hours * 3600 + minutes * 60 + seconds + int(offset_ms // 1000)) % 86400
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--whisper", required=True)
    parser.add_argument("--mic", required=True)
    parser.add_argument("--loop")
    parser.add_argument("--start", required=True)
    parser.add_argument("--local-name", default="me")
    parser.add_argument("--shared-room", action="store_true")
    parser.add_argument("--stats", action="store_true", help="print per-segment frame counts to stderr")
    args = parser.parse_args()

    with open(args.whisper, encoding="utf-8") as handle:
        segments = json.load(handle).get("transcription", [])
    mic = frame_levels(args.mic)
    loop = frame_levels(args.loop) if args.loop else None
    classes = classify_frames(mic, loop)

    turns = []
    dropped = 0
    for segment in segments:
        text = " ".join(str(segment.get("text", "")).split())
        if not text:
            continue
        offsets = segment.get("offsets", {})
        start_ms, end_ms = int(offsets.get("from", 0)), int(offsets.get("to", 0))
        label = label_for(classes, start_ms, end_ms, loop is not None, args.local_name, args.shared_room)
        if args.stats:
            first = int(start_ms / 1000 / FRAME_SECONDS)
            window = classes[first:max(first + 1, int(math.ceil(end_ms / 1000 / FRAME_SECONDS)))]
            print(f"fm-call-speaker-split: {start_ms}-{end_ms}ms L={window.count('L')} O={window.count('O')} B={window.count('B')} S={window.count('S')} -> {label}", file=sys.stderr)
        if label is None:
            # Neither track carried speech: Whisper invented text over silence ("Thank you.").
            dropped += 1
            continue
        if turns and turns[-1][1] == label and len(turns[-1][2]) < 600:
            turns[-1][2] += " " + text
        else:
            turns.append([start_ms, label, text])
    for start_ms, label, text in turns:
        print(f"[{clock(args.start, start_ms)}] {label}: {text}")
    if dropped:
        print(f"fm-call-speaker-split: dropped {dropped} segment(s) with no speech on either track", file=sys.stderr)


if __name__ == "__main__":
    main()
