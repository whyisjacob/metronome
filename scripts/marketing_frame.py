#!/usr/bin/env python3
"""Composite one raw iOS screenshot into a styled App Store *marketing* image.

Cross-platform (pure Pillow): the SAME script runs on the macOS CI runner
(`.github/workflows/screenshots.yml`) and locally on Windows, so the result can be
validated without a Mac. It NEVER fabricates UI — it only frames the genuine capture
with an on-brand background (near-black + a subtle gold glow, matching the app icon's
gold pendulum) and a short gold headline.

Output is EXACTLY --width x --height, RGB with NO alpha channel — App Store requires
opaque screenshots at the exact device pixel size. Any failure exits non-zero so CI
fails loudly rather than emitting a wrong-size or unstyled image.
"""
import argparse
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

GOLD = (255, 194, 56)     # #FFC238 — Theme.accentNormal, the app's pendulum gold
BG_TOP = (20, 24, 33)     # #141821
BG_BOTTOM = (5, 6, 10)    # #05060A
GLOW = (58, 44, 12)       # #3A2C0C — dark gold, screen-blended for a faint warm centre


def vertical_gradient(w, h, top, bottom):
    """Fast vertical gradient: build a 1px-wide column, then stretch to width."""
    col = Image.new("RGB", (1, h))
    px = col.load()
    denom = max(1, h - 1)
    for y in range(h):
        t = y / denom
        px[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * t),
            round(top[1] + (bottom[1] - top[1]) * t),
            round(top[2] + (bottom[2] - top[2]) * t),
        )
    return col.resize((w, h))


def build_background(w, h):
    grad = vertical_gradient(w, h, BG_TOP, BG_BOTTOM)
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy = w // 2, int(h * 0.42)
    rx, ry = int(w * 0.55), int(h * 0.30)
    gd.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=GLOW)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=w * 0.12))
    return ImageChops.screen(grad, glow)


def resolve_font_path(candidates):
    """First font path that Pillow can actually open (not merely one that exists on disk).

    Trying to LOAD each rules out variable/collection fonts that a given Pillow can't handle,
    so the CI runner falls through to a face it can render instead of failing outright.
    """
    for path in candidates:
        try:
            ImageFont.truetype(path, size=32, index=0)
            return path
        except Exception:  # noqa: BLE001 — a bad candidate just means try the next one
            continue
    print("::error::no usable caption font among: " + ", ".join(candidates), file=sys.stderr)
    sys.exit(1)


def load_font(path, size):
    # index=0 covers .ttc collections (e.g. Helvetica.ttc) as well as plain .ttf/.otf.
    return ImageFont.truetype(path, size=size, index=0)


def fit_font(draw, path, lines, max_width, stroke, start=92, minimum=56, step=4):
    """Largest size (<= start) at which every line fits within max_width."""
    size = start
    while size > minimum:
        font = load_font(path, size)
        widest = max(draw.textlength(ln, font=font) for ln in lines) + 2 * stroke
        if widest <= max_width:
            return font
        size -= step
    return load_font(path, minimum)


def compose(raw_path, out_path, w, h, caption, font_path):
    bg = build_background(w, h)
    draw = ImageDraw.Draw(bg)

    # ---- device screenshot: scale to 72% width, round the corners ----
    dev = Image.open(raw_path).convert("RGB")
    devw = int(w * 0.72)
    devh = round(devw * dev.height / dev.width)
    dev = dev.resize((devw, devh), Image.LANCZOS)
    radius = round(96 * devw / w)
    mask = Image.new("L", (devw, devh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, devw - 1, devh - 1], radius=radius, fill=255)

    dx = (w - devw) // 2
    dtop = int(h * 0.19)

    # ---- soft drop shadow: blurred rounded silhouette, offset slightly down ----
    pad = 60
    shadow = Image.new("RGBA", (devw + 2 * pad, devh + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [pad, pad, pad + devw - 1, pad + devh - 1], radius=radius, fill=(0, 0, 0, 150)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    bg.paste(shadow, (dx - pad, dtop - pad + 22), shadow)

    # device over its shadow
    bg.paste(dev, (dx, dtop), mask)

    # ---- gold headline, centred, auto-sized to fit, faux-bold via stroke ----
    lines = [ln for ln in caption.replace("\\n", "\n").split("\n")]
    stroke = 3
    font = fit_font(draw, font_path, lines, w - 160, stroke)
    text = "\n".join(lines)
    ctop = int(h * 0.05)
    bbox = draw.multiline_textbbox((0, 0), text, font=font, align="center",
                                   spacing=16, stroke_width=stroke)
    tx = (w - (bbox[2] - bbox[0])) // 2 - bbox[0]
    ty = ctop - bbox[1]
    draw.multiline_text((tx, ty), text, font=font, fill=GOLD, align="center",
                        spacing=16, stroke_width=stroke, stroke_fill=GOLD)

    # ---- save EXACT size, opaque (no alpha) ----
    out = bg.convert("RGB")
    if out.size != (w, h):
        print(f"::error::composited size {out.size} != ({w}, {h})", file=sys.stderr)
        sys.exit(1)
    out.save(out_path, "PNG")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--caption", required=True, help="headline; use \\n for a line break")
    ap.add_argument("--fonts", required=True,
                    help="comma-separated candidate font paths; first Pillow can open wins")
    args = ap.parse_args()
    font_path = resolve_font_path([p.strip() for p in args.fonts.split(",") if p.strip()])
    compose(args.raw, args.out, args.width, args.height, args.caption, font_path)


if __name__ == "__main__":
    main()
