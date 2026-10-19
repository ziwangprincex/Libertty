// Before speedscope starts: its colors follow the terminal's theme, and it
// makes `window.speedscope` (its way in for a profile handed over by a
// program), which it does only when the address names a local profile.
// The script it then asks for isn't there (and the page's CSP wouldn't run it).
(function () {
  const dark = (window.__blockInit && window.__blockInit.theme && window.__blockInit.theme.dark) !== false;
  try { window.localStorage["speedscope-color-scheme"] = dark ? "DARK" : "LIGHT"; } catch (e) { /* no storage: speedscope follows the system */ }
  // A recording has no meaningful time order: it opens heaviest first.
  history.replaceState(null, "", "#localProfilePath=libertty-handed-over&view=left-heavy");
})();
