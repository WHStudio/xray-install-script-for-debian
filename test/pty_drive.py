#!/usr/bin/env python3
"""在伪终端中运行命令，每遇到一个以 '：' 结尾的提问就依次回答（测试交互界面用）。"""
import os, pty, sys, time, re, select
answers = sys.argv[1].split("|")
cmd = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf, out, i = b"", b"", 0
while True:
    r, _, _ = select.select([fd], [], [], 60)
    if not r: print("TIMEOUT"); break
    try: chunk = os.read(fd, 4096)
    except OSError: break
    if not chunk: break
    out += chunk; buf += chunk
    text = re.sub(rb"\x1b\[[0-9;]*m", b"", buf).decode("utf-8", "replace")
    if text.rstrip(" ").endswith("："):
        a = answers[i] if i < len(answers) else ""
        q = text.strip().splitlines()[-1]
        print(f"Q: {q.strip()}  ->  A: {a!r}")
        os.write(fd, (a + "\n").encode()); i += 1; buf = b""
_, st = os.waitpid(pid, 0)
open(os.environ.get("PTY_LOG", "/tmp/xit-pty.log"), "wb").write(out)
print("exit", os.waitstatus_to_exitcode(st))
