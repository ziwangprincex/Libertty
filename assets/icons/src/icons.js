// Copyright (c) 2026 Kubai087. Licensed under the Kubai Icons License; see LICENSE.
// The icon set. Each entry: svg(u) builds the layers, target(hover, state) returns the
// numbers for rest or hover, draw(p, E) writes the interpolated numbers back. A contributed
// icon also names its designer's GitHub handle in `by`.

// ---------- Icons ----------
// Fills: u.lo(h) / u.up(h) carry the thin bottom band. Use them only on a flat-bottomed
// rectangle of height h whose bottom is clear: nothing within about 3 units of the edge
// and the piece itself not short. Everything else, and curved shapes, use u.loS / u.upS.
// Marks: on a mid-tone (back) body they are white; on a light (front) body or white
// content they take the deep tint; a supporting object laid over the subject (the
// lens) is deep so it reads as separate. Weights: content lines 1.6, glyphs 2.2.
const OL = 'class="ol" data-t="stroke:#5393FF"';
const LINE = 'class="ln" data-t="stroke:#D3E2FC"';
const ACC = 'class="ln" data-t="stroke:#5393FF"';
const DEEP = 'data-t="fill:#2F6FE0"';
const DEEPS = 'data-t="stroke:#2F6FE0"';
const FOLDER_BACK_R = [KR, 1.4, 1.4, KR, KR, KR];
// Keylines (fills; outside strokes add 1 all round), all centred on (15.5, 12.5) and scaled from the folder's 23-wide body
// (Material's 20 / 18 / 20×16 grid × 1.15): circle Ø23, square 20.6, landscape 23×18.4,
// portrait 18.4×23. Outlines sit 1 unit outside a shape; a coloured band around white
// content keeps 2+ units or is dropped so the content meets the edge.
const TRASH_LID = rp([[5.4, 6.6], [5.4, 4], [12.4, 4], [12.4, 1.6], [18.6, 1.6], [18.6, 4], [25.6, 4], [25.6, 6.6]], [1, 1, 0.5, 0.8, 0.8, 0.5, 1, 1]);
const GEAR = gear(6, 11.4, 9);
  const MAIL_T = 3.3;
const today = new Date();
const tomorrow = new Date(today.getTime() + 86400000);

// A capsule ring centred on the origin: outer w×h, wall t (fill-rule evenodd).
const capsuleRing = (w, h, t) => rr(-w / 2, -h / 2, w, h, h / 2) + rr(-w / 2 + t, -h / 2 + t, w - 2 * t, h - 2 * t, (h - 2 * t) / 2);
const LINK_RING = capsuleRing(15.6, 9.6, 2.8);
// An arc of radius r round the origin from angle a0 to a1 (degrees, clockwise), and a
// solid arrowhead whose base covers the arc's end. Strokes never overlap one another,
// so the head stays crisp instead of clotting where strokes would cross.
function arcArrow(a0, a1, r) {
  const rad = (d) => d * Math.PI / 180;
  const pt = (a) => [r * Math.cos(rad(a)), r * Math.sin(rad(a))];
  const s = pt(a0), e = pt(a1);
  const t = [-Math.sin(rad(a1)), Math.cos(rad(a1))], n = [Math.cos(rad(a1)), Math.sin(rad(a1))];
  const tip = [e[0] + t[0] * 3, e[1] + t[1] * 3];
  const head = rp([[e[0] + n[0] * 2.5, e[1] + n[1] * 2.5], tip, [e[0] - n[0] * 2.5, e[1] - n[1] * 2.5]], 0.5);
  return { arc: `M${f(s[0])} ${f(s[1])}A${r} ${r} 0 0 1 ${f(e[0])} ${f(e[1])}`, head };
}
// Each arrow's tip stops well short of the other arc's tail.
const SYNC_A = arcArrow(215, 300, 4.4), SYNC_B = arcArrow(35, 120, 4.4);
const SHORTCUT_TILES = [[7.2, 4.2], [16.5, 4.2], [7.2, 13.5], [16.5, 13.5]];

