#!/usr/bin/env node
// Libertty's app icon: a black terminal whose screen shows, in clean pixels, the prompt's
// chevron and over the cursor a torch's amber flame (Liberty + tty), with a CRT's glow.
// The colours are the first icon's; the drawing is a pixel sprite on an 18 × 16 grid.
//
//   node assets/icon/build-app-icon.mjs [--preview FILE]
//
// Writes libertty-icon.svg, png/libertty-{16…1024}.png, libertty.icns and favicon.ico
// here; --preview instead renders the icon at Dock sizes on light and dark to FILE.
// Needs Chrome (CHROME overrides its path), sips and iconutil.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const preview = (() => { const i = args.indexOf('--preview'); return i >= 0 ? path.resolve(args[i + 1]) : null; })();
const chrome = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
if (!fs.existsSync(chrome)) { console.error('Chrome not found. Set CHROME to the browser binary.'); process.exit(1); }

// ---------- The drawing ----------
// w glyph (the chevron, the cursor); d, o, m, c the flame from its edge to its core.
const COLORS = { w: '#EEF3F0', d: '#F28A1E', o: '#FFBE3D', m: '#FFD879', c: '#FFF6D6' };
// The flame: a pointed top leaning right, a small tongue on its left, a round bottom;
// inside it a yellow flame, and low down, where a flame is hottest, its white core. Its
// edge is drawn in d (outline), so the thin top reads redder than the heart.
const FLAME = outline([
  '.....o....',
  '.....oo...',
  '....ooo...',
  '....oooo..',
  '.o.ooooo..',
  '.oooomoo..',
  '..ooommoo.',
  '.ooommmoo.',
  '.oommcmmo.',
  '.oomcccmo.',
  '..omccco..',
  '...oooo...',
]);
// Turns the o pixels at a sprite's edge (beside nothing, across a side) into d.
function outline(rows) {
  const at = (x, y) => (rows[y] || '')[x] || '.';
  return rows.map((row, y) => [...row].map((ch, x) =>
    ch === 'o' && [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dx, dy]) => at(x + dx, y + dy) === '.') ? 'd' : ch).join(''));
}
const COLS = 18, ROWS = 16;
const SPRITE = Array.from({ length: ROWS }, () => Array(COLS).fill('.'));
const stamp = (rows, x0, y0) => rows.forEach((row, y) => [...row].forEach((ch, x) => { if (ch !== '.') SPRITE[y0 + y][x0 + x] = ch; }));
stamp(FLAME, 8, 1);
// The prompt's chevron, two pixels thick, its point in the middle.
[1, 2, 3, 4, 5, 4, 3, 2, 1].forEach((x, i) => { SPRITE[4 + i][x] = 'w'; SPRITE[4 + i][x + 1] = 'w'; });
// The cursor under the flame, as wide as the flame's body is round.
for (let x = 10; x <= 15; x++) SPRITE[14][x] = 'w';

// The macOS grid: an 824-point tile in a 1024 canvas, its outline a superellipse.
function squircle(cx, cy, half, n = 5, steps = 360) {
  const pts = [];
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * Math.PI * 2, c = Math.cos(t), s = Math.sin(t);
    pts.push([cx + half * Math.sign(c) * Math.abs(c) ** (2 / n), cy + half * Math.sign(s) * Math.abs(s) ** (2 / n)]);
  }
  return 'M' + pts.map(([x, y]) => `${x.toFixed(2)} ${y.toFixed(2)}`).join('L') + 'Z';
}
const rrect = (x, y, w, h, r) => `M${x + r} ${y}H${x + w - r}Q${x + w} ${y} ${x + w} ${y + r}V${y + h - r}Q${x + w} ${y + h} ${x + w - r} ${y + h}H${x + r}Q${x} ${y + h} ${x} ${y + h - r}V${y + r}Q${x} ${y} ${x + r} ${y}Z`;

