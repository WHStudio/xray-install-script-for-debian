# Xray-core 服务端一键部署脚本（Debian 13）

在 Debian 13 服务器上部署 **Xray-core**，提供两种入站（可只启用其一）：

| 入站 | 协议 | 默认端口 |
|---|---|---|
| `vless-reality` | VLESS + REALITY + `xtls-rprx-vision` | 443 |
| `vless-enc` | VLESS Encryption `mlkem768x25519plus.native`（后量子 ML-KEM-768 + X25519）+ Vision，`security: none` | 20000–59999 随机 |

交互界面与流程参考 [WHStudio/mihomo-install-script-for-debian](https://github.com/WHStudio/mihomo-install-script-for-debian)（mihomo 版）。本项目针对 Xray-core 独立重写。

## 快速开始

```bash
# 以 root 运行，进入中文交互菜单
bash <(curl -fsSL https://raw.githubusercontent.com/WHStudio/xray-install-script-for-debian/main/install.sh)
# 或先下载再运行
curl -fsSLo install.sh https://raw.githubusercontent.com/WHStudio/xray-install-script-for-debian/main/install.sh && bash install.sh
```

非交互的一条命令示例：

```bash
NONINTERACTIVE=1 DEPLOY_MODE=both REALITY_TARGET=www.example.com:443 \
  REALITY_PORT=443 ENC_PORT=24443 bash install.sh install
```

## 命令

```
bash install.sh [install|update|reconfigure|info|uninstall] [--purge] [-y]
```

- `install`：安装。如果已经安装过，就等同于重新配置，并默认沿用现有的密钥。
- `update`：只更新 Xray-core 二进制，配置不动。会先用新二进制执行 `run -test` 校验现有配置，通过后才替换。
- `reconfigure`：重新生成配置。
- `info`：显示客户端信息。
- `uninstall`：卸载，默认保留 `/usr/local/etc/xray`。加 `--purge` 会把配置和 `xray` 用户一并删除。
- 不带参数运行时会进入菜单：如果已经安装过，可以选择更新、重新配置、显示信息、卸载或退出。

## 环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `XRAY_ACTION` | 指定操作，同上面的命令 | 菜单 |
| `NONINTERACTIVE` | 设为 1 时全部从环境变量读取，不提问（等同 `-y`） | 0 |
| `XRAY_VERSION` | 固定版本，如 `26.10.21`。指定预发布版本时会给出警告 | 最新稳定版 |
| `GITHUB_PROXY` | 下载前缀代理，如 `https://ghfast.top/` | 空 |
| `DEPLOY_MODE` | `both` / `reality` / `enc` | both |
| `REALITY_PORT` / `ENC_PORT` | 端口。两个端口必须不同，并检查是否已被占用 | 443 / 随机 |
| `REALITY_TARGET` | REALITY 的 target，格式为 `host[:port]`。**非交互模式下使用 REALITY 时必填** | — |
| `REALITY_SNI` | serverNames，逗号分隔 | target 的主机名 |
| `CHECK_TARGET` | 设为 1 时用 openssl 检查 target 是否支持 TLS1.3 + h2（另外还会提示 X25519MLKEM768 支持和证书有效性） | 交互模式会询问，非交互默认 0 |
| `SERVER_ADDRESS` | 客户端连接用的地址（IP 或域名） | 自动探测 |
| `DETECT_PUBLIC_IP` | 设为 1 时，若 `SERVER_ADDRESS` 为空，就请求 api.ipify.org 探测公网 IP | 1 |
| `LISTEN_ADDR` | 监听地址 | 所有地址 |
| `BLOCK_BT` | 是否屏蔽 BitTorrent（会开启 sniffing，`routeOnly`） | 1 |
| `ACCESS_LOG` | 设为 1 时访问日志写入 journal | 0 |
| `NFT_CONNLIMIT` | 每个 IP 的并发 TCP 连接上限。设为 0 或留空表示不启用 | 不启用 |
| `KEEP_KEYS` | 重新配置时是否沿用已有的 UUID 和密钥 | 1 |
| `PURGE` | 卸载时设为 1，会同时删除配置和 `xray` 用户 | 0 |
| `SKIP_START` | 设为 1 时只写文件，不启动服务 | 0 |
| `FORCE_DOWNLOAD` | 设为 1 时即使版本相同也重新下载 | 0 |
| `PREFIX` | **测试用**：所有文件写入该目录，不装依赖、不建用户、不碰 systemd 和 nft | 空 |
| `XRAY_API_BASE` / `XRAY_DOWNLOAD_BASE` | GitHub API 和下载地址（可用于镜像或测试） | 官方地址 |

## 脚本对系统做了什么

- **依赖**：通过 apt 安装 `curl unzip jq openssl iproute2 ca-certificates`。只有在启用连接数限制时，才会额外安装 `nftables`。
- **用户**：创建系统用户和组 `xray`（不能登录、没有 home 目录）。
- **下载 Xray-core**：
  - 通过 GitHub API 获取最新稳定版。获取到的版本如果是预发布版会直接中止；手动指定版本时允许预发布版，只给出警告。
  - 根据架构选择 `Xray-linux-64.zip`（amd64）或 `Xray-linux-arm64-v8a.zip`（arm64）。
  - 下载后计算 SHA256，并与两处数据比对：**同名 `.dgst` 文件** 和 **GitHub API 的 asset `digest`**。任何一处不一致就中止，不改动现有安装。
- **文件**：
  - `/usr/local/bin/xray`
  - `/usr/local/share/xray/{geoip.dat,geosite.dat,LICENSE}`
  - `/usr/local/etc/xray/config.json`：权限 `640 root:xray`。写入前会先执行 `xray run -test`；内容有变化时，旧文件备份为 `config.json.bak.<时间>`
  - `/usr/local/etc/xray/client-mihomo.yaml` 和 `share-links.txt`：权限 `600`
  - `/etc/systemd/system/xray.service`
  - 启用连接数限制时，另有 `/usr/local/etc/xray/connlimit.nft` 和 `xray-connlimit.service`
- **幂等**：重复运行时，如果输入不变，`config.json` 也保持字节级相同（已验证）。版本相同时跳过下载。

## 服务端配置要点

- 日志级别为 `warning`，`access: none`，`dnsLog: false`。不开启 API、stats，也不配置 fallbacks。
- **REALITY 入站**：
  - 密钥用 `xray x25519` 生成；shortId 是随机 8 字节（16 个十六进制字符）。
  - target 和 serverNames 由用户选择，可以选择用 openssl 检查 target。
- **Encryption 入站**：
  - 用 `xray vlessenc` 生成 ML-KEM-768 密钥。服务端 decryption 为 `mlkem768x25519plus.native.600s.<seed>`，客户端 encryption 为 `mlkem768x25519plus.native.0rtt.<client>`。
  - 沿用密钥时，客户端串用 `xray mlkem768 -i <seed>` 重新推导。
- **屏蔽私有地址**：
  - routing 中设置 `geoip:private → blackhole`。
  - freedom 出站中 `finalRules` 设置 `block geoip:private`。即使目标是域名、解析后落到内网，也会被拦截。
- 可选屏蔽 BitTorrent（`protocol: bittorrent → blackhole`）。
- **systemd 加固**：
  - 以 `User=xray` 运行。能力只有 `CAP_NET_BIND_SERVICE`（Bounding 和 Ambient 均如此），并设置 `NoNewPrivileges`。
  - 文件系统：`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`PrivateDevices`。
  - 内核与进程：`ProtectKernel*`、`ProtectProc=invisible`、`RestrictNamespaces`、`MemoryDenyWriteExecute`。
  - 网络与系统调用：`RestrictAddressFamilies`、`SystemCallFilter=@system-service ~@privileged`。
  - 其他：`UMask=0077`、`LimitNOFILE=1048576`。
  - 启动前执行 `ExecStartPre=xray run -test`；配置错误（退出码 23）时不会反复重启。
  - `systemd-analyze security` 评分为 **1.6 OK**。
- **nftables 连接数限制**：
  - 使用独立的表 `inet xray_connlimit`，不动其他表。
  - 超过上限的新连接会被 `ct count over N` 规则以 TCP RST 拒绝。
  - 规则由 oneshot 服务 `xray-connlimit.service` 在开机时加载。

## 客户端

脚本会生成两类客户端信息：

- **mihomo `proxies` 片段**：
  - `client-fingerprint: chrome`、`flow: xtls-rprx-vision`。
  - 两个节点都带 `support-x25519mlkem768: true`；Xray ≥ 26.9.9 的服务端需要客户端支持该选项。
  - Encryption 节点的 `encryption` 字段为 `...native.0rtt.<client>`。
- **`vless://` 分享链接**：IPv6 地址会自动加方括号。

运行 `bash install.sh info` 可以随时再次查看。屏幕上和客户端文件中都不会输出服务端私钥或 seed。

## 卸载

```bash
bash install.sh uninstall          # 删除二进制、数据文件、systemd 服务和 nft 表，保留 /usr/local/etc/xray
bash install.sh uninstall --purge  # 同时删除配置和 xray 用户
```

保留配置后重新安装，会默认沿用原来的 UUID、密钥和 shortId，客户端不用改。

## 测试方法（test/ 目录）

所有测试都只在本机回环地址上进行，不产生任何公网代理流量。

1. 用 `debootstrap trixie` 构建 Debian 13 rootfs，然后用 `systemd-nspawn -b` 启动。容器内运行的是真实的 systemd，并共享宿主网络命名空间。
2. 在本地启动 target：127.0.0.1:9443 提供自签证书的 TLS1.3+h2，127.0.0.1:9080 提供 HTTP。
3. 用 `test/ct.sh`（在容器内以 `env -i` 的干净环境运行 install.sh）安装：
   ```bash
   LEADER=<容器PID> test/ct.sh NONINTERACTIVE=1 DEPLOY_MODE=both LISTEN_ADDR=127.0.0.1 \
     REALITY_TARGET=127.0.0.1:9443 REALITY_SNI=local.test SERVER_ADDRESS=127.0.0.1 ENC_PORT=24443
   ```
4. 运行 `sudo LEADER=… MIHOMO=… ROOTFS=… bash test/loopback-test.sh`，直接使用生成的 mihomo YAML 作为客户端，测试分两个阶段：
   - **阶段 A（生产配置）**：访问 127.0.0.1 或 localhost 的请求都必须被屏蔽。
   - **阶段 B（仅测试用配置）**：在生产配置前插入一个放行 `127.0.0.1:9080` 的例外（routing 和 finalRules 都加），写到容器的 `/run/xray-test.json`，以 xray 用户临时运行。测试完成后恢复正式服务。阶段 B 验证以下内容：
     - 两个节点都返回 200，64 MiB 下载大小校验正确。
     - 未放行的 9443 仍被屏蔽。
     - BitTorrent 首包被屏蔽。
     - 不带认证直连 REALITY 端口时，会被转发到 target。
   - **这个放行例外只存在于测试配置中，脚本生成的生产配置里没有。**

## 注意事项

- **来源**：本项目是作者自己的 [mihomo 部署脚本](https://github.com/WHStudio/mihomo-install-script-for-debian) 的 Xray 对应版本（交互界面与流程同源，代码针对 Xray-core 独立重写）。
- **Encryption 0-RTT**：服务端重启后，客户端用旧 ticket 发起的第一个 0-RTT 请求会失败，随后自动退回 1-RTT 恢复。这是协议的预期行为。
- **REALITY target**：应选择境外、支持 TLS1.3 + h2、与服务器网络位置相近、非 CDN 落地的站点。不要用自己的域名，也不要用 Cloudflare 等 CDN 上的站点。
- **nftables 规则可能被清空**：如果系统启用了 Debian 自带的 `nftables.service`，它执行 `flush ruleset` 时会清掉 `xray_connlimit` 表。可以执行 `systemctl restart xray-connlimit` 重新加载。
- **GitHub 下载代理**：`GITHUB_PROXY` 只作用于 zip 和 `.dgst` 的下载；GitHub API 请求始终直连官方地址，用 API 返回的 digest 交叉校验代理下载的文件。手动指定版本且 API 不可达时，只能用 `.dgst` 校验并给出警告：这时 `.dgst` 与 zip 来自同一来源，请自行评估代理是否可信。
- **`PREFIX` 模式**：仅用于测试。不装依赖、不建用户，也不涉及 systemd 和 nft。
- **客户端要求**：需要较新的 mihomo（支持 VLESS Encryption 和 `support-x25519mlkem768`）。
