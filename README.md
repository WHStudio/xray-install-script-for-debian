# xray-install-script-for-debian

在 Debian 13 上轻松部署 Xray-core 及其两大核心协议。

Encryption 入站为 `mlkem768x25519plus`（外观 native / xorpub / random 自选其一，默认 random）+ Vision；REALITY 入站为 VLESS + REALITY + Vision。

完整说明见 [README.zh_CN.md](README.zh_CN.md)，全部由 AI 生成，请谨慎分辨。

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WHStudio/xray-install-script-for-debian/main/install.sh)
```
