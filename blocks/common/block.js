// Shared by every block's page (Libertty's own code). The native side answers
// `block.call(method, params)`; it pushes events the page hears with
// `block.on(event, fn)`. Everything a page shows from outside — file names,
// commit messages, process names — goes in as text (`h`), never as markup.
(function () {
  const listeners = {};
  const init = window.__blockInit || { theme: {}, params: {} };

  function applyTheme(t) {
    const root = document.documentElement.style;
    for (const [key, value] of Object.entries(t)) {
      if (typeof value === "string" && key !== "fontURL" && key !== "fontDir") root.setProperty("--" + key, value);
    }
    root.colorScheme = t.dark ? "dark" : "light";
    let faces = document.getElementById("block-fonts");
    if (!faces) {
      faces = document.createElement("style");
      faces.id = "block-fonts";
      document.head.appendChild(faces);
    }
    const dir = t.fontDir || "";
    faces.textContent = dir ? `
      @font-face { font-family: 'Block Sans'; src: url("${dir}/Geist-Regular.ttf"); font-weight: 400; }
      @font-face { font-family: 'Block Sans'; src: url("${dir}/Geist-Medium.ttf"); font-weight: 500; }
      @font-face { font-family: 'Block Sans'; src: url("${dir}/Geist-SemiBold.ttf"); font-weight: 600; }
      @font-face { font-family: 'Block Mono'; src: url("${t.fontURL}"); }` : "";
  }

  // An element: h("div.row.on", { onclick, title }, "text", child…). Strings
  // become text nodes; `null`/`false` children are skipped.
  function h(spec, props, ...children) {
    const [tag, ...classes] = spec.split(".");
    const el = document.createElement(tag || "div");
    if (classes.length) el.className = classes.join(" ");
    if (props && (typeof props !== "object" || props instanceof Node || Array.isArray(props))) {
      children.unshift(props);
      props = null;
    }
    for (const [key, value] of Object.entries(props || {})) {
      if (value === undefined || value === null || value === false) continue;
      if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
      else if (key === "class") el.className += (el.className ? " " : "") + value;
      else if (key === "text") el.textContent = value;
      else if (key === "style") el.setAttribute("style", value);
      else el.setAttribute(key, value === true ? "" : String(value));
    }
    for (const child of children.flat(Infinity)) {
      if (child === null || child === undefined || child === false) continue;
      el.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return el;
  }

  function clear(el, ...children) {
    el.replaceChildren(...children.flat(Infinity).filter((c) => c !== null && c !== undefined && c !== false)
      .map((c) => (c instanceof Node ? c : document.createTextNode(String(c)))));
    return el;
  }

  function ago(seconds) {
    if (!seconds) return "";
    const d = Math.max(0, Date.now() / 1000 - seconds);
    if (d < 60) return "now";
    if (d < 3600) return Math.floor(d / 60) + "m";
    if (d < 86400) return Math.floor(d / 3600) + "h";
    if (d < 86400 * 30) return Math.floor(d / 86400) + "d";
    if (d < 86400 * 365) return Math.floor(d / (86400 * 30)) + "mo";
    return Math.floor(d / (86400 * 365)) + "y";
  }

  function date(seconds) {
    return seconds ? new Date(seconds * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "";
  }

  // A message at the bottom; errors stay until clicked.
  function toast(message, error) {
    const el = h("div.toast" + (error ? ".error" : ""), { onclick: () => el.remove() }, message);
    document.body.appendChild(el);
    if (!error) setTimeout(() => el.remove(), 2600);
  }

  // A small sheet over the page: a message, an optional field, buttons.
  function dialog({ title, message, field, ok = "OK", danger = false }) {
    return new Promise((resolve) => {
      const input = field ? h("input.field", { type: "text", placeholder: field.placeholder || "", value: field.value || "" }) : null;
      const close = (value) => { scrim.remove(); resolve(value); };
      const okButton = h("button.button.primary" + (danger ? ".danger" : ""), { onclick: () => close(input ? input.value : true) }, ok);
      const scrim = h("div.scrim", { onclick: (e) => { if (e.target === scrim) close(input ? null : false); } },
        h("div.dialog",
          h("div.dialog-title", title),
          message ? h("div.dialog-message", message) : null,
          input,
          h("div.dialog-buttons", h("button.button", { onclick: () => close(input ? null : false) }, "Cancel"), okButton)));
      scrim.addEventListener("keydown", (e) => {
        if (e.key === "Escape") { e.preventDefault(); close(input ? null : false); }
        // A focused button takes its own Enter (Tab to Cancel, Enter: cancelled).
        if (e.key === "Enter" && e.target.tagName !== "BUTTON" && (!input || input.value.trim())) {
          e.preventDefault();
          okButton.click();
        }
      });
      document.body.appendChild(scrim);
      (input || okButton).focus();
    });
  }

  // A path as git writes it in a header: "quoted" with C escapes when it
  // holds a control character or a quote (its bytes as octal), and followed
  // by a tab when it holds a space. `prefix` ("a/", "b/") comes off.
  function headerPath(raw, prefix) {
    let s = raw.replace(/\t$/, "");
    if (s.startsWith('"')) {
      const bytes = [], chars = Array.from(s);
      const escapes = { n: 10, t: 9, r: 13, a: 7, b: 8, f: 12, v: 11, '"': 34, "\\": 92 };
      for (let i = 1; i < chars.length; i++) {
        const c = chars[i];
        if (c === '"') break;
        if (c !== "\\") { bytes.push(...new TextEncoder().encode(c)); continue; }
        const n = chars[++i] || "";
        if (/[0-7]/.test(n)) { bytes.push(parseInt(chars.slice(i, i + 3).join(""), 8) & 255); i += 2; }
        else bytes.push(escapes[n] ?? n.charCodeAt(0));
      }
      s = new TextDecoder().decode(new Uint8Array(bytes));
    }
    if (s === "/dev/null") return "";
    return prefix && s.startsWith(prefix) ? s.slice(prefix.length) : s;
  }

  // The two paths of "diff --git a/x b/y": quoted ones read exactly; plain
  // ones with spaces split where both halves name the same file.
  function gitLinePaths(rest) {
    const token = (s) => {
      if (!s.startsWith('"')) return null;
      for (let i = 1; i < s.length; i++) {
        if (s[i] === "\\") i++;
        else if (s[i] === '"') return [s.slice(0, i + 1), s.slice(i + 2)];
      }
      return null;
    };
    const first = token(rest);
    if (first) {
      return [headerPath(first[0], "a/"), headerPath(first[1], "b/")];
    }
    const same = rest.match(/^a\/(.*) b\/\1$/);
    if (same) return [same[1], same[1]];
    const at = rest.indexOf(" b/");
    if (at < 0) return ["", ""];
    return [headerPath(rest.slice(0, at), "a/"), headerPath(rest.slice(at + 1), "b/")];
  }

  // A unified diff as files of hunks, with line numbers. `actions(file, hunk)`
  // may return buttons for a hunk; `patchOf(file, hunk)` cuts the patch that
  // `git apply` takes for it. A combined diff (`diff --cc`: a file with
  // conflicts) has a mark column per side and nothing to apply.
  function parseDiff(text) {
    const files = [];
    let file = null, hunk = null;
    const start = (line) => {
      file = { header: [line], hunks: [], path: "", old: "", binary: false, added: 0, removed: 0, ways: 1 };
      files.push(file);
      hunk = null;
    };
    for (const line of text.split("\n")) {
      if (line.startsWith("diff --git ")) {
        start(line);
        // Until the ---/+++ lines (a mode change or a pure rename has none).
        [file.old, file.path] = gitLinePaths(line.slice(11));
      } else if (line.startsWith("diff --cc ") || line.startsWith("diff --combined ")) {
        start(line);
        file.path = file.old = headerPath(line.replace(/^diff --(cc|combined) /, ""));
        file.ways = 2;
      } else if (!file) {
        continue;
      } else if (line.startsWith("@@")) {
        const at = line.match(/^@+/)[0].length;
        file.ways = Math.max(1, at - 1);
        const m = line.match(/ -(\d+)(?:,\d+)? .*\+(\d+)(?:,\d+)? @+(.*)$/);
        hunk = { header: line, oldStart: m ? +m[1] : 0, newStart: m ? +m[2] : 0, context: m ? m[3].trim() : "", lines: [] };
        file.hunks.push(hunk);
      } else if (hunk) {
        hunk.lines.push(line);
        const marks = line.slice(0, file.ways);
        if (marks.includes("+")) file.added++;
        else if (marks.includes("-")) file.removed++;
      } else {
        file.header.push(line);
        if (line.startsWith("+++ ")) file.path = headerPath(line.slice(4), "b/") || file.path;
        else if (line.startsWith("--- ")) file.old = headerPath(line.slice(4), "a/");
        else if (line.startsWith("rename from ")) file.old = headerPath(line.slice(12));
        else if (line.startsWith("rename to ")) file.path = headerPath(line.slice(10));
        else if (line.startsWith("Binary files") || line === "GIT binary patch") file.binary = true;
        else if (line.startsWith("new file mode")) file.created = true;
        else if (line.startsWith("deleted file mode")) file.deleted = true;
      }
    }
    // A deleted file's +++ is /dev/null: it's named by what it was.
    for (const f of files) if (!f.path) f.path = f.old;
    // The text ends with a newline: the last hunk's empty last line isn't a line.
    for (const f of files) for (const k of f.hunks) while (k.lines.length && k.lines[k.lines.length - 1] === "") k.lines.pop();
    return files;
  }

  function patchOf(file, hunk) {
    return file.header.join("\n") + "\n" + hunk.header + "\n" + hunk.lines.join("\n") + "\n";
  }

  // The hunk alone, as a change to the file where it is now (Last Turn's
  // Revert): `patchOf` keeps a renamed file's rename and a file's mode
  // change, which `git apply -R` would undo with any one of its hunks.
  // A new or deleted file keeps its header: its one hunk is the whole file.
  function hunkPatchOf(file, hunk) {
    const skip = /^(old mode|new mode|similarity index|dissimilarity index|rename from|rename to|copy from|copy to) /;
    const head = file.header.filter((line) => !skip.test(line));
    const moved = file.header.some((line) => /^(rename|copy) to /.test(line));
    const plus = head.find((line) => line.startsWith("+++ "));
    if (moved && plus) {
      // Both sides the new path: git's b/ for a/, inside its quotes when it quoted it.
      const to = plus.slice(4), name = to.replace(/\t$/, "");
      const from = to.startsWith('"b/') ? '"a/' + to.slice(3) : to.startsWith("b/") ? "a/" + to.slice(2) : to;
      for (let i = 0; i < head.length; i++) {
        if (head[i].startsWith("diff --git ")) head[i] = "diff --git " + from.replace(/\t$/, "") + " " + name;
        else if (head[i].startsWith("--- ")) head[i] = "--- " + from;
      }
    }
    return head.join("\n") + "\n" + hunk.header + "\n" + hunk.lines.join("\n") + "\n";
  }

  // How diffs lay out (Kero's): unified while narrow, side by side once
  // wide ("auto"), or one of them always ("unified", "split"); the button
  // over the diffs switches, and the config keeps the choice (diff-layout).
  let diffLayout = (window.__blockInit && window.__blockInit.prefs && window.__blockInit.prefs.diffLayout) || "auto";
  const diffPrefs = {
    get layout() { return diffLayout; },
    set layout(v) {
      diffLayout = v;
      if (window.block && window.block.call) window.block.call("setDiffLayout", { layout: v }).catch(() => {});
    },
  };
  const SPLIT_WIDTH = 900;
  // A file with this many changed lines, or binary, starts folded.
  const FOLD_LINES = 400;

  // A hunk's lines as rows of two sides: context on both, a run of
  // removals beside the additions that replaced them.
  function pairLines(hunk, ways) {
    const rows = [];
    let o = hunk.oldStart, n = hunk.newStart, dels = [], adds = [];
    const flush = () => {
      for (let i = 0; i < Math.max(dels.length, adds.length); i++) rows.push({ left: dels[i] || null, right: adds[i] || null });
      dels = []; adds = [];
    };
    for (const line of hunk.lines) {
      if (line[0] === "\\") { flush(); rows.push({ note: line }); continue; }
      const marks = line.slice(0, ways), code = line.slice(ways) || " ";
      if (ways === 1 && marks === "-") dels.push({ ln: o++, code, cls: "del" });
      else if (ways === 1 && marks === "+") adds.push({ ln: n++, code, cls: "add" });
      else { flush(); rows.push({ left: { ln: o++, code, cls: "ctx" }, right: { ln: n++, code, cls: "ctx" } }); }
    }
    flush();
    return rows;
  }

  function unifiedLines(file, hunk) {
    let o = hunk.oldStart, n = hunk.newStart;
    return hunk.lines.map((line) => {
      if (line[0] === "\\") return h("div.line.note", h("span.ln", ""), h("span.ln", ""), h("span.code", line));
      const marks = line.slice(0, file.ways);
      let left = "", right = "", cls = "ctx";
      if (file.ways > 1) {
        // A conflicted file: only the result's lines are numbered.
        if (marks.includes("-")) cls = "del"; else { right = n++; if (marks.includes("+")) cls = "add"; }
      } else if (marks === "+") { right = n++; cls = "add"; }
      else if (marks === "-") { left = o++; cls = "del"; }
      else { left = o++; right = n++; }
      return h("div.line." + cls, h("span.ln", left), h("span.ln", right), h("span.code", line.slice(file.ways) || " "));
    });
  }

  function splitLines(file, hunk) {
    const side = (x) => x ? [h("span.ln", x.ln), h("span.code." + x.cls, x.code)] : [h("span.ln", ""), h("span.code.none", "")];
    return pairLines(hunk, file.ways).map((row) => row.note
      ? h("div.sline.note", h("span.ln", ""), h("span.code", row.note))
      : h("div.sline", side(row.left), side(row.right)));
  }

  // `hide(file, hunk)`: hunks to leave out (Last Turn's kept ones); a file
  // left with none goes too.
  function diffView(text, { actions, onOpen, hide, empty = "No changes" } = {}) {
    let files = parseDiff(text);
    if (hide) {
      for (const f of files) {
        const before = f.hunks.length;
        f.hunks = f.hunks.filter((k) => !hide(f, k));
        f.allHidden = before > 0 && !f.hunks.length;
      }
      files = files.filter((f) => !f.allHidden);
    }
    if (!files.length) return h("div.empty", empty);
    const sections = [];
    let split = false;
    const renders = [];
    const sectionsOf = files.map((file) => {
      const name = file.path || file.old;
      const renamed = file.old && file.old !== file.path && !file.created && !file.deleted;
      const big = file.binary || file.added + file.removed > FOLD_LINES;
      const section = h("section.diff-file" + (big ? ".folded" : ""), { "data-path": name });
      const head = h("div.diff-file-head", {
        title: "Click to fold or unfold",
        onclick: (e) => { if (!e.target.closest(".diff-path.link")) { section.classList.toggle("folded"); updateFoldButton(); } },
      },
        h("span.diff-fold", "▾"),
        h("span.diff-path", { title: name, onclick: onOpen && !file.deleted ? () => onOpen(name) : null, class: onOpen && !file.deleted ? "link" : null }, name),
        renamed ? h("span.diff-old", "from " + file.old) : null,
        h("span.diff-count", h("span.add", "+" + file.added), " ", h("span.del", "−" + file.removed)));
      const body = [file.binary ? h("div.empty", "Binary file") : null];
      for (const hunk of file.hunks) {
        const buttons = actions && file.ways === 1 ? actions(file, hunk) : [];
        const lines = h("div.hunk-lines");
        renders.push(() => clear(lines, split && file.ways === 1 ? splitLines(file, hunk) : unifiedLines(file, hunk)));
        body.push(h("div.hunk",
          h("div.hunk-head", h("span.hunk-range", hunk.header.replace(/ @@.*$/, " @@")),
            h("span.hunk-context", hunk.context), h("span.hunk-actions", buttons)),
          lines));
      }
      section.append(head, ...body.filter(Boolean));
      sections.push(section);
      return section;
    });
    const foldButton = h("button.button.quiet", { onclick: () => {
      const fold = !sections.every((x) => x.classList.contains("folded"));
      for (const x of sections) x.classList.toggle("folded", fold);
      updateFoldButton();
    } });
    const layoutButton = h("button.button.quiet", { title: "Unified, or side by side", onclick: () => {
      const order = ["auto", "split", "unified"];
      diffPrefs.layout = order[(order.indexOf(diffPrefs.layout) + 1) % order.length];
      relayout();
    } });
    function updateFoldButton() {
      clear(foldButton, sections.every((x) => x.classList.contains("folded")) ? "Expand All" : "Collapse All");
    }
    const root = h("div.diff", h("div.diff-bar", h("span.diff-files", files.length + (files.length === 1 ? " file" : " files")),
      h("span.spacer"), layoutButton, foldButton), sectionsOf);
    function relayout() {
      const layout = diffPrefs.layout;
      const want = layout === "split" || (layout === "auto" && root.clientWidth >= SPLIT_WIDTH);
      clear(layoutButton, { auto: "Layout: Auto", split: "Side by Side", unified: "Unified" }[layout] || "Layout");
      if (want === split && root.dataset.laid) return;
      split = want;
      root.dataset.laid = "1";
      root.classList.toggle("split", split);
      for (const r of renders) r();
    }
    updateFoldButton();
    // Laid out once it has a width, and again as the width crosses the line.
    if (typeof ResizeObserver === "function") new ResizeObserver(() => relayout()).observe(root);
    setTimeout(relayout, 0);
    relayout();
    return root;
  }

  // Saving a file block's file: a change is written a moment later; a save
  // the app asks for (⌘S, closing) is answered with its round's id; a file
  // changed elsewhere is never overwritten without being asked, and the
  // page takes in a change on disk when it has nothing unsaved.
  //   const doc = fileDoc({ delay: 400, serialize, apply, onConflict });
  //   doc.load(); doc.changed(); doc.save().then(ok => …); doc.confirmReload(...)
  function fileDoc({ delay = 400, serialize, apply, onConflict }) {
    let saved = null, base = "", dirty = false, timer = null, writing = null;
    function mark(on) {
      if (dirty === on) return;
      dirty = on;
      window.block.call("dirty", { dirty: on }).catch(() => {});
    }
    async function save(force = false) {
      clearTimeout(timer);
      if (writing) await writing;
      const text = serialize();
      if (text === saved && !force) { mark(false); return true; }
      writing = window.block.call("write", { text, force, base }).then((a) => {
        if (a && a.conflict) {

          mark(true);
          onConflict?.(() => save(true), () => reload(true));
          return false;
        }
        saved = text;
        base = a.base || base;
        if (serialize() === text) mark(false);
        return true;
      }).catch((e) => {
        window.block.toast(String(e.message || e), true);
        return false;
      }).finally(() => { writing = null; });
      return writing;
    }
    function changed() {
      mark(true);
      clearTimeout(timer);
      // (A test holds the save back with window.libertty_save_delay, so a
      // change elsewhere surely finds this one unsaved.)
      timer = setTimeout(() => save(), window.libertty_save_delay ?? delay);
    }
    async function reload(fromDisk) {
      const f = await window.block.call("read");
      // Taking the file's version means exactly that: what wasn't written goes.
      if (dirty && !fromDisk) { onConflict?.(() => save(true), () => reload(true)); return false; }
      if (fromDisk) mark(false);
      const first = saved === null;
      apply(f, { first });
      saved = f.text;
      base = f.base;
      // Typed into while the read was on its way: that's unsaved again.
      if (dirty) { onConflict?.(() => save(true), () => reload(true)); return false; }
      mark(false);
      return true;
    }
    return {
      get dirty() { return dirty; },
      get saved() { return saved; },
      load: () => reload(true),
      changed, save,
      // ⌘R, and a change written elsewhere: with nothing unsaved, read again;
      // with something unsaved, ask.
      async external() {
        if (!dirty) return reload(false);
        return Promise.resolve(onConflict?.(() => save(true), () => reload(true)));
      },
      async confirmReload(confirm) {
        if (!dirty || await confirm()) reload(true);
      },
    };
  }

  window.block = {
    params: init.params || {},
    call(method, params = {}) {
      return window.webkit.messageHandlers.block.postMessage({ method, params });
    },
    on(event, fn) { (listeners[event] = listeners[event] || []).push(fn); },
    _emit(event, payload) { for (const fn of listeners[event] || []) fn(payload); },
    setTheme(t) { applyTheme(t); },
    h, clear, ago, date, toast, dialog, parseDiff, patchOf, hunkPatchOf, diffView, fileDoc,
  };
  applyTheme(init.theme || {});
})();
