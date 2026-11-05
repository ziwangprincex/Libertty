#!/usr/bin/env node
// Builds Libertty's feature icons from src/icons.js (Libertty's, not part of the Kubai
// engine): the Settings window's pages and the command palette's tools, each a PNG for
// the app in Resources/icons/<name>.png. The app icon is the pixel one in assets/icon/,
// made by assets/icon/build-app-icon.mjs.
//
//   node assets/icons/scripts/build.mjs
//
// Needs Chrome (CHROME overrides its path).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.resolve(here, '../..');
const chrome = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
if (!fs.existsSync(chrome)) { console.error('Chrome not found. Set CHROME to the browser binary.'); process.exit(1); }

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'libertty-icons-'));
const run = (cmd, argv) => execFileSync(cmd, argv, { stdio: ['ignore', 'pipe', 'pipe'] });

// Every icon as a standalone SVG in its own colour (src/app.js's ACCENTS), at rest.
function exportAll(pad) {
  const out = path.join(work, `svg-${pad}`);
  run('node', [path.join(here, 'scripts/export.mjs'), '--out', out, '--pad', String(pad), '--size', '512']);
  return (name) => fs.readFileSync(path.join(out, `${name}.svg`), 'utf8');
}

// Renders an SVG (or HTML) document to a PNG of w×h, transparent where nothing is drawn.
function rasterize(markup, w, h, file) {
  const page = path.join(work, `page-${path.basename(file)}.html`);
  fs.writeFileSync(page, `<!doctype html><style>html,body{margin:0;background:transparent}svg{display:block}</style>${markup}`);
  run(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    '--default-background-color=00000000', `--user-data-dir=${path.join(work, 'profile')}`,
    `--window-size=${w},${h}`, `--screenshot=${file}`, 'file://' + page]);
}

// ---------- The feature icons ----------
// Each at 96 px, a square with room for its shadow; the app draws them at 18–32 points.
function buildFeatures(svgOf) {
  const order = fs.readFileSync(path.join(here, 'src/app.js'), 'utf8').match(/^const ORDER = \[([\s\S]*?)\];/m)[1]
    .match(/'[^']+'/g).map((s) => s.slice(1, -1));
  const dir = path.join(repo, 'Resources/icons');
  fs.mkdirSync(dir, { recursive: true });
  for (const name of order) {
    const svg = svgOf(name).replace(/ width="[\d.]+" height="[\d.]+"/, ' width="96" height="96"');
    rasterize(svg, 96, 96, path.join(dir, `${name}.png`));
  }
  console.log(`Feature icons: Resources/icons/ (${order.length})`);
}

try {
  buildFeatures(exportAll(2.5));
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
