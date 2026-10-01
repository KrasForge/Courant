#!/usr/bin/env python3
"""Write the musical README demo scores for the RTL renderer.

    python3 docs/media/scripts/rtl/make_scores.py

Each score is a list of (seconds, kind, a, b) actions turned into per-cycle
stimulus for render_rtl.cpp: serial MIDI at 31250 baud bit by bit on midi_rx,
preset recalls, and control-bus writes. Output goes to docs/media/scores/.

Control bus (repaired 2026-09-16 RTL): addr 0 = TENSION (0.25 = in tune),
addr 3 = CHAOS (alpha). Factory presets: 0 drum, 1 gong, 2 plate.
"""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / 'scores'
CLK = 100_000_000
BIT = CLK // 31250
TUNE = 0.25


def q123(x):
    return round(x * 2 ** 23)


def stimulus(actions):
    """Same encoding as the sound-repair scores: cycle rst midi pi recall we wa wd."""
    events = {0: {'rst': 1, 'midi': 1}, 64: {'rst': 0}}
    end = 0

    def put(c, **values):
        events.setdefault(int(c), {}).update(values)

    for t, kind, a, b in sorted(actions, key=lambda x: x[0]):
        c = round(t * CLK)
        if kind == 'preset':
            put(c, pi=a, recall=1)
            put(c + 2, recall=0)
        elif kind == 'write':
            put(c, we=1, wa=a, wd=b)
            put(c + 2, we=0)
        else:
            c = max(c, end)  # one UART: messages queue behind each other
            for byte in [0x90 if kind == 'on' else 0x80, a, b]:
                for bit in [0] + [(byte >> k) & 1 for k in range(8)] + [1, 1]:
                    put(c, midi=bit)
                    c += BIT
            end = c
    state = dict(rst=1, midi=1, pi=0, recall=0, we=0, wa=0, wd=0)
    lines = []
    for c, vals in sorted(events.items()):
        state.update(vals)
        lines.append(' '.join(str(x) for x in [c, *state.values()]))
    return '\n'.join(lines) + '\n'


def voice(t, preset, chaos, tension=TUNE):
    return [(t, 'preset', preset, 0), (t + .005, 'write', 3, q123(chaos)),
            (t + .007, 'write', 0, q123(tension))]


def note(t, n, vel, dur):
    return [(t, 'on', n, vel), (t + dur, 'off', n, 0)]


def gong_chorale():
    """Slow A-minor progression on the gong: 3-4 voice chords that ring into each other."""
    a = voice(.001, 1, .06)
    chords = [([45, 57, 60, 64], 96), ([41, 57, 60, 65], 84), ([48, 55, 64, 67], 92),
              ([43, 55, 59, 62], 80), ([45, 57, 64, 69], 104)]
    t = .02
    for i, (ch, vel) in enumerate(chords):
        dur = 2.25 if i < len(chords) - 1 else 3.6
        for k, n in enumerate(ch):  # gentle strum, low to high
            a += note(t + k * .045, n, vel - 6 * k, dur - .05)
        t += 2.3
    return a, 13.0


def plate_arpeggio():
    """Rolling pentatonic arpeggios on the plate; held notes overlap across 4 voices."""
    a = voice(.001, 2, .04)
    pattern = [57, 64, 69, 72, 76, 72, 69, 64]
    roots = [0, -4, 3, 0]
    step = 60 / 112 / 2  # eighth notes at 112 BPM
    t = .02
    for bar, r in enumerate(roots):
        for k, n in enumerate(pattern):
            vel = 100 if k == 0 else 70 + 8 * (k % 3)
            a += note(t, n + r, vel, step * 3.2)
            t += step
    a += note(t, 57, 100, 2.4) + note(t + .03, 64, 88, 2.4) + note(t + .06, 69, 84, 2.4)
    return a, t + 2.6


def mallet_groove():
    """Damped drum preset played as a marimba-like line over a sustained bass."""
    a = voice(.001, 0, .02, tension=TUNE)
    bpm = 120
    s = 60 / bpm / 4  # sixteenths
    melody = [69, None, 72, 74, 76, None, 74, 72, 69, None, 67, 69, 72, None, None, None,
              69, None, 72, 74, 76, 79, 76, 74, 72, None, 74, 72, 69, None, None, None]
    bass = [45, 45, 41, 43]
    t0 = .02
    for rep in range(2):
        for i, b in enumerate(bass):
            a += note(t0 + (rep * 32 + i * 8) * s, b, 100, s * 7.5)
        for i, n in enumerate(melody):
            if n is not None:
                a += note(t0 + (rep * 32 + i) * s, n, 84 + (12 if i % 4 == 0 else 0), s * 1.6)
    end = t0 + 64 * s
    a += note(end, 45, 104, 2.0) + note(end + .01, 57, 90, 2.0) + note(end + .02, 64, 90, 2.0)
    return a, end + 2.2


def chaos_swell():
    """One held gong chord while CHAOS is turned up live, then released back to clean."""
    a = voice(.001, 1, 0.0)
    a += note(.02, 45, 110, 11.5) + note(.06, 52, 96, 11.5) + note(.10, 57, 90, 11.5)
    for i in range(120):  # 0 -> 0.22 over 7 s, then back to 0 over 3 s
        t = .5 + i * .085
        x = .22 * min(1.0, i / 82) if i <= 82 else .22 * max(0.0, 1 - (i - 82) / 37)
        a.append((t, 'write', 3, q123(x)))
    a += note(4.0, 64, 100, 7.5) + note(7.0, 69, 108, 4.5)
    return a, 12.0


SCORES = [
    ('04_gong_chorale', 'Gong Chorale', 'A-minor chord progression on the gong preset, 3-4 voices ringing together',
     gong_chorale),
    ('05_plate_arpeggio', 'Plate Arpeggio', 'Rolling pentatonic arpeggios on the plate preset, 112 BPM, overlapping voices',
     plate_arpeggio),
    ('06_mallet_groove', 'Mallet Groove', 'Marimba-like line on the damped drum preset over a held bass, 120 BPM',
     mallet_groove),
    ('07_chaos_swell', 'Chaos Swell', 'A held gong chord while CHAOS is turned up live and back down',
     chaos_swell),
]

if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    for name, title, character, fn in SCORES:
        actions, dur = fn()
        (OUT / (name + '.txt')).write_text(stimulus(actions))
        notes = sum(1 for x in actions if x[1] == 'on')
        (OUT / (name + '.json')).write_text(json.dumps(
            {'title': title, 'character': character, 'duration_s': round(dur, 2), 'notes': notes,
             'signal_path': 'serial MIDI -> RTL synth_top -> poly voices -> mixer/DC blocker -> CDC -> I2S',
             'actions': actions}, indent=1))
        print(f'{name}: {dur:.2f} s, {notes} notes, frames={round(dur * 48000)}')
