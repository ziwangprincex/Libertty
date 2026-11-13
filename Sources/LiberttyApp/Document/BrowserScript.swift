import WebKit

/// What `libertty +browser` runs in a page: a world of its own (the page's
/// scripts can't see it or stand in for the DOM calls it makes), defined
/// once a page and kept until it navigates. Refs (`e12`) name elements from
/// `snapshot` on; an element keeps its ref for as long as the page lasts.
///
/// Acting goes through the DOM, as events a page's own handlers take: a
/// click is the pointer and mouse events a click makes, at the element's
/// center (the element there checked first: one under a dialog is
/// "covered"), then `click`, whose default action follows links and submits
/// forms; typing is `execCommand("insertText")`, which WebKit carries out
/// as an edit of its own (trusted `beforeinput` and `input` events, what
/// React and every framework listen to), with setting the value as a last
/// resort. Keys are keydown/keyup events, and their default actions
/// (Enter submits, Tab moves on, Space clicks) are done here, as WebKit
/// wouldn't do them for a script's events. Nothing goes through the window
/// or the keyboard: no focus is taken, and a page in a tab not in front
/// works the same (WebKit slows its timers, though).
enum BrowserScript {
    static let world = WKContentWorld.world(name: "libertty-automation")

    /// The body for `callAsyncJavaScript`: `op` of the library with `a` (its arguments).
    static func call(_ op: String) -> String {
        "const L = globalThis.__libertty ??= (\(library))();\ntry { return await L[\(literal(op))](a); } catch (e) { return {ok: false, error: String(e && e.message || e)}; }"
    }

