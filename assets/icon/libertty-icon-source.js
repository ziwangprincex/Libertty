/*
  Libertty app icons, after Ghostty's approach: a terminal screen in a black
  bezel, with a character drawn in glowing pixels on it.

  Every variant is a sprite (a little pixel map) plus a palette.
  Sprite characters:
    w  statue (patina)        g y Y  flame (outer, mid, core)
    c  crown (gold)           .      empty

  Variants
    figure   the full statue: crown, raised arm, torch
    bust     close-up: the crowned head, crown in gold
    torch    just the hand and the torch, big
    amber    the full statue on an amber monochrome screen
    flat     the bust, crisp pixels on plain black, no CRT effects
*/
(function (root) {

  const SPRITES = {
    vBowl: [
      '.......g.......',
      '......ggg......',
      '.....ggyg.g....',
      '....gyyYgg.....',
      'ww..gyYYYg...ww',
      'www.gyYYYg..www',
      '.www.gYYg..www.',
      '..www.....www..',
      '...www...www...',
      '....www.www....',
      '.....wwwww.....',
      '......www......',
      '......www......',
      '......www......',
      '......www......',
      '.....wwwww.....',
      '......www......',
      '......www......'
    ],
    underscoreFire: [
      '............g...',
      '...........ggg..',
      '..........ggygg.',
      '..........gyYyg.',
      '.........gyYYYyg',
      'ww.......gyYYYyg',
      'www......gyYYYyg',
      '.www......gyYyg.',
      '..www......ggg..',
      '...www..........',
      '..www...........',
      '.www.....wwwwwww',
      'www......wwwwwww',
      'ww..............'
    ],
    session: [
      'dddd.ddddddd.ddd..',
      'dddddd.dddd.......',
      '..................',
      'ddd.ddddd.dddddd..',
      'ddddddddd.........',
      '..................',
      '............g.....',
      '...........ggg....',
      '..........ggyg.g..',
      '.........gyyYgg...',
      '.........gyYYYg...',
      'ww.......gyYYYg...',
      'www.......gYYg....',
      '.www.....wwwwwwww.',
      '..www.....wwwwww..',
      '.www.......wwww...',
      'www.........ww....',
      'ww..........ww....',
      '...........wwww...',
      '............ww....'
    ],
    torchCarved: [
      '......g......',
      '.....ggg.....',
      '....ggyg.g...',
      '...gyyYgg....',
      '...gyYYYg....',
      '...gyYYYg....',
      '....gYYg.....',
      '.wwwwwwwwwww.',
      '..wwwwwwwww..',
      '...wwwwwww...',
      '....wwwww....',
      '.....www.....',
      '..wwwwwwwww..',
      '..w.wwwwwww..',
      '..ww.wwwwww..',
      '..www.wwwww..',
      '..ww.wwwwww..',
      '..w.ww...ww..',
      '..wwwwwwwww..',
      '...wwwwwww...',
      '....wwwww....'
    ],
    torchCursor: [
      '............g....',
      '...........ggg...',
      '..........ggyg.g.',
      '.........gyyYgg..',
      '.........gyYYYg..',
      '.........gyYYYg..',
      '..........gYYg...',
      '........wwwwwwwww',
      'ww.......wwwwwww.',
      'www.....wwwwwwwww',
      '.www....wwwwwwwww',
      '..www...wwwwwwwww',
      '...www..wwwwwwwww',
      '..www...wwwwwwwww',
      '.www....wwwwwwwww',
      'www.....wwwwwwwww',
      'ww......wwwwwwwww'
    ],
    torchPrompt: [
      '............g....',
      '...........ggg...',
      '..........ggyg.g.',
      '.........gyyYgg..',
      '.........gyYYYg..',
      '.........gyYYYg..',
      '..........gYYg...',
      '........wwwwwwwww',
      'ww.......wwwwwww.',
      'www.......wwwww..',
      '.www.......www...',
      '..www......www...',
      '...www.....www...',
      '..www......www...',
      '.www......wwwww..',
      'www........www...',
      'ww.........www...'
    ],
    figure: [
      '...g................',
      '..gyg...............',
      '..yYy...............',
      '..gyg...............',
      '.wwwww......w.......',
      '..www...w...w...w...',
      '...w.....w..w..w....',
      '...w......wwwww.....',
      '...ww...wwwwwwwww...',
      '....w....wwwwwww....',
      '....ww...w.w.w.w....',
      '.....w...wwwwwww....',
      '.....ww...wwwww.....',
      '......w....www......',
      '......ww...www......',
      '.......wwwwwwwwww...',
      '........wwwwwwwwww..',
      '........wwwwwwwwwww.',
      '.......wwwwwwwwwwww.',
      '.......wwwwwwwwwwwww'
    ],
    bust: [
      '........c........',
      '.c......c......c.',
      '..c.....c.....c..',
      '...c....c....c...',
      '....c...c...c....',
      'c....c..c..c....c',
      '.cc..ccccccc..cc.',
      '...ccccccccccc...',
      '....wwwwwwwww....',
      '....ww.www.ww....',
      '....wwwwwwwww....',
      '.....wwwwwww.....',
      '......wwwww......',
      '.......www.......',
      '....wwwwwwwww....',
      '..wwwwwwwwwwwww..',
      '.wwwwwwwwwwwwwww.'
    ],
    torch: [
      '......g......',
      '.....ggg.....',
      '....ggyg.g...',
      '...gyyYgg....',
      '...gyYYYg....',
      '...gyYYYg....',
      '....gYYg.....',
      '.wwwwwwwwwww.',
      '..wwwwwwwww..',
      '...wwwwwww...',
      '....wwwww....',
      '.....www.....',
      '....wwwww....',
      '...wwwwwww...',
      '...w.w.w.ww..',
      '...wwwwwwww..',
      '....wwwwww...',
      '.....wwww....',
      '.....wwww....'
    ]
  };

  const PALETTES = {
    patina: { screen: ['#0c2620', '#05110e', '#020605'], w: '#a6f2d6', c: '#ffc24a',
              g: '#ffbe3d', y: '#ffd879', Y: '#fff6d6', prompt: '#a6f2d6', d: '#a6f2d6' },
    amber:  { screen: ['#2a1704', '#120a02', '#060300'], w: '#ffb547', c: '#ffd27a',
              g: '#ffcf6b', y: '#ffe6a8', Y: '#fffaf0', prompt: '#ffb547', d: '#ffb547' },
    white:  { screen: ['#1c1f20', '#0b0d0d', '#040505'], w: '#eef3f0', c: '#ffc24a',
              g: '#ffbe3d', y: '#ffd879', Y: '#fff6d6', prompt: '#eef3f0', d: '#eef3f0' },
    cream:  { screen: ['#211d18', '#0e0c0a', '#050403'], w: '#f2e6cf', c: '#ffc24a',
              g: '#ffb83a', y: '#ffd879', Y: '#fff6d6', prompt: '#f2e6cf', d: '#f2e6cf' },
    gray:   { screen: ['#18191a', '#0a0a0b', '#030303'], w: '#b9bcbf', c: '#ffc24a',
              g: '#ffbe3d', y: '#ffd879', Y: '#fff6d6', prompt: '#b9bcbf', d: '#b9bcbf' }
  };

  const BEZEL = { x: 8, y: 8, s: 240, r: 54 };
  const SCREEN = { x: 22, y: 24, w: 212, h: 196, r: 24 };

  /* centre the sprite's drawn pixels in the screen, slightly above centre,
     leaving room for the prompt in the bottom-left corner */
  function place(sprite, maxCell, hasPrompt = true) {
    const rows = sprite.length, cols = sprite[0].length;
    const area = hasPrompt
      ? { x: SCREEN.x + 16, y: SCREEN.y + 14, w: SCREEN.w - 32, h: SCREEN.h - 40 }
      : { x: SCREEN.x + 18, y: SCREEN.y + 16, w: SCREEN.w - 36, h: SCREEN.h - 32 };
    const cell = Math.min(maxCell, area.w / cols, area.h / rows);
    const ox = area.x + (area.w - cols * cell) / 2;
    const oy = area.y + (area.h - rows * cell) / 2 - 2;
    return { cell, ox, oy };
  }

  function render({ sprite = 'figure', palette = 'patina', crt = true, prompt = true, maxCell = 10, size = 1024 } = {}) {
    const S = SPRITES[sprite], P = PALETTES[palette];
    const { cell, ox, oy } = place(S, maxCell, prompt);
    const gap = crt ? cell * 0.17 : cell * 0.12;
    const warm = ch => ch === 'g' || ch === 'y' || ch === 'Y' || ch === 'c';

    let halos = '', pixels = '';
    S.forEach((row, y) => [...row].forEach((ch, x) => {
      if (ch === '.') return;
      const px = ox + x * cell, py = oy + y * cell;
      if (crt && ch !== 'd') halos += `<circle cx="${(px + cell / 2).toFixed(1)}" cy="${(py + cell / 2).toFixed(1)}" r="${(cell * 1.6).toFixed(1)}" fill="url(#${warm(ch) ? 'hw' : 'hc'})"/>`;
      pixels += `<rect x="${(px + gap / 2).toFixed(2)}" y="${(py + gap / 2).toFixed(2)}" width="${(cell - gap).toFixed(2)}" height="${(cell - gap).toFixed(2)}" rx="${crt ? 0.8 : 0}" fill="${P[ch]}"${ch === 'd' ? ' opacity="0.32"' : ''}/>`;
    }));

    let promptPx = '';
    if (prompt) {
      ['w...', '.w..', '..w.', '.w..', 'w...'].forEach((row, i) => [...row].forEach((ch, j) => {
        if (ch === '.') return;
        promptPx += `<rect x="${(SCREEN.x + 14 + j * 3.2).toFixed(1)}" y="${(SCREEN.y + SCREEN.h - 26 + i * 3.2).toFixed(1)}" width="2.6" height="2.6" fill="${P.prompt}" opacity="0.55"/>`;
      }));
      promptPx += `<rect x="${SCREEN.x + 28}" y="${SCREEN.y + SCREEN.h - 13.2}" width="9" height="2.6" fill="${P.prompt}" opacity="0.55"/>`;
    }

    let scan = '';
    if (crt) for (let y = SCREEN.y; y < SCREEN.y + SCREEN.h; y += 2.4)
      scan += `<rect x="${SCREEN.x}" y="${y.toFixed(1)}" width="${SCREEN.w}" height="0.9" fill="#000" opacity="0.28"/>`;

    const screenFill = crt ? 'url(#screen)' : '#000';
    const glass = crt ? `<rect x="${SCREEN.x}" y="${SCREEN.y}" width="${SCREEN.w}" height="${SCREEN.h}" fill="url(#glass)"/>` : '';

    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="${size}" height="${size}" role="img"><title>Libertty</title>
<defs>
  <linearGradient id="bezel" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3a3a3c"/><stop offset="0.08" stop-color="#1c1c1e"/><stop offset="1" stop-color="#060606"/>
  </linearGradient>
  <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#2a2a2c"/>
  </linearGradient>
  <radialGradient id="screen" cx="0.5" cy="0.45" r="0.75">
    <stop offset="0" stop-color="${P.screen[0]}"/><stop offset="0.7" stop-color="${P.screen[1]}"/><stop offset="1" stop-color="${P.screen[2]}"/>
  </radialGradient>
  <radialGradient id="hc"><stop offset="0" stop-color="${P.w}" stop-opacity="0.22"/><stop offset="1" stop-color="${P.w}" stop-opacity="0"/></radialGradient>
  <radialGradient id="hw"><stop offset="0" stop-color="${P.g}" stop-opacity="0.45"/><stop offset="1" stop-color="${P.g}" stop-opacity="0"/></radialGradient>
  <linearGradient id="glass" x1="0" y1="0" x2="0.7" y2="1">
    <stop offset="0" stop-color="#fff" stop-opacity="0.09"/><stop offset="0.45" stop-color="#fff" stop-opacity="0.02"/><stop offset="0.46" stop-color="#fff" stop-opacity="0"/>
  </linearGradient>
  <clipPath id="sc"><rect x="${SCREEN.x}" y="${SCREEN.y}" width="${SCREEN.w}" height="${SCREEN.h}" rx="${SCREEN.r}"/></clipPath>
</defs>
<rect x="${BEZEL.x}" y="${BEZEL.y}" width="${BEZEL.s}" height="${BEZEL.s}" rx="${BEZEL.r}" fill="url(#bezel)"/>
<rect x="${BEZEL.x + 0.5}" y="${BEZEL.y + 0.5}" width="${BEZEL.s - 1}" height="${BEZEL.s - 1}" rx="${BEZEL.r - 0.5}" fill="none" stroke="#4a4a4d" stroke-opacity="0.6"/>
<rect x="${SCREEN.x - 3}" y="${SCREEN.y - 3}" width="${SCREEN.w + 6}" height="${SCREEN.h + 6}" rx="${SCREEN.r + 3}" fill="url(#rim)"/>
<g clip-path="url(#sc)">
  <rect x="${SCREEN.x}" y="${SCREEN.y}" width="${SCREEN.w}" height="${SCREEN.h}" fill="${screenFill}"/>
  ${halos}${pixels}${promptPx}${scan}${glass}
</g>
</svg>`;
  }

  const VARIANTS = {
    figure: { sprite: 'figure', palette: 'patina' },
    bust:   { sprite: 'bust',   palette: 'patina' },
    torch:  { sprite: 'torch',  palette: 'patina' },
    amber:  { sprite: 'figure', palette: 'amber' },
    flat:   { sprite: 'bust',   palette: 'patina', crt: false },
    torchCarved: { sprite: 'torchCarved', palette: 'patina', prompt: false },
    torchPrompt: { sprite: 'torchPrompt', palette: 'patina', prompt: false },
    torchCursor: { sprite: 'torchCursor', palette: 'patina', prompt: false },
    vBowl: { sprite: 'vBowl', palette: 'patina', prompt: false },
    underscoreFire: { sprite: 'underscoreFire', palette: 'white', prompt: false },
    fireWhite: { sprite: 'underscoreFire', palette: 'white', prompt: false },
    fireCream: { sprite: 'underscoreFire', palette: 'cream', prompt: false },
    fireGray:  { sprite: 'underscoreFire', palette: 'gray', prompt: false },
    session: { sprite: 'session', palette: 'patina', prompt: false },
    torchAmber: { sprite: 'torchPrompt', palette: 'amber', prompt: false },
    torchWhite: { sprite: 'torchPrompt', palette: 'white', prompt: false },
    torchFlat: { sprite: 'torchPrompt', palette: 'patina', prompt: false, crt: false }
  };

  // kept for compatibility with the first version
  const svg = (opts = {}) => render({ ...VARIANTS.figure, ...opts });

  const api = { render, svg, VARIANTS, SPRITES, PALETTES };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.LiberttyCRT = api;
})(this);
