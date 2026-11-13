#!/usr/bin/env python3
# A flood (tests/fixtures/surfaces.txt): a hundred overlays in a moment, then
# a thousand updates of one card. A pane keeps at most 16 surfaces, takes 60
# commands a second, and of a surface's updates past that, the latest.
import base64
import json
import sys
import time


def send(obj):
    data = base64.b64encode(json.dumps(obj).encode()).decode()
    sys.stdout.write("\x1b]7502;s;b64:" + data + "\x07")


for i in range(100):
    send({"id": "f%d" % i, "placement": "overlay", "elements": [{"type": "text", "text": "flood %d" % i}]})
sys.stdout.flush()
time.sleep(1.2)
sys.stdout.write("\x1b]7502;c\x07")
sys.stdout.write("\n\n\n")
for i in range(1000):
    send({"id": "card", "rows": 3, "elements": [{"type": "text", "text": "update %d" % i}]})
sys.stdout.flush()
print("FLOODED")
sys.stdout.flush()
time.sleep(3)
