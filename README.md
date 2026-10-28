# xray-install-script-for-debian

适用于Debian13的xray服务端部署脚本

在 Debian 13 上部署 Xray-core（v1.3.0）。Encryption 入站为 `mlkem768x25519plus`（外观 native / xorpub / random，默认 random）+ Vision；REALITY 入站为 VLESS + REALITY + Vision，不叠加 VLESS Encryption；mihomo 客户端指纹为 chrome。freedom 出站的 DNS `domainStrategy` 写在 `streamSettings.sockopt`，默认 `UseIPv4v6`。完整说明见 [README.zh_CN.md](README.zh_CN.md)。

## 快速开始

```bash
bash install.sh
```
