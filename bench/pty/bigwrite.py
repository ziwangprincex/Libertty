import os, sys
data = open(sys.argv[1], 'rb').read()
chunk = (data * (8_388_608 // len(data) + 1))[:8_388_608]
for _ in range(int(sys.argv[2])):
    os.write(1, b'\x1bc')          # vtebench resets before each sample
    view = memoryview(chunk)
    while view:                    # write_all: one 8 MiB write, resumed on partial writes
        n = os.write(1, view); view = view[n:]
