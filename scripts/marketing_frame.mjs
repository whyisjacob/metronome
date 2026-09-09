#!/usr/bin/env node
// Composite ONE raw iOS screenshot into a styled App Store *marketing* image.
//
// Rendering is done by HEADLESS CHROMIUM (Puppeteer), not by drawing primitives: the layout,
// typography, gradients and shadows are plain HTML/CSS, screenshotted at an EXACT device viewport.
// This replaces the old Pillow/PIL pipeline, which could not do real type, gradients or shadows.
//
//  * The raw capture is embedded as a base64 data: URI, so the page is self-contained.
//  * The headline uses licensed Adobe Fonts (Typekit kit mzx3hcs — Bebas Neue). We WAIT for the
//    webfont and VERIFY it actually painted (width test vs a fallback); if the network silently
//    fell back to a system face we FAIL LOUDLY instead of shipping wrong-looking type.
//  * The viewport is set to EXACTLY --width x --height at deviceScaleFactor 1, and the screenshot is
//    clipped to that rect, so the PNG is natively that size with NO resampling. We re-read the PNG
//    header and abort on any size mismatch (the CI workflow also gates every PNG with `sips`).
//  * Puppeteer emits an opaque RGB PNG (no alpha) here because the page background is opaque — which
//    is what App Store Connect wants. (Verified: colorType 2.)
//
// Any failure exits non-zero so CI fails loudly rather than emitting a wrong-size or unstyled image.
//
// Usage:
//   node marketing_frame.mjs --raw RAW.png --out OUT.png --width 1284 --height 2778 \
//        --caption $'Line one\nLine two'
//
// The design is defined as RATIOS of the canvas width/height, so the 6.5" (1284x2778) and
// 6.9" (1320x2868) sets are proportionally identical and read as one set.

import puppeteer from 'puppeteer';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// ── Adobe Fonts (Typekit) ──────────────────────────────────────────────────────────────────────
const TYPEKIT_CSS = 'https://use.typekit.net/mzx3hcs.css';
const HEADLINE_FAMILY = 'bebas-neue-v14-deprecated'; // Bebas Neue — tall condensed display, all-caps
const HEADLINE_WEIGHT = 400;                          // Bebas Neue ships a single weight

// ── Palette ─────────────────────────────────────────────────────────────────────────────────────
const BG = '#0A0A0C';        // near-black canvas
const GOLD = '#D8A34A';      // warm gold, matches the app icon's pendulum
const HEADLINE_COLOR = '#FFFFFF';

// ── Layout ratios (fraction of canvas W or H) ───────────────────────────────────────────────────
const R = {
  side:        0.086,  // side margin (>=100px @1284 -> 110px)
  headerH:     0.225,  // headline band = top ~22% of canvas
  headerPadB:  0.030,  // bottom padding inside the headline band (breathing room above device)
  font:        0.104,  // headline font-size (~134px @1284) — sized so the longest line fits
  lineHeight:  0.94,   // tight leading
  deviceTop:   0.250,  // top edge of the device (fixed -> consistent across all five)
  deviceW:     0.820,  // device width; height follows (raw shares the canvas aspect) -> bleeds off bottom
  radius:      0.0436, // ~56px @1284 rounded corners
  glowCY:      0.405,  // radial-glow centre (behind upper device)
  glowW:       1.150,
  glowH:       0.660,
  ruleW:       0.070,  // optional gold accent rule width
  ruleGap:     0.020,  // gap between headline and rule
};
const LETTER_SPACING = '0.006em';
const SHOW_RULE = process.env.MKT_RULE !== '0'; // short gold underline accent (on; set MKT_RULE=0 to disable)

function parseArgs(argv) {
  const a = {};
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k.startsWith('--')) a[k.slice(2)] = argv[++i];
  }
  for (const req of ['raw', 'out', 'width', 'height', 'caption']) {
    if (a[req] == null) { console.error(`::error::missing --${req}`); process.exit(2); }
  }
  a.width = parseInt(a.width, 10);
  a.height = parseInt(a.height, 10);
  if (!Number.isInteger(a.width) || !Number.isInteger(a.height)) {
    console.error('::error::--width/--height must be integers'); process.exit(2);
  }
  return a;
}

