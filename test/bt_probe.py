#!/usr/bin/env python3
"""经 SOCKS5（无认证）连到 127.0.0.1:9080，发送首包，打印是否收到 HTTP 响应。仅回环。"""
import socket, struct, sys
port, kind = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=6)
s.sendall(b"\x05\x01\x00"); assert s.recv(2) == b"\x05\x00"
s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", 9080))
assert s.recv(10)[1] == 0
if kind == "bt":
    payload = b"\x13BitTorrent protocol" + b"\x00" * 8 + b"A" * 20 + b"B" * 20
else:
    payload = b"GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n"
s.sendall(payload)
try:
    data = s.recv(64)
except Exception:
    data = b""
print("RESPONDED" if data.startswith(b"HTTP/") else "NO_RESPONSE")
