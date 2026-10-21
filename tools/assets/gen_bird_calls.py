#!/usr/bin/env python3
"""Synthesise the quero-quero's (southern lapwing) alarm call: loud, harsh,
two-syllable "que-ro" notes repeated, each a fast downward-bending squawk
around 2-3 kHz with a rough buzz. Two variants.

    tools/.venv/bin/python tools/assets/gen_bird_calls.py --out godot/assets/audio
"""
import argparse
import wave
from pathlib import Path

import numpy as np

SR = 44100
rng = np.random.default_rng(11)


def note(f0, f1, seconds, buzz=180.0):
    t = np.arange(int(seconds * SR)) / SR
    f = np.linspace(f0, f1, len(t))
    ph = 2 * np.pi * np.cumsum(f) / SR
    tone = np.sin(ph) + 0.5 * np.sin(2 * ph) + 0.25 * np.sin(3 * ph)
    rough = 0.65 + 0.35 * np.sign(np.sin(2 * np.pi * buzz * t))      # the grating edge of the call
    env = np.minimum(1, t / 0.008) * np.exp(-t * 9)
    return tone * rough * env


def call(pairs, gap=0.07, pair_gap=0.16):
    parts = []
    for k in range(pairs):
        j = rng.uniform(0.95, 1.05)
        parts += [note(3000 * j, 2500 * j, 0.09), np.zeros(int(gap * SR)),
                  note(2700 * j, 2100 * j, 0.12), np.zeros(int(pair_gap * SR))]
    x = np.concatenate(parts)
    x += rng.normal(0, 0.02, len(x)) * (np.abs(x) > 0.01)
    return x / np.abs(x).max() * 0.9


def write(path, x):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    write(a.out / "quero_quero_000.wav", call(3))
    write(a.out / "quero_quero_001.wav", call(2))
    print("wrote quero_quero_000, quero_quero_001")
