// The board's page (Libertty's own code): a kanban kept as Markdown — each
// `## Column` a column, each `- [ ] card` a card (indented lines under it
// are its notes; `#tags` show as tags). Every other line stays where it was
// (a title, a paragraph, a footnote). Saved a moment after each change.
(function () {
  const { h, clear, toast, dialog } = block;
  const call = block.call.bind(block);
  const app = document.getElementById("app");

  // MARK: Markdown

  // { head: [lines before the first column], columns: [{ name, entries }] }
  // where an entry is { card: { text, done, notes } } or { line }, in order.
  function parse(text) {
    const board = { head: [], columns: [] };
    let column = null, card = null;
    for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
      const heading = line.match(/^##\s+(.*?)\s*$/);
      if (heading) { column = { name: heading[1], entries: [] }; board.columns.push(column); card = null; continue; }
      if (!column) { board.head.push(line); continue; }
      const item = line.match(/^[-*]\s+(?:\[([ xX])\]\s+)?(.*)$/);
      if (item) {
        card = { text: item[2], done: !!item[1] && item[1] !== " ", notes: [] };
        column.entries.push({ card });
        continue;
      }
      // Indented, or blank, under a card: its notes.
      if (card && (/^(\s{2,}|\t)/.test(line) || !line.trim())) { card.notes.push(line.replace(/^(\s{2}|\t)/, "")); continue; }
      card = null;
      column.entries.push({ line });
    }
    // A card's notes end at its last line with text: blank lines after it are
    // the file's, between the card and what follows.
    for (const c of board.columns) {
      const entries = [];
      for (const e of c.entries) {
        entries.push(e);
        if (!e.card) continue;
        let blanks = 0;
        while (e.card.notes.length && !e.card.notes[e.card.notes.length - 1].trim()) { e.card.notes.pop(); blanks++; }
        for (let i = 0; i < blanks; i++) entries.push({ line: "" });
      }
      c.entries = entries;
    }
    while (board.head.length && !board.head[board.head.length - 1].trim()) board.head.pop();
    return board;
  }

  function serialize(board) {
    const out = [];
    if (board.head.length) out.push(...board.head, "");
    for (const c of board.columns) {
      out.push("## " + c.name, "");
      const body = [];
      for (const e of c.entries) {
        if (e.card) {
          body.push(`- [${e.card.done ? "x" : " "}] ${e.card.text}`);
          for (const n of e.card.notes) body.push(n ? "  " + n : "");
        } else body.push(e.line);
      }
      while (body.length && !body[body.length - 1].trim()) body.pop();
      while (body.length && !body[0].trim()) body.shift();
      if (body.length) out.push(...body, "");
    }
    return out.join("\n").replace(/\n+$/, "") + "\n";
  }

  const cardsOf = (column) => column.entries.filter((e) => e.card).map((e) => e.card);

  // MARK: State

  let board = { head: [], columns: [] };
  let doc = null;
  let editing = null; // { column, card } — card: null for a new one
  let selected = null; // { column, card }
  let dragged = null;

  function changed() {
    render();
    doc.changed();
  }

  // MARK: Layout

  const title = h("span.title");
  const columnsEl = h("div.columns");
  app.append(
    h("div.bar", title, h("span.spacer"),
      h("button.button.quiet", { onclick: () => call("reveal") }, "Show in Finder"),
      h("button.button.quiet", { onclick: () => call("openText") }, "Edit as Text")),
    columnsEl,
    h("div.hint", "Drag cards between columns (or ⌥← ⌥→, ⌥↑ ⌥↓ on a selected card) · Enter edits · ⌫ deletes · double-click a column's name to rename it"));

  function tagsOf(text) { return [...text.matchAll(/(^|\s)#([\w-]+)/g)].map((m) => m[2]); }

  function render() {
    const top = columnsEl.scrollLeft;
    clear(columnsEl, board.columns.map((column, ci) => renderColumn(column, ci)),
      h("div.new-column", h("button.button.quiet", { onclick: () => addColumn() }, "+ Add Column")));
    columnsEl.scrollLeft = top;
  }

  function renderColumn(column, ci) {
    const cards = h("div.cards");
    for (const e of column.entries) {
      if (!e.card) {
        // The column's other lines: kept, shown faintly, in place.
        if (e.line.trim()) cards.appendChild(h("div.other", { title: "A line of the file between cards" }, e.line));
        continue;
      }
      cards.appendChild(editing && editing.column === ci && editing.card === e.card ? cardEditor(ci, e.card) : renderCard(e.card, ci));
    }
    if (editing && editing.column === ci && editing.card === null) cards.appendChild(cardEditor(ci, null));
    const el = h("section.column", { "data-column": column.name },
      h("div.column-head",
        h("span.name", { title: "Double-click to rename", ondblclick: () => renameColumn(ci) }, column.name),
        h("span.count", String(cardsOf(column).length)),
        h("button.icon", { title: "Move Column Left", onclick: () => moveColumn(ci, -1), disabled: ci === 0 }, "‹"),
        h("button.icon", { title: "Move Column Right", onclick: () => moveColumn(ci, 1), disabled: ci === board.columns.length - 1 }, "›"),
        h("button.icon", { title: "Delete Column", onclick: () => deleteColumn(ci) }, "×")),
      cards,
      editing && editing.column === ci && editing.card === null ? null
        : h("button.button.quiet.add", { onclick: () => { editing = { column: ci, card: null }; render(); } }, "+ Add Card"));
    el.addEventListener("dragover", (e) => {
      if (!dragged) return;
      e.preventDefault();
      el.classList.add("drop");
      const at = dropIndex(cards, e.clientY);
      cards.querySelector(".drop-line")?.remove();
      const line = h("div.drop-line");
      const before = cards.querySelectorAll(".card")[at];
      before ? cards.insertBefore(line, before) : cards.appendChild(line);
    });
    el.addEventListener("dragleave", (e) => { if (!el.contains(e.relatedTarget)) { el.classList.remove("drop"); cards.querySelector(".drop-line")?.remove(); } });
    el.addEventListener("drop", (e) => {
      e.preventDefault();
      if (!dragged) return;
      moveCard(dragged.column, dragged.card, ci, dropIndex(cards, e.clientY));
      dragged = null;
    });
    return el;
  }

  // Where in the cards (not the other lines) a drop at `y` goes.
  function dropIndex(cards, y) {
    const list = [...cards.querySelectorAll(".card")];
    const i = list.findIndex((c) => { const r = c.getBoundingClientRect(); return y < r.top + r.height / 2; });
    return i < 0 ? list.length : i;
  }

  function renderCard(card, ci) {
    const on = selected && selected.column === ci && selected.card === card;
    const notes = card.notes.join("\n").trim();
    const el = h("div.card" + (card.done ? ".done" : "") + (on ? ".on" : ""), {
      tabindex: 0, draggable: "true", "data-card": card.text,
      onclick: () => { selected = { column: ci, card }; render(); focusSelected(); },
      ondblclick: () => { editing = { column: ci, card }; render(); },
      ondragstart: (e) => { dragged = { column: ci, card }; el.classList.add("dragging"); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", card.text); },
      ondragend: () => { dragged = null; el.classList.remove("dragging"); render(); },
    },
      h("div.title",
        h("input.check", { type: "checkbox", checked: card.done, title: card.done ? "Not done" : "Done",
          onclick: (e) => e.stopPropagation(), onchange: (e) => { card.done = e.target.checked; changed(); } }),
        h("span.text", card.text.replace(/(^|\s)#[\w-]+/g, "").trim() || card.text)),
      notes ? h("div.notes", notes) : null,
      tagsOf(card.text).length ? h("div.tags", tagsOf(card.text).map((t) => h("span.tag", "#" + t))) : null,
      h("div.card-actions",
        h("button.icon", { title: "Edit", onclick: (e) => { e.stopPropagation(); editing = { column: ci, card }; render(); } }, "✎"),
        h("button.icon", { title: "Delete", onclick: (e) => { e.stopPropagation(); deleteCard(ci, card); } }, "×")));
    return el;
  }

  function cardEditor(ci, card) {
    const isNew = card === null;
    const source = isNew ? { text: "", notes: [] } : card;
    const area = h("textarea", { placeholder: "Card (first line), notes below. #tags work." });
    area.value = [source.text, ...source.notes].join("\n").replace(/\n+$/, "");
    const done = () => {
      const [first, ...rest] = area.value.split("\n");
      const text = (first || "").trim();
      editing = null;
      if (!text) { if (!isNew) deleteCard(ci, card); else render(); return; }
      const notes = rest.slice();
      while (notes.length && !notes[notes.length - 1].trim()) notes.pop();
      if (isNew) {
        const fresh = { text, done: false, notes };
        board.columns[ci].entries.push({ card: fresh });
        editing = { column: ci, card: null }; // straight on to the next
      } else Object.assign(card, { text, notes });
      changed();
    };
    area.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.altKey) { e.preventDefault(); done(); }
      if (e.key === "Escape") { e.preventDefault(); editing = null; render(); }
    });
    setTimeout(() => { area.focus(); area.setSelectionRange(area.value.length, area.value.length); }, 0);
    return h("div.editor", area, h("div.row-buttons",
      h("button.button.quiet", { onclick: () => { editing = null; render(); } }, "Cancel"),
      h("button.button.primary", { onclick: done }, isNew ? "Add" : "Save")));
  }

  function focusSelected() {
    setTimeout(() => columnsEl.querySelector(".card.on")?.focus(), 0);
  }

  // MARK: Changes

  function moveCard(fromColumn, card, toColumn, cardIndex) {
    const from = board.columns[fromColumn], to = board.columns[toColumn];
    const at = from.entries.findIndex((e) => e.card === card);
    if (at < 0) return;
    from.entries.splice(at, 1);
    // Among the cards: after the cardIndex-th card's last line (or at the end).
    const cards = cardsOf(to);
    let insertAt = to.entries.length;
    if (cardIndex < cards.length) insertAt = to.entries.findIndex((e) => e.card === cards[cardIndex]);
    // At the end: right after the last card (the blank line and paragraph
    // that follow it stay after the cards), not after the paragraph.
    else if (cards.length) insertAt = to.entries.findIndex((e) => e.card === cards[cards.length - 1]) + 1;
    to.entries.splice(insertAt, 0, { card });
    selected = { column: toColumn, card };
    changed();
    focusSelected();
  }

  function deleteCard(ci, card) {
    const at = board.columns[ci].entries.findIndex((e) => e.card === card);
    if (at >= 0) board.columns[ci].entries.splice(at, 1);
    selected = null;
    changed();
  }

  async function addColumn() {
    const name = await dialog({ title: "New column", field: { placeholder: "name" }, ok: "Add" });
    if (!name || !name.trim()) return;
    board.columns.push({ name: name.trim(), entries: [] });
    changed();
  }

  async function renameColumn(ci) {
    const name = await dialog({ title: "Rename column", field: { value: board.columns[ci].name }, ok: "Rename" });
    if (!name || !name.trim()) return;
    board.columns[ci].name = name.trim();
    changed();
  }

  function moveColumn(ci, by) {
    const to = ci + by;
    if (to < 0 || to >= board.columns.length) return;
    const [c] = board.columns.splice(ci, 1);
    board.columns.splice(to, 0, c);
    changed();
  }

  async function deleteColumn(ci) {
    const c = board.columns[ci];
    if (cardsOf(c).length) {
      const ok = await dialog({ title: `Delete ${c.name}?`, message: `Its ${cardsOf(c).length} card${cardsOf(c).length === 1 ? "" : "s"} go with it.`, ok: "Delete", danger: true });
      if (!ok) return;
    }
    board.columns.splice(ci, 1);
    changed();
  }

  // The keyboard, on a selected card.
  document.addEventListener("keydown", (e) => {
    if (!selected || editing || e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT") return;
    const { column, card } = selected;
    if (!board.columns[column]?.entries.some((x) => x.card === card)) return;
    const cards = cardsOf(board.columns[column]);
    const index = cards.indexOf(card);
    const last = (ci) => cardsOf(board.columns[ci]).length;
    if (e.altKey && e.key === "ArrowRight" && column < board.columns.length - 1) { e.preventDefault(); moveCard(column, card, column + 1, last(column + 1)); }
    else if (e.altKey && e.key === "ArrowLeft" && column > 0) { e.preventDefault(); moveCard(column, card, column - 1, last(column - 1)); }
    else if (e.altKey && e.key === "ArrowUp" && index > 0) { e.preventDefault(); moveCard(column, card, column, index - 1); }
    else if (e.altKey && e.key === "ArrowDown" && index < last(column) - 1) { e.preventDefault(); moveCard(column, card, column, index + 2); }
    else if (e.key === "Enter") { e.preventDefault(); editing = { column, card }; render(); }
    else if (e.key === "Backspace" || e.key === "Delete") { e.preventDefault(); deleteCard(column, card); }
    else if (e.key === " ") { e.preventDefault(); card.done = !card.done; changed(); }
    else if (e.key === "Escape") { selected = null; render(); }
  });

  // MARK: The file

  doc = block.fileDoc({
    delay: 300,
    serialize: () => serialize(board),
    apply(file) {
      board = parse(file.text);
      if (!file.text.trim()) {
        // A new board starts with the usual three columns (written once something goes in).
        board = { head: ["# " + file.name.replace(/(\.board)?\.md$/i, "")], columns: ["To Do", "Doing", "Done"].map((name) => ({ name, entries: [] })) };
      }
      clear(title, file.name);
      render();
    },
    onConflict(keep, take) {
      // One line above the board until a side is chosen.
      if (app.querySelector(".conflict")) return;
      const line = h("div.conflict", h("span", "The file changed on disk since it was read here: saving now replaces that change."),
        h("button.button", { onclick: () => { line.remove(); keep(); } }, "Keep Mine"),
        h("button.button.quiet", { onclick: () => { line.remove(); take(); } }, "Use the File's"));
      app.insertBefore(line, columnsEl);
    },
  });
  block.on("save", async ({ id }) => { const ok = await doc.save(); call("saveDone", { ok, id }); });
  block.on("fileChanged", () => doc.external().catch(() => {}));

  window.libertty_board = { get board() { return board; }, parse, serialize, moveCard, save: () => doc.save() };
  doc.load().catch((e) => clear(columnsEl, h("div.empty", "Couldn't read the board: " + String(e.message || e))));
})();
