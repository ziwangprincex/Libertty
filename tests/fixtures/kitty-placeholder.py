#!/usr/bin/env python3
"""The Libertty logo as a kitty Unicode-placeholder image (virtual placement,
U=1), as tmux passes images through: 10x5 cells of U+10EEEE whose color is
the image ID. Row 0 marks every cell's row and column; the other rows mark
only their first cell and let the rest continue it."""
import base64, os, sys
here = os.path.dirname(os.path.abspath(__file__))
data = open(os.path.join(here, "..", "..", "assets", "icon", "png", "libertty-256.png"), "rb").read()
b64 = base64.standard_b64encode(data)
out = sys.stdout.buffer
first = True
for i in range(0, len(b64), 4096):
    chunk = b64[i:i + 4096]
    more = 1 if i + 4096 < len(b64) else 0
    ctrl = f"a=T,f=100,i=42,U=1,c=10,r=5,q=2,m={more}" if first else f"m={more}"
    out.write(b"\x1b_G" + ctrl.encode() + b";" + chunk + b"\x1b\\")
    first = False
marks = [0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A]
placeholder = chr(0x10EEEE)
out.write(b"\x1b[38;5;42m")
for r in range(5):
    if r == 0:
        line = "".join(placeholder + chr(marks[r]) + chr(marks[c]) for c in range(10))
    else:
        line = placeholder + chr(marks[r]) + chr(marks[0]) + placeholder * 9
    out.write(line.encode("utf-8") + b"\r\n")
out.write(b"\x1b[0mplaceholders above (image 42, 10x5 cells)\r\n")
out.flush()
