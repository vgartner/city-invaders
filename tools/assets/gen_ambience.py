#!/usr/bin/env python3
"""Synthesise seamless ambience loops (WAV, 22.05 kHz mono) for the game:
distant traffic, wind and park birds, and the robot dropship's engine.
Pure numpy, no source recordings."""
import argparse
import wave
from pathlib import Path

import numpy as np

SR = 22050


def lowpass(x, alpha):
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += alpha * (v - acc)
        y[i] = acc
    return y


def seamless(x, fade_s=2.0):
    """Crossfade the tail into the head so the loop has no click."""
    n = int(fade_s * SR)
    head, body, tail = x[:n], x[n:-n], x[-n:]
    t = np.linspace(0, 1, n)
    return np.concatenate([tail * (1 - t) + head * t, body])


def traffic(rng, seconds):
    n = int((seconds + 4) * SR)
    brown = np.cumsum(rng.normal(0, 1, n))
    brown -= lowpass(brown, 0.0005)                 # remove drift
    rumble = lowpass(brown, 0.05)
    env = np.full(n, 0.35)
    for _ in range(int(seconds / 3)):               # a car passing every ~3 s
        c = rng.integers(0, n)
        w = rng.uniform(1.0, 2.5) * SR
        env += rng.uniform(0.3, 0.8) * np.exp(-((np.arange(n) - c) / w) ** 2)
    hiss = lowpass(rng.normal(0, 1, n), 0.25) * 0.15
    return seamless((rumble / np.abs(rumble).max() + hiss) * env)


def wind(rng, seconds):
    n = int((seconds + 4) * SR)
    noise = lowpass(rng.normal(0, 1, n), 0.02)
    t = np.arange(n) / SR
    gust = 0.5 + 0.35 * np.sin(t * 0.7 + 1.3) + 0.15 * np.sin(t * 2.3)
    return seamless(noise / np.abs(noise).max() * gust)


def birds(rng, seconds):
    n = int((seconds + 4) * SR)
    out = np.zeros(n)
    t0 = 0.0
    while t0 < seconds + 3:
        t0 += rng.uniform(0.4, 2.5)
        f0, f1 = rng.uniform(2500, 4500), rng.uniform(3000, 6000)
        for k in range(rng.integers(1, 5)):        # a short phrase of chirps
            dur = rng.uniform(0.05, 0.14)
            m = int(dur * SR)
            tt = np.arange(m) / SR
            freq = np.linspace(f0, f1, m) * (1 + 0.05 * np.sin(tt * 90))
            chirp = np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.sin(np.pi * tt / dur) ** 2
            s = int((t0 + k * dur * 1.6) * SR)
            if s + m < n:
                out[s:s + m] += chirp * rng.uniform(0.3, 1.0)
    return seamless(out / max(1e-6, np.abs(out).max()))


def ship_engine(rng, seconds):
    """Robot dropship hovering/flying: a heavy low drone with two detuned hums
    beating against each other, a rumble and a thin turbine whine."""
    n = int((seconds + 4) * SR)
    t = np.arange(n) / SR
    hum = sum(g * np.sign(np.sin(2 * np.pi * f * t)) * 0.5 + g * np.sin(2 * np.pi * f * t)
              for f, g in ((46.0, 1.0), (46.7, 0.8), (69.2, 0.45)))
    hum = lowpass(hum, 0.06)
    brown = np.cumsum(rng.normal(0, 1, n))
    brown -= lowpass(brown, 0.0008)
    rumble = lowpass(brown, 0.03)
    rumble /= np.abs(rumble).max()
    whine = np.sin(2 * np.pi * (930 + 6 * np.sin(2 * np.pi * 0.3 * t)) * t) * 0.05
    pulse = 1 + 0.15 * np.sin(2 * np.pi * 3.1 * t)                 # thrusters throbbing
    x = (hum / np.abs(hum).max() * 0.7 + rumble * 0.5) * pulse + whine
    return seamless(x)


def write(path, x, peak=0.5):
    x = x / max(1e-6, np.abs(x).max()) * peak
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", type=Path)
    ap.add_argument("--seconds", type=float, default=24.0)
    args = ap.parse_args()
    rng = np.random.default_rng(3)
    args.outdir.mkdir(parents=True, exist_ok=True)
    write(args.outdir / "amb_traffic.wav", traffic(rng, args.seconds))
    write(args.outdir / "amb_wind.wav", wind(rng, args.seconds), 0.35)
    write(args.outdir / "amb_birds.wav", birds(rng, args.seconds), 0.4)
    write(args.outdir / "ship_engine.wav", ship_engine(np.random.default_rng(11), 8.0), 0.8)
    print("wrote ambience to", args.outdir)


if __name__ == "__main__":
    main()
