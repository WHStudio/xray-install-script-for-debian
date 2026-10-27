#!/usr/bin/env python3
"""本地 UDP echo，仅监听 127.0.0.1:9053（测试用）。"""
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 9053))
while True:
    d, a = s.recvfrom(65535); s.sendto(d, a)