    private static func literal(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    // Each function answers {ok: true, text?} or {ok: false, error}.
    private static let library = #"""
    () => {
      const refs = new Map(), ids = new WeakMap();
      let next = 1, hovered = null;
      const ok = (text) => ({ok: true, text: text ?? ''});
      const fail = (error) => ({ok: false, error});
      const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
      const cut = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
      const quote = (s) => JSON.stringify(s);
      const style = (el) => el.ownerDocument.defaultView.getComputedStyle(el);

      const refOf = (el) => {
        let r = ids.get(el);
        if (!r) { r = 'e' + next++; ids.set(el, r); refs.set(r, new WeakRef(el)); }
        return r;
      };
      // How an element is named in a message: <button#go>, <div class="modal">.
      const describe = (el) => {
        const r = ids.get(el);
        if (r) return r;
        let s = '<' + el.localName;
        if (el.id) s += '#' + el.id;
        else if (el.classList && el.classList.length) s += ' class=' + quote([...el.classList].slice(0, 2).join(' '));
        return s + '>';
      };

      // Shown at all: not display:none, visibility:hidden, aria-hidden or inert.
      const shown = (el) => {
        if (el.getAttribute('aria-hidden') === 'true' || el.inert) return false;
        if (el.checkVisibility) return el.checkVisibility({checkVisibilityCSS: true});
        const s = style(el);
        return s.display !== 'none' && s.visibility !== 'hidden';
      };
      const hasBox = (el) => [...el.getClientRects()].some(r => r.width > 0 && r.height > 0);

      const textTypes = new Set(['', 'text', 'search', 'email', 'url', 'tel', 'password', 'number']);
      const inputRoles = {button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'button',
        color: 'button', checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox'};
      const sectioning = 'article, aside, main, nav, section';
      const implicitRole = (el) => {
        const t = el.localName;
        switch (t) {
          case 'a': case 'area': return el.hasAttribute('href') ? 'link' : null;
          case 'button': return 'button';
          case 'input': {
            const type = (el.getAttribute('type') || 'text').toLowerCase();
            if (type === 'hidden') return null;
            return Object.hasOwn(inputRoles, type) ? inputRoles[type] : 'textbox';
          }
          case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
          case 'textarea': return 'textbox';
          case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
          case 'img': return el.getAttribute('alt') === '' ? null : 'img';
          case 'nav': return 'navigation';
          case 'main': return 'main';
          case 'header': return el.parentElement && el.parentElement.closest(sectioning) ? null : 'banner';
          case 'footer': return el.parentElement && el.parentElement.closest(sectioning) ? null : 'contentinfo';
          case 'aside': return 'complementary';
          case 'form': return 'form';
          case 'section': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
          case 'article': return 'article';
          case 'ul': case 'ol': case 'menu': return 'list';
          case 'li': return 'listitem';
          case 'table': return 'table';
          case 'tr': return 'row';
          case 'td': return 'cell';
          case 'th': return 'columnheader';
          case 'dialog': return 'dialog';
          case 'summary': return 'button';
          case 'details': case 'fieldset': return 'group';
          case 'progress': return 'progressbar';
          case 'meter': return 'meter';
          case 'p': return 'paragraph';
          case 'hr': return 'separator';
          case 'blockquote': return 'blockquote';
          case 'iframe': case 'frame': return 'iframe';
          case 'output': return 'status';
        }
        if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
        return null;
      };
      const roleOf = (el) => {
        const r = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
        if (r === 'none' || r === 'presentation') return null;
        return r || implicitRole(el);
      };
      const interactiveRoles = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox',
        'listbox', 'option', 'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox',
        'menuitemradio', 'treeitem']);
      // Named by what they hold (a button's label), so their text isn't listed again under them.
      const contentNamed = new Set(['link', 'button', 'heading', 'tab', 'menuitem', 'menuitemcheckbox',
        'menuitemradio', 'option', 'checkbox', 'radio', 'switch', 'treeitem', 'clickable', 'columnheader']);

      // A plain element a page made clickable: an onclick, a tab stop, or the
      // outermost under a pointer cursor (which its children inherit).
      const clickable = (el, pointer, parentPointer) => el.hasAttribute('onclick')
        || (el.hasAttribute('tabindex') && el.tabIndex >= 0) || (pointer && !parentPointer);

      const byIDs = (el, attr) => {
        const root = el.getRootNode();
        return (el.getAttribute(attr) || '').split(/\s+/).filter(Boolean)
          .map(id => root.getElementById ? root.getElementById(id) : el.ownerDocument.getElementById(id)).filter(Boolean);
      };
      const nameOf = (el, role) => {
        const by = byIDs(el, 'aria-labelledby');
        if (by.length) return clean(by.map(e => e.innerText || e.textContent).join(' '));
        const label = clean(el.getAttribute('aria-label'));
        if (label) return label;
        const t = el.localName;
        if (t === 'input' || t === 'select' || t === 'textarea') {
          const type = (el.type || '').toLowerCase();
          if (['button', 'submit', 'reset'].includes(type)) return clean(el.value) || ({submit: 'Submit', reset: 'Reset'})[type] || '';
          if (type === 'image') return clean(el.alt || el.value) || 'Submit';
          const labels = el.labels ? [...el.labels] : [];
          if (labels.length) return clean(labels.map(l => l.innerText || l.textContent).join(' '));
          return clean(el.getAttribute('title') || el.getAttribute('placeholder'));
        }
        if (t === 'img' || t === 'area') return clean(el.getAttribute('alt') || el.getAttribute('title'));
        if (t === 'iframe' || t === 'frame') return clean(el.getAttribute('title'));
        if (contentNamed.has(role)) {
          const text = clean(el.innerText || el.textContent);
          if (text) return text;
          const img = el.querySelector('img[alt], [aria-label]');
          if (img) return clean(img.getAttribute('alt') || img.getAttribute('aria-label'));
        }
        return clean(el.getAttribute('title'));
      };

      const deepActive = (doc) => {
        let a = doc.activeElement;
        while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
        while (a && (a.localName === 'iframe' || a.localName === 'frame')) {
          let inner = null;
          try { inner = a.contentDocument && a.contentDocument.activeElement; } catch (e) {}
          if (!inner || inner === a.contentDocument.body) break;
          a = inner;
        }
        return a;
      };

      const states = (el, role) => {
        const s = [];
        const aria = (n) => el.getAttribute('aria-' + n);
        if (role === 'heading') s.push('level=' + (aria('level') || el.localName.slice(1)));
        if (el.disabled || aria('disabled') === 'true') s.push('disabled');
        if ((el.checked === true) || aria('checked') === 'true') s.push('checked');
        if (aria('checked') === 'mixed' || el.indeterminate) s.push('mixed');
        if (aria('pressed') === 'true') s.push('pressed');
        if (aria('selected') === 'true' || (el.localName === 'option' && el.selected)) s.push('selected');
        const expanded = aria('expanded') ?? (el.localName === 'summary' && el.parentElement && el.parentElement.localName === 'details'
          ? String(el.parentElement.open) : null);
        if (expanded === 'true') s.push('expanded'); else if (expanded === 'false') s.push('collapsed');
        if (el.required || aria('required') === 'true') s.push('required');
        if (el.readOnly || aria('readonly') === 'true') s.push('readonly');
        if (el === deepActive(el.ownerDocument)) s.push('focused');
        return s;
      };
      const valueOf = (el, role) => {
        const t = el.localName;
        if (t === 'select') return [...el.selectedOptions].map(o => clean(o.label || o.text)).join(', ');
        if (t === 'input' || t === 'textarea') {
          if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'color'].includes(el.type)) return null;
          if (el.type === 'password') return el.value ? '•'.repeat(Math.min(8, el.value.length)) : '';
          return el.value;
        }
        if (role === 'textbox' && el.isContentEditable) return clean(el.innerText);
        if (role === 'slider' || role === 'spinbutton' || role === 'progressbar' || role === 'meter')
          return el.getAttribute('aria-valuenow') ?? (el.value != null ? String(el.value) : null);
        return null;
      };

      // What is drawn as the children of `node`: a shadow root's in place of the
      // host's own, a slot's assigned elements, a same-origin frame's document.
      const children = (el) => {
        if (el.shadowRoot) return [...el.shadowRoot.childNodes];
        if (el.localName === 'slot') {
          const assigned = el.assignedNodes({flatten: true});
          return assigned.length ? assigned : [...el.childNodes];
        }
        if (el.localName === 'iframe' || el.localName === 'frame') {
          try { const d = el.contentDocument; if (d && d.body) return [d.body]; } catch (e) {}
          return [];
        }
        return [...el.childNodes];
      };
      const skipped = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link']);
      const hollow = new Set(['paragraph', 'list', 'listitem', 'row', 'cell', 'group', 'blockquote', 'article',
        'region', 'form', 'table']);

      // The page as a tree: [{role, name, ref, states, value, url, kids}] and {text}.
      const tree = (root) => {
        let budget = 30000;
        const walk = (node, parentPointer) => {
          if (--budget < 0) return [];
          if (node.nodeType === 3) {
            const t = node.data.replace(/\s+/g, ' ');
            return t.trim() ? [{text: t}] : (t ? [{text: ' '}] : []);
          }
          if (node.nodeType !== 1) return [];
          const el = node;
          const t = el.localName;
          if (skipped.has(t) || !shown(el)) return [];
          const s = style(el);
          const pointer = s.cursor === 'pointer';
          const role = roleOf(el);
          const isInteractive = interactiveRoles.has(role) || (!role && clickable(el, pointer, parentPointer));
          const r = role || (isInteractive ? 'clickable' : null);
          let kids;
          if (t === 'select') {
            kids = [...el.options].slice(0, 50).map(o => ({role: 'option', name: clean(o.label || o.text),
              states: o.selected ? ['selected'] : (o.disabled ? ['disabled'] : []), kids: []}));
          } else if (t === 'iframe' || t === 'frame') {
            let readable = false;
            try { readable = !!(el.contentDocument && el.contentDocument.body); } catch (e) {}
            if (!readable) return [{role: 'iframe', name: nameOf(el, 'iframe'), note: 'another site: not read', states: [], kids: []}];
            kids = children(el).flatMap(k => walk(k, false));
          } else {
            kids = children(el).flatMap(k => walk(k, pointer));
          }
          // A label's words are its control's name: said there, not again beside it.
          if (t === 'label' && el.control) kids = kids.filter(k => k.text == null);
          if (!r) {
            // A box of its own (a <div>) ends a run of text; an inline one (<b>) is part of it.
            const inline = s.display === 'inline' || s.display === 'contents' || s.display.startsWith('inline-');
            return kids.length && !inline ? [{text: '\n'}, ...kids, {text: '\n'}] : kids;
          }
          const item = {role: r, name: nameOf(el, r), states: states(el, r), value: valueOf(el, r), kids};
          if (isInteractive && hasBox(el)) item.ref = refOf(el);
          if (r === 'link') item.url = el.getAttribute('href');
          if (kids.length && kids.every(k => k.text != null)) {
            // Its name says its text already; or its text is all it has (a paragraph): that's its name.
            if (!item.name && !contentNamed.has(r)) { item.name = clean(kids.map(k => k.text).join(' ')); item.long = true; }
            if (item.name) item.kids = [];
          }
          // A box with nothing in it says nothing (an empty paragraph, a list not filled yet).
          if (hollow.has(r) && !item.name && !item.ref && !item.kids.length && !item.value) return [];
          return [item];
        };
        return walk(root, false);
      };

      // As lines: `- role "name" [ref=e3] [checked]: value → url`, its children indented under it.
      const lines = (items, depth, out, opts) => {
        let run = '';
        const flush = () => {
          for (const part of run.split('\n')) {
            const t = clean(part);
            if (t && !opts.interactive) out.push('  '.repeat(depth) + '- text ' + quote(cut(t, 300)));
          }
          run = '';
        };
        for (const item of items) {
          if (item.text != null) { run += item.text; continue; }
          flush();
          const interactiveOnly = opts.interactive;
          if (!interactiveOnly || item.ref) {
            let line = '  '.repeat(interactiveOnly ? 0 : depth) + '- ' + item.role;
            if (item.name) line += ' ' + quote(cut(item.name, item.long ? 300 : 120));
            if (item.ref) line += ' [ref=' + item.ref + ']';
            for (const s of item.states || []) line += ' [' + s + ']';
            if (item.value != null && item.value !== '') line += ': ' + quote(cut(String(item.value), 120));
            if (item.url) line += ' → ' + cut(item.url, 120);
            if (item.note) line += ' (' + item.note + ')';
            out.push(line);
          }
          lines(item.kids || [], depth + 1, out, opts);
        }
        flush();
        return out;
      };

      // The element an action names: a ref from a snapshot, or a CSS selector.
      const target = (a, required = true) => {
        if (a.ref) {
          const w = refs.get(a.ref);
          if (!w) return {error: 'no ' + a.ref + ' on this page (refs last until it navigates; take a snapshot)'};
          const el = w.deref();
          if (!el || !el.isConnected) return {error: a.ref + ' is gone from the page; take a new snapshot'};
          return {el};
        }
        if (a.selector) {
          let el = null;
          try { el = document.querySelector(a.selector); } catch (e) { return {error: 'not a CSS selector: ' + a.selector}; }
          return el ? {el} : {error: 'nothing matches ' + a.selector};
        }
        return required ? {error: 'which element? a selector, or --ref REF from a snapshot'} : {el: null};
      };

      // Where a click lands: the middle of what's in view of the element (scrolled to first).
      const point = (el, force) => {
        el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
        const view = el.ownerDocument.defaultView;
        const rects = [...el.getClientRects()].filter(r => r.width > 0 && r.height > 0);
        if (!rects.length) return {error: describe(el) + " isn't shown (it has no size on the page)"};
        const r = rects[0];
        const left = Math.max(r.left, 0), right = Math.min(r.right, view.innerWidth);
        const top = Math.max(r.top, 0), bottom = Math.min(r.bottom, view.innerHeight);
        if (right <= left || bottom <= top) return {error: describe(el) + " can't be scrolled into view"};
        const x = (left + right) / 2, y = (top + bottom) / 2;
        if (!force) {
          const root = el.getRootNode();
          const hit = (root.elementFromPoint ? root : el.ownerDocument).elementFromPoint(x, y);
          const reaches = !hit || hit === el || el.contains(hit) || hit.contains(el)
            || (hit.closest && hit.closest('label') && hit.closest('label').control === el);
          if (!reaches) return {error: describe(el) + ' is covered by ' + describe(hit) + " (close what's over it, or --force)"};
        }
        return {x, y};
      };
      const disabled = (el) => el.disabled === true || el.getAttribute('aria-disabled') === 'true'
        || !!(el.closest && el.closest('fieldset[disabled]') && el.matches('button, input, select, textarea'));

      const mouse = (el, type, x, y) => {
        const view = el.ownerDocument.defaultView;
        const bubbles = !type.endsWith('enter') && !type.endsWith('leave');
        const down = type === 'pointerdown' || type === 'mousedown';
        const init = {bubbles, cancelable: bubbles, composed: true, view, clientX: x, clientY: y,
          screenX: view.screenX + x, screenY: view.screenY + y, button: 0, buttons: down ? 1 : 0,
          detail: type.includes('click') || type.endsWith('down') || type.endsWith('up') ? 1 : 0};
        const event = type.startsWith('pointer')
          ? new view.PointerEvent(type, {...init, pointerId: 1, pointerType: 'mouse', isPrimary: true,
              width: 1, height: 1, pressure: down ? 0.5 : 0})
          : new view.MouseEvent(type, init);
        return el.dispatchEvent(event);
      };
      const hoverOn = (el, x, y) => {
        const last = hovered && hovered.deref();
        if (last && last !== el && last.isConnected) {
          for (const type of ['pointerout', 'pointerleave', 'mouseout', 'mouseleave']) mouse(last, type, x, y);
        }
        if (last !== el) for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter']) mouse(el, type, x, y);
        mouse(el, 'pointermove', x, y);
        mouse(el, 'mousemove', x, y);
        hovered = new WeakRef(el);
      };
      const focusable = 'a[href], area[href], button, input, select, textarea, summary, iframe, [tabindex], [contenteditable]:not([contenteditable="false"])';
      const clickAt = (el, x, y) => {
        hoverOn(el, x, y);
        const pointerDown = mouse(el, 'pointerdown', x, y);
        const mouseDown = pointerDown ? mouse(el, 'mousedown', x, y) : true;
        if (mouseDown) {
          const f = el.closest(focusable);
          if (f && f !== deepActive(el.ownerDocument)) f.focus({preventScroll: true});
        }
        mouse(el, 'pointerup', x, y);
        if (pointerDown) mouse(el, 'mouseup', x, y);
        mouse(el, 'click', x, y);
      };
      const click = (el, force) => {
        if (disabled(el)) return fail(describe(el) + ' is disabled');
        const p = point(el, force);
        if (p.error) return fail(p.error);
        clickAt(el, p.x, p.y);
        return ok();
      };

      const editable = (el) => (el.localName === 'input' && textTypes.has((el.getAttribute('type') || '').toLowerCase()))
        || el.localName === 'textarea' || el.isContentEditable;
      const editableValue = (el) => el.localName === 'input' || el.localName === 'textarea' ? el.value : el.textContent;
      // `whole`: in place of what it holds, where WebKit keeps no selection (a number field).
      const insert = (el, text, whole = false) => {
        const doc = el.ownerDocument;
        if (text && doc.execCommand('insertText', false, text)) return;
        if (!text && doc.execCommand('delete')) return;
        // A field WebKit won't edit (some input types): its value, as a framework sets it.
        if (el.localName === 'input' || el.localName === 'textarea') {
          const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
          const n = el.value.length;
          const start = el.selectionStart ?? (whole ? 0 : n), end = el.selectionEnd ?? n;
          const value = el.value.slice(0, start) + text + el.value.slice(end);
          if (setter) setter.call(el, value); else el.value = value;
        } else {
          el.textContent = text;
        }
        el.dispatchEvent(new el.ownerDocument.defaultView.InputEvent('input', {bubbles: true, composed: true,
          inputType: text ? 'insertText' : 'deleteContentBackward', data: text || null}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
      };
      const selectContents = (el, atEnd) => {
        if (el.localName === 'input' || el.localName === 'textarea') {
          try {
            if (atEnd) el.setSelectionRange(el.value.length, el.value.length); else el.select();
          } catch (e) {}
          return;
        }
        const doc = el.ownerDocument, range = doc.createRange();
        range.selectNodeContents(el);
        if (atEnd) range.collapse(false);
        const sel = doc.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      };

      const keyNames = {enter: ['Enter', 'Enter', 13], return: ['Enter', 'Enter', 13], tab: ['Tab', 'Tab', 9],
        escape: ['Escape', 'Escape', 27], esc: ['Escape', 'Escape', 27], backspace: ['Backspace', 'Backspace', 8],
        delete: ['Delete', 'Delete', 46], space: [' ', 'Space', 32], up: ['ArrowUp', 'ArrowUp', 38],
        down: ['ArrowDown', 'ArrowDown', 40], left: ['ArrowLeft', 'ArrowLeft', 37], right: ['ArrowRight', 'ArrowRight', 39],
        arrowup: ['ArrowUp', 'ArrowUp', 38], arrowdown: ['ArrowDown', 'ArrowDown', 40],
        arrowleft: ['ArrowLeft', 'ArrowLeft', 37], arrowright: ['ArrowRight', 'ArrowRight', 39],
        home: ['Home', 'Home', 36], end: ['End', 'End', 35], pageup: ['PageUp', 'PageUp', 33], pagedown: ['PageDown', 'PageDown', 34]};
      for (let n = 1; n <= 12; n++) keyNames['f' + n] = ['F' + n, 'F' + n, 111 + n];
      const parseKey = (spec) => {
        const parts = spec.split('+');
        let name = parts.pop();
        if (name === '' && parts.length) { parts.pop(); name = '+'; }
        const mods = {ctrlKey: false, altKey: false, shiftKey: false, metaKey: false};
        for (const m of parts.map(p => p.toLowerCase())) {
          if (m === 'ctrl' || m === 'control') mods.ctrlKey = true;
          else if (m === 'alt' || m === 'option' || m === 'opt') mods.altKey = true;
          else if (m === 'shift') mods.shiftKey = true;
          else if (m === 'cmd' || m === 'command' || m === 'meta' || m === 'super') mods.metaKey = true;
          else return null;
        }
        const known = keyNames[name.toLowerCase()];
        if (known) return {key: known[0], code: known[1], keyCode: known[2], ...mods, printable: known[0] === ' '};
        if ([...name].length !== 1) return null;
        const upper = name.toUpperCase();
        const code = /[a-z]/i.test(name) ? 'Key' + upper : /[0-9]/.test(name) ? 'Digit' + name : '';
        return {key: mods.shiftKey ? upper : name, code, keyCode: upper.charCodeAt(0), ...mods, printable: true};
      };
      const tabbables = (doc) => [...doc.querySelectorAll(focusable)]
        .filter(e => e.tabIndex >= 0 && !disabled(e) && shown(e) && hasBox(e))
        .sort((x, y) => (x.tabIndex || Infinity) - (y.tabIndex || Infinity));
      const keyEvent = (el, type, k) => el.dispatchEvent(new el.ownerDocument.defaultView.KeyboardEvent(type, {
        key: k.key, code: k.code, keyCode: k.keyCode, which: k.keyCode,
        charCode: type !== 'keypress' ? 0 : k.key === 'Enter' ? 13 : k.key.charCodeAt(0),
        ctrlKey: k.ctrlKey, altKey: k.altKey, shiftKey: k.shiftKey, metaKey: k.metaKey,
        bubbles: true, cancelable: true, composed: true, view: el.ownerDocument.defaultView}));
      // What the key does when the page lets it: what WebKit does for a key you press.
      const keyDefault = (el, k) => {
        const doc = el.ownerDocument;
        const command = k.ctrlKey || k.metaKey;
        const field = el.localName === 'input' || el.localName === 'textarea';
        switch (k.key) {
          case 'Enter':
            if (el.localName === 'textarea') return doc.execCommand('insertLineBreak');
            if (el.isContentEditable) return doc.execCommand('insertParagraph');
            if (el.localName === 'input' && el.form) {
              const button = el.form.querySelector('button:not([type]), button[type="submit"], input[type="submit"], input[type="image"]');
              return el.form.requestSubmit(button && !button.disabled ? button : undefined);
            }
            if (el.matches('a[href], button, summary, [role="button"], [role="link"], input[type="button"], input[type="submit"]')) return clickAt(el, 0, 0);
            return;
          case ' ':
            if (editable(el) && !command) return insert(el, ' ');
            if (el.matches('button, summary, input[type="checkbox"], input[type="radio"], input[type="button"], input[type="submit"], [role="button"], [role="checkbox"], [role="switch"]')) return clickAt(el, 0, 0);
            return;
          case 'Tab': {
            const list = tabbables(doc);
            const i = list.indexOf(el);
            const to = list[k.shiftKey ? (i <= 0 ? list.length - 1 : i - 1) : (i + 1) % list.length];
            if (to) to.focus();
            return;
          }
          case 'Backspace': if (editable(el)) doc.execCommand('delete'); return;
          case 'Delete': if (editable(el)) doc.execCommand('forwardDelete'); return;
          case 'ArrowUp': case 'ArrowDown':
            if (el.localName === 'select') {
              const i = Math.max(0, Math.min(el.options.length - 1, el.selectedIndex + (k.key === 'ArrowUp' ? -1 : 1)));
              if (i !== el.selectedIndex) {
                el.selectedIndex = i;
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
              }
            }
            return;
          case 'ArrowLeft': case 'ArrowRight': case 'Home': case 'End':
            if (field) {
              try {
                const n = el.value.length, at = el.selectionStart ?? n;
                const to = k.key === 'Home' ? 0 : k.key === 'End' ? n : Math.max(0, Math.min(n, at + (k.key === 'ArrowLeft' ? -1 : 1)));
                el.setSelectionRange(to, to);
              } catch (e) {}
            }
            return;
        }
        if (command && k.key.toLowerCase() === 'a') {
          if (editable(el)) return selectContents(el, false);
          return doc.execCommand('selectAll');
        }
        if (k.printable && !command && editable(el)) insert(el, k.key);
      };
      const press = (el, k) => {
        const down = keyEvent(el, 'keydown', k);
        if (down && (k.printable || k.key === 'Enter') && !k.ctrlKey && !k.metaKey) keyEvent(el, 'keypress', k);
        if (down) keyDefault(el, k);
        keyEvent(el, 'keyup', k);
      };

      const scrollers = {down: [0, 1], up: [0, -1], right: [1, 0], left: [-1, 0]};

      return {
        snapshot(a) {
          const t = target(a, false);
          if (t.error) return fail(t.error);
          const root = t.el || document.documentElement;
          const opts = {interactive: !!a.interactive};
          const out = [];
          if (!t.el) out.push('- document ' + quote(document.title) + ' → ' + location.href);
          lines(tree(root), t.el || opts.interactive ? 0 : 1, out, opts);
          const max = a.max > 0 ? a.max : 1000;
          if (out.length > max) {
            const more = out.length - max;
            out.length = max;
            out.push('… ' + more + ' more lines (snapshot a part of it: SELECTOR or --ref REF; or --max N)');
          }
          return ok(out.join('\n'));
        },
        text(a) {
          const t = target(a, false);
          if (t.error) return fail(t.error);
          const el = t.el || document.body;
          return ok(el ? (el.innerText ?? el.textContent) : '');
        },
        html(a) {
          const t = target(a, false);
          if (t.error) return fail(t.error);
          return ok((t.el || document.documentElement).outerHTML);
        },
        click(a) {
          const t = target(a);
          return t.error ? fail(t.error) : click(t.el, a.force);
        },
        hover(a) {
          const t = target(a);
          if (t.error) return fail(t.error);
          const p = point(t.el, a.force);
          if (p.error) return fail(p.error);
          hoverOn(t.el, p.x, p.y);
          return ok();
        },
        type(a) {
          const t = target(a);
          if (t.error) return fail(t.error);
          const el = t.el;
          if (!editable(el)) return fail(describe(el) + " isn't a text field");
          if (disabled(el) || el.readOnly) return fail(describe(el) + ' is ' + (el.readOnly ? 'read-only' : 'disabled'));
          el.scrollIntoView({block: 'center', behavior: 'instant'});
          if (el !== deepActive(el.ownerDocument)) el.focus({preventScroll: true});
          selectContents(el, !!a.append);
          const text = a.text || '';
          if (a.keys) {
            // Key by key, for a page that listens to keys (an old autocomplete): what it holds goes first.
            if (!a.append && editableValue(el)) insert(el, '', true);
            for (const c of text) press(el, parseKey(c === ' ' ? 'space' : c === '+' ? 'shift++' : c));
          } else if (text || !a.append) {
            insert(el, text, !a.append);
          }
          if (a.enter) press(el, parseKey('Enter'));
          return ok();
        },
        press(a) {
          const k = parseKey(a.key || '');
          if (!k) return fail('not a key: ' + a.key + ' (Enter, Tab, Escape, Backspace, Space, up, down, a, shift+Tab, cmd+a…)');
          const t = target(a, false);
          if (t.error) return fail(t.error);
          let el = t.el || deepActive(document) || document.body;
          if (t.el && el !== deepActive(el.ownerDocument)) el.focus({preventScroll: true});
          press(el, k);
          return ok();
        },
        select(a) {
          const t = target(a);
          if (t.error) return fail(t.error);
          const el = t.el;
          if (el.localName !== 'select') return fail(describe(el) + " isn't a <select> (click its options instead)");
          if (disabled(el)) return fail(describe(el) + ' is disabled');
          const wanted = a.values || [];
          const options = [...el.options];
          const chosen = wanted.map(v => options.find(o => o.value === v) || options.find(o => clean(o.label || o.text) === clean(v)));
          const missing = wanted.filter((v, i) => !chosen[i]);
          if (missing.length) {
            const have = options.slice(0, 12).map(o => quote(clean(o.label || o.text))).join(', ');
            return fail('no option ' + missing.map(quote).join(', ') + ' in ' + describe(el) + ' (it has ' + have + ')');
          }
          if (!el.multiple && chosen.length > 1) return fail(describe(el) + ' takes one option');
          for (const o of options) o.selected = chosen.includes(o);
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return ok(chosen.map(o => o.value).join('\n'));
        },
        check(a) {
          const t = target(a);
          if (t.error) return fail(t.error);
          const el = t.el;
          const isBox = el.localName === 'input' && (el.type === 'checkbox' || el.type === 'radio');
          const ariaBox = ['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(roleOf(el));
          if (!isBox && !ariaBox) return fail(describe(el) + " isn't a checkbox or radio button");
          const radio = el.type === 'radio' || roleOf(el) === 'radio' || roleOf(el) === 'menuitemradio';
          if (!a.want && radio) return fail('a radio button is unchecked by checking another');
          const checked = () => isBox ? el.checked : el.getAttribute('aria-checked') === 'true';
          if (checked() === a.want) return ok();
          // A styled box often hides the input under its label: then the label is what's clicked.
          let r = click(el, a.force);
          if (!r.ok && isBox && !a.force && el.labels && el.labels.length) r = click(el.labels[0], false);
          if (!r.ok) return r;
          return checked() === a.want ? ok() : fail(describe(el) + " didn't change (the page kept it as it was)");
        },
        scroll(a) {
          const t = target(a, false);
          if (t.error) return fail(t.error);
          const dir = a.direction;
          if (!dir) {
            if (!t.el) return fail('scroll where: up, down, left, right, top, bottom, or an element');
            t.el.scrollIntoView({block: 'center', behavior: 'instant'});
            return ok();
          }
          const box = t.el || null;
          const view = document.defaultView;
          if (dir === 'top' || dir === 'bottom') {
            const y = dir === 'top' ? 0 : (box ? box.scrollHeight : document.documentElement.scrollHeight);
            (box || view).scrollTo({top: y, behavior: 'instant'});
          } else {
            const [dx, dy] = scrollers[dir];
            const amount = a.amount > 0 ? a.amount : Math.round((dy ? (box ? box.clientHeight : view.innerHeight)
              : (box ? box.clientWidth : view.innerWidth)) * 0.8);
            (box || view).scrollBy({left: dx * amount, top: dy * amount, behavior: 'instant'});
          }
          return ok(box ? box.scrollLeft + ',' + box.scrollTop : Math.round(view.scrollX) + ',' + Math.round(view.scrollY));
        },
        // `wait`'s question, asked again until it holds.
        holds(a) {
          let present;
          if (a.selector != null) {
            let el = null;
            try { el = document.querySelector(a.selector); } catch (e) { return fail('not a CSS selector: ' + a.selector); }
            present = !!el && shown(el) && hasBox(el);
          } else if (a.text != null) {
            present = !!document.body && (document.body.innerText || '').includes(a.text);
          } else {
            present = document.readyState === 'complete';
          }
          return ok(present !== !!a.gone ? 'yes' : 'no');
        },
      };
    }
    """#
}
