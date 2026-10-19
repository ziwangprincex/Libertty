// The profiler's page (Libertty's own code): pick a process (one running in
// a terminal, or any pid of yours), record it with `sample` for a few
// seconds, and the report opens as a flame graph. Names come in as text.
(function () {
  const { h, clear, toast, ago } = block;
  const call = block.call.bind(block);
  const app = document.getElementById("app");

  const state = { targets: [], pid: null, seconds: 5, recording: null, recent: [] };

  const pidField = h("input.field", { type: "text", placeholder: "pid", inputmode: "numeric" });
  const chips = h("div.chips", { style: "padding:0" });
  const recordButton = h("button.button.primary", { onclick: () => record() }, "Record");
  const stopButton = h("button.button", { onclick: () => call("stop"), hidden: true }, "Stop");
  const countdown = h("span.countdown");
  const targetList = h("div.list");
  const recentList = h("div.list");
  app.append(
    h("div.bar", h("span.title", "Profiler"), h("span.spacer"),
      h("button.button.quiet", { onclick: () => call("reveal") }, "Show Profiles in Finder")),
    h("div.page",
      h("div",
        h("div.section-head", "Record"),
        h("div.record-row", pidField, chips, recordButton, stopButton, countdown),
        h("div.hint", "macOS's sample: every thread's stack, each millisecond. Your own processes only.")),
      h("div", h("div.section-head", "In your terminals"), targetList),
      h("div", h("div.section-head", "Recent profiles"), recentList)));

  pidField.addEventListener("input", () => { state.pid = parseInt(pidField.value, 10) || null; render(); });
  pidField.addEventListener("keydown", (e) => { if (e.key === "Enter") record(); });

  function render() {
    clear(chips, [3, 5, 10, 30].map((s) => h("button.chip" + (state.seconds === s ? ".on" : ""), {
      onclick: () => { state.seconds = s; render(); },
    }, s + " s")));
    recordButton.disabled = !state.pid || !!state.recording;
    stopButton.hidden = !state.recording;
    if (String(state.pid || "") !== pidField.value) pidField.value = state.pid || "";
    clear(targetList, state.targets.length ? state.targets.map((t) => h("div.row" + (t.pid === state.pid ? ".on" : ""), {
      title: t.terminal, onclick: () => { state.pid = t.pid; render(); }, ondblclick: () => { state.pid = t.pid; record(); },
      "data-name": t.name,
    }, h("span.mark", "›"), h("span.main", t.name, h("span.sub", "  " + t.terminal)), h("span.meta", String(t.pid))))
      : h("div.empty", "Nothing is running in this window's terminals. Start something, or type a pid."));
    clear(recentList, state.recent.length ? state.recent.map((r) => h("div.row", {
      title: r.path, onclick: () => call("open", { path: r.path }), "data-name": r.name,
    }, h("span.mark", "≋"), h("span.main", r.name), h("span.meta", ago(r.time)),
      h("span.actions", h("button.icon", { title: "Move to Trash", onclick: (e) => { e.stopPropagation(); remove(r); } }, "×"))))
      : h("div.empty", "No profiles yet."));
  }

  async function record() {
    if (!state.pid || state.recording) return;
    const seconds = state.seconds;
    let left = seconds;
    state.recording = setInterval(() => { left = Math.max(0, left - 1); clear(countdown, left ? left + " s" : "reading…"); }, 1000);
    clear(countdown, left + " s");
    render();
    try {
      await call("record", { pid: state.pid, seconds });
      toast("Recorded");
    } catch (e) {
      toast(String(e.message || e), true);
    } finally {
      clearInterval(state.recording);
      state.recording = null;
      clear(countdown);
      await refresh();
    }
  }

  async function remove(r) {
    try { await call("remove", { path: r.path }); } catch (e) { toast(String(e.message || e), true); }
    refresh();
  }

  async function refresh() {
    try {
      [state.targets, state.recent] = await Promise.all([call("targets"), call("recent")]);
    } catch (e) { toast(String(e.message || e), true); }
    render();
  }

  setInterval(() => { if (!document.hidden && !state.recording) refresh(); }, 3000);
  window.addEventListener("focus", refresh);
  call("start").then((s) => { if (s.pid) state.pid = s.pid; render(); });
  render();
  refresh();
})();
