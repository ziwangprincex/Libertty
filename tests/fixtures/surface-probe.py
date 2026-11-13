#!/usr/bin/env python3
# A program that draws a surface (tests/fixtures/surfaces.txt): asks whether
# the terminal draws them, shows a card with a field, a list and buttons,
# prints each event it hears, updates the card, shows an overlay, and ends.
#   python3 surface-probe.py TOOLS_DIR
import sys
import time

sys.path.insert(0, sys.argv[1])
import surface  # noqa: E402

s = surface.Surface()
print("SUPPORTED" if s.supported else "UNSUPPORTED", s.info.get("v", ""))
sys.stdout.flush()
if not s.supported:
    sys.exit(0)
s.show("demo", [
    surface.text("Deploy now?", "title"),
    surface.input_("note", "Note"),
    surface.list_("env", [("staging", "Staging"), ("prod", "Production")]),
    surface.buttons([("deploy", "Deploy", "primary"), ("cancel", "Cancel")]),
], rows=10, title="Deploy")
print("SHOWN")
sys.stdout.flush()
for _ in range(3):
    e = s.next_event(timeout=20)
    if e is None:
        print("NO-EVENT")
        break
    print("EVENT", e["type"], e.get("item") or e.get("element"), (e.get("values") or {}).get("note", ""),
          ",".join(e.get("items", [])))
    sys.stdout.flush()
    if e["type"] == "click":
        break
s.update("demo", [surface.text("Deploying", "title"), surface.progress(0.5, "half")], rows=10, title="Deploy")
time.sleep(0.5)
s.overlay("ov", [surface.text("Overlay here")], position="top-right", cols=30, rows=4, title="Over")
print("OVERLAY")
sys.stdout.flush()
time.sleep(1.5)
print("DONE")
