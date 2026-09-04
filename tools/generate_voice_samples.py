#!/usr/bin/env python3
"""Generate the bundled Voice-mode audio samples for the Metronome app.

The metronome's Voice sound speaks the count ("one, two, e, and, a, trip, let").
Historically these were synthesized *live on device* with AVSpeechSynthesizer, which is
robotic, varies by device, and is too long/laggy to land cleanly on fast subdivisions.
Instead we pre-generate short, trimmed, normalized clips here — once, off-device — and
bundle them as app resources (see Sources/Metronome/Engine/VoiceSampleFactory.swift, which
loads them at Voice-mode init and schedules them sample-accurately, exactly like a click).

Voice: en_US-ljspeech-high (Piper).
  * Dataset:  LJ Speech (https://keithito.com/LJ-Speech-Dataset/) — PUBLIC DOMAIN.
  * Training: Bryce Beattie (https://brycebeattie.com/files/tts/).
  * License:  public domain — commercial redistribution of the generated audio is allowed;
              no attribution is legally required (we credit it anyway in the app's About).

Usage (Windows, Python 3.9+):
    pip install piper-tts
    # download en_US-ljspeech-high.onnx (+ .onnx.json) from
    #   https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_US/ljspeech/high
    python tools/generate_voice_samples.py --model C:/path/to/en_US-ljspeech-high.onnx

Outputs 37 mono 16-bit PCM WAVs at 22.05 kHz to Resources/Voice/:
    voice_1.wav … voice_32.wav   (spoken "one" … "thirty-two"; beat numbers)
    voice_and.wav voice_e.wav voice_a.wav voice_trip.wav voice_let.wav   (subdivision syllables)

The clips are deliberately short and punchy. The Swift side additionally trims to the
onset and hard-caps syllable length, so timing never depends on the synthesizer.
"""

import argparse
import os
import sys
import wave

import numpy as np

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO_ROOT, "Resources", "Voice")

# Beat numbers 1..32 (TimeSignature.numeratorRange.upperBound == 32). Filename is the
# numeral (voice_<n>.wav); the *audio* speaks the English word.
NUMBER_WORDS = [
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
    "eighteen", "nineteen", "twenty", "twenty one", "twenty two", "twenty three",
    "twenty four", "twenty five", "twenty six", "twenty seven", "twenty eight",
    "twenty nine", "thirty", "thirty one", "thirty two",
]

# Subdivision syllables. Key == VoiceSyllable.spokenText (the Swift filename stem,
# voice_<key>.wav); value == the text handed to the synthesizer to get the *counted*
# pronunciation ("e" is counted "ee" /iː/, "a" is counted "uh" /ʌ/).
SYLLABLES = {
    "and": "and",
    "e": "ee",
    "a": "uh",
    "trip": "trip",
    "let": "let",
}


def make_syn_config(length_scale):
    """Build a Piper SynthesisConfig if supported, tolerating API differences."""
    try:
        from piper import SynthesisConfig
    except Exception:
        return None
    for kwargs in ({"length_scale": length_scale, "normalize_audio": False},
                   {"length_scale": length_scale},
                   {}):
        try:
            return SynthesisConfig(**kwargs)
        except TypeError:
            continue
    return None


def synth(voice, text, length_scale):
    """Synthesize `text` to a float32 mono array at the model's sample rate."""
    cfg = make_syn_config(length_scale)
    chunks = list(voice.synthesize(text, cfg) if cfg is not None else voice.synthesize(text))
    if not chunks:
        return None, None
    rate = chunks[0].sample_rate
    audio = np.concatenate([np.asarray(c.audio_float_array, dtype=np.float32) for c in chunks])
    return audio, rate


def process(x, rate, peak=0.9, trim_thresh=0.008):
    """Trim outer silence, normalize to `peak`, and apply short anti-click fades.

    Kept intentionally light: the Swift loader re-trims to the onset (so the token lands
    on the beat frame) and hard-caps syllable length, so this only makes the committed
    files small, quiet-air-free, and consistent in loudness."""
    if x is None or len(x) == 0:
        return None
    idx = np.where(np.abs(x) >= trim_thresh)[0]
    if len(idx) == 0:
        return None
    x = x[idx[0]:idx[-1] + 1].astype(np.float32).copy()
    peak_now = float(np.max(np.abs(x)))
    if peak_now > 0:
        x *= (peak / peak_now)
    # ~1 ms fade-in, ~6 ms fade-out so neither boundary clicks.
    fi = min(len(x), max(1, int(0.001 * rate)))
    x[:fi] *= np.linspace(0.0, 1.0, fi, dtype=np.float32)
    fo = min(len(x), max(1, int(0.006 * rate)))
    x[-fo:] *= np.linspace(1.0, 0.0, fo, dtype=np.float32)
    return np.clip(x, -1.0, 1.0)


def write_wav(path, x, rate):
    pcm = (x * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())


def main():
    ap = argparse.ArgumentParser()
    default_model = os.path.join(os.environ.get("TEMP", "/tmp"),
                                 "piper-voice", "en_US-ljspeech-high.onnx")
    ap.add_argument("--model", default=default_model,
                    help="Path to the Piper .onnx model (config .onnx.json must sit beside it).")
    ap.add_argument("--number-length-scale", type=float, default=1.0)
    ap.add_argument("--syllable-length-scale", type=float, default=0.85)
    args = ap.parse_args()

    if not os.path.isfile(args.model):
        sys.exit(f"model not found: {args.model}")

    from piper import PiperVoice
    voice = PiperVoice.load(args.model)

    os.makedirs(OUT_DIR, exist_ok=True)
    summary = []

    for n, word in enumerate(NUMBER_WORDS, start=1):
        audio, rate = synth(voice, word, args.number_length_scale)
        x = process(audio, rate)
        if x is None:
            sys.exit(f"empty synthesis for number {n} ({word!r})")
        path = os.path.join(OUT_DIR, f"voice_{n}.wav")
        write_wav(path, x, rate)
        summary.append((f"voice_{n}.wav", word, len(x) / rate))

    for stem, text in SYLLABLES.items():
        audio, rate = synth(voice, text, args.syllable_length_scale)
        x = process(audio, rate)
        if x is None:
            sys.exit(f"empty synthesis for syllable {stem!r} ({text!r})")
        path = os.path.join(OUT_DIR, f"voice_{stem}.wav")
        write_wav(path, x, rate)
        summary.append((f"voice_{stem}.wav", text, len(x) / rate))

    print(f"Wrote {len(summary)} clips to {OUT_DIR} @ {rate} Hz, mono 16-bit:")
    for name, text, dur in summary:
        print(f"  {name:16s} <- {text!r:20s} {dur*1000:6.0f} ms")


if __name__ == "__main__":
    main()
