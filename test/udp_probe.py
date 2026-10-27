#!/usr/bin/env python3
"""经 mihomo 的 SOCKS5 UDP ASSOCIATE（127.0.0.1:<port>）向 127.0.0.1:9053 的本地 UDP echo 发包，打印 ECHO_OK / NO_ECHO。仅回环。"""
import socket, struct, sys, os
port = int(sys.argv[1])
t = socket.create_connection(("127.0.0.1", port), timeout=6)
t.sendall(b"\x05\x01\x00"); assert t.recv(2) == b"\x05\x00"
t.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
r = t.recv(10); assert r[1] == 0, r
relay = (socket.inet_ntoa(r[4:8]), struct.unpack(">H", r[8:10])[0])
if relay[0] == "0.0.0.0": relay = ("127.0.0.1", relay[1])
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(3)
hdr = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", 9053)
ok = 0
for i in range(3):  # 首包可能因 0-RTT/建链丢失，重试
    payload = b"udp-probe-" + os.urandom(8).hex().encode()
    u.sendto(hdr + payload, relay)
    try:
        data, _ = u.recvfrom(2048)
        if data[10:] == payload: ok = 1; break
    except socket.timeout:
        pass
print("ECHO_OK" if ok else "NO_ECHO")
