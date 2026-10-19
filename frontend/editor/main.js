// The editor block (Libertty's own code; CodeMirror 6 is MIT). The native side
// owns the file: it hands the text over with `libertty.load`, asks for it back
// to save, and tells the page when the file changed on disk. Messages go back
// through window.webkit.messageHandlers.libertty.
import { EditorState, Compartment, EditorSelection } from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLineGutter, highlightSpecialChars, drawSelection,
  dropCursor, rectangularSelection, crosshairCursor, highlightActiveLine,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import {
  indentOnInput, syntaxHighlighting, HighlightStyle, bracketMatching, foldGutter, foldKeymap,
  StreamLanguage, indentUnit,
} from "@codemirror/language";
import { searchKeymap, highlightSelectionMatches, openSearchPanel } from "@codemirror/search";
import { autocompletion, completionKeymap, closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { tags as t } from "@lezer/highlight";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { cpp } from "@codemirror/lang-cpp";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { go } from "@codemirror/lang-go";
import { java } from "@codemirror/lang-java";
import { sql } from "@codemirror/lang-sql";
import { xml } from "@codemirror/lang-xml";
import { yaml } from "@codemirror/lang-yaml";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { kotlin, scala, csharp, objectiveC } from "@codemirror/legacy-modes/mode/clike";
import { diff } from "@codemirror/legacy-modes/mode/diff";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { vim, Vim } from "@replit/codemirror-vim";

const post = (message) => window.webkit?.messageHandlers?.libertty?.postMessage(message);

const languages = {
  javascript: () => javascript({ jsx: true }), typescript: () => javascript({ typescript: true, jsx: true }),
  python: () => python(), rust: () => rust(), cpp: () => cpp(), json: () => json(), markdown: () => markdown(),
  html: () => html(), css: () => css(), go: () => go(), java: () => java(), sql: () => sql(), xml: () => xml(),
  yaml: () => yaml(), swift: () => StreamLanguage.define(swift), shell: () => StreamLanguage.define(shell),
  toml: () => StreamLanguage.define(toml), ruby: () => StreamLanguage.define(ruby), lua: () => StreamLanguage.define(lua),
  dockerfile: () => StreamLanguage.define(dockerFile), kotlin: () => StreamLanguage.define(kotlin),
  scala: () => StreamLanguage.define(scala), csharp: () => StreamLanguage.define(csharp),
  objc: () => StreamLanguage.define(objectiveC), diff: () => StreamLanguage.define(diff),
  ini: () => StreamLanguage.define(properties),
};

const language = new Compartment(), theme = new Compartment(), keys = new Compartment();
const readOnly = new Compartment(), separator = new Compartment(), indent = new Compartment();
let view = null;
// The text as last saved (or loaded): what "unsaved changes" compares against.
let savedText = "";
let lastDirty = false;
let pending = null;
// The text a save is writing: once the native side says it's on disk, it's
// what "unsaved" compares against — not whatever was typed meanwhile.
let saving = null;

// The text with the file's own line ends (`doc.toString()` always joins with \n).
function docText() { return view.state.sliceDoc(); }

// `savedText` null: the file is gone from disk, so whatever is here is unsaved.
function dirty() { return view !== null && (savedText === null || docText() !== savedText); }

// While there are unsaved changes, the native side keeps a copy (a second
// behind): if this page's process dies, the text comes back from it.
let backupTimer = null;
function scheduleBackup() {
  clearTimeout(backupTimer);
  backupTimer = setTimeout(() => { if (dirty()) post({ type: "backup", text: docText() }); }, 1000);
}

function reportDirty() {
  const now = dirty();
  if (now !== lastDirty) { lastDirty = now; post({ type: "dirty", dirty: now }); }
}

// The terminal's theme, as the native side sends it: background, foreground,
// selection, cursor and the 16 ANSI colors that syntax colors are drawn from.
function themeExtension(c) {
  const a = c.ansi;
  const style = HighlightStyle.define([
    { tag: [t.keyword, t.operatorKeyword, t.modifier, t.controlKeyword], color: a[5] },
    { tag: [t.string, t.special(t.string), t.regexp], color: a[2] },
    { tag: [t.number, t.bool, t.null, t.atom], color: a[3] },
    { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: c.muted, fontStyle: "italic" },
    { tag: [t.typeName, t.className, t.namespace], color: a[6] },
    { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], color: a[4] },
    { tag: [t.definition(t.variableName), t.definition(t.propertyName)], color: c.fg },
    { tag: [t.propertyName, t.attributeName], color: a[12] || a[4] },
    { tag: [t.tagName], color: a[1] },
    { tag: [t.heading], color: a[4], fontWeight: "600" },
    { tag: [t.link, t.url], color: a[6], textDecoration: "underline" },
    { tag: [t.emphasis], fontStyle: "italic" }, { tag: [t.strong], fontWeight: "600" },
    { tag: [t.inserted], color: a[2] }, { tag: [t.deleted], color: a[1] }, { tag: [t.changed], color: a[3] },
    { tag: [t.meta, t.processingInstruction], color: a[8] || c.muted },
    { tag: [t.invalid], color: a[1] },
  ]);
  const base = EditorView.theme({
    "&": { color: c.fg, backgroundColor: c.bg, height: "100%", fontSize: c.fontSize + "px" },
    ".cm-scroller": { fontFamily: c.font, lineHeight: "1.55" },
    ".cm-content": { caretColor: c.cursor, padding: "10px 0 40vh" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: c.cursor, borderLeftWidth: "2px" },
    "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, ::selection":
      { backgroundColor: c.selection },
    ".cm-activeLine": { backgroundColor: c.line },
    ".cm-gutters": { backgroundColor: c.bg, color: c.muted, border: "none", paddingLeft: "6px" },
    ".cm-activeLineGutter": { backgroundColor: "transparent", color: c.fg },
    ".cm-foldPlaceholder": { backgroundColor: c.line, border: "none", color: c.muted },
    ".cm-matchingBracket, .cm-nonmatchingBracket": { backgroundColor: c.line, outline: "1px solid " + c.muted },
    ".cm-searchMatch": { backgroundColor: c.match, outline: "1px solid " + c.muted },
    ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: c.selection },
    ".cm-selectionMatch": { backgroundColor: c.line },
    ".cm-panels": { backgroundColor: c.panel, color: c.fg, borderColor: c.line },
    ".cm-panels input, .cm-panels button": { font: "12px " + c.ui, color: c.fg },
    ".cm-textfield": { backgroundColor: c.bg, border: "1px solid " + c.line, borderRadius: "6px", padding: "3px 6px" },
    ".cm-button": { backgroundImage: "none", backgroundColor: c.line, border: "none", borderRadius: "6px", padding: "3px 9px" },
    ".cm-tooltip": { backgroundColor: c.panel, color: c.fg, border: "1px solid " + c.line, borderRadius: "8px" },
    ".cm-tooltip-autocomplete > ul > li[aria-selected]": { backgroundColor: c.selection, color: c.fg },
    ".cm-vim-panel": { fontFamily: c.font },
  }, { dark: c.dark });
  return [base, syntaxHighlighting(style)];
}

