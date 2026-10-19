// The Git block's page (Libertty's own code). State comes from `block.call`;
// everything shown from git — paths, messages, names — goes in as text.
(function () {
  const { h, clear, call, ago, date, toast, dialog, diffView } = Object.assign({}, block, { call: block.call.bind(block) });
  const app = document.getElementById("app");

  const state = {
    tab: "changes", // changes | history | branches | stashes
    status: null,
    log: [], logDone: false, all: false,
    branches: null, stashes: [],
    selected: null, // { kind: "file", path, staged, untracked } | { kind: "commit", hash } | { kind: "stash", ref }
    message: "", amend: false,
    busy: null, // a local change running (one at a time)
    remote: null, // fetch / pull / push: minutes, maybe, while the rest goes on
  };
  // Each look at something counts; an answer for an older one is dropped
  // (two quick clicks: the second file shows, whichever git answers last).
  let looking = 0;

  // MARK: Layout

  const title = h("span.title");
  const branchButton = h("button.button.quiet", { onclick: () => showBranchMenu() });
  const track = h("span.muted");
  const fetchButton = h("button.button", { onclick: () => remote("fetch", "Fetched") }, "Fetch");
  const pullButton = h("button.button", { onclick: () => remote("pull", "Pulled") }, "Pull");
  const pushButton = h("button.button", { onclick: () => remote("push", "Pushed") }, "Push");
  const refreshButton = h("button.icon", { title: "Refresh", onclick: () => refresh(true) }, "↻");
  const bar = h("div.bar", title, branchButton, track, h("span.spacer"), fetchButton, pullButton, pushButton, refreshButton);
  const stateLine = h("div.state", { hidden: true });

  const chips = h("div.chips");
  const list = h("div.list");
  const message = h("textarea.field", { placeholder: "Message (⌘↩ commits)", rows: 3 });
  const amend = h("input", { type: "checkbox" });
  const commitButton = h("button.button.primary", { onclick: () => commit() }, "Commit");
  const commitBox = h("div.commit-box", message,
    h("div.commit-row", h("label.check", amend, "Amend last commit"), h("span.spacer"), commitButton));
  const side = h("div.side", chips, list, commitBox);

  const back = h("button.button.quiet.back", { onclick: () => columns.classList.remove("showing-detail") }, "‹ Back");
  const detailBody = h("div.detail-body");
  const detail = h("div.detail", h("div.bar", back, h("span.title.detail-title")), detailBody);
  const columns = h("div.columns", side, detail);
  app.append(bar, stateLine, columns);

  message.addEventListener("input", () => { state.message = message.value; updateCommit(); });
  message.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.metaKey) { e.preventDefault(); commit(); } });
  amend.addEventListener("change", async () => {
    state.amend = amend.checked;
    // Amending starts from the last commit's message.
    if (amend.checked && !message.value.trim()) {
      message.value = (await call("lastMessage").catch(() => "")).trim();
      state.message = message.value;
    }
    updateCommit();
  });

  function setChips() {
    const tabs = [["changes", "Changes"], ["history", "History"], ["branches", "Branches"], ["stashes", "Stashes"]];
    clear(chips, tabs.map(([id, name]) => h("button.chip" + (state.tab === id ? ".on" : ""), {
      onclick: () => { if (state.tab !== id) { state.tab = id; clearDetail(); } render(); load(); },
    }, name, id === "changes" && state.status ? " " + changeCount() : "")));
  }

  function changeCount() {
    const s = state.status;
    const n = (s.staged || []).length + (s.unstaged || []).length + (s.conflicted || []).length;
    return n ? String(n) : "";
  }

  // MARK: Loading

  async function refresh(all) {
    try {
      state.status = await call("status");
    } catch (e) { return toast(String(e.message || e), true); }
    if (all || state.tab !== "changes") await load();
    render();
    // What was shown may be gone (committed, dropped): then nothing is.
    const sel = state.selected, s = state.status;
    if (sel?.kind === "file") {
      const list = sel.staged ? s?.staged : sel.conflicted ? s?.conflicted : s?.unstaged;
      const still = (list || []).find((c) => c.path === sel.path);
      if (still) showFile(selection(still, sel.staged, sel.conflicted), true); else clearDetail();
    } else if (sel?.kind === "stash" && !state.stashes.some((x) => x.ref === sel.ref)) {
      clearDetail();
    }
  }

  function clearDetail() {
    looking++;
    state.selected = null;
    clear(detail.querySelector(".detail-title"));
    clear(detailBody, h("div.empty", "Select a file, a commit or a stash to see its changes."));
    columns.classList.remove("showing-detail");
  }

  async function load() {
    try {
      if (state.tab === "history") {
        // As much as was scrolled through: reading again keeps the place.
        const limit = Math.min(5000, Math.max(200, state.log.length));
        state.log = await call("log", { skip: 0, limit, all: state.all });
        state.logDone = state.log.length < limit;
      } else if (state.tab === "branches") {
        state.branches = await call("branches");
      } else if (state.tab === "stashes") {
        state.stashes = await call("stashes");
      }
    } catch (e) { toast(String(e.message || e), true); }
    render();
  }

  async function moreLog() {
    if (state.logDone || state.loadingMore) return;
    state.loadingMore = true;
    try {
      const more = await call("log", { skip: state.log.length, limit: 200, all: state.all });
      state.log = state.log.concat(more);
      state.logDone = more.length < 200;
      render();
    } finally { state.loadingMore = false; }
  }

  list.addEventListener("scroll", () => {
    if (state.tab === "history" && list.scrollTop + list.clientHeight > list.scrollHeight - 300) moreLog();
  });

  // MARK: Rendering

  function render() {
    const s = state.status;
    if (s && !s.repository) {
      clear(title, "Not a Git repository");
      clear(branchButton);
      clear(track);
      for (const b of [fetchButton, pullButton, pushButton]) b.hidden = true;
      clear(list, h("div.empty", h("div", s.directory),
        h("div", { style: "margin-top:12px" }, h("button.button", { onclick: () => act("init", {}, "Made a repository") }, "Make It a Repository"))));
      commitBox.hidden = true;
      chips.hidden = true;
      return;
    }
    chips.hidden = false;
    commitBox.hidden = state.tab !== "changes";
    for (const b of [fetchButton, pullButton, pushButton]) { b.hidden = false; b.disabled = !!state.remote; }
    if (s) {
      clear(title, s.name);
      clear(branchButton, "⎇ ", s.detached ? "detached at " + s.head : s.branch || "—", " ▾");
      const parts = [];
      if (s.ahead) parts.push("↑" + s.ahead);
      if (s.behind) parts.push("↓" + s.behind);
      clear(track, parts.join(" "));
      track.title = s.upstream ? "Tracking " + s.upstream : "No upstream";
      pullButton.disabled = !!state.remote || !s.upstream;
      stateLine.hidden = !s.state;
      if (s.state) clear(stateLine, ({ merging: "Merging", rebasing: "Rebasing", "cherry-picking": "Cherry-picking" })[s.state] +
        " — conflicts are marked U; resolve them, stage them, and commit (or abort in a terminal).");
    }
    setChips();
    updateCommit();
    const top = list.scrollTop;
    if (state.tab === "changes") renderChanges();
    else if (state.tab === "history") renderHistory();
    else if (state.tab === "branches") renderBranches();
    else renderStashes();
    list.scrollTop = top;
  }

  function updateCommit() {
    const staged = (state.status?.staged || []).length;
    commitButton.disabled = !!state.busy || (!state.amend && (!staged || !message.value.trim()));
    clear(commitButton, state.amend ? "Amend" : staged ? `Commit ${staged}` : "Commit");
  }

  // A file as selected: a rename carries the path it came from, so its
  // diff and its unstaging take both.
  function selection(change, staged, conflicted) {
    return { kind: "file", path: change.path, old: change.old || null, staged, untracked: !!change.untracked, conflicted: !!conflicted };
  }

  function pathsOf(change) { return change.old ? [change.path, change.old] : [change.path]; }

  function fileRow(change, staged, conflicted) {
    const name = change.path.split("/").pop();
    const dir = change.path.slice(0, change.path.length - name.length);
    const sel = state.selected;
    const on = sel?.kind === "file" && sel.path === change.path && sel.staged === staged && !!sel.conflicted === !!conflicted;
    const button = (title, glyph, fn) => h("button.icon", { title, onclick: (e) => { e.stopPropagation(); fn(); } }, glyph);
    const actions = conflicted
      ? [button("Mark Resolved (stage it)", "✓", () => act("stage", { paths: [change.path] }, "Marked resolved")),
         button("Use Ours", "◧", () => resolve(change, "ours")),
         button("Use Theirs", "◨", () => resolve(change, "theirs"))]
      : staged
      ? [button("Unstage", "−", () => act("unstage", { paths: pathsOf(change) }))]
      : [button("Stage", "+", () => act("stage", { paths: [change.path] })),
         button("Discard Changes", "↺", () => discard(change))];
    if (change.mark !== "D") actions.push(button("Open", "↗", () => openFile(change.path)));
    return h("div.row" + (on ? ".on" : ""), {
      title: change.old ? `${change.old} → ${change.path}` : change.path,
      onclick: () => showFile(selection(change, staged, conflicted)),
    },
      h("span.mark." + (change.mark === "?" ? "A" : change.mark), change.mark),
      h("span.main", name, dir ? h("span.sub", "  " + dir) : null),
      h("span.actions", actions));
  }

  function renderChanges() {
    const s = state.status;
    if (!s) return clear(list, h("div.empty", "Reading…"));
    const parts = [];
    if (s.conflicted.length) {
      parts.push(h("div.section-head", "Conflicts", h("span.count", s.conflicted.length)));
      parts.push(s.conflicted.map((c) => fileRow(c, false, true)));
    }
    if (s.staged.length) {
      parts.push(h("div.section-head", "Staged", h("span.count", s.staged.length), h("span.spacer"),
        h("button.button.quiet", { onclick: () => act("unstageAll") }, "Unstage All")));
      parts.push(s.staged.map((c) => fileRow(c, true)));
    }
    if (s.unstaged.length) {
      parts.push(h("div.section-head", "Changes", h("span.count", s.unstaged.length), h("span.spacer"),
        h("button.button.quiet", { onclick: () => act("stageAll") }, "Stage All")));
      parts.push(s.unstaged.map((c) => fileRow(c, false)));
    }
    if (!parts.length) parts.push(h("div.empty", "Nothing to commit — the working tree is clean."));
    clear(list, parts);
  }

  // The commit graph: a lane per line of history, drawn per row.
  function lanes(log) {
    const rows = [];
    let open = [];
    for (const c of log) {
      let lane = open.indexOf(c.hash);
      if (lane < 0) { lane = open.indexOf(null); if (lane < 0) { lane = open.length; open.push(null); } }
      const before = open.slice();
      const after = open.slice();
      // Every lane that waited for this commit ends here.
      for (let i = 0; i < after.length; i++) if (after[i] === c.hash) after[i] = null;
      after[lane] = c.parents[0] || null;
      const forks = [];
      for (const p of c.parents.slice(1)) {
        let i = after.indexOf(p);
        if (i < 0) { i = after.indexOf(null); if (i < 0) { i = after.length; after.push(null); } after[i] = p; }
        forks.push(i);
      }
      while (after.length && after[after.length - 1] === null) after.pop();
      rows.push({ lane, before, after, forks, merge: c.parents.length > 1 });
      open = after;
    }
    return rows;
  }

  function graph(row, width) {
    const H = 30, W = 12, mid = H / 2, x = (i) => 8 + i * W;
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("width", width);
    svg.setAttribute("height", H);
    svg.classList.add("graph");
    const line = (x1, y1, x2, y2) => {
      const p = document.createElementNS(ns, "path");
      const d = x1 === x2 ? `M${x1} ${y1}V${y2}` : `M${x1} ${y1}C${x1} ${(y1 + y2) / 2} ${x2} ${(y1 + y2) / 2} ${x2} ${y2}`;
      p.setAttribute("d", d);
      p.setAttribute("fill", "none");
      p.setAttribute("stroke", "var(--t4)");
      p.setAttribute("stroke-width", "1.5");
      svg.appendChild(p);
    };
    row.before.forEach((h, i) => {
      if (h === null) return;
      if (i === row.lane || h === row.hash) line(x(i), 0, x(row.lane), mid);
      else line(x(i), 0, x(i), mid);
    });
    row.after.forEach((h, i) => {
      if (h === null) return;
      if (i === row.lane || row.forks.includes(i)) line(x(row.lane), mid, x(i), H);
      else line(x(i), mid, x(i), H);
    });
    const dot = document.createElementNS(ns, "circle");
    dot.setAttribute("cx", x(row.lane));
    dot.setAttribute("cy", mid);
    dot.setAttribute("r", row.merge ? 3.5 : 3.5);
    dot.setAttribute("fill", row.merge ? "var(--bg)" : "var(--t2)");
    dot.setAttribute("stroke", "var(--t2)");
    dot.setAttribute("stroke-width", "1.5");
    svg.appendChild(dot);
    return svg;
  }

  function renderHistory() {
    const toggle = h("div.section-head", h("label.check", h("input", {
      type: "checkbox", checked: state.all, onchange: (e) => { state.all = e.target.checked; load(); },
    }), "All branches"), h("span.spacer"), h("span.count", state.log.length + (state.logDone ? "" : "+")));
    if (!state.log.length) return clear(list, toggle, h("div.empty", state.status?.hasHead === false ? "No commits yet." : "Reading…"));
    const rows = lanes(state.log);
    const width = 16 + Math.max(...rows.map((r) => Math.max(r.before.length, r.after.length, r.lane + 1))) * 12;
    clear(list, toggle, state.log.map((c, i) => {
      rows[i].hash = c.hash;
      const on = state.selected?.kind === "commit" && state.selected.hash === c.hash;
      const refs = c.refs.map((r) => h("span.ref" + (r.startsWith("HEAD") ? ".head" : ""), { title: r }, r.replace(/^HEAD -> /, "")));
      return h("div.row.history-row" + (on ? ".on" : ""), { title: c.subject, onclick: () => showCommit(c.hash) },
        graph(rows[i], Math.min(width, 140)),
        h("span.main", refs, c.subject),
        h("span.meta", c.author.split(" ")[0] + " · " + ago(c.time)));
    }));
  }

  function renderBranches() {
    const b = state.branches;
    if (!b) return clear(list, h("div.empty", "Reading…"));
    const row = (branch, remote) => {
      const track = (branch.track || "").replace("ahead ", "↑").replace("behind ", "↓").replace(/[\[\],]/g, "");
      const actions = branch.current ? [] : [
        h("button.icon", { title: "Switch to It", onclick: (e) => { e.stopPropagation(); act("checkout", { name: branch.name, remote }, "On " + branch.name, true); } }, "⇢"),
      ];
      if (!remote && !branch.current) {
        actions.push(h("button.icon", { title: "Delete", onclick: (e) => { e.stopPropagation(); deleteBranch(branch.name); } }, "×"));
      }
      return h("div.row" + (branch.current ? ".on" : ""), { title: branch.subject, ondblclick: () => !branch.current && act("checkout", { name: branch.name, remote }, "On " + branch.name, true) },
        h("span.mark", branch.current ? "●" : ""),
        h("span.main", branch.name, branch.subject ? h("span.sub", "  " + branch.subject) : null),
        h("span.meta", [track, ago(branch.time)].filter(Boolean).join(" · ")),
        h("span.actions", actions));
    };
    clear(list,
      h("div.section-head", "Local", h("span.count", b.local.length), h("span.spacer"),
        h("button.button.quiet", { onclick: () => newBranch() }, "New Branch…")),
      b.local.map((x) => row(x, false)),
      b.remote.length ? h("div.section-head", "Remote", h("span.count", b.remote.length)) : null,
      b.remote.map((x) => row(x, true)));
  }

  function renderStashes() {
    clear(list,
      h("div.section-head", "Stashes", h("span.count", state.stashes.length), h("span.spacer"),
        h("button.button.quiet", { onclick: () => stash() }, "Stash Changes…")),
      state.stashes.length ? state.stashes.map((s) => {
        const on = state.selected?.kind === "stash" && state.selected.ref === s.ref;
        return h("div.row" + (on ? ".on" : ""), { title: s.message, onclick: () => showStash(s.ref) },
          h("span.mark", "≡"),
          h("span.main", s.message, h("span.sub", "  " + s.ref)),
          h("span.meta", ago(s.time)),
          h("span.actions",
            h("button.icon", { title: "Apply", onclick: (e) => { e.stopPropagation(); act("stashApply", { ref: s.ref }, "Applied", true); } }, "⤓"),
            h("button.icon", { title: "Pop (apply and drop)", onclick: (e) => { e.stopPropagation(); act("stashPop", { ref: s.ref }, "Popped", true); } }, "⇡"),
            h("button.icon", { title: "Drop", onclick: (e) => { e.stopPropagation(); dropStash(s.ref); } }, "×")));
      }) : h("div.empty", "No stashes."));
  }

  function setDetail(heading, ...body) {
    clear(detail.querySelector(".detail-title"), heading);
    clear(detailBody, body);
    detailBody.scrollTop = 0;
    columns.classList.add("showing-detail");
  }

  // MARK: Showing things

  function openFile(path) {
    call("openFile", { paths: [path] }).catch((e) => toast(String(e.message || e), true));
  }

  async function showFile(sel, keepScroll) {
    const look = ++looking;
    state.selected = sel;
    render();
    const top = detailBody.scrollTop;
    let got;
    try {
      got = await call("diff", { paths: sel.old ? [sel.path, sel.old] : [sel.path], staged: sel.staged, untracked: sel.untracked });
    } catch (e) { if (look === looking) toast(String(e.message || e), true); return; }
    if (look !== looking) return;
    const actions = (file, hunk) => {
      // A cut-short diff's hunks may be cut too: nothing to apply from it.
      if (sel.untracked || got.truncated) return [];
      const patch = block.patchOf(file, hunk);
      return sel.staged
        ? [h("button.button", { onclick: () => act("applyPatch", { patch, cached: true, reverse: true }) }, "Unstage Hunk")]
        : [h("button.button", { onclick: () => act("applyPatch", { patch, cached: true }) }, "Stage Hunk"),
           h("button.button.quiet", { onclick: () => discardHunk(patch) }, "Discard")];
    };
    setDetail(sel.path + (sel.staged ? " (staged)" : sel.conflicted ? " (conflicted)" : ""),
      sel.conflicted ? h("div.state", "Each side's lines are marked in its column. Edit the file, or use ours or theirs, then mark it resolved.") : null,
      diffView(got.diff, { actions, onOpen: openFile, empty: "No changes to show." }),
      truncatedNote(got));
    if (keepScroll) detailBody.scrollTop = top;
  }

  function truncatedNote(got) {
    return got.truncated ? h("div.empty", "The diff is cut short: it's over 2 MB.") : null;
  }

  async function showCommit(hash) {
    const look = ++looking;
    state.selected = { kind: "commit", hash };
    render();
    let c;
    try { c = await call("show", { hash }); } catch (e) { if (look === looking) toast(String(e.message || e), true); return; }
    if (look !== looking) return;
    const [subject, ...rest] = c.message.split("\n");
    setDetail(c.hash.slice(0, 10),
      h("div.detail-head",
        h("div.subject", subject),
        rest.join("\n").trim() ? h("div.body", rest.join("\n").trim()) : null,
        h("div.who", h("span", c.author), h("span", date(c.time)),
          h("span.hash.selectable", c.hash),
          c.parents.length > 1 ? h("span", "merge of " + c.parents.map((p) => p.slice(0, 7)).join(" + ")) : null,
          h("button.button.quiet", { onclick: () => newBranch(c.hash) }, "Branch from Here…"))),
      c.files.length ? h("div.detail-files", c.files.map((f) =>
        h("div.row", { title: f.old ? `${f.old} → ${f.path}` : f.path, onclick: () => scrollToFile(f.path) },
          h("span.mark." + f.status, f.status), h("span.main", f.path)))) : null,
      diffView(c.diff, { empty: "No changes in this commit." }),
      truncatedNote(c));
  }

  function scrollToFile(path) {
    for (const el of detailBody.querySelectorAll(".diff-path")) {
      if (el.textContent === path) { el.closest(".diff-file").scrollIntoView({ block: "start" }); return; }
    }
  }

  async function showStash(ref) {
    const look = ++looking;
    state.selected = { kind: "stash", ref };
    render();
    let got;
    try { got = await call("stashShow", { ref }); } catch (e) { if (look === looking) toast(String(e.message || e), true); return; }
    if (look !== looking) return;
    setDetail(ref, diffView(got.diff, { empty: "Nothing in this stash." }), truncatedNote(got));
  }

  function showBranchMenu() {
    document.querySelector(".branch-menu")?.remove();
    const rect = branchButton.getBoundingClientRect();
    const menu = h("div.branch-menu", { style: `left:${rect.left}px; top:${rect.bottom + 4}px` }, h("div.empty", "Reading…"));
    const dismiss = (e) => { if (!menu.contains(e.target)) { menu.remove(); document.removeEventListener("mousedown", dismiss); } };
    document.addEventListener("mousedown", dismiss);
    document.body.appendChild(menu);
    call("branches").then((b) => {
      state.branches = b;
      clear(menu,
        h("div.row", { onclick: () => { menu.remove(); newBranch(); } }, h("span.mark", "+"), h("span.main", "New Branch…")),
        h("div.section-head", "Switch to"),
        b.local.map((x) => h("div.row" + (x.current ? ".on" : ""), {
          onclick: () => { menu.remove(); if (!x.current) act("checkout", { name: x.name }, "On " + x.name, true); },
        }, h("span.mark", x.current ? "●" : ""), h("span.main", x.name), h("span.meta", ago(x.time)))));
    }).catch((e) => clear(menu, h("div.empty", String(e.message || e))));
  }

  // MARK: Doing things

  async function act(method, params = {}, done, reload) {
    if (state.busy) return;
    state.busy = method;
    app.classList.add("busy");
    updateCommit();
    try {
      await call(method, params);
      if (done) toast(done);
    } catch (e) {
      toast(String(e.message || e), true);
    } finally {
      state.busy = null;
      app.classList.remove("busy");
      updateCommit();
    }
    await refresh(reload);
  }

  // Fetch, pull, push: the network's time, not the page's. Only the three
  // buttons wait (git's own lock keeps a pull and a stage apart).
  async function remote(method, done) {
    if (state.remote) return;
    const button = { fetch: fetchButton, pull: pullButton, push: pushButton }[method];
    const label = button.textContent;
    state.remote = method;
    render();
    clear(button, h("span.spin", "◌"), " ", label);
    try {
      await call(method, {});
      if (done) toast(done);
    } catch (e) {
      toast(String(e.message || e), true);
    } finally {
      state.remote = null;
      clear(button, label);
    }
    await refresh(true);
  }

  async function commit() {
    if (commitButton.disabled) return;
    const text = message.value;
    state.busy = "commit";
    updateCommit();
    try {
      await call("commit", { message: text, amend: state.amend });
      message.value = "";
      state.message = "";
      amend.checked = false;
      state.amend = false;
      // What was shown (a staged diff) is in the commit now.
      clearDetail();
      toast("Committed");
    } catch (e) {
      // The message stays, for another try (a hook said no, no user.email…).
      toast(String(e.message || e), true);
    } finally {
      state.busy = null;
      updateCommit();
    }
    await refresh(true);
  }

  async function discard(change) {
    const ok = await dialog({
      title: `Discard changes in ${change.path.split("/").pop()}?`,
      message: change.untracked ? "The file is new: it will be deleted." : "Its changes go back to what's staged (or the last commit).",
      ok: "Discard", danger: true,
    });
    if (ok) act("discard", { paths: [change.path], untracked: !!change.untracked });
  }

  async function resolve(change, side) {
    const ok = await dialog({
      title: `Use ${side === "ours" ? "our" : "their"} ${change.path.split("/").pop()}?`,
      message: `The file becomes ${side === "ours" ? "this branch's" : "the incoming"} version, conflicts and all of the other side's changes in it gone, and is marked resolved.`,
      ok: side === "ours" ? "Use Ours" : "Use Theirs", danger: true,
    });
    if (ok) act("resolve", { paths: [change.path], side }, "Resolved " + change.path.split("/").pop());
  }

  async function discardHunk(patch) {
    const ok = await dialog({ title: "Discard this hunk?", message: "Its changes in the file are undone.", ok: "Discard", danger: true });
    if (ok) act("applyPatch", { patch, reverse: true });
  }

  async function newBranch(from) {
    const name = await dialog({ title: from ? "New branch from " + from.slice(0, 7) : "New branch", field: { placeholder: "name" }, ok: "Create" });
    if (name && name.trim()) act("createBranch", { name: name.trim(), from }, "On " + name.trim(), true);
  }

  async function deleteBranch(name) {
    const ok = await dialog({ title: `Delete ${name}?`, message: "Only if it's merged; git refuses otherwise.", ok: "Delete", danger: true });
    if (!ok) return;
    try {
      await call("deleteBranch", { name });
      toast("Deleted " + name);
    } catch (e) {
      const force = await dialog({ title: `${name} isn't merged`, message: String(e.message || e) + "\n\nDelete it anyway? Its commits are lost unless another branch has them.", ok: "Delete Anyway", danger: true });
      if (force) await act("deleteBranch", { name, force: true }, "Deleted " + name);
    }
    await refresh(true);
  }

  async function stash() {
    const name = await dialog({ title: "Stash the changes", message: "Staged, unstaged and new files are put aside.", field: { placeholder: "message (optional)" }, ok: "Stash" });
    if (name !== null) act("stash", { message: name.trim() }, "Stashed", true);
  }

  async function dropStash(ref) {
    const ok = await dialog({ title: `Drop ${ref}?`, message: "Its changes are lost.", ok: "Drop", danger: true });
    if (ok) act("stashDrop", { ref }, "Dropped", true);
  }

  // Something ran in a terminal: read again (once things go quiet).
  let soon = null;
  block.on("changed", () => { clearTimeout(soon); soon = setTimeout(() => refresh(state.tab !== "changes"), 400); });
  window.addEventListener("focus", () => refresh(false));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") document.querySelector(".branch-menu")?.remove();
  });

  render();
  clearDetail();
  refresh(true);
})();
