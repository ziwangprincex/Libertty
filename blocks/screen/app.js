// The screen block's page (Libertty's own code): a display or a window of
// this Mac, captured by the native side (ScreenCaptureKit) and shown here
// frame by frame. Window names come in as text.
(function () {
  const { h, clear, toast } = block;
  const call = block.call.bind(block);
  const app = document.getElementById("app");

  const state = { sources: null, picked: null, fps: 10, live: null, actual: false, frames: 0, since: 0 };
  const chips = h("div.chips", { style: "padding:0" });
  const startButton = h("button.button.primary", { onclick: () => start() }, "Show");
  const stopButton = h("button.button", { onclick: () => stop(), hidden: true }, "Stop");
  const sizeButton = h("button.button.quiet", { onclick: () => { state.actual = !state.actual; render(); } });
  const side = h("div.side");
  const image = h("img", { alt: "" });
  const stats = h("div.stats", { hidden: true });
  const stage = h("div.stage", h("div.empty", "Pick a display or a window."));
  app.append(h("div.bar", h("span.title", "Screen"), chips, h("span.spacer"), sizeButton, stopButton, startButton,
    h("button.icon", { title: "Look Again", onclick: () => load() }, "↻")),
    h("div.columns", side, stage));

  function render() {
    clear(chips, [5, 10, 15, 30].map((n) => h("button.chip" + (state.fps === n ? ".on" : ""), {
      onclick: () => { state.fps = n; render(); if (state.live) start(); },
    }, n + " fps")));
    clear(sizeButton, state.actual ? "Fit" : "Actual Size");
    stage.classList.toggle("actual", state.actual);
    startButton.disabled = !state.picked;
    stopButton.hidden = !state.live;
    const s = state.sources;
    if (!s) return clear(side, h("div.empty", "Reading…"));
    const row = (src) => h("div.row" + (state.picked && state.picked.id === src.id && state.picked.kind === src.kind ? ".on" : ""), {
      title: src.name, "data-kind": src.kind, "data-id": src.id,
      onclick: () => { state.picked = src; render(); }, ondblclick: () => { state.picked = src; start(); },
    }, h("span.mark", src.kind === "display" ? "▭" : "▢"), h("span.main", src.name), h("span.meta", `${src.width}×${src.height}`));
    clear(side,
      s.displays.length ? [h("div.section-head", "Displays"), s.displays.map(row)] : null,
      h("div.section-head", "Windows", h("span.count", s.windows.length)), s.windows.map(row),
      !s.windows.length && !s.displays.length ? h("div.empty", "Nothing to show.") : null);
  }

  async function load() {
    try { state.sources = await call("sources"); } catch (e) {
      state.sources = { displays: [], windows: [] };
      clear(stage, h("div.empty", String(e.message || e)));
    }
    render();
  }

  async function start() {
    if (!state.picked) return;
    try {
      state.live = await call("start", { id: state.picked.id, kind: state.picked.kind, fps: state.fps, width: Math.round(stage.clientWidth * devicePixelRatio) });
      state.frames = 0;
      state.since = Date.now();
      clear(stage, image, stats);
    } catch (e) { toast(String(e.message || e), true); }
    render();
  }

  async function stop() {
    await call("stop").catch(() => {});
    state.live = null;
    stats.hidden = true;
    render();
  }

  block.on("frame", (f) => {
    if (!state.live) return;
    image.src = "data:image/jpeg;base64," + f.data;
    state.frames++;
    const seconds = (Date.now() - state.since) / 1000;
    stats.hidden = false;
    stats.textContent = `${f.width}×${f.height} · ${(state.frames / Math.max(seconds, 0.001)).toFixed(1)} fps`;
    window.libertty_screen = { frames: state.frames, width: f.width, height: f.height };
    // One at a time: the next frame is asked for once this one is drawn.
    const shown = () => call("frameShown").catch(() => {});
    if (image.decode) image.decode().then(shown, shown); else shown();
  });
  block.on("error", (e) => { toast(e.message, true); state.live = null; render(); });

  render();
  load();
})();
