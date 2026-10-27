#!/usr/bin/env bash
# 在 nspawn 容器内以干净环境运行 install.sh；参数为 KEY=VAL 列表
L="${LEADER:?}"
exec sudo nsenter -t "$L" -a -- /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb "$@" bash /root/install.sh
