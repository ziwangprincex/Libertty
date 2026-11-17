#!/usr/bin/env python3
"""Stands in for the listener an ssh ControlMaster opens for `-L`/`-R`
(tests/fixtures/fake-ssh): listens on LOCAL and carries each connection to
REMOTE. The fake host is this Mac, so LOCAL == REMOTE would be a loop: that
one only holds the port, as a forward to a port nothing answers on does.

  fake-ssh-relay.py LOCAL REMOTE READY
"""
import socket
import sys
import threading


def pump(source: socket.socket, sink: socket.socket) -> None:
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            sink.sendall(data)
    except OSError:
        pass
    finally:
        for end in (source, sink):
            try:
                end.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            end.close()


def main() -> int:
    local, remote, ready = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # As ssh's own forward listener does, so a port whose earlier
    # connections are still in TIME_WAIT can be listened on again.
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", local))
    listener.listen(16)
    # Only now is the port really open: fake-ssh waits for this.
    with open(ready, "w", encoding="utf-8") as f:
        f.write("ready\n")
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return 0
        if local == remote:
            client.close()
            continue
        try:
            upstream = socket.create_connection(("127.0.0.1", remote), timeout=5)
        except OSError:
            client.close()
            continue
        for a, b in ((client, upstream), (upstream, client)):
            threading.Thread(target=pump, args=(a, b), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
