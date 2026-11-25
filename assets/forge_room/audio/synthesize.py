#!/usr/bin/env python3
"""Generate the forge room's original mono positional audio assets."""

import math
import random
import struct
import wave
from pathlib import Path

DIRECTORY = Path(__file__).resolve().parent
RATE = 24_000
TAU = math.tau


def save(name, samples):
    samples = [round(max(-1, min(1, sample)) * 32767) for sample in samples]
    with wave.open(str(DIRECTORY / f"{name}.wav"), "wb") as audio:
        audio.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        audio.writeframes(struct.pack(f"<{len(samples)}h", *samples))


def impact(duration, modes, seed, noise_strength):
    rng = random.Random(seed)
    previous = 0.0
    for index in range(round(duration * RATE)):
        t = index / RATE
        previous += 0.3 * (rng.uniform(-1, 1) - previous)
        signal = sum(
            gain * math.sin(TAU * frequency * t) * math.exp(-decay * t)
            for frequency, gain, decay in modes
        )
        attack = min(t * 1200, 1)
        release = min((duration - t) * 100, 1)
        yield (signal + noise_strength * previous * math.exp(-135 * t)) * attack * release


def ambience(duration, seed, fire):
    rng = random.Random(seed)
    fast = slow = crackle = 0.0
    count = round(duration * RATE)
    overlap = RATE // 12
    samples = []
    for index in range(count + overlap):
        t = index / RATE
        raw = rng.uniform(-1, 1)
        fast += 0.21 * (raw - fast)
        slow += 0.016 * (raw - slow)
        if fire:
            crackle *= 0.92
            if rng.random() < 0.0025:
                crackle += rng.uniform(0.12, 0.62)
            swell = 0.78 + 0.14 * math.sin(TAU * 1.7 * t) + 0.08 * math.sin(TAU * 3.2 * t)
            samples.append(swell * (1.15 * slow + 0.30 * fast) + crackle * raw)
        else:
            bubble = 0.80 + 0.12 * math.sin(TAU * 9.2 * t) + 0.08 * math.sin(TAU * 16.3 * t)
            samples.append(bubble * (0.28 * (raw - fast) + 0.56 * (fast - slow)))
    for index in range(overlap):
        blend = index / overlap
        samples[index] = samples[count + index] * (1 - blend) + samples[index] * blend
    return samples[:count]


def main():
    save("hearth", ambience(3.0, 30, True))
    save("quench_hiss", ambience(2.0, 42, False))
    save("hammer_ping", impact(0.48, [(780, 0.21, 10), (1562, 0.26, 13),
                                    (2339, 0.14, 23), (3191, 0.06, 42)], 11, 0.36))
    save("hammer_thunk", impact(0.22, [(143, 0.42, 30), (287, 0.21, 56),
                                     (529, 0.13, 78), (1183, 0.06, 96)], 12, 0.60))


if __name__ == "__main__":
    main()
