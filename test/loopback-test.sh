#!/usr/bin/env bash
# 仅回环测试（不产生任何公网代理流量）。
# 前提：systemd-nspawn 容器（共享宿主网络命名空间）里已用 install.sh 安装，
#       LISTEN_ADDR=127.0.0.1 REALITY_TARGET=127.0.0.1:9443 REALITY_SNI=local.test SERVER_ADDRESS=127.0.0.1
#       本地 target（自签 TLS1.3+h2 于 127.0.0.1:9443，HTTP 于 127.0.0.1:9080）已运行。
# 用法：sudo LEADER=<容器 systemd 的 PID> MIHOMO=/path/to/mihomo ROOTFS=/path/to/rootfs bash loopback-test.sh
set -Eeuo pipefail
: "${LEADER:?}" "${MIHOMO:?}" "${ROOTFS:?}"
WORK="$(mktemp -d)"
MPID=""
cleanup() { if [[ -n "${MPID}" ]]; then kill "${MPID}" 2>/dev/null || true; fi; rm -rf "${WORK}"; }
trap cleanup EXIT
inct() { nsenter -t "${LEADER}" -a -- "$@"; }

# 1) mihomo 客户端：直接使用 install.sh 生成的 proxies，加两个只监听 127.0.0.1 的 socks 入口
{
  printf 'mode: rule\nlog-level: warning\nallow-lan: false\nbind-address: 127.0.0.1\nipv6: false\n'
  grep -v '^#' "${ROOTFS}/usr/local/etc/xray/client-mihomo.yaml"
  printf 'listeners:\n'
  printf '  - {name: l-reality, type: socks, listen: 127.0.0.1, port: 35001, udp: false, proxy: xray-reality}\n'
  printf '  - {name: l-enc, type: socks, listen: 127.0.0.1, port: 35002, udp: false, proxy: xray-vless-enc}\n'
  printf 'rules:\n  - MATCH,DIRECT\n'
} > "${WORK}/client.yaml"
"${MIHOMO}" -t -d "${WORK}" -f "${WORK}/client.yaml" >/dev/null
"${MIHOMO}" -d "${WORK}" -f "${WORK}/client.yaml" > "${WORK}/mihomo.log" 2>&1 &
MPID=$!
sleep 2

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -k "$@" || true; }
pass=0; fail=0
expect() { # 名称 期望 实际
  if [[ "$3" == "$2" ]]; then echo "  PASS  $1 → $3"; pass=$((pass+1)); else echo "  FAIL  $1 → $3（期望 $2）"; fail=$((fail+1)); fi
}

echo "== 阶段 A：生产配置（systemd xray.service，geoip:private 屏蔽生效）"
inct systemctl is-active xray.service
for p in 35001:reality 35002:enc; do
  port="${p%%:*}"; n="${p#*:}"
  expect "[$n] http://127.0.0.1:9080 应被屏蔽" 000 "$(code --socks5 "127.0.0.1:${port}" http://127.0.0.1:9080/)"
  expect "[$n] https://127.0.0.1:9443 应被屏蔽" 000 "$(code --socks5 "127.0.0.1:${port}" https://127.0.0.1:9443/)"
  expect "[$n] http://localhost:9080（域名解析到回环）应被屏蔽" 000 "$(code --socks5-hostname "127.0.0.1:${port}" http://localhost:9080/)"
done

echo "== 阶段 B：仅测试用配置（在生产配置前插入对 127.0.0.1:9080 的放行例外）"
inct jq '
  .routing.rules = [{protocol:["bittorrent"], outboundTag:"block"}, {ip:["127.0.0.1/32"], port:"9080", outboundTag:"direct"}] + .routing.rules
  | (.outbounds[] | select(.tag=="direct") | .settings.finalRules) |= ([{action:"allow", ip:["127.0.0.1/32"], port:"9080"}] + .)
' /usr/local/etc/xray/config.json > "${WORK}/test.json"
# 容器的 /run 是独立 tmpfs，需在容器内写入
inct install -m 0640 -o root -g xray /dev/stdin /run/xray-test.json < "${WORK}/test.json"
inct env XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config /run/xray-test.json >/dev/null && echo "  test config: xray run -test OK"
inct systemctl stop xray.service
inct systemctl reset-failed xray-loopback-test.service 2>/dev/null || true
inct systemd-run -q --unit=xray-loopback-test -p User=xray -p Group=xray \
  -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p CapabilityBoundingSet=CAP_NET_BIND_SERVICE -p NoNewPrivileges=yes \
  --setenv=XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -config /run/xray-test.json
sleep 2
# 已知行为：服务端重启后客户端缓存的 0-RTT ticket 失效，Encryption 节点重启后的第一个连接会失败，随后自动回到 1-RTT
echo "  INFO  [enc] 服务端重启后的首个请求（预热，可能为 000）→ $(code --socks5 127.0.0.1:35002 http://127.0.0.1:9080/)"
for p in 35001:reality 35002:enc; do
  port="${p%%:*}"; n="${p#*:}"
  expect "[$n] http://127.0.0.1:9080（放行例外）" 200 "$(code --socks5 "127.0.0.1:${port}" http://127.0.0.1:9080/)"
  expect "[$n] 下载 64MiB 校验大小" 67108864 "$(curl -s -o /dev/null -w '%{size_download}' --max-time 20 --socks5 "127.0.0.1:${port}" 'http://127.0.0.1:9080/?mb=64' || true)"
  expect "[$n] https://127.0.0.1:9443（未放行，仍屏蔽）" 000 "$(code --socks5 "127.0.0.1:${port}" https://127.0.0.1:9443/)"
done
# BitTorrent 屏蔽（测试配置中 bittorrent 规则排在放行例外之前）
for p in 35001:reality 35002:enc; do
  port="${p%%:*}"; n="${p#*:}"
  expect "[$n] 普通 HTTP 首包经隧道" RESPONDED "$(python3 "$(dirname "$0")/bt_probe.py" "${port}" http)"
  expect "[$n] BitTorrent 握手首包应被屏蔽" NO_RESPONSE "$(python3 "$(dirname "$0")/bt_probe.py" "${port}" bt)"
done
# 错误 shortId / 未认证客户端应被当作普通 TLS 访问转给 target（REALITY 伪装）
expect "直连 REALITY 端口（无认证，应看到 target 的自签证书页面）" 200 "$(code --resolve local.test:443:127.0.0.1 https://local.test:443/)"
inct systemctl stop xray-loopback-test.service
inct rm -f /run/xray-test.json
inct systemctl start xray.service
inct systemctl is-active xray.service
echo "mihomo 客户端日志（warning 级别）："; sed -E 's/[A-Za-z0-9_-]{40,}/<hidden>/g' "${WORK}/mihomo.log" | tail -5
echo "结果：PASS=${pass} FAIL=${fail}"
[[ "${fail}" -eq 0 ]]
