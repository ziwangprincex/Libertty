// The SQLite block's page (Libertty's own code): tables and views on the
// left; a table's rows (a page at a time, sorted by a column), its
// structure, or a query's result on the right. Cells go in as text.
(function () {
  const { h, clear, toast, dialog } = block;
  const call = block.call.bind(block);
  const app = document.getElementById("app");

  const state = {
    db: null, objects: [], selected: null, view: "data", // data | structure | query
    data: null, page: 0, sort: null, desc: false, structure: null, result: null, running: false,
  };

  const title = h("span.title");
  const lock = h("span.lock");
  const writeButton = h("button.button.quiet", { onclick: () => toggleWrite() });
  const chips = h("div.chips", { style: "padding:0" });
  const side = h("div.side");
  const body = h("div.main-pane");
  app.append(h("div.bar", title, lock, chips, h("span.spacer"), writeButton,
    h("button.icon", { title: "Refresh", onclick: () => reload() }, "↻"),
    h("button.button.quiet", { onclick: () => call("reveal") }, "Show in Finder")),
    h("div.columns", side, body));

  const sql = h("textarea", { placeholder: "SELECT … (⌘↩ runs; several statements run in order)", spellcheck: "false" });
  sql.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.metaKey) { e.preventDefault(); runQuery(); } });

  function cell(value, type) {
    if (value === null) return h("td.null", "NULL");
    if (typeof value === "object" && value.blob !== undefined) return h("td.blob", { title: value.head }, `BLOB ${value.blob} B`);
    // Cut for the grid: shown, never edited from here (its whole text isn't here).
    if (typeof value === "object" && value.cut !== undefined) return h("td", { title: `Too long to edit here (${value.cut} bytes)` }, value.text);
    if (typeof value === "number") return h("td.num", String(value));
    return h("td", { title: value.length > 60 ? value.slice(0, 2000) : null }, value);
  }

  function grid({ columns, types, rows, rowids, offset = 0, sortable, editable, table }) {
    if (!columns.length) return h("div.empty", "No columns.");
    const head = h("tr", h("th", ""), columns.map((c, i) => h("th" + (sortable ? ".sortable" : ""), {
      onclick: sortable ? () => sortBy(c) : null, "data-column": c,
    }, c, types[i] ? h("span.type", types[i]) : null, state.sort === c && sortable ? (state.desc ? " ↓" : " ↑") : "")));
    const lines = rows.map((row, r) => h("tr", h("td.rownum", String(offset + r + 1)),
      row.map((v, i) => {
        const td = cell(v, types[i]);
        if (editable) td.addEventListener("dblclick", () => editCell(td, table, columns[i], rowids[r], v));
        return td;
      })));
    return h("table.grid", h("thead", head), h("tbody", lines));
  }

  function render() {
    const db = state.db;
    if (!db) return;
    clear(title, db.name);
    clear(lock, db.writable ? "changes allowed" : "read-only");
    clear(writeButton, db.writable ? "Read Only" : "Allow Changes");
    writeButton.hidden = !db.canWrite;
    clear(chips, [["data", "Data"], ["structure", "Structure"], ["query", "Query"]].map(([id, name]) =>
      h("button.chip" + (state.view === id ? ".on" : ""), { onclick: () => { state.view = id; render(); load(); } }, name)));
    const tables = state.objects.filter((o) => o.type === "table"), views = state.objects.filter((o) => o.type === "view");
    const row = (o) => h("div.row" + (state.selected === o.name ? ".on" : ""), {
      onclick: () => select(o.name), title: o.name, "data-name": o.name,
    }, h("span.mark", o.type === "view" ? "◇" : "▦"), h("span.main", o.name),
      h("span.meta", o.count === null ? "" : o.count > 100000 ? "100k+" : String(o.count)));
    clear(side,
      h("div.section-head", "Tables", h("span.count", tables.length)), tables.map(row),
      views.length ? [h("div.section-head", "Views", h("span.count", views.length)), views.map(row)] : null,
      !state.objects.length ? h("div.empty", "No tables yet.") : null);
    if (state.view === "query") return renderQuery();
    if (!state.selected) return clear(body, h("div.empty", "Pick a table or view, or write a query."));
    if (state.view === "structure") return renderStructure();
    renderData();
  }

  function renderData() {
    const d = state.data;
    if (!d) return clear(body, h("div.empty", "Reading…"));
    const offset = d.page * 200;
    clear(body,
      h("div.grid-wrap", d.rows.length ? grid({ ...d, offset, sortable: true, table: state.selected }) : h("div.empty", "No rows.")),
      h("div.pager",
        h("span", d.rows.length ? `Rows ${offset + 1}–${offset + d.rows.length}` : ""),
        d.editable ? h("span", "· double-click a cell to edit it") : null,
        h("span.spacer"),
        h("button.button.quiet", { disabled: d.page === 0, onclick: () => { state.page--; load(); } }, "‹ Previous"),
        h("button.button.quiet", { disabled: !d.more, onclick: () => { state.page++; load(); } }, "Next ›")));
  }

  function renderStructure() {
    const s = state.structure;
    if (!s) return clear(body, h("div.empty", "Reading…"));
    clear(body, h("div.structure",
      s.columns.length ? h("table.grid", h("thead", h("tr", ["Column", "Type", "Not null", "Default", "Key"].map((x) => h("th", x)))),
        h("tbody", s.columns.map((c) => h("tr", h("td", c.name), h("td", c.type || ""), h("td", c.notNull ? "yes" : ""),
          c.default === null ? h("td.null", "") : h("td", String(c.default)), h("td", c.primaryKey ? "primary" : ""))))) : null,
      h("div.section-head", "Definition"), h("pre", s.sql || "—"),
      s.indexes.length ? [h("div.section-head", "Indexes"), s.indexes.map((i) => h("pre", i.sql || i.name + " (automatic)"))] : null));
  }

  function renderQuery() {
    const r = state.result;
    const status = state.running ? "Running…" : r ? (r.columns.length
      ? `${r.rows.length}${r.truncated ? "+" : ""} row${r.rows.length === 1 ? "" : "s"}${r.truncated ? ` (the first ${r.limit})` : ""} · ${r.ms} ms`
      : `Done · ${r.changes} row${r.changes === 1 ? "" : "s"} changed · ${r.ms} ms`) : "";
    clear(body,
      h("div.query-box", sql, h("div.query-row",
        h("span.status", status), h("span.spacer"),
        state.running ? h("button.button", { onclick: () => call("stop") }, "Stop") : null,
        h("button.button.primary", { onclick: () => runQuery(), disabled: state.running }, "Run"))),
      h("div.grid-wrap", r && r.columns.length ? grid({ ...r, rowids: [] }) : null));
  }

  // MARK: Doing things

  async function select(name) {
    state.selected = name;
    state.page = 0;
    state.sort = null;
    state.desc = false;
    if (state.view === "query") state.view = "data";
    render();
    load();
  }

  function sortBy(column) {
    if (state.sort === column) state.desc = !state.desc; else { state.sort = column; state.desc = false; }
    state.page = 0;
    load();
  }

  async function load() {
    try {
      if (state.view === "data" && state.selected) {
        state.data = await call("rows", { name: state.selected, page: state.page, sort: state.sort, desc: state.desc });
      } else if (state.view === "structure" && state.selected) {
        state.structure = await call("structure", { name: state.selected });
      }
    } catch (e) { toast(String(e.message || e), true); }
    render();
  }

  async function runQuery() {
    if (state.running || !sql.value.trim()) return;
    state.running = true;
    render();
    try {
      state.result = await call("query", { sql: sql.value });
      // A statement may have made or dropped a table.
      if (state.result.changes || /\b(create|drop|alter)\b/i.test(sql.value)) state.objects = await call("objects");
    } catch (e) { toast(String(e.message || e), true); }
    state.running = false;
    render();
    sql.focus();
  }

  function editCell(td, table, column, rowid, value) {
    if (value !== null && typeof value === "object") {
      return toast(value.blob !== undefined ? "A blob can't be edited here." : "That cell is too long to edit here.", true);
    }
    const input = h("input", { type: "text", value: value === null ? "" : String(value), placeholder: value === null ? "NULL" : "" });
    td.classList.add("editing");
    clear(td, input);
    input.focus();
    input.select();
    let done = false;
    const finish = async (save) => {
      if (done) return;
      done = true;
      if (save && input.value !== (value === null ? "" : String(value))) {
        try {
          // Numbers stay numbers: the page sends them as themselves, not as text.
          const typed = input.value.trim();
          const number = typed !== "" && !Number.isNaN(Number(typed)) && String(Number(typed)) === typed.replace(/^\+/, "");
          await call("update", { name: table, column, rowid, value: number ? Number(typed) : input.value });
          toast("Saved");
        } catch (e) { toast(String(e.message || e), true); }
      }
      load();
    };
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); finish(true); }
      if (e.key === "Escape") { e.preventDefault(); finish(false); }
    });
    input.addEventListener("blur", () => finish(true));
  }

  async function toggleWrite() {
    if (!state.db.writable) {
      const ok = await dialog({ title: "Allow changes?", message: "Edits and statements that change data go straight into the file. There's no undo; a backup first is wise.", ok: "Allow Changes" });
      if (!ok) return;
    }
    await open(!state.db.writable);
  }

  async function open(write) {
    try {
      state.db = await call("open", { write });
      state.objects = state.db.objects;
    } catch (e) { return clear(body, h("div.empty", String(e.message || e))); }
    if (state.selected && !state.objects.some((o) => o.name === state.selected)) state.selected = null;
    render();
    load();
  }

  async function reload() {
    try { state.objects = await call("objects"); } catch (e) { toast(String(e.message || e), true); }
    load();
  }

  window.libertty_sqlite = { get state() { return state; }, runQuery, select };
  open(false);
})();