function saveKey() {
  // ⌘S saves through the native side (it owns the file); the text goes with it.
  saving = docText();
  post({ type: "save", text: saving });
  return true;
}

function build(options) {
  const extensions = [
    lineNumbers(), highlightActiveLineGutter(), highlightSpecialChars(), history(), foldGutter(), drawSelection(),
    dropCursor(), EditorState.allowMultipleSelections.of(true), indentOnInput(), bracketMatching(), closeBrackets(),
    autocompletion({ activateOnTyping: false }), rectangularSelection(), crosshairCursor(), highlightActiveLine(),
    highlightSelectionMatches(),
    keys.of(options.keymap === "vim" ? vim() : []),
    keymap.of([
      { key: "Mod-s", run: saveKey, preventDefault: true },
      ...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap,
      ...completionKeymap, indentWithTab,
    ]),
    language.of(languages[options.language]?.() ?? []),
    theme.of(themeExtension(options.theme)),
    readOnly.of(EditorState.readOnly.of(!!options.readOnly)),
    separator.of(EditorState.lineSeparator.of(options.crlf ? "\r\n" : "\n")),
    indent.of(indentUnit.of(options.indent || "    ")),
    EditorView.updateListener.of((update) => {
      if (update.docChanged) { reportDirty(); scheduleBackup(); }
      if (update.selectionSet || update.docChanged) {
        const head = update.state.selection.main.head;
        const line = update.state.doc.lineAt(head);
        post({ type: "cursor", line: line.number, column: head - line.from + 1 });
      }
    }),
    EditorView.lineWrapping,
  ];
  return EditorState.create({ doc: options.text, extensions });
}

function goToLine(n) {
  if (!n || !view) return;
  const line = view.state.doc.line(Math.max(1, Math.min(n, view.state.doc.lines)));
  view.dispatch({ selection: EditorSelection.cursor(line.from), effects: EditorView.scrollIntoView(line.from, { y: "center" }) });
}

