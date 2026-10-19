// The canvas block's page (Libertty's own code around Excalidraw, MIT): one
// .excalidraw file, drawn on and written back a moment after each change.
// The native side reads and writes the file (block.call "read"/"write"),
// refuses to overwrite a change made elsewhere, and says when one happens.
import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw, MainMenu, serializeAsJSON, restore, exportToBlob, exportToSvg, hashElementsVersion,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

const call = (method, params) => block.call(method, params);

function themeName() {
  return document.documentElement.style.colorScheme === "light" ? "light" : "dark";
}

function App() {
  const [initial, setInitial] = useState(null);
  const [failure, setFailure] = useState(null);
  const [theme, setTheme] = useState(themeName());
  const [conflict, setConflict] = useState(null);
  const api = useRef(null);
  const readOnly = useRef(false);
  // The drawing as last written: its version, and what's saved besides the
  // elements (the background, the grid). A change is one or the other.
  const sceneKey = useRef({ version: null, background: null });
  const doc = useRef(null);

  const look = () => {
    const a = api.current?.getAppState() || {};
    return [a.viewBackgroundColor, a.gridSize, a.gridModeEnabled].join("|");
  };
  const keyOf = (elements) => ({ version: hashElementsVersion(elements), background: look() });

  // A file read and shown: the page's own start, or a change taken in.
  function applyFile(file, { first }) {
    const data = file.text.trim() ? JSON.parse(file.text) : { elements: [] };
    const scene = restore(data, null, null, { repairBindings: true });
    if (first) readOnly.current = !file.writable;
    const shown = { elements: scene.elements, appState: { ...scene.appState, theme: themeName() }, files: scene.files, scrollToContent: !!first };
    if (first) { setInitial(shown); sceneKey.current = keyOf(scene.elements); }
    else if (api.current) {
      api.current.updateScene({ elements: shown.elements, appState: { viewBackgroundColor: scene.appState.viewBackgroundColor } });
      sceneKey.current = keyOf(shown.elements);
    }
  }

  useEffect(() => {
    doc.current = block.fileDoc({
      serialize: () => api.current ? serializeAsJSON(api.current.getSceneElementsIncludingDeleted(), api.current.getAppState(), api.current.getFiles(), "local") : "",
      apply: applyFile,
      onConflict: (keep, take) => setConflict((shown) => shown || { keep, take }),
    });
    doc.current.load().catch((e) => {
      // The page's start fails: say so; later bad reads leave the drawing be.
      if (!api.current) setFailure(String(e.message || e));
      else block.toast("Couldn't read the file: " + String(e.message || e), true);
    });
    block.on("save", async ({ id }) => { const ok = await doc.current.save(); call("saveDone", { ok, id }); });
    block.on("fileChanged", () => doc.current.external().catch(() => {}));
    block.on("export", (format) => exportImage(format));
    const observer = new MutationObserver(() => setTheme(themeName()));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["style"] });
    return () => observer.disconnect();
  }, []);

  function changed(elements) {
    if (!api.current || readOnly.current) return;
    const key = keyOf(elements);
    if (key.version === sceneKey.current.version && key.background === sceneKey.current.background) return;
    sceneKey.current = key;
    doc.current.changed();
  }

  async function exportImage(format) {
    const a = api.current;
    if (!a) return;
    const elements = a.getSceneElements();
    if (!elements.length) return block.toast("Nothing to export yet.");
    const appState = { ...a.getAppState(), exportBackground: true, exportWithDarkMode: theme === "dark" };
    try {
      let data;
      if (format === "svg") {
        const svg = await exportToSvg({ elements, appState, files: a.getFiles() });
        data = btoa(unescape(encodeURIComponent(svg.outerHTML)));
      } else {
        const blob = await exportToBlob({ elements, appState, files: a.getFiles(), mimeType: "image/png", getDimensions: (w, h) => ({ width: w * 2, height: h * 2, scale: 2 }) });
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let s = "";
        for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        data = btoa(s);
      }
      await call("export", { format, data });
    } catch (e) { block.toast(String(e.message || e), true); }
  }

  if (failure) return <div className="empty">{"Couldn't read the drawing: " + failure}</div>;
  if (!initial) return <div className="empty">Reading…</div>;
  const banner = conflict ? (
    <div className="conflict">
      <span>The file changed on disk since it was read here: saving now replaces that change.</span>
      <button className="button" onClick={() => { setConflict(null); conflict.keep(); }}>Keep Mine</button>
      <button className="button quiet" onClick={() => { setConflict(null); conflict.take(); }}>Use the File's</button>
    </div>
  ) : null;
  return (
    <>
    {banner}
    <Excalidraw
      excalidrawAPI={(a) => { api.current = a; window.libertty_canvas = { api: a, save: () => doc.current.save() }; }}
      initialData={initial}
      theme={theme}
      viewModeEnabled={readOnly.current}
      onChange={changed}
      UIOptions={{ canvasActions: { loadScene: false, saveToActiveFile: false, export: false, saveAsImage: false, toggleTheme: false } }}
    >
      <MainMenu>
        <MainMenu.Item onSelect={() => exportImage("png")}>Export PNG…</MainMenu.Item>
        <MainMenu.Item onSelect={() => exportImage("svg")}>Export SVG…</MainMenu.Item>
        <MainMenu.Item onSelect={() => call("reveal")}>Show in Finder</MainMenu.Item>
        <MainMenu.Separator />
        <MainMenu.DefaultItems.ClearCanvas />
        <MainMenu.DefaultItems.ChangeCanvasBackground />
        <MainMenu.DefaultItems.Help />
      </MainMenu>
    </Excalidraw>
    </>
  );
}

window.EXCALIDRAW_ASSET_PATH = new URL("lib/", location.href).href;
createRoot(document.getElementById("app")).render(<App />);
