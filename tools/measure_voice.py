#!/usr/bin/env python3
"""Diagnostic: measure the bundled Voice clips and compare their lengths to the
subdivision intervals they must fit inside.

Prints, for every Resources/Voice/voice_*.wav:
  * format (rate / channels / sample width)
  * raw duration (ms)
  * "audible" duration (ms) after trimming outer silence at the same threshold the
    Swift loader uses (numbers: trimSilence @ 0.02; syllables: compactSyllable trims
    @ 0.03 then hard-caps at maxSeconds) — i.e. what actually plays.
  * peak amplitude.

Then prints the sixteenth-note interval at common tempos (interval = 60 / (BPM*4))
and flags which tokens are LONGER than that interval (they get hard-cut / smear).

Read-only. Run on Windows:  python tools/measure_voice.py
"""

import glob
import os
import wave

import numpy as np

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VOICE_DIR = os.path.join(REPO_ROOT, "Resources", "Voice")

# Mirror the Swift constants (VoiceSampleFactory.swift / RenderPlan.swift).
SWIFT_TRIM_NUMBER = 0.02      # trimSilence threshold for numbers
SWIFT_TRIM_SYLLABLE = 0.03   # compactSyllable trim threshold
SWIFT_SYLLABLE_CAP = 0.12    # compactSyllable maxSeconds hard cap
MIN_SPOKEN_SUBDIV = 0.14     # RenderPlan.minSpokenSubdivisionSeconds (Tier-1 sixteenth threshold)

SYLLABLE_STEMS = {"and", "e", "a", "trip", "let"}


def word_for(stem):
    numbers = {
        "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six",
        "7": "seven", "8": "eight", "9": "nine", "10": "ten", "11": "eleven",
        "12": "twelve", "13": "thirteen", "14": "fourteen", "15": "fifteen",
        "16": "sixteen", "17": "seventeen", "18": "eighteen", "19": "nineteen",
        "20": "twenty", "21": "twenty-one", "22": "twenty-two", "23": "twenty-three",
        "24": "twenty-four", "25": "twenty-five", "26": "twenty-six",
        "27": "twenty-seven", "28": "twenty-eight", "29": "twenty-nine",
        "30": "thirty", "31": "thirty-one", "32": "thirty-two",
    }
    if stem in numbers:
        return numbers[stem]
    return {"e": '"e" (ee)', "a": '"a" (uh)', "and": '"and"',
            "trip": '"trip"', "let": '"let"'}.get(stem, stem)


def read_wav(path):
    with wave.open(path, "rb") as w:
        rate = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        n = w.getnframes()
        raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif sw == 1:
        x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128) / 128.0
    else:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, rate, ch, sw


def trimmed_len_seconds(x, rate, thresh):
    idx = np.where(np.abs(x) >= thresh)[0]
    if len(idx) == 0:
        return 0.0
    return (idx[-1] - idx[0] + 1) / rate


def audible_seconds(stem, x, rate):
    """What the Swift loader actually plays: trim outer silence, and for syllables
    additionally hard-cap at SWIFT_SYLLABLE_CAP."""
    if stem in SYLLABLE_STEMS:
        t = trimmed_len_seconds(x, rate, SWIFT_TRIM_SYLLABLE)
        return min(t, SWIFT_SYLLABLE_CAP)
    return trimmed_len_seconds(x, rate, SWIFT_TRIM_NUMBER)


def main():
    paths = sorted(glob.glob(os.path.join(VOICE_DIR, "voice_*.wav")))
    if not paths:
        print("no clips found in", VOICE_DIR)
        return

    rows = []
    for p in paths:
        stem = os.path.splitext(os.path.basename(p))[0].replace("voice_", "")
        x, rate, ch, sw = read_wav(p)
        raw = len(x) / rate
        aud = audible_seconds(stem, x, rate)
        peak = float(np.max(np.abs(x))) if len(x) else 0.0
        rows.append(dict(stem=stem, rate=rate, ch=ch, sw=sw,
                         raw=raw, aud=aud, peak=peak))

    # ---- table ------------------------------------------------------------
    print(f"Voice clips in {VOICE_DIR}\n")
    print(f"{'file':16s} {'word':22s} {'fmt':16s} {'raw ms':>7s} {'audible ms':>11s} {'peak':>6s}")
    print("-" * 84)

    def sort_key(r):
        return (0, int(r["stem"])) if r["stem"].isdigit() else (1, r["stem"])

    for r in sorted(rows, key=sort_key):
        fmt = f"{r['rate']}Hz {r['ch']}ch {r['sw']*8}b"
        print(f"voice_{r['stem']:10s} {word_for(r['stem']):22s} {fmt:16s} "
              f"{r['raw']*1000:7.0f} {r['aud']*1000:11.0f} {r['peak']:6.2f}")

    numbers = [r for r in rows if r["stem"].isdigit()]
    syllables = [r for r in rows if r["stem"] in SYLLABLE_STEMS]

    def stats(group, key="aud"):
        vals = [r[key] * 1000 for r in group]
        return min(vals), max(vals), sum(vals) / len(vals)

    nmin, nmax, navg = stats(numbers)
    smin, smax, savg = stats(syllables)
    print(f"\nNumbers  (audible ms): min {nmin:.0f}  max {nmax:.0f}  avg {navg:.0f}")
    print(f"Syllables(audible ms): min {smin:.0f}  max {smax:.0f}  avg {savg:.0f}")

    # ---- interval fit -----------------------------------------------------
    print("\nSixteenth-note interval = 60 / (BPM x 4). A token LONGER than the interval")
    print("cannot finish before the next sixteenth onset (it is hard-cut / would smear).\n")
    print(f"{'BPM':>5s} {'16th ms':>8s}   {'#syllables too long':>20s}   {'#numbers too long':>18s}")
    print("-" * 64)
    for bpm in (60, 72, 80, 90, 100, 110, 120, 132, 144, 160, 180, 200):
        interval = 60.0 / (bpm * 4)
        syl_over = sum(1 for r in syllables if r["aud"] > interval)
        num_over = sum(1 for r in numbers if r["aud"] > interval)
        flag = "  <- speak cutoff" if abs(interval - MIN_SPOKEN_SUBDIV) < 0.011 else ""
        print(f"{bpm:5d} {interval*1000:8.0f}   {syl_over:20d}   {num_over:18d}{flag}")

    # ---- eighth-note interval (the degrade tier) --------------------------
    print("\nEighth-note interval = 60 / (BPM x 2) — the interval the beat number and")
    print('"and" get when e/a are clicked (the middle degrade tier).\n')
    print(f"{'BPM':>5s} {'8th ms':>8s}   {'longest syllable fits?':>24s}   {'longest number fits?':>22s}")
    print("-" * 68)
    for bpm in (100, 110, 120, 132, 144, 160, 180, 200, 220):
        interval = 60.0 / (bpm * 2)
        print(f"{bpm:5d} {interval*1000:8.0f}   {str(smax <= interval*1000):>24s}   "
              f"{str(nmax <= interval*1000):>22s}")


if __name__ == "__main__":
    main()
