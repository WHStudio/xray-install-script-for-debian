#!/usr/bin/env python3
"""仅回环抓包断言：VLESS Encryption（random）端口上不应出现 TLS 记录头链（17 03 03 len ...）。
用法：pcap_check.py <pcap> <server_port>
对每条 TCP 流的两个方向重组（取前 4 MiB），在任意偏移处寻找 >=3 个首尾相接的
TLS 记录头（类型 20-23、版本 03 01/03 03、长度 1..16640）；找到即判定为“有 TLS 记录特征”。
输出：streams=<n> bytes=<n> tls_chain_streams=<n> max_entropy_gap=<...>，并以退出码 0/1 表示通过/失败。"""
import math, struct, sys
pcap, port = sys.argv[1], int(sys.argv[2])
CAP = 4 << 20
f = open(pcap, "rb"); gh = f.read(24)
le = gh[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"); E = "<" if le else ">"
lt = struct.unpack(E + "I", gh[20:24])[0]; off = {1: 14, 113: 16, 0: 4, 12: 0}[lt]
fl = {}
while True:
    h = f.read(16)
    if len(h) < 16: break
    incl = struct.unpack(E + "IIII", h)[2]; p = f.read(incl); ip = p[off:]
    if not ip or ip[0] >> 4 != 4 or ip[9] != 6: continue
    ihl = (ip[0] & 15) * 4; t = ip[ihl:]; sp, dp, seq = struct.unpack(">HHI", t[:8]); doff = (t[12] >> 4) * 4
    pl = t[doff:struct.unpack(">H", ip[2:4])[0] - ihl]
    if dp == port: k, d = sp, 0
    elif sp == port: k, d = dp, 1
    else: continue
    s = fl.setdefault(k, [[bytearray(), None], [bytearray(), None]])[d]
    if t[13] & 2: s[1] = (seq + 1) & 0xffffffff; continue
    if not pl or s[1] is None: continue
    if ((seq - s[1]) & 0xffffffff) > 0x7fffffff: continue  # 重传
    s[1] = (seq + len(pl)) & 0xffffffff
    if len(s[0]) < CAP: s[0] += pl

def chain(b):
    n = len(b); i = 0
    while i + 5 <= n and i < 64 * 1024:
        j = b.find(b"\x03", i + 1)
        if j < 1: return False
        i = j - 1
        if b[i] in (20, 21, 22, 23) and b[i + 2] in (1, 3):
            k, c = i, 0
            while k + 5 <= n and b[k] in (20, 21, 22, 23) and b[k + 1] == 3 and b[k + 2] in (1, 3):
                l = b[k + 3] << 8 | b[k + 4]
                if not 1 <= l <= 16640: break
                k += 5 + l; c += 1
                if c >= 3: return True
        i += 1
    return False

def ent(b):
    if not b: return 0.0
    c = [0] * 256
    for x in b: c[x] += 1
    return -sum(v / len(b) * math.log2(v / len(b)) for v in c if v)

ns = nb = bad = 0; lo = 8.0
for k, dirs in fl.items():
    for d in dirs:
        b = bytes(d[0])
        if not b: continue
        ns += 1; nb += len(b)
        if chain(b): bad += 1
        if len(b) >= 4096: lo = min(lo, ent(b[:65536]))
print(f"streams={ns} bytes={nb} tls_chain_streams={bad} min_entropy(>=4KiB)={lo:.3f}")
sys.exit(0 if ns and bad == 0 else 1)
