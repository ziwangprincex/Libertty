#!/usr/bin/env python3
"""Libertty's surface protocol from Python (standard library only).

A program in a Libertty pane asks for native UI — a card in its output, or a
panel over its pane — and hears what you click, choose or type. The protocol
is docs/surface-protocol.md; this is its reference client.

    import surface
    s = surface.Surface()
    if s.supported:
        s.show("build", [surface.text("Building…", "title"), surface.progress(None, "compiling")], rows=4)
        s.show("ask", [surface.buttons([("retry", "Retry", "primary"), ("quit", "Quit")])], rows=3)
        for event in s.events():
            if event["type"] == "click" and event["item"] == "quit":
                break

Run it as a script for a demo: python3 surface.py
"""

import base64
import json
import os
import select
import sys
import termios
import time
import tty

OSC = "\x1b]7502;"
BEL = "\x07"


def _encode(obj):
    return "b64:" + base64.b64encode(json.dumps(obj, separators=(",", ":")).encode()).decode()


# Elements: plain dictionaries, made with these or by hand.

def text(t, style="body"):
    return {"type": "text", "text": t, "style": style}


def markdown(t):
    return {"type": "markdown", "text": t}


def buttons(items, id=None):
    """items: (id, label) or (id, label, style), style primary | default | destructive."""
    e = {"type": "buttons", "items": [{"id": i[0], "label": i[1], "style": i[2] if len(i) > 2 else "default"} for i in items]}
    if id:
        e["id"] = id
    return e


def list_(id, items, select="single", height=None):
    """items: (id, label) or (id, label, detail)."""
    e = {"type": "list", "id": id, "select": select,
         "items": [{"id": i[0], "label": i[1], "detail": i[2] if len(i) > 2 else ""} for i in items]}
    if height:
        e["height"] = height
    return e


def table(id, columns, rows, select="single"):
    """rows: lists of cells (their ids are their positions), or {"id", "cells"}."""
    return {"type": "table", "id": id, "columns": columns, "rows": rows, "select": select}


def progress(value, label=""):
    """value 0…1, or None while it can't be told."""
    return {"type": "progress", "value": value, "label": label}


def keyvalue(pairs):
    return {"type": "keyvalue", "items": [list(p) for p in pairs]}


def input_(id, label="", placeholder="", value=""):
    return {"type": "input", "id": id, "label": label, "placeholder": placeholder, "value": value}


def image(path=None, data=None, height=6, label=""):
    e = {"type": "image", "height": height, "label": label}
    if data is not None:
        e["data"] = base64.b64encode(data).decode()
    else:
        e["path"] = os.path.abspath(path)
    return e


def diff(t):
    return {"type": "diff", "text": t}


def divider():
    return {"type": "divider"}


class Surface:
    """The terminal this program runs in (its controlling tty)."""

    def __init__(self, timeout=0.5):
        self.tty = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        self._buffer = b""
        self.supported = False
        self.info = {}
        reply = self._ask(OSC + "q" + BEL, b"\x1b]7502;q;", timeout)
        if reply is not None:
            self.supported = True
            for part in reply.split(";"):
                if "=" in part:
                    k, v = part.split("=", 1)
                    self.info[k] = v

    def _write(self, s):
        os.write(self.tty, s.encode())

    def _raw(self):
        """Keys and replies as they come, unseen (they're for us, not the screen)."""
        old = termios.tcgetattr(self.tty)
        tty.setcbreak(self.tty)
        return old

    def _ask(self, request, prefix, timeout):
        old = self._raw()
        try:
            self._write(request)
            end = time.time() + timeout
            while time.time() < end:
                frame = self._frame(prefix, end - time.time())
                if frame is not None:
                    return frame
            return None
        finally:
            termios.tcsetattr(self.tty, termios.TCSADRAIN, old)

    def _frame(self, prefix, timeout):
        """The next `ESC ] 7502 ; X ; … BEL` starting with prefix, within timeout seconds."""
        while True:
            start = self._buffer.find(prefix)
            if start >= 0:
                end = self._buffer.find(b"\x07", start)
                if end >= 0:
                    body = self._buffer[start + len(prefix):end].decode("utf-8", "replace")
                    self._buffer = self._buffer[end + 1:]
                    return body
            ready, _, _ = select.select([self.tty], [], [], max(0, timeout) if timeout is not None else None)
            if not ready:
                return None
            chunk = os.read(self.tty, 65536)
            if not chunk:
                return None
            self._buffer += chunk

    def show(self, id, elements, rows=4, title="", anchor="above"):
        """A card in the output, `rows` rows tall: those rows are printed first
        (blank), so the card sits over them and the output goes on below."""
        if anchor == "above":
            self._write("\n" * rows)
        self._write(OSC + "s;" + _encode({"id": id, "placement": "inline", "rows": rows, "anchor": anchor,
                                          "title": title, "elements": elements}) + BEL)

    def update(self, id, elements, rows=4, title=""):
        """The same card again, changed (where it is, and what you typed or chose in it, stay)."""
        self._write(OSC + "s;" + _encode({"id": id, "placement": "inline", "rows": rows, "title": title,
                                          "elements": elements}) + BEL)

    def overlay(self, id, elements, position="bottom-right", cols=60, rows=10, title=""):
        """A panel over the pane: top, bottom, center, top-right, bottom-right or full."""
        self._write(OSC + "s;" + _encode({"id": id, "placement": "overlay", "position": position, "cols": cols,
                                          "rows": rows, "title": title, "elements": elements}) + BEL)

    def remove(self, id):
        self._write(OSC + "d;" + id + BEL)

    def clear(self):
        self._write(OSC + "c" + BEL)

    def next_event(self, timeout=None):
        """One event ({"surface", "type", "item"…}), or None when timeout passes."""
        old = self._raw()
        try:
            end = None if timeout is None else time.time() + timeout
            while True:
                body = self._frame(b"\x1b]7502;e;", None if end is None else end - time.time())
                if body is None:
                    return None
                if body.startswith("b64:"):
                    return json.loads(base64.b64decode(body[4:]))
        finally:
            termios.tcsetattr(self.tty, termios.TCSADRAIN, old)

    def events(self, timeout=None):
        while True:
            event = self.next_event(timeout)
            if event is None:
                return
            yield event


def _demo():
    s = Surface()
    if not s.supported:
        print("This terminal doesn't draw surfaces (Libertty with surfaces = true does).")
        return
    print("Libertty draws surfaces, protocol " + s.info.get("v", "?"))
    s.show("demo", [
        text("Deploy to staging?", "title"),
        keyvalue([("Branch", "main"), ("Commit", "3f2a91c")]),
        input_("note", "Note", "what changed"),
        buttons([("deploy", "Deploy", "primary"), ("cancel", "Cancel")]),
    ], rows=8, title="Deploy")
    for event in s.events():
        if event["type"] == "click":
            print("clicked", event["item"], "with note:", event.get("values", {}).get("note", ""))
            if event["item"] == "deploy":
                for i in range(11):
                    s.update("demo", [text("Deploying…", "title"), progress(i / 10, "%d%%" % (i * 10))], rows=8, title="Deploy")
                    time.sleep(0.15)
            break


if __name__ == "__main__":
    _demo()
