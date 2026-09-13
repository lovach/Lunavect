#!/usr/bin/env python3
"""Original additive synthesis: a brief rising fifth with a soft glass timbre.

Render the approved Lunavect Lift cue without samples or external dependencies.
"""
from pathlib import Path
import math
import struct
import wave
import json

RATE = 48000
DURATION = .46
TAU = 2 * math.pi
ROOT = Path(__file__).resolve().parents[1]

def voice(t, pitch, amplitude, decay):
    if t <= 0:
        return 0.0
    attack = math.sin(min(1.0, t / .006) * math.pi / 2) ** 2
    fundamental = math.sin(TAU * pitch * t) * math.exp(-t / decay)
    warmth = .12 * math.sin(TAU * pitch * 2 * t + .18) * math.exp(-t / .025)
    glass = .09 * math.sin(TAU * pitch * 2.71 * t + .32) * math.exp(-t / .031)
    shimmer = .014 * math.sin(TAU * pitch * 4.83 * t) * math.exp(-t / .015)
    return amplitude * attack * (fundamental + warmth + glass + shimmer)

def dry(t):
    return voice(t, 698.456, .81, .051) + voice(t - .070, 1046.502, .69, .065)

frames = []
for i in range(round(RATE * DURATION)):
    t = i / RATE
    fade = math.sin(min(1.0, (DURATION - t) / .045) * math.pi / 2) ** 2
    # Very small reflections lend space without a long reverb tail.
    l = (dry(t) + .052 * dry(t - .017) + .024 * dry(t - .041)) * fade
    r = (dry(t) + .052 * dry(t - .022) + .024 * dry(t - .047)) * fade
    frames.append((l, r))

active = frames[:round(.3 * RATE)]
rms = math.sqrt(sum(l*l + r*r for l,r in active) / (len(active)*2))
peak = max(abs(v) for pair in frames for v in pair)
scale = min(10 ** (-23 / 20) / rms, .40 / peak)
frames = [(l*scale, r*scale) for l,r in frames]
assert max(abs(v) for pair in frames for v in pair) <= .40001
assert all(abs(v) < .00001 for v in frames[0] + frames[-1])
output = ROOT / 'Sources/Weekleft/Resources/lunavect-complete.wav'
with wave.open(str(output), 'wb') as out:
    out.setnchannels(2)
    out.setsampwidth(2)
    out.setframerate(RATE)
    out.writeframes(b''.join(struct.pack('<hh', round(l*32767), round(r*32767)) for l,r in frames))
report = {'seconds': DURATION, 'rate': RATE, 'channels': 2,
    'peak_dbfs': round(20*math.log10(peak*scale), 2),
    'first_300ms_rms_dbfs': round(20*math.log10(rms*scale), 2),
    'source_audio': 'None; synthesized from oscillators'}
print(output)
print(json.dumps(report, indent=2))
