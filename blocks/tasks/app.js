// The task manager's page (Libertty's own code): a table of processes, read
// every two seconds while it's in view. Names come in as text.
(function () {
  const { h, clear, toast, dialog } = block;
  const call = block.call.bind(block);
  const app = document.getElementById("app");

  const state = {
    scope: "mine", // mine | terminals | all
    sort: "cpu", desc: true,
    query: "",
    data: null,
    selected: null, // pid
    details: null,
  };

  const summary = h("span.summary");
  const search = h("input.field.search", { type: "search", placeholder: "Filter by name or pid" });
  const chips = h("div.chips", { style: "padding:0" });
  const bar = h("div.bar", h("span.title", "Tasks"), chips, h("span.spacer"), summary, search);
  const tableWrap = h("div.table-wrap");
  const detail = h("div.detail", { hidden: true });
  app.append(bar, h("div.columns", tableWrap, detail));

  search.addEventListener("input", () => { state.query = search.value.trim().toLowerCase(); render(); });

  const columns = [
    ["name", "Name", true], ["cpu", "% CPU"], ["mem", "Memory"], ["threads", "Threads"], ["pid", "PID"],
  ];

  function bytes(n) {
    if (!n) return "—";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return (i >= 2 ? n.toFixed(n < 10 ? 1 : 0) : Math.round(n)) + " " + units[i];
  }

  function visible() {
    const d = state.data;
    if (!d) return [];
    let rows = d.processes;
    if (state.scope === "mine") rows = rows.filter((p) => p.mine);
    if (state.scope === "terminals") rows = rows.filter((p) => p.pane);
    if (state.query) rows = rows.filter((p) => p.name.toLowerCase().includes(state.query) || String(p.pid) === state.query
      || (p.terminal || "").toLowerCase().includes(state.query));
    const key = state.sort, dir = state.desc ? -1 : 1;
    rows = rows.slice().sort((a, b) => {
      const x = a[key], y = b[key];
      if (typeof x === "string") return dir * x.localeCompare(y);
      // Unknown (another user's CPU) sorts below every known value.
      if (x === null || y === null) return (x === null) - (y === null) || a.pid - b.pid;
      return dir * ((x || 0) - (y || 0)) || a.pid - b.pid;
    });
    return rows;
  }

  function render() {
    const d = state.data;
    clear(chips, [["mine", "Mine"], ["terminals", "In Terminals"], ["all", "All"]].map(([id, name]) =>
      h("button.chip" + (state.scope === id ? ".on" : ""), { onclick: () => { state.scope = id; render(); } }, name)));
    if (!d) return clear(tableWrap, h("div.empty", "Reading…"));
    const used = d.processes.reduce((s, p) => s + (p.mine ? p.mem : 0), 0);
    clear(summary, `CPU ${d.first ? "…" : Math.round(d.load) + "%"} of ${d.cores} cores · your processes ${bytes(used)} of ${bytes(d.memory)}`);
    const rows = visible();
    const maxCPU = 100;
    const head = h("tr", columns.map(([key, label, left]) => h("th" + (left ? ".left" : "") + (state.sort === key ? ".sorted" : ""), {
      onclick: () => { if (state.sort === key) state.desc = !state.desc; else { state.sort = key; state.desc = key !== "name"; } render(); },
    }, label, state.sort === key ? (state.desc ? " ↓" : " ↑") : "")));
    const body = rows.slice(0, 600).map((p) => h("tr" + (p.pid === state.selected ? ".on" : "") + (p.mine ? "" : ".theirs"), {
      onclick: () => select(p.pid), title: p.terminal ? "In " + p.terminal : p.name, "data-name": p.name,
    },
      h("td.left", p.name, p.terminal ? h("span.pane", "▸ " + p.terminal) : null),
      h("td.num.bar-cell", p.cpu === null ? "—" : d.first ? "…" : p.cpu.toFixed(1),
        h("span.meter", h("i", { style: `width:${Math.min(100, ((p.cpu || 0) / maxCPU) * 100)}%` }))),
      h("td.num", p.mine ? bytes(p.mem) : "—"),
      h("td.num", p.threads || "—"),
      h("td.num", p.pid)));
    const top = tableWrap.scrollTop;
    clear(tableWrap, h("table", h("thead", head), h("tbody", body)),
      rows.length > 600 ? h("div.empty", `${rows.length - 600} more — filter to find them`) : null,
      !rows.length ? h("div.empty", state.query ? "Nothing matches." : "No processes here.") : null);
    tableWrap.scrollTop = top;
    renderDetail();
  }

  async function select(pid) {
    state.selected = pid;
    state.details = null;
    render();
    let details = null;
    try { details = await call("details", { pid }); } catch (e) { details = null; }
    // A slower answer for the one picked before doesn't land on this one.
    if (state.selected !== pid) return;
    state.details = details;
    renderDetail();
  }

  // Drawn again only when something in it changed: every two seconds would
  // drop a selection being made in it (to copy the command or folder).
  let shownDetail = null;

  function renderDetail() {
    const p = state.data?.processes.find((x) => x.pid === state.selected);
    detail.hidden = !state.selected;
    if (!state.selected) { shownDetail = null; return; }
    const x = state.details?.pid === p?.pid ? state.details : null;
    const key = JSON.stringify([p, x, state.data?.self]);
    if (key === shownDetail) return;
    shownDetail = key;
    if (!p) return clear(detail, h("div.empty", "That process has ended."));
    const started = p.started ? new Date(p.started * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "—";
    const parent = state.data.processes.find((q) => q.pid === p.ppid);
    clear(detail,
      h("h2", p.name), h("div.pid", "PID " + p.pid + (parent ? ` · parent ${parent.name} (${parent.pid})` : "")),
      h("dl",
        h("dt", "CPU"), h("dd", p.cpu === null ? "—" : p.cpu.toFixed(1) + "%"),
        h("dt", "Memory"), h("dd", p.mine ? bytes(p.mem) : "—"),
        h("dt", "Threads"), h("dd", String(p.threads || "—")),
        h("dt", "Started"), h("dd", started),
        p.terminal ? [h("dt", "Terminal"), h("dd", p.terminal)] : null,
        x?.path ? [h("dt", "Program"), h("dd.mono", x.path)] : null,
        x?.command ? [h("dt", "Command"), h("dd.mono", x.command)] : null,
        x?.cwd ? [h("dt", "Folder"), h("dd.mono", x.cwd)] : null,
        x?.ports?.length ? [h("dt", "Listening"), h("dd", x.ports.map((port) =>
          h("button.button.quiet", { onclick: () => call("openPort", { port }), title: "Open localhost:" + port + " in a browser" }, ":" + port)))] : null),
      h("div.buttons",
        p.pane ? h("button.button", { onclick: () => call("reveal", { pane: p.pane }) }, "Show Terminal") : null,
        x?.cwd ? h("button.button", { onclick: () => call("openFolder", { path: x.cwd }) }, "Open Folder") : null,
        p.mine && p.known ? h("button.button", { onclick: () => call("profile", { pid: p.pid }) }, "Profile…") : null,
        p.mine && p.pid !== state.data.self ? h("button.button", { onclick: () => signal(p, "TERM") }, "Quit") : null,
        p.mine && p.pid !== state.data.self ? h("button.button.danger", { onclick: () => signal(p, "KILL") }, "Force Quit") : null));
  }

  async function signal(p, name) {
    const ok = await dialog({
      title: (name === "KILL" ? "Force quit " : "Quit ") + p.name + "?",
      message: name === "KILL" ? "It stops at once, without saving anything." : "It's asked to finish (SIGTERM); a program may save first, or ignore it.",
      ok: name === "KILL" ? "Force Quit" : "Quit", danger: name === "KILL",
    });
    if (!ok) return;
    try {
      await call("signal", { pid: p.pid, signal: name, started: p.started });
      toast(name === "KILL" ? "Force quit " + p.name : "Asked " + p.name + " to quit");
    } catch (e) { toast(String(e.message || e), true); }
    setTimeout(refresh, 300);
  }

  // One look at a time: the timer, a tab shown again and a Quit's refresh may coincide.
  let reading = false;
  async function refresh() {
    if (reading) return;
    reading = true;
    try {
      state.data = await call("list");
      if (state.data.first) { setTimeout(refresh, 500); }
    } catch (e) { return toast(String(e.message || e), true); } finally { reading = false; }
    render();
  }

  // Every two seconds while it shows (a tab in the back costs nothing).
  setInterval(() => { if (!document.hidden) refresh(); }, 2000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
  render();
  refresh();
})();
