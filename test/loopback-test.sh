#!/usr/bin/env bash
# 仅回环测试（不产生任何公网代理流量）。
# 前提：systemd-nspawn 容器（共享宿主网络命名空间）里已用 install.sh 安装，
#       LISTEN_ADDR=127.0.0.1 REALITY_TARGET=127.0.0.1:9443 REALITY_SNI=local.test SERVER_ADDRESS=127.0.0.1
#       本地 target（自签 TLS1.3+h2 于 127.0.0.1:9443，HTTP 于 127.0.0.1:9080）已运行。
#       UDP echo（127.0.0.1:9053）由本脚本自行启动。
#       宿主需有 tcpdump、tshark（Encryption 端口抓包断言，仅抓 lo）。
# 用法：sudo LEADER=<容器 systemd 的 PID> MIHOMO=/path/to/mihomo ROOTFS=/path/to/rootfs [PCAP_OUT=/path/enc.pcap] bash loopback-test.sh
set -Eeuo pipefail
: "${LEADER:?}" "${MIHOMO:?}" "${ROOTFS:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
MPID=""; UPID=""; TPID=""
cleanup() { for p in "${MPID}" "${UPID}" "${TPID}"; do if [[ -n "${p}" ]]; then kill "${p}" 2>/dev/null || true; fi; done; rm -rf "${WORK}"; }
trap cleanup EXIT
inct() { nsenter -t "${LEADER}" -a -- "$@"; }
ETC="${ROOTFS}/usr/local/etc/xray"
pass=0; fail=0
expect() { # 名称 期望 实际
  if [[ "$3" == "$2" ]]; then echo "  PASS  $1 → $3"; pass=$((pass+1)); else echo "  FAIL  $1 → $3（期望 $2）"; fail=$((fail+1)); fi
}

echo "== 阶段 0：输出文件格式与服务端配置"
# 去掉可变值，只保留字段集合 / 顺序 / 固定值；encryption 的 key 段替换为 <长度>
norm() {
  awk '{
    if ($0 ~ /^ *(server|port|uuid|servername|public-key|short-id):/) { sub(/:.*/, ":"); print; next }
    if ($0 ~ /^ *encryption: /) { split($0, a, ": "); n = split(a[2], s, "."); o = s[1] "." s[2] "." s[3];
      for (i = 4; i <= n; i++) o = o ".<" length(s[i]) ">"; print a[1] ": " o; next }
    print }' "$1"
}
if diff -u "${HERE}/expected-client-format.txt" <(norm "${ETC}/client-mihomo.yaml"); then r="same"; else r="different"; fi
expect "client-mihomo.yaml 字段集合/顺序/取值风格与参考格式一致" same "${r}"
expect "client-mihomo.yaml 权限" 600 "$(stat -c %a "${ETC}/client-mihomo.yaml")"
expect "share-links.txt 权限" 600 "$(stat -c %a "${ETC}/share-links.txt")"
expect "Encryption 链接：random.0rtt + 单个 ML-KEM-768 client 密钥 + flow=vision" 1 \
  "$(grep -cE '^vless://[^?]+\?encryption=mlkem768x25519plus\.random\.0rtt\.[A-Za-z0-9_-]{1579}&flow=xtls-rprx-vision&security=none&.*#vless-encryption$' "${ETC}/share-links.txt")"
expect "REALITY 链接：encryption=none、flow=vision、fp=chrome" 1 \
  "$(grep -cE '^vless://[^?]+\?encryption=none&flow=xtls-rprx-vision&security=reality&.*&fp=chrome&.*#vless-reality$' "${ETC}/share-links.txt")"
