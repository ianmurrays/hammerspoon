#!/usr/bin/env python3
"""Manual test client for the STT daemon.

Connects to the daemon, records for 5 seconds, and prints results.
"""

import json
import socket
import time


def send_json(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_message(sock, buf=""):
    while "\n" not in buf:
        data = sock.recv(4096)
        if not data:
            return None, buf
        buf += data.decode()
    line, buf = buf.split("\n", 1)
    return json.loads(line.strip()), buf


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect(("127.0.0.1", 9876))
    print("Connected to daemon")

    buf = ""

    # Wait for ready
    msg, buf = read_message(sock, buf)
    print(f"<- {msg}")
    assert msg["type"] == "ready"

    # Start recording
    print("Starting recording (5 seconds)...")
    send_json(sock, {"cmd": "start"})

    time.sleep(5)

    # Stop recording
    print("Stopping recording...")
    send_json(sock, {"cmd": "stop"})

    # Read messages until final
    sock.settimeout(30)
    while True:
        msg, buf = read_message(sock, buf)
        print(f"<- {msg}")
        if msg and msg["type"] in ("final", "error"):
            break

    sock.close()
    print("Done")


if __name__ == "__main__":
    main()
