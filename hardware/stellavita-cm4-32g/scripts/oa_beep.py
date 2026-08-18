#!/usr/bin/python
# OpenAstro jingle on the StellaVita piezo (BCM GPIO 12)
# usage: oa_beep.py [gpio]
import RPi.GPIO as GPIO
import time
import sys

PIN = int(sys.argv[1]) if len(sys.argv) > 1 else 12

# (freq_hz, duration_s) — 0 freq = rest
# "O-pen-As-tro!" rising motif, then a little starlight trill
TUNE = [
    (523, 0.12), (0, 0.03),   # C5  O-
    (659, 0.12), (0, 0.03),   # E5  pen
    (784, 0.12), (0, 0.03),   # G5  As-
    (1047, 0.22), (0, 0.08),  # C6  tro!
    (1319, 0.07), (1568, 0.07), (2093, 0.18),  # E6 G6 C7 sparkle
]

def tone(hz, dur):
    if hz == 0:
        time.sleep(dur)
        return
    half = 1.0 / (2 * hz)
    cycles = int(dur * hz)
    for _ in range(cycles):
        GPIO.output(PIN, GPIO.LOW)
        time.sleep(half)
        GPIO.output(PIN, GPIO.HIGH)
        time.sleep(half)

GPIO.setwarnings(False)
GPIO.setmode(GPIO.BCM)
GPIO.setup(PIN, GPIO.OUT, initial=GPIO.HIGH)
for hz, dur in TUNE:
    tone(hz, dur)
GPIO.cleanup()
