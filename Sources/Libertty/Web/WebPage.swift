import Foundation

/// The browser side of Web Access: one self-contained page (no third-party
/// code). It shows the screen libghostty-vt formats as HTML, puts a cursor
/// on it, and sends keys and text back. Its script runs only under the
/// per-response nonce, so nothing in a screen (a program's OSC 8 link
/// included) can run script.
enum WebPage {
    static func html(nonce: String) -> String { template.replacingOccurrences(of: "{{NONCE}}", with: nonce) }

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-{{NONCE}}'; style-src 'unsafe-inline'; connect-src ws: wss:; img-src 'self' data:">
<meta name="referrer" content="no-referrer">
<title>Libertty</title>
<link rel="icon" href="/favicon.ico">
<style>
  :root { --fg: #cdd6f4; --bg: #1e1e2e; --cursor: #f5e0dc; color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg);
    font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  body { display: flex; flex-direction: column; overflow: hidden; }
  header { display: flex; gap: 8px; align-items: center; padding: 8px 10px; padding-top: max(8px, env(safe-area-inset-top));
    background: color-mix(in srgb, var(--bg) 82%, #888 18%); }
  header select { flex: 1; min-width: 0; font: inherit; padding: 4px 6px; border-radius: 6px; }
  header button, #keys button { font: inherit; padding: 4px 10px; border-radius: 6px; border: 1px solid #8884;
    background: #8882; color: inherit; }
  #status { font-size: 12px; opacity: .7; white-space: nowrap; }
  #status.down { color: #f38ba8; opacity: 1; }
  main { flex: 1; overflow: auto; position: relative; padding: 6px; }
  #screen { position: relative; display: inline-block; font-family: ui-monospace, Menlo, monospace; line-height: 1.25; }
  #screen > div { font-family: inherit !important; }
  #screen a { color: inherit; }
  #cursor { position: absolute; background: var(--cursor); opacity: .55; pointer-events: none; }
  #keys { display: flex; gap: 6px; padding: 6px 8px; padding-bottom: max(6px, env(safe-area-inset-bottom));
    overflow-x: auto; background: color-mix(in srgb, var(--bg) 82%, #888 18%); }
  #keys button.on { background: #89b4fa66; }
  #input { position: fixed; left: -1000px; top: 0; width: 10px; height: 10px; opacity: 0; }
  #history { position: fixed; inset: 0; background: var(--bg); display: none; flex-direction: column; z-index: 5; }
  #history pre { flex: 1; margin: 0; padding: 10px; overflow: auto; font: 12px ui-monospace, Menlo, monospace; white-space: pre-wrap; }
  #history header { justify-content: space-between; }
  #notice { position: fixed; left: 50%; top: 56px; transform: translateX(-50%); background: #f9e2af; color: #1e1e2e;
    padding: 6px 12px; border-radius: 8px; display: none; z-index: 6; }
  .empty { opacity: .6; padding: 24px; }
</style>
</head>
<body>
<header>
  <select id="panes" aria-label="Pane"></select>
  <button id="historyButton" title="Scrollback">History</button>
  <span id="status">connecting…</span>
</header>
<main id="main"><div id="screen"></div><div id="cursor"></div></main>
<div id="keys">
  <button data-code="Escape" data-key="Escape">esc</button>
  <button data-code="Tab" data-key="Tab">tab</button>
  <button id="ctrl">ctrl</button>
  <button data-code="KeyC" data-key="c" data-ctrl="1">^C</button>
  <button data-code="ArrowUp" data-key="ArrowUp">↑</button>
  <button data-code="ArrowDown" data-key="ArrowDown">↓</button>
  <button data-code="ArrowLeft" data-key="ArrowLeft">←</button>
  <button data-code="ArrowRight" data-key="ArrowRight">→</button>
  <button data-code="Enter" data-key="Enter">⏎</button>
  <button id="type">keyboard</button>
</div>
<textarea id="input" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false"></textarea>
<div id="history"><header><strong>Scrollback</strong><button id="closeHistory">Close</button></header><pre id="historyText"></pre></div>
<div id="notice"></div>
<script nonce="{{NONCE}}">
(() => {
  const token = location.hash.slice(1);
  const $ = (id) => document.getElementById(id);
  const screen = $("screen"), cursor = $("cursor"), panes = $("panes"), status = $("status"), input = $("input");
  let ws = null, watching = sessionStorage.getItem("libertty-pane"), canType = true, ctrl = false;
  let cell = { w: 8, h: 17 }, cols = 80, rows = 24, cursorAt = null;
  const palette = document.createElement("style");
  document.head.appendChild(palette);

  function setStatus(text, down) { status.textContent = text; status.classList.toggle("down", !!down); }
  function notice(text) {
    const n = $("notice"); n.textContent = text; n.style.display = "block";
    clearTimeout(notice.timer); notice.timer = setTimeout(() => n.style.display = "none", 4000);
  }

  function measure() {
    const probe = document.createElement("span");
    probe.textContent = "M".repeat(100);
    probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre";
    screen.appendChild(probe);
    cell = { w: probe.getBoundingClientRect().width / 100, h: probe.getBoundingClientRect().height };
    probe.remove();
  }

  // As large as the window allows, down to a size still readable on a phone.
  function fit() {
    const width = $("main").clientWidth - 12;
    let size = 15;
    screen.style.fontSize = size + "px"; measure();
    if (cell.w * cols > width) { size = Math.max(7, Math.floor(size * width / (cell.w * cols) * 10) / 10); }
    screen.style.fontSize = size + "px"; measure();
    placeCursor();
  }

  function placeCursor() {
    if (!cursorAt) { cursor.style.display = "none"; return; }
    cursor.style.display = "block";
    cursor.style.left = (6 + cursorAt[1] * cell.w) + "px";
    cursor.style.top = (6 + cursorAt[0] * cell.h) + "px";
    cursor.style.width = cell.w + "px";
    cursor.style.height = cell.h + "px";
  }

  // Links a program wrote (OSC 8) open as web links, and only those.
  function tameLinks() {
    for (const a of screen.querySelectorAll("a")) {
      const href = a.getAttribute("href") || "";
      if (/^(https?:|mailto:)/i.test(href)) { a.target = "_blank"; a.rel = "noopener noreferrer"; }
      else a.removeAttribute("href");
    }
  }

  function connect() {
    if (!token) { setStatus("open the link Libertty shows (with its #secret)", true); return; }
    const scheme = location.protocol === "https:" ? "wss://" : "ws://";
    ws = new WebSocket(scheme + location.host + "/ws?t=" + encodeURIComponent(token));
    ws.onopen = () => setStatus("connected");
    ws.onclose = () => { setStatus("reconnecting…", true); setTimeout(connect, 2000); };
    ws.onmessage = (event) => {
      const m = JSON.parse(event.data);
      if (m.t === "hello") {
        canType = m.input;
        document.documentElement.style.setProperty("--fg", m.fg);
        document.documentElement.style.setProperty("--bg", m.bg);
        document.documentElement.style.setProperty("--cursor", m.cursor);
        $("keys").style.display = canType ? "" : "none";
        if (!canType) setStatus("view only");
      } else if (m.t === "panes") {
        panes.innerHTML = "";
        for (const p of m.panes) {
          const o = document.createElement("option");
          o.value = p.id;
          o.textContent = (p.title || "shell") + "  —  " + p.place + (p.host ? "  @" + p.host : "");
          panes.appendChild(o);
        }
        if (!m.panes.some((p) => p.id === watching)) watching = m.panes.length ? m.panes[0].id : null;
        if (watching) { panes.value = watching; send({ t: "watch", id: watching }); }
        else screen.innerHTML = '<div class="empty">No terminal windows are open in Libertty.</div>';
      } else if (m.t === "style") {
        palette.textContent = m.css;
      } else if (m.t === "screen" && m.id === watching) {
        screen.innerHTML = m.html;
        tameLinks();
        cursorAt = m.cursor;
        document.title = m.title || "Libertty";
        if (m.cols !== cols || m.rows !== rows) { cols = m.cols; rows = m.rows; fit(); } else placeCursor();
      } else if (m.t === "history" && m.id === watching) {
        $("historyText").textContent = m.text;
        $("history").style.display = "flex";
        const pre = $("historyText"); pre.scrollTop = pre.scrollHeight;
      } else if (m.t === "gone" && m.id === watching) {
        watching = null;
      } else if (m.t === "notice") {
        notice(m.text);
      }
    };
  }

  function send(message) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(message)); }

  function sendKey(code, key, mods) {
    send({ t: "key", code, key, ctrl: !!mods.ctrl || ctrl, alt: !!mods.alt, shift: !!mods.shift, meta: !!mods.meta });
    if (ctrl) { ctrl = false; $("ctrl").classList.remove("on"); }
  }

  panes.onchange = () => { watching = panes.value; sessionStorage.setItem("libertty-pane", watching); send({ t: "watch", id: watching }); };
  $("historyButton").onclick = () => send({ t: "history" });
  $("closeHistory").onclick = () => { $("history").style.display = "none"; };
  $("ctrl").onclick = () => { ctrl = !ctrl; $("ctrl").classList.toggle("on", ctrl); input.focus(); };
  $("type").onclick = () => input.focus();
  for (const b of document.querySelectorAll("#keys button[data-code]")) {
    b.onclick = () => { sendKey(b.dataset.code, b.dataset.key, { ctrl: b.dataset.ctrl === "1" }); input.focus(); };
  }
  $("main").onclick = () => { if (canType && !getSelection().toString()) input.focus(); };

  // Keys with a meaning to the terminal go as keys (the Mac encodes them as
  // the program wants); plain typing from soft keyboards and input methods
  // arrives as text.
  input.addEventListener("keydown", (e) => {
    if (!canType || e.isComposing || e.keyCode === 229) return;
    const special = e.key.length > 1 && e.key !== "Unidentified" && e.key !== "Process";
    if (special || e.ctrlKey || e.metaKey || e.altKey || ctrl) {
      if (e.metaKey && (e.key === "v" || e.key === "c")) return;  // the browser's own paste and copy
      e.preventDefault();
      sendKey(e.code, e.key, { ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey });
    }
  });
  input.addEventListener("input", (e) => {
    if (!canType || e.isComposing) return;
    const text = input.value;
    input.value = "";
    if (!text) return;
    if (ctrl && text.length === 1) {
      const c = text.toLowerCase();
      sendKey(/[a-z]/.test(c) ? "Key" + c.toUpperCase() : "", c, { ctrl: true });
    } else send({ t: "text", text });
  });
  input.addEventListener("compositionend", () => {
    const text = input.value; input.value = "";
    if (text) send({ t: "text", text });
  });
  input.addEventListener("beforeinput", (e) => {
    if (e.inputType === "deleteContentBackward" && !input.value) { e.preventDefault(); sendKey("Backspace", "Backspace", {}); }
    if (e.inputType === "insertLineBreak") { e.preventDefault(); sendKey("Enter", "Enter", {}); }
  });
  input.addEventListener("paste", (e) => {
    e.preventDefault();
    send({ t: "text", text: e.clipboardData.getData("text/plain") });
  });
  document.addEventListener("keydown", (e) => { if (document.activeElement !== input && canType && !e.metaKey) input.focus(); });

  window.addEventListener("resize", fit);
  fit();
  connect();
})();
</script>
</body>
</html>
"""#
}
