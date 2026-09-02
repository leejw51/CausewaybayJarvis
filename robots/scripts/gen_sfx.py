#!/usr/bin/env python3
"""Generate 8-bit Jarvis-style chiptune WAV files (square/pulse/noise)."""
from __future__ import annotations

import math
import os
import random
import struct
import wave

RATE = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sfx")


def clamp(v: float, lo: float = -1.0, hi: float = 1.0) -> float:
    return lo if v < lo else hi if v > hi else v


def write_wav(name: str, samples: list[float]) -> None:
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = b"".join(
            struct.pack("<h", int(clamp(s) * 32000)) for s in samples
        )
        w.writeframes(frames)
    print(f"  wrote {path} ({len(samples) / RATE:.2f}s)")


def square(freq: float, t: float, duty: float = 0.5) -> float:
    return 1.0 if (t * freq) % 1.0 < duty else -1.0


def tri(freq: float, t: float) -> float:
    p = (t * freq) % 1.0
    return 4.0 * p - 1.0 if p < 0.5 else 3.0 - 4.0 * p


def noise() -> float:
    return random.uniform(-1.0, 1.0)


def env(t: float, a: float, d: float, s: float, r: float, hold: float) -> float:
    if t < 0:
        return 0.0
    if t < a:
        return t / a if a > 0 else 1.0
    t2 = t - a
    if t2 < d:
        return 1.0 + (s - 1.0) * (t2 / d if d > 0 else 1.0)
    t3 = t2 - d
    if t3 < hold:
        return s
    t4 = t3 - hold
    if t4 < r:
        return s * (1.0 - t4 / r)
    return 0.0


def mix_note(buf: list[float], start: float, freq: float, dur: float, amp: float,
             duty: float = 0.5, kind: str = "pulse") -> None:
    n = int(dur * RATE)
    i0 = int(start * RATE)
    for i in range(n):
        t = i / RATE
        e = env(t, 0.008, 0.04, 0.55, 0.08, max(0.0, dur - 0.128))
        osc = square(freq, t, duty) if kind != "tri" else tri(freq, t)
        # tiny 2nd harmonic for Genesis bite
        osc = osc * 0.82 + square(freq * 2.0, t, 0.25) * 0.18
        idx = i0 + i
        if 0 <= idx < len(buf):
            buf[idx] += osc * e * amp


def clap() -> list[float]:
    dur = 0.42
    n = int(dur * RATE)
    buf = [0.0] * n
    random.seed(7)

    def burst(t0: float, amp: float, length: float) -> None:
        i0 = int(t0 * RATE)
        ln = int(length * RATE)
        prev = 0.0
        for i in range(ln):
            t = i / RATE
            raw = noise()
            hp = raw - prev
            prev = raw
            e = math.exp(-t * 38.0)
            # layered: noise + a short 1.8kHz click
            click = square(1800, t, 0.2) * math.exp(-t * 90.0)
            buf[i0 + i] += (hp * 0.72 + click * 0.35) * e * amp

    burst(0.00, 1.05, 0.09)
    burst(0.11, 0.82, 0.12)
    return buf


def sting() -> list[float]:
    """Rising 'systems online' fanfare — original 8-bit, not a movie cue."""
    dur = 1.85
    buf = [0.0] * int(dur * RATE)
    # C major power-on ladder
    melody = [
        (0.00, 261.63, 0.12, 0.28),   # C4
        (0.12, 329.63, 0.12, 0.30),   # E4
        (0.24, 392.00, 0.12, 0.32),   # G4
        (0.36, 523.25, 0.14, 0.36),   # C5
        (0.50, 659.25, 0.16, 0.38),   # E5
        (0.66, 783.99, 0.22, 0.42),   # G5
        (0.90, 1046.50, 0.55, 0.50),  # C6 hold
    ]
    for t0, f, d, a in melody:
        mix_note(buf, t0, f, d, a, duty=0.25)
        mix_note(buf, t0, f * 0.5, d, a * 0.22, duty=0.5, kind="tri")
    # shimmer delay
    delay = int(0.08 * RATE)
    for i in range(delay, len(buf)):
        buf[i] += buf[i - delay] * 0.18
    return buf


def online() -> list[float]:
    dur = 0.38
    buf = [0.0] * int(dur * RATE)
    mix_note(buf, 0.00, 523.25, 0.10, 0.34, duty=0.25)
    mix_note(buf, 0.08, 783.99, 0.12, 0.40, duty=0.25)
    mix_note(buf, 0.18, 1046.50, 0.18, 0.46, duty=0.125)
    return buf


