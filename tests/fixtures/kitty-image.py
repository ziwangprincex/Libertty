#!/usr/bin/env python3
"""Show the Libertty logo with the kitty graphics protocol, chunked, then text
under it and a second placement of the same image over text (z = 1)."""
import base64, os, sys
here = os.path.dirname(os.path.abspath(__file__))
data = open(os.path.join(here, "..", "..", "assets", "icon", "png", "libertty-256.png"), "rb").read()
b64 = base64.standard_b64encode(data)
out = sys.stdout.buffer
first = True
for i in range(0, len(b64), 4096):
    chunk = b64[i:i + 4096]
    more = 1 if i + 4096 < len(b64) else 0
    ctrl = f"a=T,f=100,i=7,c=12,r=6,m={more}" if first else f"m={more}"
    out.write(b"\x1b_G" + ctrl.encode() + b";" + chunk + b"\x1b\\")
    first = False
out.write(b"\r\nkitty graphics: image id 7, 12x6 cells above\r\n")
out.write(b"over this line: ")
out.write(b"\x1b_Ga=p,i=7,c=4,r=2,z=1\x1b\\")
out.write(b"\r\n\r\n\r\ndone\r\n")
out.flush()
