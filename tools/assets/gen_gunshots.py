#!/usr/bin/env python3
"""Synthesise the weapon sounds (WAV, 44.1 kHz mono): the players' firearms,
which must read as real guns on a city street, and the robots' phaser.
Pure numpy, no source recordings.

A shot is layered the way it is heard outdoors:
  crack   muzzle blast transient: broadband noise, sub-millisecond attack,
          ~10 ms decay, bright
  body    the low "boom": low-passed noise plus a falling sine thump
  mech    a short metallic click of the action (slide / bolt)
  slap    early reflections off the facades across the street (15-90 ms)
  tail    diffuse decaying street reverb, darker than the shot
then gently saturated for punch and normalised.

    tools/.venv/bin/python tools/assets/gen_gunshots.py --out godot/assets/audio
"""
import argparse
import wave
from pathlib import Path

import numpy as np

SR = 44100


def band(x, lo, hi, slope=1.0):
    """Frequency-domain band-pass with soft edges (lo/hi in Hz, None = open)."""
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X = np.fft.rfft(x)
    g = np.ones_like(f)
    if lo:
        g *= 1 / (1 + (lo / np.maximum(f, 1)) ** (2 * slope))
    if hi:
        g *= 1 / (1 + (f / hi) ** (2 * slope))
    return np.fft.irfft(X * g, len(x))


def env(t, attack, decay):
    return (1 - np.exp(-t / max(attack, 1e-5))) * np.exp(-t / decay)


def shot(rng, p, seconds):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    # crack: bright broadband transient
    crack = band(rng.normal(0, 1, n), 700, 9000) * env(t, 0.0002, p["crack_decay"])
    out += p["crack"] * crack / np.abs(crack).max()
    # body: low boom
    body = band(rng.normal(0, 1, n), 40, p["body_hi"]) * env(t, 0.001, p["body_decay"])
    out += p["body"] * body / np.abs(body).max()
    f0, f1 = p["thump_hz"]
    freq = f1 + (f0 - f1) * np.exp(-t / 0.03)
    thump = np.sin(2 * np.pi * np.cumsum(freq) / SR) * env(t, 0.001, p["thump_decay"])
    out += p["thump"] * thump
    # mechanical click of the action
    if p["mech"]:
        d = int(rng.uniform(*p["mech_at"]) * SR)
        click = band(rng.normal(0, 1, 900), 2500, 8000) * np.exp(-np.arange(900) / SR / 0.003)
        for hz in (3100, 4700, 6900):                       # small metal parts ringing
            click += 0.4 * np.sin(2 * np.pi * hz * np.arange(900) / SR) * np.exp(-np.arange(900) / SR / 0.006)
        out[d:d + 900] += p["mech"] * click / np.abs(click).max()
    dry = out.copy()
    # early reflections off the buildings
    for _ in range(p["slaps"]):
        d = int(rng.uniform(0.015, 0.09) * SR)
        g = rng.uniform(0.15, 0.4)
        refl = band(dry, 80, rng.uniform(2500, 5000))
        out[d:] += g * refl[:n - d]
    # diffuse street reverb
    tail = band(rng.normal(0, 1, n), 150, p["tail_hi"]) * env(np.maximum(t - 0.02, 0), 0.03, p["tail_decay"])
    tail[t < 0.02] = 0
    out += p["tail"] * tail / np.abs(tail).max()
    out = np.tanh(out * p["drive"]) / np.tanh(p["drive"])  # saturation for punch
    fade = np.minimum(1, (n - np.arange(n)) / (0.05 * SR))
    out *= fade
    return out / np.abs(out).max() * 0.89