def click() -> list[float]:
    n = int(0.07 * RATE)
    buf = [0.0] * n
    for i in range(n):
        t = i / RATE
        e = math.exp(-t * 70.0)
        buf[i] = square(1200, t, 0.2) * e * 0.45 + square(2400, t, 0.15) * e * 0.2
    return buf


def blip() -> list[float]:
    n = int(0.12 * RATE)
    buf = [0.0] * n
    mix_note(buf, 0.00, 880.00, 0.05, 0.28, duty=0.25)
    mix_note(buf, 0.04, 1320.00, 0.07, 0.22, duty=0.25)
    return buf


def alert() -> list[float]:
    n = int(0.28 * RATE)
    buf = [0.0] * n
    mix_note(buf, 0.00, 440.00, 0.08, 0.36, duty=0.5)
    mix_note(buf, 0.10, 349.23, 0.12, 0.36, duty=0.5)
    return buf


def scan() -> list[float]:
    n = int(0.55 * RATE)
    buf = [0.0] * n
    for i in range(n):
        t = i / RATE
        freq = 400 + 1600 * (t / 0.55)
        e = env(t, 0.02, 0.05, 0.4, 0.12, 0.36)
        buf[i] = square(freq, t, 0.125) * e * 0.28
    return buf


def toggle() -> list[float]:
    n = int(0.18 * RATE)
    buf = [0.0] * n
    mix_note(buf, 0.00, 660.00, 0.07, 0.28, duty=0.25)
    mix_note(buf, 0.07, 990.00, 0.09, 0.32, duty=0.25)
    return buf


def spark() -> list[float]:
    n = int(0.16 * RATE)
    buf = [0.0] * n
    random.seed(3)
    for i in range(n):
        t = i / RATE
        e = math.exp(-t * 28.0)
        buf[i] = noise() * e * 0.35 + square(2100 + 800 * math.sin(t * 80), t, 0.2) * e * 0.25
    return buf


def type_tick() -> list[float]:
    n = int(0.04 * RATE)
    buf = [0.0] * n
    for i in range(n):
        t = i / RATE
        buf[i] = square(1900, t, 0.5) * math.exp(-t * 120.0) * 0.22
    return buf


def whoosh() -> list[float]:
    n = int(0.32 * RATE)
    buf = [0.0] * n
    random.seed(11)
    for i in range(n):
        t = i / RATE
        freq = 200 + 1800 * (t / 0.32)
        e = env(t, 0.01, 0.04, 0.35, 0.1, 0.17)
        buf[i] = (square(freq, t, 0.2) * 0.55 + noise() * 0.2) * e * 0.3
    return buf


def hum() -> list[float]:
    """CRT / workshop drone loop."""
    dur = 2.0
    n = int(dur * RATE)
    buf = [0.0] * n
    random.seed(42)
    for i in range(n):
        t = i / RATE
        drone = tri(55.0, t) * 0.22 + square(110.0, t, 0.5) * 0.05
        shimmer = square(880.0, t, 0.125) * (0.03 + 0.02 * math.sin(t * math.pi * 2))
        hiss = noise() * 0.018
        # fade edges for seamless loop
        fade = 1.0
        edge = 0.04
        if t < edge:
            fade = t / edge
        elif t > dur - edge:
            fade = (dur - t) / edge
        buf[i] = (drone + shimmer + hiss) * fade * 0.85
    return buf


def crt_on() -> list[float]:
    n = int(0.55 * RATE)
    buf = [0.0] * n
    random.seed(1)
    for i in range(n):
        t = i / RATE
        if t < 0.06:
            buf[i] = noise() * (1.0 - t / 0.06) * 0.5
        else:
            t2 = t - 0.06
            freq = 80 + 420 * min(1.0, t2 / 0.25)
            e = min(1.0, t2 / 0.04) * (1.0 if t2 < 0.28 else max(0.0, 1.0 - (t2 - 0.28) / 0.2))
            buf[i] = tri(freq, t2) * e * 0.4 + square(freq * 2, t2, 0.5) * e * 0.08
    return buf


def main() -> None:
    random.seed(0)
    print("generating 8-bit sfx...")
    write_wav("clap.wav", clap())
    write_wav("sting.wav", sting())
    write_wav("online.wav", online())
    write_wav("click.wav", click())
    write_wav("blip.wav", blip())
    write_wav("alert.wav", alert())
    write_wav("scan.wav", scan())
    write_wav("toggle.wav", toggle())
    write_wav("spark.wav", spark())
    write_wav("type.wav", type_tick())
    write_wav("whoosh.wav", whoosh())
    write_wav("hum.wav", hum())
    write_wav("crt_on.wav", crt_on())
    print("done.")


if __name__ == "__main__":
    main()
