# Reads keys raw until a plain Return (0x0d), the kitty keyboard flags
# given as its argument turned on, and prints what came as hex: "GOT 1b 5b …".
import os, select, sys, termios, time, tty

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
got = b""
try:
    if len(sys.argv) > 1:
        os.write(1, ("\x1b[>%su" % sys.argv[1]).encode())
    os.write(1, b"READY\r\n")
    deadline = time.time() + 8
    while time.time() < deadline and not got.endswith(b"\r"):
        if select.select([fd], [], [], 0.1)[0]:
            got += os.read(fd, 64)
    if len(sys.argv) > 1:
        os.write(1, b"\x1b[<u")
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
print("GOT " + " ".join("%02x" % b for b in got))
