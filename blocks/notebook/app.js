// The notebook block's page (Libertty's own code): an .ipynb's cells,
// edited and saved as the other file blocks are; code runs in a kernel of
// the user's own Jupyter, through the native side (which holds the server
// and its token). Markdown and HTML outputs are shown after a sanitizer
// keeps only plain formatting; everything else goes in as text.
(function () {
  const { h, clear, toast, dialog } = block;
  const call = block.call.bind(block);
  const app = document.getElementById("app");

  let nb = null, writable = true, selected = 0, editing = null;
  const running = new Map(); // msg id → cell
  let kernel = { state: "off", name: "" }; // off | starting | idle | busy | dead

  // MARK: The file

  const lines = (text) => text.split(/(?<=\n)/);
  const sourceOf = (cell) => Array.isArray(cell.source) ? cell.source.join("") : (cell.source || "");
  const newID = () => Math.random().toString(16).slice(2, 10) + Math.random().toString(16).slice(2, 10);

  function parse(text) {
    if (!text.trim()) {
      return { cells: [{ cell_type: "code", id: newID(), metadata: {}, source: [], outputs: [], execution_count: null }],
        metadata: { kernelspec: { name: "python3", display_name: "Python 3", language: "python" } }, nbformat: 4, nbformat_minor: 5 };
    }
    const doc = JSON.parse(text);
    if (!Array.isArray(doc.cells)) throw new Error("not a notebook (version 4)");
    return doc;
  }

  // Jupyter writes one-space indents, sources as lists of lines.
  function serialize() {
    for (const c of nb.cells) if (!Array.isArray(c.source)) c.source = lines(c.source || "");
    return JSON.stringify(nb, null, 1) + "\n";
  }

  // MARK: Sanitizing (markdown cells, HTML outputs)

  const allowed = new Set(["P", "BR", "HR", "H1", "H2", "H3", "H4", "H5", "H6", "STRONG", "B", "EM", "I", "U", "S", "DEL", "CODE", "PRE",
    "BLOCKQUOTE", "UL", "OL", "LI", "A", "IMG", "TABLE", "THEAD", "TBODY", "TFOOT", "TR", "TH", "TD", "CAPTION", "DIV", "SPAN", "SUP", "SUB",
    "DL", "DT", "DD", "INPUT", "SMALL", "KBD", "MARK"]);
  function sanitize(html) {
    const doc = new DOMParser().parseFromString(`<div>${html}</div>`, "text/html");
    const root = doc.body.firstChild;
    (function walk(el) {
      for (const child of [...el.children]) {
        if (!allowed.has(child.tagName)) {
          // Scripts, styles and frames go entirely; anything else keeps its
          // content, which is checked in turn (it stands where the element was).
          if (["SCRIPT", "STYLE", "IFRAME", "OBJECT", "EMBED", "TEMPLATE", "META", "LINK", "BASE", "FORM", "SVG", "MATH"].includes(child.tagName.toUpperCase())) {
            child.remove();
          } else {
            const kids = [...child.childNodes];
            child.replaceWith(...kids);
            for (const k of kids) if (k.nodeType === 1) { const holder = document.createElement("div"); k.replaceWith(holder); holder.appendChild(k); walk(holder); holder.replaceWith(...holder.childNodes); }
          }
          continue;
        }
        for (const attr of [...child.attributes]) {
          const name = attr.name.toLowerCase(), value = attr.value.trim();
          const keep = (name === "href" && /^(https?:|#)/i.test(value)) || (name === "src" && /^data:image\//i.test(value))
            || (["colspan", "rowspan", "align", "alt", "title", "start", "type", "checked", "disabled"].includes(name));
          // No class or id: content mustn't borrow the page's own (a full-window overlay, a cell).
          if (!keep) child.removeAttribute(attr.name);
        }
        if (child.tagName === "INPUT" && child.getAttribute("type") !== "checkbox") { child.remove(); continue; }
        if (child.tagName === "INPUT") child.setAttribute("disabled", "");
        walk(child);
      }
    })(root);
    const out = document.createElement("div");
    out.append(...root.childNodes);
    // Links leave through the native side (a page's in the browser block).
    out.addEventListener("click", (e) => {
      const a = e.target.closest("a");
      if (!a) return;
      e.preventDefault();
      const href = a.getAttribute("href") || "";
      if (/^https?:/i.test(href)) call("openLink", { url: href });
    });
    return out;
  }

  const strip = (text) => String(text).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
  const joined = (x) => Array.isArray(x) ? x.join("") : (x ?? "");

  // MARK: Rendering

  const title = h("span.title");
  const status = h("span.kernel", h("span.dot"), h("span.label", "No kernel"));
  const banner = h("div.banner", { hidden: true });
  const cellsEl = h("div.cells");
  app.append(h("div.bar", title, status, h("span.spacer"),
    h("button.button.quiet", { onclick: () => runAll() }, "Run All"),
    h("button.button.quiet", { onclick: () => kernelCall("interrupt") }, "Interrupt"),
    h("button.button.quiet", { onclick: () => restart() }, "Restart"),
    h("button.button.quiet", { onclick: () => { for (const c of nb.cells) if (c.cell_type === "code") { c.outputs = []; c.execution_count = null; } changed(); } }, "Clear Outputs"),
    h("button.button.quiet", { onclick: () => call("openText") }, "Edit as JSON")),
    banner, cellsEl);

  function showKernel() {
    status.className = "kernel " + kernel.state;
    status.querySelector(".label").textContent = { off: "No kernel — Run starts one", starting: "Starting…", idle: kernel.name + " · idle",
      busy: kernel.name + " · busy", dead: "Kernel stopped" }[kernel.state] || kernel.state;
  }

  function render() {
    const top = cellsEl.scrollTop;
    clear(cellsEl, nb.cells.map((cell, i) => renderCell(cell, i)),
      h("div.add-row",
        h("button.button.quiet", { onclick: () => insert(nb.cells.length, "code") }, "+ Code"),
        h("button.button.quiet", { onclick: () => insert(nb.cells.length, "markdown") }, "+ Markdown")));
    cellsEl.scrollTop = top;
    showKernel();
  }

  function renderCell(cell, i) {
    const code = cell.cell_type === "code";
    const isRunning = [...running.values()].includes(cell);
    const prompt = code ? (isRunning ? "[*]" : cell.execution_count ? `[${cell.execution_count}]` : "[ ]") : "";
    const showSource = code || editing === cell || cell.cell_type === "raw";
    const body = h("div.body");
    if (showSource) {
      const area = h("textarea.source", { spellcheck: "false", rows: 1, readonly: !writable });
      area.value = sourceOf(cell);
      const fit = () => { area.style.height = "auto"; area.style.height = area.scrollHeight + 2 + "px"; };
      area.addEventListener("input", () => { cell.source = area.value; fit(); doc.changed(); });
      area.addEventListener("focus", () => { if (selected !== i) { selected = i; markSelected(); } });
      area.addEventListener("keydown", (e) => keys(e, cell, i, area));
      body.appendChild(area);
      setTimeout(fit, 0);
      if (editing === cell) setTimeout(() => area.focus(), 0);
    } else {
      const shown = h("div.rendered", { ondblclick: () => { if (writable) { editing = cell; render(); } } });
      body.appendChild(shown);
      const text = sourceOf(cell);
      if (text.trim()) call("markdown", { text }).then((html) => { shown.replaceChildren(sanitize(html)); }).catch(() => { shown.textContent = text; });
    }
    if (code && (cell.outputs || []).length) body.appendChild(h("div.outputs", cell.outputs.map(renderOutput)));
    return h("div.cell" + (code ? ".code" : ".markdown") + (i === selected ? ".on" : ""), {
      "data-index": i, onmousedown: () => { if (selected !== i) { selected = i; markSelected(); } },
    },
      h("div.prompt", prompt), body,
      h("div.cell-tools",
        code ? h("button.icon", { title: "Run (⇧↩)", onclick: () => run(cell) }, "▶") : null,
        h("button.icon", { title: code ? "Make Markdown" : "Make Code", onclick: () => { cell.cell_type = code ? "markdown" : "code"; if (code) { delete cell.outputs; delete cell.execution_count; } else { cell.outputs = []; cell.execution_count = null; } changed(); } }, code ? "M" : "{}"),
        h("button.icon", { title: "Move Up", onclick: () => move(i, -1), disabled: i === 0 }, "↑"),
        h("button.icon", { title: "Move Down", onclick: () => move(i, 1), disabled: i === nb.cells.length - 1 }, "↓"),
        h("button.icon", { title: "Insert Below", onclick: () => insert(i + 1, "code") }, "+"),
        h("button.icon", { title: "Delete", onclick: () => remove(i) }, "×")));
  }

  function markSelected() {
    for (const el of cellsEl.querySelectorAll(":scope > .cell")) el.classList.toggle("on", +el.dataset.index === selected);
  }

  function renderOutput(o) {
    if (o.output_type === "stream") return h("div.output." + (o.name === "stderr" ? "stderr" : "stdout"), strip(joined(o.text)));
    if (o.output_type === "error") return h("div.output.error", strip((o.traceback || []).join("\n")) || `${o.ename}: ${o.evalue}`);
    const data = o.data || {};
    if (data["image/png"]) return h("div.output", h("img", { src: "data:image/png;base64," + joined(data["image/png"]).replace(/\s/g, "") }));
    if (data["image/jpeg"]) return h("div.output", h("img", { src: "data:image/jpeg;base64," + joined(data["image/jpeg"]).replace(/\s/g, "") }));
    if (data["image/svg+xml"]) return h("div.output", h("img", { src: "data:image/svg+xml;charset=utf-8," + encodeURIComponent(joined(data["image/svg+xml"])) }));
    if (data["text/html"]) { const el = h("div.output.html"); el.appendChild(sanitize(joined(data["text/html"]))); return el; }
    if (data["text/markdown"]) {
      const el = h("div.output.html");
      call("markdown", { text: joined(data["text/markdown"]) }).then((html) => el.appendChild(sanitize(html)));
      return el;
    }
    if (data["text/plain"] !== undefined) return h("div.output", strip(joined(data["text/plain"])));
    if (data["application/json"]) return h("div.output", JSON.stringify(data["application/json"], null, 2));
    return h("div.output", "(" + Object.keys(data).join(", ") + ")");
  }

  // MARK: Editing

  function changed() { render(); doc.changed(); }

  function insert(at, type) {
    const cell = type === "code" ? { cell_type: "code", id: newID(), metadata: {}, source: "", outputs: [], execution_count: null }
      : { cell_type: "markdown", id: newID(), metadata: {}, source: "" };
    nb.cells.splice(at, 0, cell);
    selected = at;
    editing = type === "markdown" ? cell : null;
    changed();
    if (type === "code") setTimeout(() => cellsEl.querySelector(`:scope > .cell[data-index="${at}"] textarea`)?.focus(), 0);
  }

  function move(i, by) {
    const to = i + by;
    if (to < 0 || to >= nb.cells.length) return;
    const [c] = nb.cells.splice(i, 1);
    nb.cells.splice(to, 0, c);
    selected = to;
    changed();
  }

  function remove(i) {
    nb.cells.splice(i, 1);
    if (!nb.cells.length) nb.cells.push({ cell_type: "code", id: newID(), metadata: {}, source: "", outputs: [], execution_count: null });
    selected = Math.min(i, nb.cells.length - 1);
    changed();
  }

  function keys(e, cell, i, area) {
    if (e.key === "Enter" && (e.shiftKey || e.metaKey)) {
      e.preventDefault();
      if (cell.cell_type === "code") run(cell);
      if (cell.cell_type === "markdown") { editing = null; render(); }
      // ⇧↩ goes on to the next cell (a new one at the end).
      if (e.shiftKey) {
        if (i === nb.cells.length - 1) insert(nb.cells.length, "code");
        else { selected = i + 1; render(); setTimeout(() => cellsEl.querySelector(`:scope > .cell[data-index="${i + 1}"] textarea`)?.focus(), 0); }
      }
    } else if (e.key === "Tab" && !e.shiftKey) {
      e.preventDefault();
      area.setRangeText("    ", area.selectionStart, area.selectionEnd, "end");
      cell.source = area.value;
      doc.changed();
    } else if (e.key === "Escape" && editing === cell) {
      editing = null;
      render();
    }
  }

  // MARK: Running

  async function ensureKernel() {
    if (kernel.state === "idle" || kernel.state === "busy") return true;
    if (kernel.state === "dead") kernel.state = "off";
    if (kernel.state === "starting") return kernel.ready;
    kernel.state = "starting";
    showKernel();
    kernel.ready = call("kernelStart", { kernel: nb.metadata?.kernelspec?.name || "" }).then((k) => {
      kernel = { state: "idle", name: k.kernel || "kernel" };
      showKernel();
      return true;
    }).catch((e) => {
      kernel = { state: "off", name: "" };
      showKernel();
      showBanner(String(e.message || e));
      return false;
    });
    return kernel.ready;
  }

  async function run(cell) {
    if (cell.cell_type !== "code") return;
    if (!(await ensureKernel())) return;
    cell.outputs = [];
    cell.execution_count = null;
    let id;
    try { id = await call("execute", { code: sourceOf(cell) }); } catch (e) { return toast(String(e.message || e), true); }
    running.set(id, cell);
    refreshOutputs(cell);
  }

  async function runAll() {
    for (const c of nb.cells) if (c.cell_type === "code") await run(c);
  }

  async function restart() {
    if (kernel.state === "off") return;
    try {
      await call("restart");
      running.clear();
      toast("Restarted");
    } catch (e) { toast(String(e.message || e), true); }
    render();
  }

  async function kernelCall(method) {
    try { await call(method); } catch (e) { toast(String(e.message || e), true); }
  }

  // A cleared output waits for the next one (`clear_output(wait=True)`).
  const clearPending = new Set();

  block.on("kernel", (m) => {
    if (m.type === "status") {
      const state = m.content.execution_state;
      if (state === "busy" || state === "idle") { kernel.state = state; showKernel(); }
      if (state === "idle" && running.has(m.parent)) { const cell = running.get(m.parent); running.delete(m.parent); refreshOutputs(cell); }
      if (state === "dead") { kernel.state = "dead"; showKernel(); }
      return;
    }
    const cell = running.get(m.parent);
    if (!cell) return;
    const c = m.content || {};
    const out = cell.outputs || (cell.outputs = []);
    const add = (o) => { if (clearPending.has(cell)) { out.length = 0; clearPending.delete(cell); } out.push(o); };
    switch (m.type) {
      case "execute_input": cell.execution_count = c.execution_count; break;
      case "stream": {
        const last = out[out.length - 1];
        if (last && last.output_type === "stream" && last.name === c.name && !clearPending.has(cell)) last.text = joined(last.text) + c.text;
        else add({ output_type: "stream", name: c.name, text: c.text });
        break;
      }
      case "execute_result": add({ output_type: "execute_result", data: c.data, metadata: c.metadata || {}, execution_count: c.execution_count }); cell.execution_count = c.execution_count; break;
      case "display_data": add({ output_type: "display_data", data: c.data, metadata: c.metadata || {} }); break;
      case "error": add({ output_type: "error", ename: c.ename, evalue: c.evalue, traceback: c.traceback || [] }); break;
      case "clear_output": if (c.wait) clearPending.add(cell); else out.length = 0; break;
      case "execute_reply": if (c.execution_count) cell.execution_count = c.execution_count; break;
      default: return;
    }
    refreshOutputs(cell);
    doc.changed();
  });

  // One cell's prompt and outputs drawn again (not the page: a cell being
  // typed in elsewhere keeps its cursor while output streams).
  function refreshOutputs(cell) {
    const i = nb.cells.indexOf(cell);
    const el = cellsEl.querySelector(`:scope > .cell[data-index="${i}"]`);
    if (!el) return;
    const isRunning = [...running.values()].includes(cell);
    el.querySelector(".prompt").textContent = isRunning ? "[*]" : cell.execution_count ? `[${cell.execution_count}]` : "[ ]";
    el.querySelector(".outputs")?.remove();
    if ((cell.outputs || []).length) el.querySelector(".body").appendChild(h("div.outputs", cell.outputs.map(renderOutput)));
  }
  block.on("kernelError", (e) => { kernel.state = "dead"; showKernel(); showBanner(e.message); });
  // The tab closed (and came back): the kernel is gone; Run starts another.
  block.on("kernelStopped", () => { kernel = { state: "off", name: "" }; running.clear(); render(); });

  function showBanner(text, buttons = []) {
    clear(banner, h("span", text), buttons, h("button.icon", { title: "Dismiss", onclick: () => { banner.hidden = true; } }, "×"));
    banner.hidden = false;
  }

  // MARK: Saving

  const doc = block.fileDoc({
    delay: 800,
    serialize: () => nb ? serialize() : "",
    apply(file, { first }) {
      nb = parse(file.text);
      writable = file.writable;
      clear(title, file.name);
      if (first) selected = 0;
      render();
    },
    onConflict(keep, take) {
      showBanner("The file changed on disk since it was read here: saving now replaces that change.", [
        h("button.button", { onclick: () => { banner.hidden = true; keep(); } }, "Keep Mine"),
        h("button.button.quiet", { onclick: () => { banner.hidden = true; take(); } }, "Use the File's")]);
    },
  });
  block.on("save", async ({ id }) => { const ok = await doc.save(); call("saveDone", { ok, id }); });
  block.on("fileChanged", () => doc.external().catch(() => {}));

  window.libertty_notebook = { get nb() { return nb; }, get kernel() { return kernel; }, run, runAll, save: () => doc.save() };
  doc.load().catch((e) => clear(cellsEl, h("div.empty", "Couldn't read the notebook: " + String(e.message || e))));
  call("jupyter").then((j) => { if (!j.found) showBanner("No jupyter found: cells can be edited, not run. Install it (pip install jupyter_server ipykernel), or set jupyter = /path/to/jupyter in the config."); });
})();
