// The Plugins block's page (Libertty's own code): the plugins in the
// config folder, each switched on or off, with its commands and its log.
(function () {
  const { h, clear, toast, dialog } = block;
  const call = block.call.bind(block);
  const app = document.getElementById("app");

  const state = { list: null, selected: null };
  const side = h("div.side"), detail = h("div.detail");
  app.append(h("div.bar", h("span.title", "Plugins"), h("span.spacer"),
    h("button.button.quiet", { onclick: () => create() }, "New Plugin…"),
    h("button.button.quiet", { onclick: () => call("reveal") }, "Show Plugins Folder"),
    h("button.icon", { title: "Look Again", onclick: () => call("rescan").then(refresh) }, "↻")),
    h("div.columns", side, detail));

  const API = `libertty.command("Title", () => …)     a command in the palette
libertty.on("commandFinished", (e) => …)  e: command, exitCode, duration, cwd
libertty.notify(title, body)
libertty.send(text)          typed into the focused terminal ("\\n" runs it)
libertty.open(pathOrURL)     a file (from the terminal's folder) or a page
libertty.cwd()               the focused terminal's folder
libertty.screen(lines)       its last lines of text
libertty.storage.get(key) / .set(key, value)
console.log(…), setTimeout, setInterval`;

  function render() {
    const list = state.list;
    if (!list) return clear(side, h("div.empty", "Reading…"));
    const plugins = list.plugins;
    clear(side, h("div.section-head", "Installed", h("span.count", plugins.length)),
      plugins.length ? plugins.map((p) => h("div.row" + (state.selected === p.name ? ".on" : ""), {
        onclick: () => { state.selected = p.name; render(); }, "data-name": p.name, title: p.file,
      },
        h("input.switch", { type: "checkbox", checked: p.enabled, title: p.enabled ? "Turn Off" : "Turn On",
          onclick: (e) => e.stopPropagation(), onchange: (e) => enable(p, e.target.checked) }),
        h("span.main", p.title, p.failure ? h("span.sub", "  failed") : p.running ? h("span.sub", "  " + p.commands.length + " command" + (p.commands.length === 1 ? "" : "s")) : null),
        h("span.meta", p.version)))
      : h("div.empty", "No plugins yet. New Plugin… makes one from a template, in " + list.folder + "."));
    const p = plugins.find((x) => x.name === state.selected);
    if (!p) return clear(detail, h("h2", "Plugins"), h("div.about", "JavaScript that adds commands and reacts to what terminals do. Each runs on its own, with only this:"),
      h("div.api", API));
    clear(detail,
      h("h2", p.title), h("div.about", p.description || p.file),
      h("div.state-line" + (p.failure ? ".failed" : ""), p.failure ? "Failed: " + p.failure : p.running ? "Running" : p.enabled ? "Starting…" : "Off — a plugin runs once it's turned on"),
      h("div.buttons", { style: "margin-top:10px" },
        h("button.button", { onclick: () => enable(p, !p.enabled) }, p.enabled ? "Turn Off" : "Turn On"),
        p.enabled ? h("button.button", { onclick: () => call("reload", { name: p.name }).then(refresh) }, "Reload") : null,
        h("button.button", { onclick: () => call("edit", { name: p.name }) }, "Edit")),
      p.commands.length ? [h("div.section-head", "Commands (in the palette)"), p.commands.map((c) => h("div.row", h("span.mark", "›"), h("span.main", c)))] : null,
      h("div.section-head", "Log"),
      p.log.length ? h("div.log", p.log.map((l) => h("div.line." + l.level, h("span.time", l.time.slice(11, 19)), l.text)))
        : h("div.empty", "Nothing logged."));
  }

  async function enable(p, on) {
    try { await call("enable", { name: p.name, on }); } catch (e) { toast(String(e.message || e), true); }
    state.selected = p.name;
    refresh();
  }

  async function create() {
    const title = await dialog({ title: "New plugin", message: "A folder with plugin.json and main.js, opened in the editor. It runs once you turn it on.", field: { placeholder: "name" }, ok: "Create" });
    if (!title || !title.trim()) return;
    try { await call("create", { title: title.trim() }); } catch (e) { toast(String(e.message || e), true); }
    refresh();
  }

  async function refresh() {
    try { state.list = await call("list"); } catch (e) { toast(String(e.message || e), true); }
    if (!state.selected && state.list?.plugins.length) state.selected = state.list.plugins[0].name;
    render();
  }

  let soon = null;
  block.on("changed", () => { clearTimeout(soon); soon = setTimeout(refresh, 100); });
  render();
  refresh();
})();