expect "服务端 Encryption 入站：random.600s、单个 key、flow=vision" "random.600s keys=1 xtls-rprx-vision" \
  "$(jq -r '.inbounds[]|select(.tag=="vless-enc")|.settings as $s|($s.decryption|split(".")) as $d|"\($d[1:3]|join(".")) keys=\($d|length-3) \($s.clients[0].flow//"-")"' "${ETC}/config.json")"
expect "服务端 Encryption 入站 key 为 ML-KEM-768 seed（86 字符）" 86 \
  "$(jq -r '.inbounds[]|select(.tag=="vless-enc")|.settings.decryption|split(".")[3]|length' "${ETC}/config.json")"
expect "服务端 REALITY 入站 decryption=none 且 flow=vision" "none xtls-rprx-vision" \
  "$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.settings.decryption+" "+.settings.clients[0].flow' "${ETC}/config.json")"
ep="$(jq -r '.inbounds[]|select(.tag=="vless-enc")|.port' "${ETC}/config.json")"
expect "Encryption 端口默认落在 4000-9999（实际 ${ep}）" yes "$( ((ep >= 4000 && ep <= 9999)) && echo yes || echo no)"

# 1) mihomo 客户端：直接使用 install.sh 生成的 proxies（原样，fp=chrome），
#    另追加一个只把 client-fingerprint 改成 safari 的 REALITY 副本做反例对照；入口只监听 127.0.0.1
{
  printf 'mode: rule\nlog-level: warning\nallow-lan: false\nbind-address: 127.0.0.1\nipv6: false\n'
  cat "${ETC}/client-mihomo.yaml"
  awk '/^  - name: vless-reality$/ { f = 1; print "  - name: vless-reality-safari"; next } /^  - name: / { f = 0 }
       f { sub(/client-fingerprint: .*/, "client-fingerprint: safari"); print }' "${ETC}/client-mihomo.yaml"
  printf 'listeners:\n'
  printf '  - {name: l-reality, type: socks, listen: 127.0.0.1, port: 35001, udp: true, proxy: vless-reality}\n'
  printf '  - {name: l-enc, type: socks, listen: 127.0.0.1, port: 35002, udp: true, proxy: vless-encryption}\n'
  printf '  - {name: l-reality-safari, type: socks, listen: 127.0.0.1, port: 35003, udp: true, proxy: vless-reality-safari}\n'
  printf 'rules:\n  - MATCH,DIRECT\n'
} > "${WORK}/client.yaml"
"${MIHOMO}" -t -d "${WORK}" -f "${WORK}/client.yaml" >/dev/null
"${MIHOMO}" -d "${WORK}" -f "${WORK}/client.yaml" > "${WORK}/mihomo.log" 2>&1 &
MPID=$!
python3 "${HERE}/udp_echo.py" & UPID=$!
sleep 2

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 -k "$@" || true; }

echo "== 阶段 A：生产配置（systemd xray.service，geoip:private 屏蔽生效）"
inct systemctl is-active xray.service
for p in 35001:reality 35002:enc; do
  port="${p%%:*}"; n="${p#*:}"
  expect "[$n] http://127.0.0.1:9080 应被屏蔽" 000 "$(code --socks5 "127.0.0.1:${port}" http://127.0.0.1:9080/)"
  expect "[$n] https://127.0.0.1:9443 应被屏蔽" 000 "$(code --socks5 "127.0.0.1:${port}" https://127.0.0.1:9443/)"
  expect "[$n] http://localhost:9080（域名解析到回环）应被屏蔽" 000 "$(code --socks5-hostname "127.0.0.1:${port}" http://localhost:9080/)"
  expect "[$n] UDP 127.0.0.1:9053 应被屏蔽" NO_ECHO "$(python3 "${HERE}/udp_probe.py" "${port}" || true)"
done

echo "== 阶段 B：仅测试用配置（在生产配置前插入对 127.0.0.1:9080/9053/9443 的放行例外）"
inct jq '
  .routing.rules = [{protocol:["bittorrent"], outboundTag:"block"}, {ip:["127.0.0.1/32"], port:"9080,9053,9443", outboundTag:"direct"}] + .routing.rules
  | (.outbounds[] | select(.tag=="direct") | .settings.finalRules) |= ([{action:"allow", ip:["127.0.0.1/32"], port:"9080,9053,9443"}] + .)
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
# 已知行为：服务端重启后客户端缓存的 0-RTT ticket 失效，重启后的第一个连接会失败，随后自动回到 1-RTT
for port in 35002 35001; do
  echo "  INFO  [${port}] 服务端重启后的首个请求（预热，可能为 000）→ $(code --socks5 "127.0.0.1:${port}" http://127.0.0.1:9080/)"
