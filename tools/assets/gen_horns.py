#!/usr/bin/env python3
"""Synthesise vehicle horns (WAV, 44.1 kHz mono): a car's two-tone horn, a
bus's deeper air horn, a motorbike's beep and a bicycle bell.

    tools/.venv/bin/python tools/assets/gen_horns.py --out godot/assets/audio
"""
import argparse
import wave
from pathlib import Path

import numpy as np

SR = 44100


def tone(freqs, seconds, bright=6, attack=0.01, release=0.06, wobble=0.0):
    t = np.arange(int(seconds * SR)) / SR
    out = np.zeros_like(t)
    for f in freqs:
        ph = 2 * np.pi * f * t + wobble * np.sin(2 * np.pi * 5 * t)
        for h in range(1, bright + 1):          # reedy: odd and even harmonics falling off
            out += np.sin(h * ph) / h ** 1.2
    env = np.minimum(1, t / attack) * np.minimum(1, (seconds - t) / release)
    return np.tanh(out * env * 0.9)


def bell(seconds=0.9):
    t = np.arange(int(seconds * SR)) / SR
    out = sum(np.sin(2 * np.pi * f * t) * np.exp(-t * d) for f, d in ((2380, 5), (3120, 7), (5600, 11)))
    return out / 3


def write(path, x):
    x = x / max(np.abs(x).max(), 1e-6) * 0.85
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())
    print(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    gap = np.zeros(int(0.08 * SR))
    write(a.out / "horn_car_000.wav", tone([415, 520], 0.45))
    write(a.out / "horn_car_001.wav", np.concatenate([tone([415, 520], 0.18), gap, tone([415, 520], 0.3)]))
    write(a.out / "horn_bus_000.wav", tone([233, 294, 349], 0.8, bright=9, wobble=0.15))
    write(a.out / "horn_moto_000.wav", tone([660], 0.25, bright=4))
    write(a.out / "bell_bike_000.wav", np.concatenate([bell(0.25), bell(0.7)]))


if __name__ == "__main__":
    main()
