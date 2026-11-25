#!/usr/bin/env python3
# How often liberttyd's lock was free over SECONDS: tried every half
# millisecond, taken and let go at once, as a liberttyd starting then would
# take it. Prints the count.
#   tests/fixtures/lock-watch.py LOCKFILE SECONDS
import fcntl
import os
import sys
import time

path, end = sys.argv[1], time.time() + float(sys.argv[2])
free = 0
while time.time() < end:
    try:
        fd = os.open(path, os.O_RDWR)
    except OSError:
        time.sleep(0.0005)
        continue
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        free += 1
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    os.close(fd)
    time.sleep(0.0005)
print(free)