GUNS = {
    # pistol: sharp crack, moderate boom, slide click, long-ish street echo
    "gun_pistol": dict(crack=1.0, crack_decay=0.010, body=0.7, body_hi=500, body_decay=0.05,
                       thump=0.6, thump_hz=(140, 55), thump_decay=0.06, mech=0.12, mech_at=(0.035, 0.05),
                       slaps=5, tail=0.22, tail_hi=1800, tail_decay=0.35, drive=2.2, seconds=1.4),
    # rifle (machine gun): harder and brighter, tighter tail so bursts don't smear
    "gun_rifle": dict(crack=1.0, crack_decay=0.008, body=0.85, body_hi=650, body_decay=0.04,
                      thump=0.7, thump_hz=(170, 60), thump_decay=0.05, mech=0.08, mech_at=(0.025, 0.035),
                      slaps=4, tail=0.18, tail_hi=2200, tail_decay=0.22, drive=2.8, seconds=0.9),
    # .38 revolver: deeper and rounder than the pistol, no slide click
    "gun_revolver": dict(crack=0.9, crack_decay=0.012, body=0.85, body_hi=420, body_decay=0.07,
                         thump=0.8, thump_hz=(120, 45), thump_decay=0.08, mech=0.0, mech_at=(0.03, 0.04),
                         slaps=5, tail=0.25, tail_hi=1500, tail_decay=0.45, drive=2.4, seconds=1.6),
    # 12-gauge: a heavy boom, long rolling echo down the street
    "gun_shotgun": dict(crack=0.8, crack_decay=0.016, body=1.0, body_hi=380, body_decay=0.12,
                        thump=1.0, thump_hz=(95, 35), thump_decay=0.13, mech=0.0, mech_at=(0.03, 0.04),
                        slaps=6, tail=0.32, tail_hi=1300, tail_decay=0.7, drive=3.0, seconds=2.0),
}


def phaser(rng, seconds=1.1):
    """Robot energy weapon: menacing rather than sci-fi cute. A short rising
    charge whine, then a heavy distorted discharge - sub-bass punch, a growling
    detuned low saw, electric sizzle and crackle - and a dark street echo."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    fire = 0.09                                           # charge time before the discharge
    out = np.zeros(n)
    # charge: whine sweeping up, swelling into the shot
    ch = t < fire
    f_ch = 300 + 2600 * (t / fire) ** 2
    whine = np.sin(2 * np.pi * np.cumsum(f_ch) / SR) * (t / fire) ** 2
    out[ch] += 0.35 * whine[ch]
    td = np.maximum(t - fire, 0)
    on = t >= fire
    # sub-bass punch
    f_sub = 38 + 70 * np.exp(-td / 0.04)
    out += 1.0 * on * np.sin(2 * np.pi * np.cumsum(f_sub * on) / SR) * np.exp(-td / 0.18)
    # growl: detuned low saws, pitch dropping, heavily driven
    growl = np.zeros(n)
    f_g = rng.uniform(95, 115) * (1 - 0.35 * (1 - np.exp(-td / 0.25)))
    for det in (0.0, 0.021, -0.017, 1.003):              # the last adds an octave
        ph = np.cumsum(f_g * (1 + det) * (2 if det > 1 else 1)) / SR
        growl += 2 * (ph % 1.0) - 1
    growl *= 0.7 + 0.3 * np.sin(2 * np.pi * rng.uniform(22, 30) * t)     # rough tremolo
    out += 0.55 * on * np.tanh(2.5 * growl) * np.exp(-td / 0.3)
    # electric sizzle and crackle
    sizzle = band(rng.normal(0, 1, n), 2500, 10000) * np.exp(-td / 0.12) * on
    crackle = (rng.random(n) < 0.004) * rng.normal(0, 1, n) * np.exp(-td / 0.2) * on * 6
    out += 0.3 * sizzle + band(crackle, 1500, 8000)
    blast = band(rng.normal(0, 1, n), 200, 6000) * np.exp(-td / 0.02) * on
    out += 0.8 * blast
    out = np.tanh(out * 1.8)
    # dark echo off the facades
    for d_s, g in ((0.07, 0.35), (0.16, 0.22), (0.29, 0.12)):
        d = int(d_s * SR)
        out[d:] += g * band(out, 60, 1800)[:n - d]
    fade = np.minimum(1, (n - np.arange(n)) / (0.15 * SR))
    out = band(out * fade, 30, 12000)
    return out / np.abs(out).max() * 0.9


def write(path, x):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype("<i2").tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--variants", type=int, default=3)
    args = ap.parse_args()
    for name, p in GUNS.items():
        for v in range(args.variants):
            rng = np.random.default_rng(sum(map(ord, name)) * 10 + v)
            write(args.out / f"{name}_{v:03d}.wav", shot(rng, p, p["seconds"]))
            print(args.out / f"{name}_{v:03d}.wav")
    for v in range(args.variants):
        write(args.out / f"robot_phaser_{v:03d}.wav", phaser(np.random.default_rng(900 + v)))
        print(args.out / f"robot_phaser_{v:03d}.wav")


if __name__ == "__main__":
    main()
