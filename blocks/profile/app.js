// The profile block's page (Libertty's own code around speedscope, MIT): one
// profile file, shown in speedscope. A report of macOS's `sample` (what the
// profiler block records) becomes collapsed stacks here; speedscope reads
// the other formats itself (Chrome .cpuprofile, its own JSON, folded stacks).
(function () {
  const { h, toast } = block;

  // "start  (in dyld) + 6688  [0x18868fe80]" → "start (dyld)". A frame
  // without a symbol keeps its offset in the image ("??? (Python3) +0x5515c"),
  // so two such functions stay apart. A thread keeps its number, its name
  // ("Thread_123: worker") and its queue's.
  function frame(text) {
    let label;
    const thread = text.match(/^Thread_(\d+)(?::\s*(.*?))?(?:\s{2,}DispatchQueue_\d+:\s*(.*?))?(?:\s{2,}\(\w+\))?\s*$/);
    if (thread) {
      label = "Thread " + thread[1] + [thread[2], thread[3]].filter(Boolean).map((n) => " · " + n).join("");
    } else {
      const name = text.split("  (in ")[0].trim();
      const module = (text.match(/\(in ([^)]+)\)/) || [])[1];
      const offset = name === "???" ? (text.match(/load address 0x[0-9a-f]+ \+ (0x[0-9a-f]+)/) || [])[1] : null;
      label = module ? `${name} (${module})${offset ? " +" + offset : ""}` : text.replace(/\s+\[0x[^\]]*\].*$/, "").trim();
    }
    // `;` separates frames in collapsed stacks.
    return label.replace(/;/g, ",");
  }

  // The "Call graph:" of a `sample` report as collapsed stacks ("a;b;c N").
  // Each line's count holds its callees': what's left is its own.
  function sampleToCollapsed(text) {
    const lines = text.split("\n");
    let i = lines.findIndex((l) => l.startsWith("Call graph:"));
    if (i < 0) return null;
    const stacks = new Map(), open = [];
    const close = (depth) => {
      while (open.length && open[open.length - 1].depth >= depth) {
        const node = open.pop();
        const own = node.count - node.callees;
        if (own > 0) {
          const key = open.map((n) => n.name).concat(node.name).join(";");
          stacks.set(key, (stacks.get(key) || 0) + own);
        }
      }
    };
    for (i++; i < lines.length; i++) {
      const line = lines[i];
      if (!line.trim()) break;
      const m = line.match(/^([\s+!:|]*?)(\d+) (.*)$/);
      if (!m) continue;
      const depth = m[1].length, count = +m[2];
      close(depth);
      if (open.length) open[open.length - 1].callees += count;
      open.push({ depth, name: frame(m[3]), count, callees: 0 });
    }
    close(0);
    return [...stacks].map(([k, v]) => k + " " + v).join("\n");
  }

  function base64(text) {
    const bytes = new TextEncoder().encode(text);
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }

  const note = h("div.profile-note", "Reading…");
  document.body.appendChild(note);

  // speedscope makes `window.speedscope` once it's on screen.
  function ready() {
    return new Promise((resolve) => {
      const t = setInterval(() => { if (window.speedscope) { clearInterval(t); resolve(window.speedscope); } }, 30);
    });
  }

  async function show() {
    let file;
    try { file = await block.call("read"); } catch (e) { note.textContent = String(e.message || e); return; }
    let text = file.text, name = file.name;
    if (/^Analysis of sampling /.test(text) || text.includes("\nCall graph:\n")) {
      const collapsed = sampleToCollapsed(text);
      if (!collapsed) { note.textContent = "This sample report has no call graph."; return; }
      text = collapsed;
      name = name.replace(/(\.sample)?\.txt$/, "") + ".folded";
    }
    const speedscope = await ready();
    speedscope.loadFileFromBase64(name, base64(text));
    note.remove();
    window.libertty_profile = { name, lines: text.split("\n").length };
  }

  block.on("fileChanged", () => location.reload());
  window.libertty_sampleToCollapsed = sampleToCollapsed;
  show().catch((e) => toast(String(e.message || e), true));
})();