// ---------- Libertty's own ----------
// A flame with a smaller tongue on its left, drawn once in a box 17.8 wide and 23 tall
// centred on x = 15.5, then placed: centre cx, top y, height h (its width follows).
const FLAME = [
  ['M', 15.8, 1], ['C', 17, 5, 24.4, 8.6, 24.4, 15.6], ['C', 24.4, 20.6, 20.4, 24, 15.5, 24],
  ['C', 10.6, 24, 6.6, 20.6, 6.6, 15.8], ['C', 6.6, 12.6, 8, 10.4, 9.6, 8.4],
  ['C', 9.8, 10.8, 10.8, 12.4, 12.2, 13], ['C', 12, 8.6, 13.4, 4.4, 15.8, 1]
];
function flame(cx, top, h) {
  const k = h / 23;
  return FLAME.map(([c, ...n]) => c + n.map((v, i) => f(i % 2 ? top + (v - 1) * k : cx + (v - 15.5) * k)).join(' ')).join('') + 'Z';
}
// A teardrop: the hot core inside a flame, its bottom at `base`.
function drop(cx, top, base, w) {
  const h = base - top, x = (k) => f(cx + w * k), y = (k) => f(top + h * k);
  return `M${f(cx)} ${f(top)}C${x(0.2)} ${y(0.22)} ${x(0.5)} ${y(0.42)} ${x(0.5)} ${y(0.66)}`
    + `C${x(0.5)} ${y(0.88)} ${x(0.27)} ${f(base)} ${f(cx)} ${f(base)}`
    + `C${x(-0.27)} ${f(base)} ${x(-0.5)} ${y(0.88)} ${x(-0.5)} ${y(0.66)}`
    + `C${x(-0.5)} ${y(0.42)} ${x(-0.2)} ${y(0.22)} ${f(cx)} ${f(top)}Z`;
}
// The window every terminal icon starts from: a landscape body, a title bar in the
// front colour, and the screen two units inside the outline.
const WIN_BODY = rr(4, 3.3, 23, 18.4, KR);
const WIN_HEAD = rp(R(4, 3.3, 23, 4.6), [KR, KR, 0, 0]);
const WIN_SCREEN = rr(6, 9.9, 19, 9.8, CR);
const windowParts = (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${WIN_BODY}" fill="${u.loS}"/></g></g>
      <path d="${WIN_BODY}" ${OL}/>`;
const windowHead = (u) => `
      <g filter="${u.hi}"><path d="${WIN_HEAD}" fill="${u.upS}"/></g>
      <path d="${WIN_HEAD}" ${OL}/>`;
// The prompt's chevron, as a glyph.
const CHEVRON = 'M8.7 12.1L12 14.8L8.7 17.5';
// Static icons keep one pose.
const still = () => ({});
const none = () => {};
// A puzzle piece's edge, x = 15.5, with a knob of radius 2.8 centred 2.2 past it, halfway down
// that one piece carries and the other takes in.
const KNOB_R = 2.8, KNOB_DY = Math.sqrt(KNOB_R ** 2 - 2.2 ** 2);
const PIECE_T = 6.8, PIECE_B = 22.4, PIECE_MID = (PIECE_T + PIECE_B) / 2;
// ⌘, centred on (cx, cy): a square of side s whose sides run on into four loops of radius r.
function command(cx, cy, s, r) {
  const a = cx - s / 2, b = cx + s / 2, c = cy - s / 2, d = cy + s / 2, A = (x, y) => `A${r} ${r} 0 1 1 ${f(x)} ${f(y)}`;
  return `M${f(a - r)} ${f(c)}H${f(b + r)}M${f(a - r)} ${f(d)}H${f(b + r)}M${f(a)} ${f(c - r)}V${f(d + r)}M${f(b)} ${f(c - r)}V${f(d + r)}`
    + `M${f(a - r)} ${f(c)}${A(a, c - r)}M${f(b)} ${f(c - r)}${A(b + r, c)}`
    + `M${f(b + r)} ${f(d)}${A(b, d + r)}M${f(a)} ${f(d + r)}${A(a - r, d)}`;
}

const LIBERTTY = [
  {
    name: 'terminal',
    // A terminal window at its prompt.
    svg: (u) => `${windowParts(u)}
      <path d="${WIN_SCREEN}" fill="#fff"/>
      <path d="${CHEVRON}M14.6 17.5H19.6" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" ${DEEPS}/>
      ${windowHead(u)}`,
    target: still, draw: none
  },
  {
    name: 'window',
    // Libertty's window: a sidebar of tabs beside a pane.
    svg: (u) => `${windowParts(u)}
      <path d="${rr(6, 9.9, 5.4, 9.8, CR)}" fill="#fff"/>
      <path d="${rr(13.4, 9.9, 11.6, 9.8, CR)}" fill="#fff"/>
      <path d="${lines(7.6, 12.6, [2.2, 2.2])}" ${ACC}/>
      <path d="${lines(15.4, 12.6, [7.4, 4.6])}" ${LINE}/>
      ${windowHead(u)}`,
    target: still, draw: none
  },
  {
    name: 'server',
    // liberttyd: two units of a rack, a drive slot and a light on each.
    svg: (u) => {
      const back = rr(5.2, 2.2, 20.6, 20.6, KR), front = rp(R(5.2, 12.9, 20.6, 9.9), [1.8, 1.8, KR, KR]);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.loS}"/></g></g>
      <path d="${back}" ${OL}/>
      <path d="M9 7.6H16" class="ln" stroke="#fff" data-w="stroke"/>
      <circle cx="21.2" cy="7.6" r="1.4" fill="#fff" data-w="fill"/>
      <g filter="${u.hi}"><path d="${front}" fill="${u.upS}"/></g>
      <path d="${front}" ${OL}/>
      <path d="M9 17.9H16" class="ln" ${DEEPS}/>
      <circle cx="21.2" cy="17.9" r="1.4" ${DEEP}/>`;
    },
    target: still, draw: none
  },
  {
    name: 'keycap',
    // A key with ⌘ on its top, its skirt showing below.
    svg: (u) => {
      const skirt = rr(5.2, 2.2, 20.6, 20.6, KR), top = rr(7.2, 4.2, 16.6, 14.2, 2);
      return `
      <g filter="${u.sh}"><path d="${skirt}" fill="${u.loS}"/></g>
      <path d="${skirt}" ${OL}/>
      <g filter="${u.hi}"><path d="${top}" fill="${u.upS}"/></g>
      <path d="${top}" ${OL}/>
      <path d="${command(15.5, 11.3, 3.6, 1.7)}" fill="none" stroke-width="1.6" stroke-linecap="round" ${DEEPS}/>`;
    },
    target: still, draw: none
  },
  {
    name: 'puzzle',
    // Plugins: two pieces of a puzzle, fitted together, each with a knob on top.
    svg: (u) => {
      const T = PIECE_T, B = PIECE_B, y1 = f(PIECE_MID - KNOB_DY), y2 = f(PIECE_MID + KNOB_DY), r = KR;
      // A knob on a top edge, centred on x: the edge leaves it 1.3 either side of x.
      const knob = (x) => `H${f(x - 1.3)}A2.5 2.5 0 1 1 ${f(x + 1.3)} ${T}`;
      const left = `M${4 + r} ${T}${knob(9.75)}H15.5V${y1}A${KNOB_R} ${KNOB_R} 0 1 1 15.5 ${y2}V${B}H${4 + r}Q4 ${B} 4 ${B - r}V${T + r}Q4 ${T} ${4 + r} ${T}Z`;
      const right = `M15.5 ${T}${knob(21.25)}H${27 - r}Q27 ${T} 27 ${T + r}V${B - r}Q27 ${B} ${27 - r} ${B}H15.5V${y2}A${KNOB_R} ${KNOB_R} 0 1 0 15.5 ${y1}Z`;
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${left}" fill="${u.loS}"/></g></g>
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${right}" fill="${u.upS}"/></g></g>
      <path d="${left}" ${OL}/>
      <path d="${right}" ${OL}/>`;
    },
    target: still, draw: none
  },
  {
    name: 'branch',
    // Git: two commits on one line, and a branch that leaves it.
    svg: (u) => {
      const node = (x, y, fill) => `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(x, y, 3.8)}" fill="${fill}"/></g></g><path d="${circ(x, y, 3.8)}" ${OL}/>`;
      return `<path d="M9 6V19M22 6.6C22 14 9 11.4 9 17.4" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
      ${node(9, 19, u.loS)}${node(9, 6, u.upS)}${node(22, 6, u.upS)}`;
    },
    target: still, draw: none
  },
  {
    name: 'flame',
    // The profiler: a flame, its hot core in front.
    svg: (u) => {
      const outer = flame(15.5, 1, 23), inner = drop(15.7, 11.6, 21, 8.4);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${outer}" fill="${u.loS}"/></g></g>
      <path d="${outer}" ${OL}/>
      <g filter="${u.hi}"><path d="${inner}" fill="${u.upS}"/></g>
      <path d="${inner}" ${OL}/>`;
    },
    target: still, draw: none
  },
  {
    name: 'board',
    // A kanban board: three columns of cards.
    svg: (u) => {
      const body = rr(5.2, 2.2, 20.6, 20.6, KR);
      const cards = [[7.2, 4.2, 6.2], [7.2, 12.4, 4.4], [13.4, 4.2, 9.4], [19.6, 4.2, 4.4]]
        .map(([x, y, h]) => rr(x, y, 4.2, h, CR)).join('');
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g>
      <path d="${body}" ${OL}/>
      <path d="${cards}" fill="#fff"/>`;
    },
    target: still, draw: none
  },
  {
    name: 'database',
    // SQLite: a cylinder of stacked discs under its lid.
    svg: (u) => {
      const rx = 9.2, ry = 3.2, top = 4.2, bottom = 20.8, L = 15.5 - rx, Rr = 15.5 + rx;
      const can = `M${f(L)} ${top}V${bottom}A${rx} ${ry} 0 0 0 ${f(Rr)} ${bottom}V${top}Z`;
      const lid = `M${f(L)} ${top}A${rx} ${ry} 0 1 0 ${f(Rr)} ${top}A${rx} ${ry} 0 1 0 ${f(L)} ${top}Z`;
      const rings = [9.8, 15.4].map((y) => `M${f(L)} ${y}A${rx} ${ry} 0 0 0 ${f(Rr)} ${y}`).join('');
      return `<clipPath id="${u.id('can')}"><path d="${can}"/></clipPath>
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${can}" fill="${u.loS}"/></g></g>
      <g clip-path="url(#${u.id('can')})"><path d="${rings}" class="ln" stroke="#fff" data-w="stroke"/></g>
      <path d="${can}" ${OL}/>
      <g filter="${u.hi}"><path d="${lid}" fill="${u.upS}"/></g>
      <path d="${lid}" ${OL}/>`;
    },
    target: still, draw: none
  },
  {
    name: 'monitor',
    // Screen sharing: a display on its stand.
    svg: (u) => {
      const body = rr(4, 2.6, 23, 15.6, KR);
      const stand = rp([[13.2, 17], [17.8, 17], [18.6, 20.4], [21.8, 20.4], [21.8, 23.2], [9.2, 23.2], [9.2, 20.4], [12.4, 20.4]], [0, 0, 0.6, 1, 1, 1, 1, 0.6]);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${stand}" fill="${u.upS}"/></g></g>
      <path d="${stand}" ${OL}/>
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${body}" fill="${u.loS}"/></g></g>
      <path d="${body}" ${OL}/>
      <path d="${rr(6, 4.6, 19, 11.6, CR)}" fill="#fff"/>
      <path d="M15.5 13.4V9.4" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
      <path d="${rp([[12.3, 10], [15.5, 6.6], [18.7, 10]], 0.5)}" ${DEEP}/>`;
    },
    target: still, draw: none
  }
];

const ICONS = [
  ...LIBERTTY,
  {
    name: 'photo',
    // Two prints, one behind the other: on hover the back one fans out to the left and
    // the front one tilts, like leafing through an album.
    svg: (u) => {
      const frame = rr(4, 5.6, 23, 16.1, KR), back = rr(6, 3.3, 19, 15, KR);
      return `
      <g data-n="back"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.lo(15)}"/></g></g><path d="${back}" ${OL}/></g>
      <g data-n="front">
        <clipPath id="${u.id('sky')}"><path d="${frame}"/></clipPath>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${frame}" fill="${u.upS}"/></g></g>
        <g clip-path="url(#${u.id('sky')})">
          <circle cx="20.4" cy="9.8" r="2.5" fill="#fff"/>
          <path d="${rp([[-1, 23], [-1, 20.2], [10.6, 10.8], [23, 20.8], [23, 23]], [0, 0, 1.8, 0, 0])}" fill="${u.loS}"/>
          <path d="${rp([[8, 23], [8, 21.4], [19.8, 13.2], [32, 20.8], [32, 23]], [0, 0, 1.8, 0, 0])}" fill="${u.pure('#5393FF')}"/>
        </g>
        <path d="${frame}" ${OL}/>
      </g>`;
    },
    target: (h) => ({ back: h ? [-1.4, -1.2, -9] : [0, 0, 0], front: h ? [0.6, 0.2, 4] : [0, 0, 0] }),
    draw(p, E) {
      at(E.back, { transform: `translate(${f(p.back[0])} ${f(p.back[1])}) rotate(${f(p.back[2])} 15.5 21.7)` });
      at(E.front, { transform: `translate(${f(p.front[0])} ${f(p.front[1])}) rotate(${f(p.front[2])} 15.5 21.7)` });
    }
  },
  {
    name: 'gear',
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><g data-n="gear"><path d="${GEAR}" fill="${u.loS}"/></g></g></g><g data-n="gearO"><path d="${GEAR}" ${OL}/></g>
      <path d="${circ(15.5, 12.5, 5.8)}" fill="#fff"/>
      <g filter="${u.hi}"><path data-n="hub" fill="${u.upS}"/></g>
      <path data-n="hubO" ${OL}/>`,
    target: (h) => ({ rot: h ? 60 : 0, hub: h ? 2.9 : 3.5 }),
    draw(p, E) {
      at(E.gear, { transform: `rotate(${f(p.rot)} 15.5 12.5)` }); at(E.gearO, { transform: `rotate(${f(p.rot)} 15.5 12.5)` });
      const d = circ(15.5, 12.5, p.hub);
      at(E.hub, { d }); at(E.hubO, { d });
    }
  },
  {
    name: 'link',
    // Two links of a chain; hover draws them tighter.
    svg: (u) => `
      <g data-n="g">
        <g data-n="a"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${LINK_RING}" fill-rule="evenodd" fill="${u.loS}"/></g></g><path d="${LINK_RING}" fill-rule="evenodd" ${OL}/></g>
        <g data-n="bb"><g filter="${u.sh}"><g filter="${u.hi}"><path d="${LINK_RING}" fill-rule="evenodd" fill="${u.upS}"/></g></g><path d="${LINK_RING}" fill-rule="evenodd" ${OL}/></g>
      </g>`,
    target: (h) => ({ gap: h ? 3.5 : 4.2, rot: h ? -40 : -45 }),
    draw(p, E) {
      at(E.g, { transform: `rotate(${f(p.rot)} 15.5 12.5)` });
      at(E.a, { transform: `translate(${f(15.5 - p.gap)} 12.5)` });
      at(E.bb, { transform: `translate(${f(15.5 + p.gap)} 12.5)` });
    }
  },
  {
    name: 'appearance',
    // Light and dark halves of one disc; hover turns the light half across.
    svg: (u) => {
      const disc = [15.5, 12.5, 11.5], half = frontPiece(disc, disc, 12.5, 2);
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <g filter="${u.hi}"><g data-n="half"><path d="${half}" fill="${u.upS}"/></g></g>
      <g data-n="halfO"><path d="${half}" ${OL}/></g>`;
    },
    target: (h) => ({ rot: h ? 90 : -90 }),
    draw(p, E) {
      const t = `rotate(${f(p.rot)} 15.5 12.5)`;
      at(E.half, { transform: t }); at(E.halfO, { transform: t });
    }
  },
  {
    name: 'bell',
    // A bell that swings from its knob; the clapper lags behind.
    svg: (u) => {
      const bell = 'M7.8 18.4C9 17 9.3 15 9.3 12C9.3 8 12 5.2 15.5 5.2C19 5.2 21.7 8 21.7 12C21.7 15 22 17 23.2 18.4Z';
      const rim = rr(5.6, 17.4, 19.8, 3.8, 1.9);
      return `<g data-n="bell">
        <circle cx="15.5" cy="4.4" r="1.8" ${DEEP}/>
        <circle data-n="clap" cx="15.5" cy="21.4" r="2.3" ${DEEP}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${bell}" fill="${u.loS}"/></g></g><path d="${bell}" ${OL}/>
        <g filter="${u.hi}"><path d="${rim}" fill="${u.upS}"/></g><path d="${rim}" ${OL}/>
      </g>`;
    },
    target: (h) => ({ swing: h ? 14 : 0, clap: h ? -1.6 : 0 }),
    draw(p, E) {
      at(E.bell, { transform: `rotate(${f(p.swing)} 15.5 4.4)` });
      at(E.clap, { cx: f(15.5 + p.clap) });
    }
  },
  {
    name: 'globe',
    // A globe whose meridian swings round as if it turns.
    svg: (u) => {
      const disc = circ(15.5, 12.5, 11.5);
      return `<clipPath id="${u.id('gl')}"><path d="${disc}"/></clipPath>
        <g filter="${u.sh}"><g filter="${u.hi}"><path d="${disc}" fill="${u.loS}"/></g></g>
        <g clip-path="url(#${u.id('gl')})" fill="none" stroke-width="1.6" stroke="#fff" data-w="stroke">
          <path d="M3 12.5H28"/><path data-n="mer"/>
        </g>
        <path d="${disc}" ${OL}/>`;
    },
    target: (h) => ({ rx: h ? 8.6 : 4.6 }),
    draw(p, E) {
      const rx = p.rx;
      at(E.mer, { d: `M${f(15.5 - rx)} 12.5A${f(rx)} 11.5 0 1 0 ${f(15.5 + rx)} 12.5A${f(rx)} 11.5 0 1 0 ${f(15.5 - rx)} 12.5Z` });
    }
  },
  {
    name: 'pencil',
    // A pencil that writes a line on hover.
    svg: (u) => {
      const body = rr(7.1, 9.6, 15, 6.8, 0.8), tip = rp([[22.1, 9.6], [28.4, 13], [22.1, 16.4]], [0.3, 0.9, 0.3]), cap = rr(2.8, 9.6, 4.7, 6.8, 2);
      return `<path data-n="ink" fill="none" stroke-width="2.2" stroke-linecap="round" ${DEEPS}/>
        <g filter="${u.sh}"><g filter="${u.hi}"><g data-n="pen"><path d="${body}" fill="${u.loS}"/><path d="${tip}" fill="${u.upS}"/><path d="${cap}" fill="${u.upS}"/></g></g></g>
        <g data-n="penO"><path d="${body}" ${OL}/><path d="${tip}" ${OL}/><path d="${cap}" ${OL}/></g>`;
    },
    target: (h) => ({ push: h ? 1.6 : 0, ink: h ? 9 : 0 }),
    draw(p, E) {
      const t = `rotate(135 15.5 13) translate(${f(p.push)} 0)`;
      at(E.pen, { transform: t }); at(E.penO, { transform: t });
      at(E.ink, { d: `M6.4 23.6H${f(6.4 + p.ink)}`, opacity: p.ink > 0.2 ? 1 : 0 });
    }
  },
  {
    name: 'chart',
    // A bar chart whose bars rise and fall to new values on hover.
    svg: (u) => `<g filter="${u.sh}"><g filter="${u.hi}"><path d="${rr(5.2, 2.2, 20.6, 20.6, KR)}" fill="${u.loS}"/></g></g>
      <path d="${rr(5.2, 2.2, 20.6, 20.6, KR)}" ${OL}/>
      <path data-n="b1" fill="#fff"/><path data-n="b2" fill="#fff"/><path data-n="b3" fill="#fff"/>`,
    target: (h) => ({ hgt: h ? [10, 5.4, 13.4] : [5.4, 10.6, 7.6] }),
    draw(p, E) {
      [8.4, 13.7, 19].forEach((x, i) => {
        const hh = p.hgt[i];
        at(E['b' + (i + 1)], { d: rp(R(x, 20 - hh, 3.6, hh), [1, 1, 0.4, 0.4]) });
      });
    }
  },
  {
    name: 'document',
    // A page whose folded corner opens a little more on hover.
    svg: (u) => `<g filter="${u.sh}"><g filter="${u.hi}"><path data-n="pg" fill="${u.loS}"/></g></g><path data-n="pgO" ${OL}/>
      <path d="${lines(9.6, 13.4, [11.8, 8.2])}" class="ln" stroke="#fff" data-w="stroke"/>
      <g filter="${u.hi}"><path data-n="fold" fill="${u.upS}"/></g><path data-n="foldO" ${OL}/>`,
    target: (h) => ({ fold: h ? 8 : 6 }),
    draw(p, E) {
      const c = p.fold;
      const pg = rp([[6.3, 1.5], [24.7 - c, 1.5], [24.7, 1.5 + c], [24.7, 23.5], [6.3, 23.5]], [KR, 0.5, 0.5, KR, KR]);
      const fold = rp([[24.7 - c, 1.5], [24.7, 1.5 + c], [24.7 - c, 1.5 + c]], [0.4, 0.4, 1.2]);
      at(E.pg, { d: pg }); at(E.pgO, { d: pg }); at(E.fold, { d: fold }); at(E.foldO, { d: fold });
    }
  },
  {
    name: 'notebook',
    // A spiral notebook. On hover the cover turns over on its rings and folds away behind,
    // leaving the lined first page.
    svg: (u) => {
      const back = rr(6.3, 1, 18.4, 23, KR);
      const rings = [5.5, 10.2, 14.8, 19.5].map((y) => rr(3.8, y - 1.2, 7.4, 2.4, 1.2)).join('');
      return `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${back}" fill="${u.loS}"/></g></g>
      <path d="${back}" ${OL}/>
      <path d="${rr(9.4, 3, 13.3, 19, CR)}" fill="#fff"/>
      <path d="${lines(13.4, 8.4, [7.4, 5])}" ${ACC}/>
      <g data-n="cvG"><g filter="${u.hi}"><path data-n="cv" fill="${u.upS}"/></g>
        <path data-n="shade" ${DEEP} opacity="0"/>
        <path data-n="cvO" ${OL}/>
        <g data-n="label"><path d="${lines(13.4, 7.4, [7])}" class="ln" ${DEEPS} stroke-opacity=".55"/></g></g>
      <path d="${rings}" ${DEEP}/>`;
    },
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      // The cover's width shrinks to its hinge on the rings, darkening as it faces away; at
      // the end it has gone round behind the back.
      const o = Math.max(0, Math.min(1, p.o));
      const s = Math.cos(o * Math.PI / 2), w = 15.3 * s;
      const d = rp(R(9.4, 1, w, 23), [1.6, KR, KR, 1.6]);
      at(E.cv, { d }); at(E.cvO, { d }); at(E.shade, { d, opacity: f(0.4 * Math.sin(o * Math.PI / 2)) });
      at(E.label, { transform: `translate(9.4 0) scale(${f(Math.max(0.001, s))} 1) translate(-9.4 0)` });
      at(E.cvG, { opacity: o > 0.985 ? 0 : 1 });
    }
  },
  {
    name: 'compass',
    // A compass resting a little off north. On hover the needle swings past north and back,
    // each swing smaller, and settles pointing north.
    svg: (u) => `
      <g filter="${u.sh}"><g filter="${u.hi}"><path d="${circ(15.5, 12.5, 11.5)}" fill="${u.loS}"/></g></g>
      <path d="${circ(15.5, 12.5, 11.5)}" ${OL}/>
      <path d="${circ(15.5, 12.5, 8.6)}" fill="#fff"/>
      <g data-n="needle">
        <path d="${rp([[13.1, 12.5], [15.5, 5.9], [17.9, 12.5]], [0, 0.6, 0])}" ${DEEP}/>
        <path d="${rp([[17.9, 12.5], [15.5, 19.1], [13.1, 12.5]], [0, 0.6, 0])}" data-t="fill:#89B5FF"/>
        <circle cx="15.5" cy="12.5" r="1.3" fill="#fff"/>
      </g>`,
    target: (h) => ({ o: h ? 1 : 0 }),
    draw(p, E) {
      const o = Math.max(0, Math.min(1, p.o));
      at(E.needle, { transform: `rotate(${f(40 * (1 - o) * Math.cos(3 * Math.PI * o))} 15.5 12.5)` });
    }
  }
];
