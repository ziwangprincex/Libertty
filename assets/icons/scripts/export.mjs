#!/usr/bin/env node
// Copyright (c) 2026 Kubai087. Licensed under the Kubai Icons License; see LICENSE.
// Exports icons as static, self-contained SVG files: no script, no stylesheet, every
// colour resolved for one palette and one state. Use them where the hover motion isn't
// needed or can't run: design tools, documents, native apps, <img> tags.
//
//   node scripts/export.mjs [--only 名字,名字] [--palette 彩色] [--accent #hex]
//                           [--state rest|hover] [--size 96] [--pad 2.5] [--out dir]
//
// --palette picks a palette by name (彩色 by default); --accent paints every icon in one
// colour in the colourful palette instead. --state picks the rest pose or the end of the
// hover. --size sets the width and height in pixels. --pad adds room around the 31×29
// canvas, in icon units, so the drop shadow isn't cut off. Files go to export/ unless
// --out says otherwise, one <name>.svg per icon.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const only = (opt('--only') || '').split(',').map((s) => s.trim()).filter(Boolean);
const palette = opt('--palette', '彩色');
const accent = opt('--accent');
const state = opt('--state', 'rest');
const size = Number(opt('--size', 96));
const pad = Number(opt('--pad', 2.5));
const out = path.resolve(opt('--out', path.join(root, 'export')));

const fail = (msg) => { console.error(msg); process.exit(1); };
if (!['rest', 'hover'].includes(state)) fail('--state takes rest or hover.');
if (accent && !/^#[0-9a-f]{6}$/i.test(accent)) fail('--accent takes a colour like #F59E0B.');
if (!(size > 0) || !(pad >= 0)) fail('--size and --pad take positive numbers.');

const chrome = process.env.CHROME || [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser'
].find((p) => fs.existsSync(p));
if (!chrome) fail('Chrome not found. Set CHROME to the browser binary.');

const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');
const icons = read('src/icons.js');
const js = [read('src/engine.js'), icons, read('src/app.js')].join('\n');
const html = read('index.html');

const known = new Set([...icons.matchAll(/\bname:\s*'([^']+)'/g)].map((m) => m[1]));
const unknown = only.filter((n) => !known.has(n));
if (unknown.length) fail(`Unknown icon names: ${unknown.join(', ')}`);

// In the page: mount each icon in the chosen palette and state, then copy what the
// stylesheet contributes (outline and line widths, the date's typeface) onto the elements
// themselves, so the SVG looks the same with no stylesheet around it.
const script = `const opts = ${JSON.stringify({ only, palette, accent, state })};
  const pal = PALETTES.find((p) => p.name === opts.palette);
  if (!pal) throw new Error('Unknown palette: ' + opts.palette + '. Palettes: ' + PALETTES.map((p) => p.name).join(', '));
  if (opts.accent) PALETTES[0].colors.fill(opts.accent);
  runtime.palette = pal;
  const list = opts.only.length ? opts.only : ORDER;
  const host = document.createElement('div'); document.body.appendChild(host);
  const result = list.map((name) => {
    const icon = ICONS.find((x) => x.name === name);
    const src = insts.findIndex((x) => x.icon === icon);
    // An icon left out of ORDER has no colour of its own yet; it borrows the first one.
    const i = src >= 0 ? src : ORDER.length;
    if (src < 0) PALETTES.forEach((p) => { p.colors[i] = p.colors[0]; if (p.edges) p.edges[i] = p.edges[0]; });
    const cell = document.createElement('span'); host.appendChild(cell);
    const inst = mountIcon(icon, i, cell);
    if (opts.state === 'hover') { inst.hover = 1; inst.cur = targetOf(inst); render(inst); }
    const svg = cell.querySelector('svg');
    svg.querySelectorAll('.ol, .ln').forEach((el) => {
      const cs = getComputedStyle(el);
      el.setAttribute('fill', 'none');
      el.setAttribute('stroke-width', parseFloat(cs.strokeWidth));
      if (cs.strokeLinecap !== 'butt') el.setAttribute('stroke-linecap', cs.strokeLinecap);
      el.removeAttribute('class');
    });
    svg.querySelectorAll('text').forEach((el) => el.setAttribute('font-family', getComputedStyle(el).fontFamily));
    svg.querySelectorAll('*').forEach((el) => [...el.attributes].forEach((a) => { if (a.name.startsWith('data-')) el.removeAttribute(a.name); }));
    return { name, svg: svg.outerHTML };
  });
  const tag = document.createElement('script'); tag.type = 'application/json'; tag.id = 'export';
  tag.textContent = JSON.stringify(result); document.body.appendChild(tag);`;

const page = html
  .replace('<head>', '<head><script>window.addEventListener("error",(e)=>{document.documentElement.dataset.err=e.message;});</script>')
  .replace(/<script src="src\/engine\.js"><\/script>\s*<script src="src\/icons\.js"><\/script>\s*<script src="src\/app\.js"><\/script>/,
    `<script>\n${js}\n</script><script>{${script}}</script>`);

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'kubai-icons-export-'));
let dom;
try {
  const file = path.join(work, 'export.html');
  fs.writeFileSync(file, page);
  dom = execFileSync(chrome, ['--headless=new', '--disable-gpu', '--force-prefers-reduced-motion', `--user-data-dir=${path.join(work, 'profile')}`,
    '--virtual-time-budget=3000', '--dump-dom', 'file://' + file],
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 256 * 1024 * 1024 });
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
const err = dom.match(/data-err="([^"]*)"/);
if (err) fail(err[1]);
const json = dom.match(/<script type="application\/json" id="export">([\s\S]*?)<\/script>/);
if (!json) fail('The page produced no icons.');

// Each file gets its own id prefix, so several exported icons can sit inline on one page.
const slug = (s) => [...s].map((ch) => (/[a-z0-9]/i.test(ch) ? ch : ch.codePointAt(0).toString(36))).join('');
const side = 31 + pad * 2, box = [15.5 - side / 2, 12.5 - side / 2, side, side].map((n) => +n.toFixed(3));
fs.mkdirSync(out, { recursive: true });
for (const { name, svg } of JSON.parse(json[1])) {
  const prefix = `ki-${slug(name)}-`;
  const ids = [...svg.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  let text = svg;
  for (const id of ids) {
    const esc = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    text = text.replace(new RegExp(`(\\sid="|url\\(#|href="#)${esc}(?=[")])`, 'g'), `$1${prefix}${id}`);
  }
  text = text
    .replace(/\saria-hidden="true"/, '')
    .replace(/<svg viewBox="[^"]*"/, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box.join(' ')}" width="${size}" height="${size}"`);
  fs.writeFileSync(path.join(out, `${name}.svg`), `${text}\n`);
}
console.log(`${JSON.parse(json[1]).length} icons exported to ${path.relative(process.cwd(), out) || '.'} (${palette}${accent ? ' ' + accent : ''}, ${state})`);