function svg() {
  const tile = squircle(512, 512, 412);
  // The screen sits in the bezel with a deeper chin, as the first icon's did.
  const sx = 150, sy = 150, sw = 724, sh = 672, screen = rrect(sx, sy, sw, sh, 92);
  const P = 38, ox = sx + (sw - COLS * P) / 2, oy = sy + (sh - ROWS * P) / 2;
  // One path a colour, so pixels side by side show no seam between them.
  const paths = Object.entries(COLORS).map(([k, color]) => {
    let d = '';
    SPRITE.forEach((row, y) => row.forEach((ch, x) => { if (ch === k) d += `M${ox + x * P} ${oy + y * P}h${P}v${P}h${-P}Z`; }));
    return d ? `<path d="${d}" fill="${color}"/>` : '';
  }).join('');
  const lines = Array.from({ length: Math.ceil(sh / 8) }, (_, i) => `M${sx} ${sy + i * 8 + 6}h${sw}`).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img"><title>Libertty</title>
  <defs>
    <linearGradient id="lb-bezel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3A3A3C"/><stop offset="0.1" stop-color="#1C1C1E"/><stop offset="1" stop-color="#060606"/></linearGradient>
    <radialGradient id="lb-screen" cx="0.5" cy="0.42" r="0.78"><stop offset="0" stop-color="#1C1F20"/><stop offset="0.7" stop-color="#0B0D0D"/><stop offset="1" stop-color="#040505"/></radialGradient>
    <linearGradient id="lb-glass" x1="0" y1="0" x2="0.7" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.07"/><stop offset="0.45" stop-color="#fff" stop-opacity="0.015"/><stop offset="0.46" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <radialGradient id="lb-fire"><stop offset="0" stop-color="#FFBE3D" stop-opacity="0.32"/><stop offset="1" stop-color="#FFBE3D" stop-opacity="0"/></radialGradient>
    <filter id="lb-drop" x="-20%" y="-20%" width="140%" height="150%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="10" result="o"/>
      <feColorMatrix in="o" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.3 0"/>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="lb-bloom" x="-30%" y="-30%" width="160%" height="160%" color-interpolation-filters="sRGB">
      <feGaussianBlur stdDeviation="16"/>
    </filter>
    <clipPath id="lb-sc"><path d="${screen}"/></clipPath>
  </defs>
  <g filter="url(#lb-drop)"><path d="${tile}" fill="url(#lb-bezel)"/></g>
  <path d="${tile}" fill="none" stroke="#4A4A4D" stroke-opacity="0.6" stroke-width="3"/>
  <path d="${screen}" fill="#000" transform="translate(0 -6)" opacity="0.7"/>
  <path d="${screen}" fill="url(#lb-screen)"/>
  <g clip-path="url(#lb-sc)">
    <circle cx="${ox + 12.5 * P}" cy="${oy + 8 * P}" r="250" fill="url(#lb-fire)"/>
    <g filter="url(#lb-bloom)" opacity="0.55">${paths}</g>
    ${paths}
    <path d="${lines}" stroke="#000" stroke-opacity="0.16" stroke-width="2"/>
    <path d="${screen}" fill="url(#lb-glass)"/>
  </g>
  <path d="${screen}" fill="none" stroke="#000" stroke-opacity="0.6" stroke-width="4"/>
</svg>
`;
}

// ---------- Files ----------
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'libertty-app-icon-'));
const run = (cmd, argv) => execFileSync(cmd, argv, { stdio: ['ignore', 'pipe', 'pipe'] });
function rasterize(markup, w, h, file) {
  const page = path.join(work, `page-${path.basename(file)}.html`);
  fs.writeFileSync(page, `<!doctype html><style>html,body{margin:0;background:transparent}svg{display:block}</style>${markup}`);
  run(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    '--default-background-color=00000000', `--user-data-dir=${path.join(work, 'profile')}`,
    `--window-size=${w},${h}`, `--screenshot=${file}`, 'file://' + page]);
}
// A Windows icon file of PNG images, as browsers take for a favicon.
function ico(pngs) {
  const head = Buffer.alloc(6 + 16 * pngs.length);
  head.writeUInt16LE(1, 2); head.writeUInt16LE(pngs.length, 4);
  let offset = head.length;
  pngs.forEach(({ size, data }, i) => {
    const e = 6 + 16 * i;
    head.writeUInt8(size, e); head.writeUInt8(size, e + 1);
    head.writeUInt16LE(1, e + 4); head.writeUInt16LE(32, e + 6);
    head.writeUInt32LE(data.length, e + 8); head.writeUInt32LE(offset, e + 12);
    offset += data.length;
  });
  return Buffer.concat([head, ...pngs.map((p) => p.data)]);
}

try {
  const icon = svg();
  const master = path.join(work, 'libertty-1024.png');
  rasterize(icon, 1024, 1024, master);
  const sized = (px) => {
    if (px === 1024) return master;
    const file = path.join(work, `libertty-${px}.png`);
    if (!fs.existsSync(file)) run('sips', ['-z', String(px), String(px), master, '--out', file]);
    return file;
  };
  if (preview) {
    const sizes = [1024, 256, 128, 64, 32, 16];
    const row = (bg) => `<div style="background:${bg};display:flex;align-items:center;gap:24px;padding:24px">${sizes.map((s) => `<img src="file://${sized(s)}" style="width:${Math.min(s, 512)}px;height:${Math.min(s, 512)}px">`).join('')}</div>`;
    rasterize(`<body style="margin:0">${row('#E9EBEF')}${row('#1E1F24')}</body>`, 1500, 1160, preview);
    console.log(`Preview: ${preview}`);
  } else {
    fs.writeFileSync(path.join(dir, 'libertty-icon.svg'), icon);
    for (const px of [16, 32, 64, 128, 256, 512, 1024]) fs.copyFileSync(sized(px), path.join(dir, `png/libertty-${px}.png`));
    const set = path.join(work, 'Libertty.iconset');
    fs.mkdirSync(set);
    for (const pt of [16, 32, 128, 256, 512]) {
      fs.copyFileSync(sized(pt), path.join(set, `icon_${pt}x${pt}.png`));
      fs.copyFileSync(sized(pt * 2), path.join(set, `icon_${pt}x${pt}@2x.png`));
    }
    run('iconutil', ['--convert', 'icns', '--output', path.join(dir, 'libertty.icns'), set]);
    fs.writeFileSync(path.join(dir, 'favicon.ico'), ico([16, 32, 48].map((size) => ({ size, data: fs.readFileSync(sized(size)) }))));
    console.log('App icon: assets/icon/ (libertty-icon.svg, png/, libertty.icns, favicon.ico)');
  }
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
