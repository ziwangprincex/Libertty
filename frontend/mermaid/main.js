// The diagram page's one script (scripts/build-mermaid.sh bundles it with
// Mermaid): Libertty hands it a diagram's source and gets SVG back. The page
// runs out of any window, with no network (its CSP) and nothing else in it.
import mermaid from 'mermaid';

window.libertty = {
  // options: { id, theme, themeVariables, fontFamily }
  async render(source, options) {
    mermaid.initialize({
      startOnLoad: false,
      // Labels as text, click handlers off, links sanitized.
      securityLevel: 'strict',
      suppressErrorRendering: true,
      theme: options.theme,
      themeVariables: options.themeVariables,
      fontFamily: options.fontFamily,
      // Dagre lays them out: ELK (Mermaid 12's default, EPL-2.0) isn't bundled.
      layout: 'dagre',
      state: { layout: 'dagre' },
      // A diagram's own %%{init}%% may not loosen these, nor restyle the page with CSS.
      secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering', 'themeCSS'],
    });
    try {
      const { svg } = await mermaid.render(options.id, source);
      return svg;
    } finally {
      // What Mermaid measured with, gone.
      document.getElementById(options.id)?.remove();
      document.getElementById('d' + options.id)?.remove();
    }
  },
};