done
# Encryption 端口全程抓包（只抓 lo、只抓该端口），稍后断言无 TLS 记录头/无 TLS 解析
PCAP="${PCAP_OUT:-${WORK}/enc.pcap}"
tcpdump -i lo -B 262144 -s 0 -w "${PCAP}" "tcp port ${ep}" 2> "${WORK}/tcpdump.log" & TPID=$!
sleep 1
for p in 35001:reality 35002:enc; do
  port="${p%%:*}"; n="${p#*:}"
  expect "[$n] http://127.0.0.1:9080（放行例外）" 200 "$(code --socks5 "127.0.0.1:${port}" http://127.0.0.1:9080/)"
  expect "[$n] 下载 64MiB 校验大小" 67108864 "$(curl -s -o /dev/null -w '%{size_download}' --max-time 20 --socks5 "127.0.0.1:${port}" 'http://127.0.0.1:9080/?mb=64' || true)"
  expect "[$n] UDP echo 127.0.0.1:9053（XUDP）" ECHO_OK "$(python3 "${HERE}/udp_probe.py" "${port}" || true)"
  # 内层 HTTPS（自签 TLS1.3，SNI=local.test）：覆盖 Vision 的内层 TLS 识别/直连复制路径
  expect "[$n] 内层 HTTPS（SNI local.test）下载 8MiB" "200 8388608" \
    "$(curl -s -k -o /dev/null -w '%{http_code} %{size_download}' --max-time 20 --socks5 "127.0.0.1:${port}" \
       --resolve local.test:9443:127.0.0.1 'https://local.test:9443/?mb=8' || true)"
done
sleep 1; kill -INT "${TPID}" 2>/dev/null || true; wait "${TPID}" 2>/dev/null || true; TPID=""
echo "  INFO  tcpdump：$(grep -E 'captured|dropped by kernel' "${WORK}/tcpdump.log" | tr '\n' ' ')"
pc="$(python3 "${HERE}/pcap_check.py" "${PCAP}" "${ep}" || true)"
echo "  INFO  pcap_check：${pc}"
expect "[enc 抓包] 端口 ${ep} 无 TLS 记录头链（17 03 03 …）" 0 "$(sed -nE 's/.*tls_chain_streams=([0-9]+).*/\1/p' <<< "${pc}")"
expect "[enc 抓包] tshark 默认启发式解析出的 TLS 帧数" 0 "$(tshark -r "${PCAP}" -Y tls 2>/dev/null | wc -l)"
expect "[enc 抓包] tshark 强制 -d tcp.port==${ep},tls：TLS 握手/SNI 字段数" 0 \
  "$(tshark -r "${PCAP}" -d "tcp.port==${ep},tls" -Y 'tls.handshake or tls.handshake.extensions_server_name or tls.record.content_type' 2>/dev/null | wc -l)"
expect "[enc 抓包] 抓包内容中无明文 SNI/HTTP" 0 "$(grep -c -a -E 'local\.test|HTTP/1\.1' "${PCAP}" || true)"
# 已知不兼容（见 CHANGES-t109.md）：mihomo 的 safari 指纹不带 X25519MLKEM768，Xray REALITY 拒绝 → 回落到 target
expect "[reality fp=safari 反例] 已知不兼容：应连接失败" 000 "$(code --socks5 127.0.0.1:35003 http://127.0.0.1:9080/)"
# BitTorrent 屏蔽（测试配置中 bittorrent 规则排在放行例外之前）
for p in 35001:reality 35002:enc; do
  port="${p%%:*}"; n="${p#*:}"
  expect "[$n] 普通 HTTP 首包经隧道" RESPONDED "$(python3 "${HERE}/bt_probe.py" "${port}" http)"
  expect "[$n] BitTorrent 握手首包应被屏蔽" NO_RESPONSE "$(python3 "${HERE}/bt_probe.py" "${port}" bt)"
done
# 未认证客户端应被当作普通 TLS 访问转给 target（REALITY 伪装）
expect "直连 REALITY 端口（无认证，应看到 target 的自签证书页面）" 200 "$(code --resolve local.test:443:127.0.0.1 https://local.test:443/)"
inct systemctl stop xray-loopback-test.service
inct rm -f /run/xray-test.json
inct systemctl start xray.service
inct systemctl is-active xray.service
echo "mihomo 客户端日志（warning 级别，最后 5 行）："; sed -E 's/[A-Za-z0-9_-]{40,}/<hidden>/g' "${WORK}/mihomo.log" | tail -5
echo "结果：PASS=${pass} FAIL=${fail}"
[[ "${fail}" -eq 0 ]]