const escapeHtml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function buildHtml({ W, H, dataUri, lines }) {
  const px = (r) => Math.round(r) + 'px';
  const side = R.side * W;
  const content = W - 2 * side;
  const shadow = `0 ${px(0.020 * H)} ${px(0.052 * H)} ${px(-0.014 * H)} rgba(0,0,0,0.78)`;
  const lineSpans = lines.map((l) => `<span class="line">${escapeHtml(l)}</span>`).join('');
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<link rel="stylesheet" href="${TYPEKIT_CSS}">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { width: ${W}px; height: ${H}px; }
  body {
    position: relative;
    background: ${BG};
    overflow: hidden;
    -webkit-font-smoothing: antialiased;
    text-rendering: geometricPrecision;
  }
  /* ONE warm radial glow behind the device — low opacity, nothing more. */
  .glow {
    position: absolute;
    left: 50%; top: ${px(R.glowCY * H)};
    width: ${px(R.glowW * W)}; height: ${px(R.glowH * H)};
    transform: translate(-50%, -50%);
    background: radial-gradient(closest-side,
      rgba(216,163,74,0.24) 0%,
      rgba(216,163,74,0.09) 44%,
      rgba(216,163,74,0.00) 72%);
    pointer-events: none;
  }
  /* Headline lives in the top band, bottom-anchored so every headline shares one baseline. */
  .headline {
    position: absolute;
    left: 0; right: 0; top: 0;
    height: ${px(R.headerH * H)};
    padding: 0 ${px(side)} ${px(R.headerPadB * H)};
    display: flex; flex-direction: column;
    align-items: center; justify-content: flex-end;
    text-align: center;
  }
  .headline h1 {
    font-family: "${HEADLINE_FAMILY}", sans-serif;
    font-weight: ${HEADLINE_WEIGHT};
    font-size: ${px(R.font * W)};
    line-height: ${R.lineHeight};
    letter-spacing: ${LETTER_SPACING};
    color: ${HEADLINE_COLOR};
    text-transform: uppercase;
    max-width: ${px(content)};
  }
  .headline .line { display: block; white-space: nowrap; }
  .rule {
    width: ${px(R.ruleW * W)}; height: ${px(0.0038 * W)};
    margin-top: ${px(R.ruleGap * H)};
    border-radius: 999px; background: ${GOLD};
  }
  /* The device: rounded rect, ONE hairline light border, ONE soft drop shadow. No bezel/notch. */
  .device {
    position: absolute;
    top: ${px(R.deviceTop * H)};
    left: 50%; transform: translateX(-50%);
    width: ${px(R.deviceW * W)};
    border-radius: ${px(R.radius * W)};
    overflow: hidden;
    border: 1px solid rgba(255,255,255,0.10);
    box-shadow: ${shadow};
  }
  .device img { display: block; width: 100%; height: auto; }
</style>
</head>
<body>
  <div class="glow"></div>
  <div class="headline"><h1>${lineSpans}</h1>${SHOW_RULE ? '<div class="rule"></div>' : ''}</div>
  <div class="device"><img id="shot" src="${dataUri}" alt=""></div>
</body>
</html>`;
}

async function main() {
  const args = parseArgs(process.argv);
  const { width: W, height: H } = args;

  const rawBuf = fs.readFileSync(args.raw);
  const dataUri = 'data:image/png;base64,' + rawBuf.toString('base64');
  const lines = args.caption.replace(/\\n/g, '\n').split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  if (lines.length === 0) { console.error('::error::empty caption'); process.exit(2); }
  if (lines.length > 2) { console.error(`::error::caption has ${lines.length} lines (max 2)`); process.exit(2); }

  const html = buildHtml({ W, H, dataUri, lines });
  const tmpHtml = path.join(os.tmpdir(), `frame-${process.pid}-${W}x${H}.html`);
  fs.writeFileSync(tmpHtml, html);

  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--force-color-profile=srgb', '--hide-scrollbars'],
  });
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
    await page.goto('file://' + tmpHtml.replace(/\\/g, '/'), { waitUntil: 'networkidle0', timeout: 60000 });

    // Ensure the embedded screenshot is actually decoded before we snap.
    await page.evaluate(() => document.getElementById('shot').decode());

    // Wait for + VERIFY the Adobe webfont painted. Width test: the condensed Bebas face is far
    // narrower than any monospace fallback, so equal widths ⇒ the webfont did NOT load.
    const fontsize = Math.round(R.font * W);
    const report = await page.evaluate(async (family, weight, size) => {
      try { await document.fonts.load(`${weight} ${size}px "${family}"`); } catch (e) {}
      await document.fonts.ready;
      const widthOf = (fam) => {
        const el = document.createElement('span');
        el.style.cssText =
          `position:absolute;left:-9999px;top:0;white-space:nowrap;font-weight:${weight};font-size:${size}px;font-family:${fam}`;
        el.textContent = 'BUILD THE WHOLE SONG';
        document.body.appendChild(el);
        const w = el.getBoundingClientRect().width;
        el.remove();
        return w;
      };
      const mono = widthOf('monospace');
      const web = widthOf(`"${family}",monospace`);
      const face = [...document.fonts].find((f) => f.family === family && f.status === 'loaded');
      return {
        check: document.fonts.check(`${weight} ${size}px "${family}"`),
        loadedFace: !!face,
        mono, web,
        differs: Math.abs(web - mono) > 1,
      };
    }, HEADLINE_FAMILY, HEADLINE_WEIGHT, fontsize);

    if (!(report.differs && report.check && report.loadedFace)) {
      console.error(`::error::Adobe webfont "${HEADLINE_FAMILY}" did NOT load — refusing to ship fallback type. ` +
        `report=${JSON.stringify(report)}`);
      process.exit(1);
    }
    console.error(`font OK: "${HEADLINE_FAMILY}" loaded (web=${report.web.toFixed(1)} vs mono=${report.mono.toFixed(1)})`);

    // A headline line must never silently overflow the safe content box.
    const side = R.side * W;
    const contentW = W - 2 * side;
    const overflow = await page.evaluate((limit) => {
      return [...document.querySelectorAll('.headline .line')]
        .map((el) => ({ text: el.textContent, w: el.getBoundingClientRect().width }))
        .filter((x) => x.w > limit + 0.5);
    }, contentW);
    if (overflow.length) {
      console.error(`::error::headline overflow (content ${Math.round(contentW)}px): ` +
        overflow.map((o) => `"${o.text}"=${o.w.toFixed(0)}px`).join(', '));
      process.exit(1);
    }

    await page.screenshot({ path: args.out, type: 'png', clip: { x: 0, y: 0, width: W, height: H } });
  } finally {
    await browser.close();
    try { fs.unlinkSync(tmpHtml); } catch (e) {}
  }

  // Defense in depth: re-read the PNG header and confirm exact pixel size + opaque RGB.
  const out = fs.readFileSync(args.out);
  const ow = out.readUInt32BE(16), oh = out.readUInt32BE(20), colorType = out.readUInt8(25);
  if (ow !== W || oh !== H) {
    console.error(`::error::output ${ow}x${oh} != ${W}x${H}`); process.exit(1);
  }
  if (colorType !== 2) {
    console.error(`::error::output PNG colorType ${colorType} (want 2=RGB, opaque, no alpha)`); process.exit(1);
  }
  console.error(`wrote ${args.out}  ${ow}x${oh}  RGB`);
}

main().catch((e) => { console.error('::error::' + (e && e.stack || e)); process.exit(1); });