function setFont(c) {
  // Scrollbars and form controls in the theme's light or dark.
  document.documentElement.style.colorScheme = c.dark ? "dark" : "light";
  if (!c.fontURL) return;
  let style = document.getElementById("libertty-font");
  if (!style) {
    style = document.createElement("style");
    style.id = "libertty-font";
    document.head.appendChild(style);
  }
  style.textContent = `@font-face { font-family: 'Libertty Mono'; src: url("${c.fontURL}"); }`;
}

function showBanner(text, actions) {
  hideBanner();
  const bar = document.createElement("div");
  bar.id = "banner";
  const label = document.createElement("span");
  label.textContent = text;
  bar.appendChild(label);
  for (const [title, run] of actions) {
    const button = document.createElement("button");
    button.textContent = title;
    button.onclick = () => { hideBanner(); run(); };
    bar.appendChild(button);
  }
  document.body.appendChild(bar);
}

function hideBanner() { document.getElementById("banner")?.remove(); }

window.libertty = {
  // A file opened (or reopened): its text, language, theme, and where to go.
  load(options) {
    setFont(options.theme);
    document.body.style.background = options.theme.bg;
    document.documentElement.style.setProperty("--banner-bg", options.theme.panel);
    document.documentElement.style.setProperty("--banner-fg", options.theme.fg);
    document.documentElement.style.setProperty("--banner-line", options.theme.line);
    savedText = options.text;
    lastDirty = false;
    const state = build(options);
    if (view) { view.setState(state); } else { view = new EditorView({ state, parent: document.getElementById("editor") }); }
    goToLine(options.line);
    view.focus();
    post({ type: "dirty", dirty: false });
  },
  // The native side wrote the text it took (`takeText`, or ⌘S's) to the file.
  saved() { if (saving !== null) savedText = saving; saving = null; reportDirty(); },
  // Null with no editor yet: a save must never write an empty file for it.
  takeText() { if (!view) return null; saving = docText(); return saving; },
  text() { return view ? docText() : ""; },
  // The page came back after its process died: the unsaved text it had.
  restore(text) {
    if (!view) return;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
    reportDirty();
    showBanner("The editor restarted. Your unsaved changes are back (as of a moment before).", [["OK", () => {}]]);
  },
  // The file was deleted or moved away: the text stays, and counts as unsaved.
  diskGone() {
    savedText = null;
    reportDirty();
    showBanner("The file isn't on disk any more. Save to put it back.", [["OK", () => {}]]);
  },
  isDirty() { return dirty(); },
  focus() { view?.focus(); },
  goToLine,
  find() { if (view) openSearchPanel(view); },
  setTheme(c) {
    setFont(c);
    document.body.style.background = c.bg;
    view?.dispatch({ effects: theme.reconfigure(themeExtension(c)) });
  },
  setKeymap(name) { view?.dispatch({ effects: keys.reconfigure(name === "vim" ? vim() : []) }); },
  // Someone else changed the file. Unchanged here: take theirs, keeping the
  // place; changed here too: ask.
  diskChanged(text) {
    if (!view || text === docText()) { savedText = text; reportDirty(); return; }
    const take = () => {
      const head = view.state.selection.main.head;
      const scroll = view.scrollDOM.scrollTop;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
      // Positions count a line end as one: clamp against the new document, not the text.
      view.dispatch({ selection: EditorSelection.cursor(Math.min(head, view.state.doc.length)) });
      view.scrollDOM.scrollTop = scroll;
      savedText = text;
      reportDirty();
    };
    if (!dirty()) return take();
    pending = text;
    showBanner("The file changed on disk.", [["Reload", () => { take(); pending = null; }], ["Keep Mine", () => { savedText = pending; pending = null; reportDirty(); }]]);
  },
  // `--ui-probe`: type at the cursor, as keystrokes would.
  insert(text) {
    if (!view) return;
    view.dispatch(view.state.replaceSelection(text));
  },
  vimMode() { return view ? !!Vim.maybeInitVimState_?.(view.cm) : false; },
};

// Vim's :w, :q, :wq and :x (`editor-keymap = vim`), through the native side like ⌘S.
Vim.defineEx("write", "w", () => saveKey());
Vim.defineEx("quit", "q", () => post({ type: "close" }));
Vim.defineEx("wq", "wq", () => { saving = docText(); post({ type: "save", text: saving, close: true }); });
Vim.defineEx("xit", "x", () => { saving = docText(); post({ type: "save", text: saving, close: true }); });

post({ type: "ready" });
