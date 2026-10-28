#!/usr/bin/env bash
# Xray-core 服务端一键部署脚本（Debian 13）
# VLESS + REALITY + Vision  /  VLESS Encryption + Vision (mlkem768x25519plus, 0-RTT)
# REALITY 入站 decryption=none（按作者建议，REALITY 与 Encryption 二选一，不叠加）；
# 独立 Encryption 入站：native/xorpub/random 外观（默认 random）、600s 0-RTT ticket、单个 ML-KEM-768 密钥、flow=xtls-rprx-vision
# direct 出站 freedom domainStrategy 可选（默认 UseIPv4v6）
#
# 交互界面与流程参考 WHStudio/mihomo-install-script-for-debian（mihomo 版），
# 本脚本为针对 Xray-core 的独立重写实现。详见 README.zh_CN.md。

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.3.0"

# ── 可通过环境变量覆盖的参数 ────────────────────────────────────────────────
XRAY_ACTION="${XRAY_ACTION:-}"            # install | update | reconfigure | info | uninstall
NONINTERACTIVE="${NONINTERACTIVE:-0}"     # 1 = 全部从环境变量读取，不提问
XRAY_VERSION="${XRAY_VERSION:-}"          # 固定版本，如 26.10.21；留空 = 最新稳定版
GITHUB_PROXY="${GITHUB_PROXY:-}"          # 下载前缀代理，如 https://ghfast.top/
DEPLOY_MODE="${DEPLOY_MODE:-}"            # both | reality | enc
REALITY_PORT="${REALITY_PORT:-}"
ENC_PORT="${ENC_PORT:-}"                  # 留空 = 随机 4000-9999（避开已占用端口）
REALITY_TARGET="${REALITY_TARGET:-}"      # host[:port]，port 默认 443
REALITY_SNI="${REALITY_SNI:-}"            # 逗号分隔的 serverNames，默认 = target 主机名
CHECK_TARGET="${CHECK_TARGET:-}"          # 1/0：是否用 openssl 检查 target 支持 TLS1.3 + h2
SERVER_ADDRESS="${SERVER_ADDRESS:-}"      # 客户端连接用的地址（IP 或域名）
CLIENT_FP="${CLIENT_FP:-}"                # REALITY 节点 client-fingerprint / fp；留空 = 沿用已有，否则 chrome
DETECT_PUBLIC_IP="${DETECT_PUBLIC_IP:-1}" # 1 = SERVER_ADDRESS 为空时请求 api.ipify.org 探测
LISTEN_ADDR="${LISTEN_ADDR:-}"            # 留空 = 监听所有地址
BLOCK_BT="${BLOCK_BT:-}"                  # 1/0：屏蔽 BitTorrent（默认 1）
ENC_MODE="${ENC_MODE:-}"                  # native | xorpub | random：Encryption 外观；留空 = 沿用已有，否则 random
DOMAIN_STRATEGY="${DOMAIN_STRATEGY:-}"    # direct 出站 sockopt.domainStrategy；留空 = 沿用已有，否则 UseIPv4v6
ACCESS_LOG="${ACCESS_LOG:-}"              # 1/0：访问日志写入 journal；留空 = 沿用已有，否则 0（保护隐私）
NFT_CONNLIMIT="${NFT_CONNLIMIT:-}"        # 每 IP 并发连接上限；0 = 不启用；留空 = 沿用已有，否则不启用
KEEP_KEYS="${KEEP_KEYS:-}"                # 1/0：重新配置时沿用已有 UUID/密钥
PURGE="${PURGE:-0}"                       # 卸载时 1 = 同时删除配置与 xray 用户
SKIP_START="${SKIP_START:-0}"             # 1 = 只写文件不启动服务
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"     # 1 = 版本相同也重新下载
PREFIX="${PREFIX:-}"                      # 测试用：把所有文件写入该目录（不装依赖、不建用户、不碰 systemd/nft）
XRAY_API_BASE="${XRAY_API_BASE:-https://api.github.com/repos/XTLS/Xray-core}"
XRAY_DOWNLOAD_BASE="${XRAY_DOWNLOAD_BASE:-https://github.com/XTLS/Xray-core/releases/download}"

# ── 路径 ───────────────────────────────────────────────────────────────────
ROOT="${PREFIX%/}"
readonly ROOT
readonly XRAY_BIN="${ROOT}/usr/local/bin/xray"
readonly XRAY_SHARE="${ROOT}/usr/local/share/xray"
readonly XRAY_ETC="${ROOT}/usr/local/etc/xray"
readonly XRAY_CONFIG="${XRAY_ETC}/config.json"
readonly CLIENT_YAML="${XRAY_ETC}/client-mihomo.yaml"
readonly LINKS_FILE="${XRAY_ETC}/share-links.txt"
readonly NFT_FILE="${XRAY_ETC}/connlimit.nft"
readonly XRAY_UNIT="${ROOT}/etc/systemd/system/xray.service"
readonly NFT_UNIT="${ROOT}/etc/systemd/system/xray-connlimit.service"
readonly XRAY_USER="xray"
readonly TAG_REALITY="vless-reality"
readonly TAG_ENC="vless-enc"
readonly NAME_REALITY="vless-reality"     # mihomo 节点名 / 链接备注
readonly NAME_ENC="vless-encryption"
# VLESS Encryption：native / xorpub / random 外观；服务端 600s 0-RTT ticket；单个 ML-KEM-768 密钥（seed 86 / client 1579）
# （1.1.0 的 X25519+ML-KEM 双密钥不再匹配，reconfigure 时会重新生成）
readonly ENC_DEC_RE='^mlkem768x25519plus\.(native|xorpub|random)\.[0-9]+(-[0-9]+)?s\.[A-Za-z0-9_-]{86}$'
readonly ENC_ENC_RE='^mlkem768x25519plus\.(native|xorpub|random)\.0rtt\.[A-Za-z0-9_-]{1579}$'
# direct 出站 streamSettings.sockopt.domainStrategy 可选值（Xray v26.10.21 infra/conf/transport_sockopt.go 均支持）
readonly DS_VALUES="AsIs UseIPv4v6 UseIPv6v4 UseIPv4 UseIPv6 ForceIPv4v6 ForceIPv6v4 ForceIPv4 ForceIPv6"
readonly VISION_FLOW="xtls-rprx-vision"

TEMP_DIR=""
INTERACTIVE=1
STAGING=0
USE_SYSTEMD=1
REPLY=""

# ── UI ─────────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''
fi
readonly C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_MAGENTA C_CYAN
readonly LINE="${C_DIM}────────────────────────────────────────────────────────${C_RESET}"

banner() {
  printf '\n%s%s' "${C_CYAN}" "${C_BOLD}"
  cat <<'EOF'
  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║              Xray-core  服务端管理脚本               ║
  ║        VLESS REALITY  ·  VLESS Encryption (PQ)       ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝
EOF
  printf '%s\n' "${C_RESET}"
}

section() { printf '\n%s\n  %s●%s %s%s%s\n%s\n' "${LINE}" "${C_BLUE}" "${C_RESET}" "${C_BOLD}" "$1" "${C_RESET}" "${LINE}" >&2; }
# 状态信息全部写 stderr，避免污染 $(...) 的返回值
info() { printf '  %s▸%s %s\n' "${C_CYAN}" "${C_RESET}" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn() { printf '  %s!%s %s%s%s\n' "${C_YELLOW}" "${C_RESET}" "${C_YELLOW}" "$*" "${C_RESET}" >&2; }
err()  { printf '  %s✘%s %s%s%s\n' "${C_RED}" "${C_RESET}" "${C_RED}" "$*" "${C_RESET}" >&2; }
die()  { err "$*"; exit 1; }

menu_item() {
  if [[ -n "${3:-}" ]]; then
    printf '     %s%s%s) %s  %s%s%s\n' "${C_CYAN}${C_BOLD}" "$1" "${C_RESET}" "$2" "${C_DIM}" "$3" "${C_RESET}" >&2
  else
    printf '     %s%s%s) %s\n' "${C_CYAN}${C_BOLD}" "$1" "${C_RESET}" "$2" >&2
  fi
}

# ask "提示" [默认值] -> REPLY
ask() {
  local prompt="$1" def="${2:-}"
  if [[ "${INTERACTIVE}" -ne 1 ]]; then
    REPLY="${def}"
    return
  fi
  if [[ -n "${def}" ]]; then
    printf '  %s?%s %s %s[默认 %s]%s：' "${C_MAGENTA}" "${C_RESET}" "${prompt}" "${C_DIM}" "${def}" "${C_RESET}" >&2
  else
    printf '  %s?%s %s：' "${C_MAGENTA}" "${C_RESET}" "${prompt}" >&2
  fi
  IFS= read -r REPLY || REPLY=""
  REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
  REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
  [[ -n "${REPLY}" ]] || REPLY="${def}"
}

# yes_no "提示" 默认(1/0) -> 返回 0 表示是
yes_no() {
  local prompt="$1" def="$2" hint
  if [[ "${def}" == 1 ]]; then hint="Y/n"; else hint="y/N"; fi
  if [[ "${INTERACTIVE}" -ne 1 ]]; then
    [[ "${def}" == 1 ]]
    return
  fi
  while true; do
    printf '  %s?%s %s %s[%s]%s：' "${C_MAGENTA}" "${C_RESET}" "${prompt}" "${C_DIM}" "${hint}" "${C_RESET}" >&2
    IFS= read -r REPLY || REPLY=""
    case "${REPLY}" in
      "") [[ "${def}" == 1 ]]; return ;;
      [Yy]|[Yy][Ee][Ss]|是) return 0 ;;
      [Nn]|[Nn][Oo]|否) return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}
trap cleanup EXIT
trap 'err "脚本在第 ${LINENO} 行执行失败（命令：${BASH_COMMAND}）"; exit 1' ERR

usage() {
  cat <<EOF
用法：bash install.sh [install|update|reconfigure|info|uninstall] [--purge] [-y]

  install       安装（已安装时等同重新配置，默认沿用现有密钥）
  update        仅更新 Xray-core 二进制（校验 SHA256，保留配置）
  reconfigure   重新生成配置
  info          显示客户端信息（mihomo YAML 与 vless:// 链接）
  uninstall     卸载（默认保留 ${XRAY_ETC#"${ROOT}"}；加 --purge 一并删除）
  -y            非交互模式（等同 NONINTERACTIVE=1）

不带参数运行进入交互菜单。全部环境变量见 README.zh_CN.md。
EOF
}

# ── 通用工具 ───────────────────────────────────────────────────────────────
is_true() { [[ "${1:-0}" =~ ^(1|y|Y|yes|YES|true|TRUE|on)$ ]]; }

proxy_url() { printf '%s%s\n' "${GITHUB_PROXY}" "$1"; }

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

is_valid_domain() {
  local d="$1" label
  local -a labels
  [[ -n "${d}" && ${#d} -le 253 && "${d}" == *.* && "${d}" != .* && "${d}" != *. && "${d}" != *..* ]] || return 1
  IFS='.' read -r -a labels <<< "${d}"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  [[ ! "${d}" =~ ^[0-9.]+$ ]]
}

is_ipv4() {
  local ip="$1" o
  local -a octets
  [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "${ip}"
  for o in "${octets[@]}"; do ((10#${o} <= 255)) || return 1; done
}

is_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }

port_in_use() {
  # 返回 0 = 端口已被非 xray 进程占用
  local port="$1" out
  command -v ss >/dev/null 2>&1 || return 1
  out="$(ss -Hltnp "sport = :${port}" 2>/dev/null || true)"
  [[ -n "${out}" && "${out}" != *'"xray"'* ]]
}

port_listening() {
  # 返回 0 = 端口已有任意 TCP 监听（含 xray 自身）
  command -v ss >/dev/null 2>&1 || return 1
  [[ -n "$(ss -Hltn "sport = :$1" 2>/dev/null || true)" ]]
}

random_port() {
  # random_port [避开的端口] -> 4000-9999 中一个未被监听的端口
  local p i avoid="${1:-}"
  for ((i = 0; i < 200; i++)); do
    p=$((4000 + RANDOM % 6000))
    [[ "${p}" != "${avoid}" ]] || continue
    port_listening "${p}" || { echo "${p}"; return; }
  done
  die "无法在 4000-9999 中找到空闲端口，请用 ENC_PORT 指定"
}

xray_env() { XRAY_LOCATION_ASSET="${XRAY_SHARE}" "$@"; }

installed_version() {
  [[ -x "${XRAY_BIN}" ]] || return 1
  "${XRAY_BIN}" version 2>/dev/null | awk 'NR==1 && $1=="Xray" { print $2; exit }'
}

normalize_version() {
  local v="$1"
  v="${v//[[:space:]]/}"
  v="${v#v}"
  [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式无效：$1（应形如 26.10.21）"
  printf '%s\n' "${v}"
}

# ── 环境检查与依赖 ─────────────────────────────────────────────────────────
preflight() {
  section "环境检查"
  if [[ -n "${ROOT}" ]]; then
    STAGING=1
    USE_SYSTEMD=0
    warn "PREFIX=${ROOT}：暂存/测试模式，不安装依赖、不创建用户、不操作 systemd 与 nftables"
  else
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本"
  fi

  [[ -r /etc/os-release ]] || die "无法识别当前操作系统"
  local os_id os_ver
  os_id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
  os_ver="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
  if [[ "${STAGING}" -eq 0 ]]; then
    [[ "${os_id}" == "debian" ]] || die "此脚本仅支持 Debian（检测到：${os_id:-未知}）"
    [[ "${os_ver}" == "13" ]] || warn "此脚本面向 Debian 13，当前为 Debian ${os_ver:-未知}，继续执行但未经测试"
  fi

  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${arch}" in
    amd64|x86_64) ASSET_NAME="Xray-linux-64.zip" ;;
    arm64|aarch64) ASSET_NAME="Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的架构：${arch}（仅支持 amd64 / arm64）" ;;
  esac
  ok "系统：${os_id:-?} ${os_ver:-?} / ${arch} → ${ASSET_NAME}"

  if [[ "${STAGING}" -eq 0 ]]; then
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd"
    if [[ ! -d /run/systemd/system ]]; then
      warn "systemd 未作为 init 运行（容器/chroot？），将只写入文件不启动服务"
      SKIP_START=1
    fi
  fi
}

ensure_deps() {
  local -a need=(ca-certificates curl unzip jq openssl iproute2)
  local -a missing=()
  local p
  if [[ "${STAGING}" -eq 1 ]]; then
    for p in curl unzip jq sha256sum; do
      command -v "${p}" >/dev/null 2>&1 || die "暂存模式需要预先安装：${p}"
    done
    return
  fi
  for p in "${need[@]}"; do
    dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "install ok installed" || missing+=("${p}")
  done
  if ((${#missing[@]} > 0)); then
    info "正在安装依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
    ok "依赖安装完成"
  else
    ok "依赖已就绪"
  fi
}

prompt_github_proxy() {
  [[ "${INTERACTIVE}" -eq 1 && -z "${GITHUB_PROXY}" ]] || return 0
  section "GitHub 代理"
  info "访问 GitHub 较慢时可启用下载代理（无论是否使用代理，都会校验 SHA256）"
  printf '\n' >&2
  menu_item "0" "不使用代理（直连）" "[默认，推荐]"
  menu_item "1" "https://ghfast.top/"
  menu_item "2" "https://gh-proxy.com/"
  printf '\n' >&2
  while true; do
    ask "请输入选项 [0-2]" "0"
    case "${REPLY}" in
      0) GITHUB_PROXY=""; ok "直连 GitHub"; return ;;
      1) GITHUB_PROXY="https://ghfast.top/"; break ;;
      2) GITHUB_PROXY="https://gh-proxy.com/"; break ;;
      *) warn "选项无效，请重新输入" ;;
    esac
  done
  ok "已启用代理：${GITHUB_PROXY}"
}

# ── 下载与校验 ─────────────────────────────────────────────────────────────
# 结果：TARGET_VERSION、API_DIGEST（可能为空）
resolve_release() {
  section "获取版本"
  local api_url json tag
  API_DIGEST=""
  if [[ -n "${XRAY_VERSION}" ]]; then
    TARGET_VERSION="$(normalize_version "${XRAY_VERSION}")"
    api_url="${XRAY_API_BASE}/releases/tags/v${TARGET_VERSION}"
    info "使用指定版本 v${TARGET_VERSION}"
  else
    api_url="${XRAY_API_BASE}/releases/latest"
    info "正在获取 Xray-core 最新稳定版..."
  fi
  if json="$(curl -fsSL --retry 2 --connect-timeout 10 -H 'Accept: application/vnd.github+json' "${api_url}" 2>/dev/null)"; then
    tag="$(jq -r '.tag_name // empty' <<< "${json}")"
    if [[ "$(jq -r '.prerelease' <<< "${json}")" == "true" ]]; then
      [[ -n "${XRAY_VERSION}" ]] || die "latest 指向预发布版本，已中止"
      warn "v${TARGET_VERSION} 是预发布版本（prerelease），仅在你明确需要时使用"
    fi
    if [[ -z "${XRAY_VERSION}" ]]; then
      TARGET_VERSION="$(normalize_version "${tag}")"
    fi
    API_DIGEST="$(jq -r --arg n "${ASSET_NAME}" '.assets[]? | select(.name == $n) | .digest // empty' <<< "${json}")"
    API_DIGEST="${API_DIGEST#sha256:}"
    [[ -z "${API_DIGEST}" || "${API_DIGEST}" =~ ^[0-9a-f]{64}$ ]] || die "GitHub API 返回的 digest 格式异常"
  else
    [[ -n "${XRAY_VERSION}" ]] || die "无法访问 GitHub API 获取最新版本，可设置 XRAY_VERSION 固定版本"
    warn "无法访问 GitHub API，将只用 .dgst 文件校验"
  fi
  ok "目标版本：${C_BOLD}v${TARGET_VERSION}${C_RESET}"
}

# 下载并校验，解包到 ${TEMP_DIR}/pkg
download_verify() {
  local base="${XRAY_DOWNLOAD_BASE}/v${TARGET_VERSION}/${ASSET_NAME}"
  local zip="${TEMP_DIR}/${ASSET_NAME}" dgst="${TEMP_DIR}/${ASSET_NAME}.dgst"
  local actual expected got_ver
  info "正在下载 ${ASSET_NAME} (v${TARGET_VERSION}) ..."
  curl -fsSL --retry 2 --connect-timeout 15 --proto '=https,http' -o "${zip}" "$(proxy_url "${base}")" \
    || die "下载失败：${base}"
  curl -fsSL --retry 2 --connect-timeout 15 --proto '=https,http' -o "${dgst}" "$(proxy_url "${base}.dgst")" \
    || die "下载校验文件失败：${base}.dgst（拒绝在无校验的情况下安装）"

  actual="$(sha256sum "${zip}" | awk '{print $1}')"
  expected="$(awk -F'= *' '$1 == "SHA2-256" { print $2; exit }' "${dgst}" | tr -d '\r[:space:]')"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die ".dgst 文件中没有有效的 SHA2-256"
  if [[ "${actual}" != "${expected}" ]]; then
    err "SHA256 不匹配！"
    err "  实际：${actual}"
    err "  .dgst：${expected}"
    die "文件可能被篡改或下载不完整，已中止（未做任何更改）"
  fi
  ok "SHA256 与 .dgst 一致：${actual}"
  if [[ -n "${API_DIGEST}" ]]; then
    [[ "${actual}" == "${API_DIGEST}" ]] || die "SHA256 与 GitHub API digest 不一致（API：${API_DIGEST}），已中止"
    ok "SHA256 与 GitHub API asset digest 一致"
  fi
  if [[ -n "${GITHUB_PROXY}" && -z "${API_DIGEST}" ]]; then
    warn "使用了第三方代理且未取得 GitHub API digest：.dgst 与文件来自同一代理，请自行评估信任"
  fi

  mkdir -p "${TEMP_DIR}/pkg"
  unzip -q -o "${zip}" xray geoip.dat geosite.dat LICENSE -d "${TEMP_DIR}/pkg" || die "解压失败"
  chmod 0755 "${TEMP_DIR}/pkg/xray"
  got_ver="$("${TEMP_DIR}/pkg/xray" version | awk 'NR==1 { print $2 }')"
  [[ "${got_ver}" == "${TARGET_VERSION}" ]] || die "二进制版本 (${got_ver}) 与目标版本 (${TARGET_VERSION}) 不一致"
  ok "二进制自检通过：Xray ${got_ver}"
}

own() {
  # own 模式 属主 文件...
  local mode="$1" owner="$2"; shift 2
  chmod "${mode}" "$@"
  if [[ "${STAGING}" -eq 0 ]]; then chown "${owner}" "$@"; fi
}

install_binary() {
  install -d -m 0755 "${ROOT}/usr/local/bin" "${XRAY_SHARE}"
  install -m 0755 "${TEMP_DIR}/pkg/xray" "${XRAY_BIN}.new"
  mv -f "${XRAY_BIN}.new" "${XRAY_BIN}"
  install -m 0644 "${TEMP_DIR}/pkg/geoip.dat" "${TEMP_DIR}/pkg/geosite.dat" "${TEMP_DIR}/pkg/LICENSE" "${XRAY_SHARE}/"
  ok "已安装 ${XRAY_BIN#"${ROOT}"} 与 geoip/geosite 数据"
}

ensure_user() {
  [[ "${STAGING}" -eq 0 ]] || return 0
  if ! id -u "${XRAY_USER}" >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin --comment "Xray-core service" "${XRAY_USER}"
    ok "已创建系统用户 ${XRAY_USER}"
  else
    ok "系统用户 ${XRAY_USER} 已存在"
  fi
}

# ── 读取已有配置（用于沿用密钥 / 显示信息）────────────────────────────────
jq_cfg() { jq -r "$1" "${XRAY_CONFIG}" 2>/dev/null || true; }

load_existing() {
  OLD_R_PORT=""; OLD_R_UUID=""; OLD_R_PRIV=""; OLD_R_SID=""; OLD_R_TARGET=""; OLD_R_SNI=""
  OLD_E_PORT=""; OLD_E_UUID=""; OLD_E_DEC=""; OLD_BT=""; OLD_LISTEN=""; OLD_R_DEC=""; OLD_E_FLOW=""
  OLD_E_MODE=""; OLD_DS=""; OLD_DS_LEGACY=0; OLD_ACCESS=""; OLD_NFT=""
  if [[ -f "${NFT_FILE}" ]]; then
    OLD_NFT="$(sed -nE 's/.*ct count over ([0-9]+).*/\1/p' "${NFT_FILE}" | head -n1)"
  fi
  [[ -f "${XRAY_CONFIG}" ]] || return 0
  local r=".inbounds[]? | select(.tag==\"${TAG_REALITY}\")" e=".inbounds[]? | select(.tag==\"${TAG_ENC}\")"
  OLD_R_PORT="$(jq_cfg "${r} | .port")"
  OLD_R_UUID="$(jq_cfg "${r} | .settings.clients[0].id")"
  OLD_R_PRIV="$(jq_cfg "${r} | .streamSettings.realitySettings.privateKey")"
  OLD_R_SID="$(jq_cfg "${r} | .streamSettings.realitySettings.shortIds[0]")"
  OLD_R_TARGET="$(jq_cfg "${r} | .streamSettings.realitySettings.target")"
  OLD_R_SNI="$(jq_cfg "${r} | .streamSettings.realitySettings.serverNames | join(\",\")")"
  OLD_R_DEC="$(jq_cfg "${r} | .settings.decryption")"
  OLD_E_PORT="$(jq_cfg "${e} | .port")"
  OLD_E_UUID="$(jq_cfg "${e} | .settings.clients[0].id")"
  OLD_E_DEC="$(jq_cfg "${e} | .settings.decryption")"
  OLD_E_FLOW="$(jq_cfg "${e} | .settings.clients[0].flow // empty")"
  OLD_LISTEN="$(jq_cfg '[.inbounds[]? | .listen // empty][0] // empty')"
  if [[ "${OLD_E_DEC}" =~ ^mlkem768x25519plus\.(native|xorpub|random)\. ]]; then OLD_E_MODE="${BASH_REMATCH[1]}"; fi
  # 写在 streamSettings.sockopt.domainStrategy；也识别已弃用的 settings.domainStrategy（Xray 会打印弃用警告），重新配置时迁移
  local d=".outbounds[]? | select(.tag==\"direct\")"
  OLD_DS="$(jq_cfg "[${d} | .streamSettings.sockopt.domainStrategy // empty][0] // empty")"
  if [[ -z "${OLD_DS}" ]]; then
    OLD_DS="$(jq_cfg "[${d} | .settings.domainStrategy // empty][0] // empty")"
    [[ -z "${OLD_DS}" ]] || OLD_DS_LEGACY=1
  fi
  if [[ "$(jq_cfg '.log.access // "none"')" == "none" ]]; then OLD_ACCESS=0; else OLD_ACCESS=1; fi
  if [[ -n "$(jq_cfg '.routing.rules[]? | select(.protocol? | index("bittorrent")) | .outboundTag')" ]]; then OLD_BT=1; else OLD_BT=0; fi
}

reality_pubkey() {
  # 由私钥推导公钥（兼容 "PublicKey:" 与 "Password (PublicKey):" 两种输出）
  "${XRAY_BIN}" x25519 -i "$1" | awk -F': *' '$1 ~ /PublicKey/ { print $2; exit }' | tr -d '\r'
}

enc_client_from_dec() {
  # 服务端 decryption -> 客户端 encryption（逐个 key 推导，保持顺序；ticket 段改为 0rtt）
  #   mlkem768x25519plus.<mode>.600s.<ML-KEM-768 seed>
  #   -> mlkem768x25519plus.<mode>.0rtt.<ML-KEM-768 client>
  # 也兼容 1.0.0（native 单 seed）/ 1.1.0（X25519 + ML-KEM 双密钥）旧配置（仅用于 info 显示）
  local dec="$1" k pub out=""
  local -a parts
  IFS='.' read -r -a parts <<< "${dec}"
  ((${#parts[@]} >= 4)) && [[ "${parts[0]}" == "mlkem768x25519plus" ]] || return 1
  [[ "${parts[1]}" =~ ^(native|xorpub|random)$ ]] || return 1
  for k in "${parts[@]:3}"; do
    case "${#k}" in
      43) pub="$(reality_pubkey "${k}")" ;;
      86) pub="$("${XRAY_BIN}" mlkem768 -i "${k}" | awk -F': *' '$1 == "Client" { print $2; exit }' | tr -d '\r')" ;;
      *) return 1 ;;
    esac
    [[ "${pub}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    out+=".${pub}"
  done
  printf 'mlkem768x25519plus.%s.0rtt%s\n' "${parts[1]}" "${out}"
}

gen_enc_pair() {
  # 生成一个新的 VLESS Encryption 密钥（单个 ML-KEM-768，不混用 X25519 -> 作者建议 "do not mix them"）
  #   -> GEN_DEC（服务端 decryption）/ GEN_ENC（客户端 encryption）
  local m seed client
  m="$("${XRAY_BIN}" mlkem768 | tr -d '\r')"
  seed="$(awk -F': *' '$1 == "Seed" { print $2; exit }' <<< "${m}")"
  client="$(awk -F': *' '$1 == "Client" { print $2; exit }' <<< "${m}")"
  GEN_DEC="mlkem768x25519plus.${ENC_MODE}.600s.${seed}"
  GEN_ENC="mlkem768x25519plus.${ENC_MODE}.0rtt.${client}"
  [[ "${GEN_DEC}" =~ ${ENC_DEC_RE} && "${GEN_ENC}" =~ ${ENC_ENC_RE} ]] || die "VLESS Encryption 密钥生成/解析失败"
}

yaml_val() {
  # 默认输出 plain 标量（与参考格式一致）；只有会被 YAML 误读的值才加引号
  local v="$1"
  if [[ -z "${v}" || "${v}" =~ ^[-+]?([0-9_]+(\.[0-9_]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$ || "${v}" =~ ^0[xXoObB] \
        || "${v,,}" =~ ^(true|false|yes|no|on|off|y|n|null|~)$ || "${v}" =~ ^[:\[\{\&\*\!\|\>\'\"%@\`] || "${v}" == *" #"* || "${v}" == *": "* ]]; then
    printf '"%s"' "${v}"
  else
    printf '%s' "${v}"
  fi
}

# ── 配置问答 ───────────────────────────────────────────────────────────────
choose_mode() {
  # 重新配置时默认沿用现有部署模式
  local dm=both dn=1
  if [[ -n "${OLD_R_PRIV}" && -z "${OLD_E_DEC}" ]]; then dm=reality; dn=2
  elif [[ -z "${OLD_R_PRIV}" && -n "${OLD_E_DEC}" ]]; then dm=enc; dn=3; fi
  if [[ -z "${DEPLOY_MODE}" && "${INTERACTIVE}" -eq 1 ]]; then
    section "部署模式"
    local m1="" m2="" m3=""; printf -v "m${dn}" '%s' "[默认] "
    menu_item "1" "两者都部署" "${m1}REALITY 直连 + Encryption 备用/中转"
    menu_item "2" "仅 VLESS + REALITY + Vision" "${m2% }"
    menu_item "3" "仅 VLESS Encryption (0-RTT + Vision)" "${m3% }"
    printf '\n' >&2
    while true; do
      ask "请输入选项 [1-3]" "${dn}"
      case "${REPLY}" in
        1) DEPLOY_MODE=both; break ;;
        2) DEPLOY_MODE=reality; break ;;
        3) DEPLOY_MODE=enc; break ;;
        *) warn "选项无效，请重新输入" ;;
      esac
    done
  fi
  DEPLOY_MODE="${DEPLOY_MODE:-${dm}}"
  case "${DEPLOY_MODE}" in
    both) DO_REALITY=1; DO_ENC=1 ;;
    reality) DO_REALITY=1; DO_ENC=0 ;;
    enc|encryption) DEPLOY_MODE=enc; DO_REALITY=0; DO_ENC=1 ;;
    *) die "DEPLOY_MODE 只能是 both / reality / enc" ;;
  esac
  ok "部署模式：${DEPLOY_MODE}"
}

pick_port() {
  # pick_port 标签 默认 禁止端口 -> SELECTED_PORT
  local label="$1" def="$2" forbid="${3:-}" env_val="${4:-}" cand
  while true; do
    if [[ -n "${env_val}" ]]; then cand="${env_val}"; env_val=""; else ask "${label} 监听端口" "${def}"; cand="${REPLY}"; fi
    if ! valid_port "${cand}"; then
      [[ "${INTERACTIVE}" -eq 1 ]] || die "${label} 端口无效：${cand}"
      warn "端口无效，请输入 1-65535"; continue
    fi
    cand="$((10#${cand}))"
    if [[ -n "${forbid}" && "${cand}" == "${forbid}" ]]; then
      [[ "${INTERACTIVE}" -eq 1 ]] || die "两个入站不能使用同一端口：${cand}"
      warn "两个入站不能使用同一端口"; continue
    fi
    if [[ "${STAGING}" -eq 0 ]] && port_in_use "${cand}"; then
      [[ "${INTERACTIVE}" -eq 1 ]] || die "端口 ${cand} 已被其他进程占用"
      warn "端口 ${cand} 已被其他进程占用"; continue
    fi
    SELECTED_PORT="${cand}"
    ok "${label} 端口 → ${C_BOLD}${SELECTED_PORT}${C_RESET}"
    return
  done
}

parse_target() {
  # 输入 host[:port]；输出 T_HOST T_PORT
  local t="$1"
  T_HOST="${t}"; T_PORT=443
  if [[ "${t}" =~ ^\[(.+)\]:([0-9]+)$ ]]; then T_HOST="${BASH_REMATCH[1]}"; T_PORT="${BASH_REMATCH[2]}"
  elif [[ "${t}" =~ ^([^:]+):([0-9]+)$ ]]; then T_HOST="${BASH_REMATCH[1]}"; T_PORT="${BASH_REMATCH[2]}"
  fi
  valid_port "${T_PORT}" || return 1
  is_valid_domain "${T_HOST}" || is_ipv4 "${T_HOST}" || is_ipv6 "${T_HOST}"
}

check_target() {
  # 用本机 openssl 检查 target 是否支持 TLS1.3 + h2（以及 X25519MLKEM768）
  local host="$1" port="$2" sni="$3" out connect="$1:$2"
  is_ipv6 "${host}" && connect="[${host}]:${port}"
  command -v openssl >/dev/null 2>&1 || { warn "未找到 openssl，跳过 target 检查"; return 0; }
  info "正在检查 ${connect}（SNI=${sni}）是否支持 TLS 1.3 + HTTP/2 ..."
  out="$(timeout 12 openssl s_client -connect "${connect}" -servername "${sni}" -tls1_3 -alpn h2 \
        -groups X25519MLKEM768:X25519 -verify_hostname "${sni}" </dev/null 2>&1 | tr -d '\000' || true)"
  local good=1
  if grep -q 'TLSv1.3' <<< "${out}"; then ok "TLS 1.3：支持"; else err "TLS 1.3：不支持或无法连接"; good=0; fi
  if grep -q 'ALPN protocol: h2' <<< "${out}"; then ok "HTTP/2 (ALPN h2)：支持"; else err "HTTP/2 (ALPN h2)：不支持"; good=0; fi
  if grep -q 'X25519MLKEM768' <<< "${out}"; then ok "X25519MLKEM768：支持"; else warn "X25519MLKEM768：未协商（目标不支持后量子密钥交换，可用但不够理想）"; fi
  if grep -q 'Verify return code: 0 (ok)' <<< "${out}"; then ok "证书：有效且匹配 ${sni}"; else warn "证书：校验未通过（SNI 与证书不匹配或自签）"; fi
  [[ "${good}" -eq 1 ]]
}

configure_reality() {
  section "VLESS + REALITY + Vision"
  local def_port="${OLD_R_PORT:-443}" def_target="${OLD_R_TARGET}" sni_def tgt
  [[ "${KEEP}" -eq 1 ]] || def_port=443
  pick_port "REALITY" "${def_port}" "" "${REALITY_PORT}"
  R_PORT="${SELECTED_PORT}"
  [[ "${R_PORT}" == 443 ]] || warn "REALITY 不在 443 端口：Xray 启动时会打印警告（Listening on non-443 ports will increase the likelihood of your server's IP being blocked）"

  info "target 应为境外、支持 TLS1.3 + h2、非 CDN、与本机同地区的网站（不要用自己的域名，也不要用 Apple/Cloudflare 等大站）"
  tgt="${REALITY_TARGET}"
  if [[ -z "${tgt}" && "${INTERACTIVE}" -ne 1 && -n "${def_target}" ]]; then
    tgt="${def_target}"; info "沿用已有 REALITY target：${tgt}"
  fi
  while true; do
    if [[ -z "${tgt}" ]]; then
      [[ "${INTERACTIVE}" -eq 1 ]] || die "非交互模式必须设置 REALITY_TARGET（如 www.example.com:443）"
      ask "REALITY target（host[:port]）" "${def_target}"
      tgt="${REPLY}"
    fi
    if parse_target "${tgt}"; then break; fi
    [[ "${INTERACTIVE}" -eq 1 ]] || die "REALITY_TARGET 格式无效：${tgt}"
    warn "格式无效，示例：www.example.com 或 www.example.com:443"; tgt=""
  done
  R_TARGET_HOST="${T_HOST}"; R_TARGET_PORT="${T_PORT}"
  if is_ipv6 "${T_HOST}"; then R_TARGET="[${T_HOST}]:${T_PORT}"; else R_TARGET="${T_HOST}:${T_PORT}"; fi
  ok "target → ${C_BOLD}${R_TARGET}${C_RESET}"

  if is_valid_domain "${R_TARGET_HOST}"; then sni_def="${R_TARGET_HOST}"; else sni_def=""; fi
  [[ "${KEEP}" -eq 1 && -n "${OLD_R_SNI}" && "${OLD_R_TARGET}" == "${R_TARGET}" ]] && sni_def="${OLD_R_SNI}"
  local sni_in="${REALITY_SNI}" s ok_all
  while true; do
    if [[ -z "${sni_in}" ]]; then
      if [[ "${INTERACTIVE}" -eq 1 ]]; then ask "serverNames（逗号分隔，客户端使用第一个）" "${sni_def}"; sni_in="${REPLY}"
      else sni_in="${sni_def}"; fi
    fi
    sni_in="${sni_in// /}"
    ok_all=1
    IFS=',' read -r -a R_SNIS <<< "${sni_in}"
    ((${#R_SNIS[@]} > 0)) || ok_all=0
    for s in "${R_SNIS[@]}"; do is_valid_domain "${s}" || ok_all=0; done
    [[ "${ok_all}" -eq 1 ]] && break
    [[ "${INTERACTIVE}" -eq 1 ]] || die "REALITY_SNI 无效：${sni_in}"
    warn "serverNames 必须是域名列表"; sni_in=""
  done
  ok "serverNames → ${C_BOLD}${R_SNIS[*]}${C_RESET}"
  for s in "${R_SNIS[@]}"; do
    case "${s,,}" in
      *.ru|*.ir|*.cn|*apple*|*icloud*|*microsoft*)
        warn "serverName ${s}：Xray 认为此类目标（.cn/.ru/.ir、apple/icloud/microsoft）更容易导致 IP 被封，启动时会打印警告" ;;
    esac
  done

  local do_check=0
  if [[ -n "${CHECK_TARGET}" ]]; then is_true "${CHECK_TARGET}" && do_check=1
  elif yes_no "现在从本机检查 target 是否支持 TLS1.3 + h2？" 1; then do_check=1; fi
  if [[ "${do_check}" -eq 1 ]]; then
    if ! check_target "${R_TARGET_HOST}" "${R_TARGET_PORT}" "${R_SNIS[0]}"; then
      if [[ "${INTERACTIVE}" -eq 1 ]]; then
        yes_no "target 检查未通过，仍要继续吗？" 0 || die "已中止，请换一个 target"
      else
        die "target 检查未通过（设置 CHECK_TARGET=0 可跳过）"
      fi
    fi
  fi

}

reality_keys() {
  if [[ "${KEEP}" -eq 1 && -n "${OLD_R_PRIV}" && -n "${OLD_R_UUID}" ]]; then
    R_UUID="${OLD_R_UUID}"; R_PRIV="${OLD_R_PRIV}"; R_SID="${OLD_R_SID}"
    info "沿用已有 REALITY UUID / 密钥 / shortId"
  else
    local kp
    R_UUID="$("${XRAY_BIN}" uuid | tr -d '\r\n')"
    kp="$("${XRAY_BIN}" x25519 | tr -d '\r')"
    R_PRIV="$(awk -F': *' '$1 == "PrivateKey" { print $2; exit }' <<< "${kp}")"
    # shortId 至少含一个 a-d/f，保证在 YAML 中不加引号也不会被解析成数字
    R_SID=""
    until [[ "${R_SID}" =~ [a-df] ]]; do R_SID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; done
    ok "已生成新的 UUID、x25519 密钥对与 shortId"
  fi
  # REALITY 入站不叠加 VLESS Encryption（作者：REALITY 与 Encryption 二选一）
  R_ENC=""
  if [[ "${KEEP}" -eq 1 && -n "${OLD_R_DEC}" && "${OLD_R_DEC}" != "none" ]]; then
    warn "REALITY 入站已移除 VLESS Encryption（decryption=none）：客户端 REALITY 节点需要更新（删除 encryption）"
  fi
  R_PUB="$(reality_pubkey "${R_PRIV}")"
  [[ "${R_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "UUID 无效"
  [[ "${R_PRIV}" =~ ^[A-Za-z0-9_-]{43}$ && "${R_PUB}" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "REALITY 密钥解析失败"
  [[ "${R_SID}" =~ ^[0-9a-f]{0,16}$ ]] || die "shortId 无效"
}

enc_mode_menu() {
  printf '\n' >&2
  menu_item "1" "native" "TLS 1.3 记录头外观；可 splice"
  printf '        %s优势：配合 Vision 服务端可 splice（零拷贝，性能最好）；作者推荐 native/xorpub + Vision%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '        %s风险：数据记录头为 17 03 03，tshark 会标为 TLS Application Data（无握手/SNI/JA3）；握手中的公钥字节未隐藏%s\n' "${C_DIM}" "${C_RESET}" >&2
  menu_item "2" "xorpub" "在 native 基础上隐藏公钥字节"
  printf '        %s优势：同 native（可 splice，作者推荐），另对握手中的 X25519 公钥 / ML-KEM 密文做 XOR%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '        %s风险：数据记录头仍为 17 03 03，同样被识别为 TLS Application Data（无握手/SNI/JA3）%s\n' "${C_DIM}" "${C_RESET}" >&2
  menu_item "3" "random" "全随机外观（新装默认）"
  printf '        %s优势：记录头也做 XOR，抓包无 TLS 特征（本项目回环抓包已验证）%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '        %s风险：不能 splice，性能低于 native/xorpub；作者称 GFW 已将全随机外观列入黑名单（未核实）%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '\n' >&2
}

configure_enc() {
  section "VLESS Encryption (mlkem768x25519plus, 0-RTT)"
  local def_mode="${OLD_E_MODE:-random}" n
  if [[ -z "${ENC_MODE}" && "${INTERACTIVE}" -eq 1 ]]; then
    info "选择 Encryption 流量外观（两端必须一致；均为单个 ML-KEM-768 密钥 + Vision）："
    enc_mode_menu
    case "${def_mode}" in native) n=1 ;; xorpub) n=2 ;; *) n=3 ;; esac
    while true; do
      ask "请输入选项 [1-3]" "${n}"
      case "${REPLY}" in
        1|native) ENC_MODE=native; break ;;
        2|xorpub) ENC_MODE=xorpub; break ;;
        3|random) ENC_MODE=random; break ;;
        *) warn "选项无效，请重新输入" ;;
      esac
    done
  fi
  ENC_MODE="${ENC_MODE:-${def_mode}}"
  [[ "${ENC_MODE}" =~ ^(native|xorpub|random)$ ]] || die "ENC_MODE 只能是 native / xorpub / random"
  ok "Encryption 外观：${ENC_MODE}"
  local def_port
  if [[ "${KEEP}" -eq 1 && -n "${OLD_E_PORT}" ]]; then def_port="${OLD_E_PORT}"; else def_port="$(random_port "${R_PORT:-}")"; fi
  [[ "${def_port}" != "${R_PORT:-}" ]] || def_port="$(random_port "${R_PORT:-}")"
  pick_port "Encryption" "${def_port}" "${R_PORT:-}" "${ENC_PORT}"
  E_PORT="${SELECTED_PORT}"
}

enc_keys() {
  if [[ "${KEEP}" -eq 1 && -n "${OLD_E_UUID}" ]]; then
    E_UUID="${OLD_E_UUID}"
    info "沿用已有 Encryption UUID"
  else
    E_UUID="$("${XRAY_BIN}" uuid | tr -d '\r\n')"
    [[ "${E_UUID}" != "${R_UUID:-}" ]] || E_UUID="$("${XRAY_BIN}" uuid | tr -d '\r\n')"
  fi
  if [[ "${KEEP}" -eq 1 && "${OLD_E_DEC}" =~ ${ENC_DEC_RE} ]]; then
    # 密钥与外观无关：只替换外观段，seed / ticket 保持不变
    local -a parts
    IFS='.' read -r -a parts <<< "${OLD_E_DEC}"
    E_DEC="${parts[0]}.${ENC_MODE}.${parts[2]}.${parts[3]}"
    E_ENC="$(enc_client_from_dec "${E_DEC}")" || die "无法从现有 decryption 推导客户端 encryption"
    info "沿用已有 Encryption 密钥"
    if [[ "${OLD_E_MODE}" != "${ENC_MODE}" ]]; then
      warn "Encryption 外观 ${OLD_E_MODE} → ${ENC_MODE}：所有客户端的 ${NAME_ENC} 节点都必须更新 encryption 字段（密钥不变）"
    fi
    [[ "${OLD_E_FLOW}" == "${VISION_FLOW}" ]] || warn "Encryption 入站新增 flow=${VISION_FLOW}：客户端需要更新"
  else
    gen_enc_pair
    E_DEC="${GEN_DEC}"; E_ENC="${GEN_ENC}"
    ok "已生成 VLESS Encryption 密钥（单个 ML-KEM-768，${ENC_MODE} / 0-RTT）"
    if [[ "${KEEP}" -eq 1 && -n "${OLD_E_DEC}" ]]; then
      warn "旧版（1.1.0）Encryption 配置已升级为 ${ENC_MODE} + 单个 ML-KEM-768 + Vision，密钥已重新生成："
      warn "  所有客户端的 ${NAME_ENC} 节点都必须更新（UUID 与端口不变）"
    fi
  fi
  E_FLOW="${VISION_FLOW}"
  [[ "${E_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "UUID 无效"
  [[ "${E_ENC}" =~ ${ENC_ENC_RE} ]] || die "encryption 解析失败"
}

# 规范化 domainStrategy（大小写不敏感）-> 标准写法；无效返回 1
canon_ds() {
  local v
  for v in ${DS_VALUES}; do
    if [[ "${1,,}" == "${v,,}" ]]; then printf '%s\n' "${v}"; return 0; fi
  done
  return 1
}

configure_dns() {
  section "出站 DNS 解析策略（direct 出站 sockopt.domainStrategy）"
  local def="UseIPv4v6" fam n c
  [[ "${OLD_DS_LEGACY}" -eq 0 ]] || info "已有配置使用已弃用的 freedom settings.domainStrategy=${OLD_DS}，将迁移到 streamSettings.sockopt.domainStrategy（行为不变）"
  if [[ -n "${OLD_DS}" ]]; then
    if c="$(canon_ds "${OLD_DS}")"; then def="${c}"; else warn "已有 domainStrategy=${OLD_DS} 不在可选列表中，改用默认 UseIPv4v6"; fi
  fi
  if [[ -z "${DOMAIN_STRATEGY}" && "${INTERACTIVE}" -eq 1 ]]; then
    info "AsIs = 交给系统解析；Use* = Xray 内置解析，失败后回退到系统处理；Force* = 内置解析，失败不回退"
    info "v4 / v6 = 只解析该协议；v4v6 = 先 IPv4 后 IPv6；v6v4 = 先 IPv6 后 IPv4（当前默认：${def}）"
    if yes_no "域名解析交给系统处理（AsIs）？" "$([[ ${def} == AsIs ]] && echo 1 || echo 0)"; then
      DOMAIN_STRATEGY=AsIs
    else
      local pre="Use"
      if ! yes_no "Xray 内置解析失败后回退到系统处理？（是 = Use*，否 = Force*）" "$([[ ${def} == Force* ]] && echo 0 || echo 1)"; then pre="Force"; fi
      fam="${def#Use}"; fam="${fam#Force}"
      case "${fam}" in IPv4) n=1 ;; IPv6) n=2 ;; IPv6v4) n=4 ;; *) n=3 ;; esac
      printf '\n' >&2
      menu_item "1" "v4" "只解析 IPv4"
      menu_item "2" "v6" "只解析 IPv6"
      menu_item "3" "v4v6" "先 IPv4 后 IPv6$([[ ${n} == 3 ]] && echo '（默认）')"
      menu_item "4" "v6v4" "先 IPv6 后 IPv4"
      printf '\n' >&2
      while true; do
        ask "请选择解析顺序 [1-4]" "${n}"
        case "${REPLY}" in
          1|v4) fam=IPv4; break ;;
          2|v6) fam=IPv6; break ;;
          3|v4v6) fam=IPv4v6; break ;;
          4|v6v4) fam=IPv6v4; break ;;
          *) warn "选项无效，请重新输入" ;;
        esac
      done
      DOMAIN_STRATEGY="${pre}${fam}"
    fi
  fi
  DOMAIN_STRATEGY="${DOMAIN_STRATEGY:-${def}}"
  DOMAIN_STRATEGY="$(canon_ds "${DOMAIN_STRATEGY}")" || die "DOMAIN_STRATEGY 只能是：${DS_VALUES// / | }"
  ok "出站 domainStrategy：${DOMAIN_STRATEGY}"
}

configure_misc() {
  section "安全与其他选项"
  if [[ -z "${BLOCK_BT}" ]]; then
    local d="${OLD_BT:-1}"
    if yes_no "屏蔽 BitTorrent 流量？（启用 routeOnly 嗅探）" "${d}"; then BLOCK_BT=1; else BLOCK_BT=0; fi
  fi
  is_true "${BLOCK_BT}" && BLOCK_BT=1 || BLOCK_BT=0
  ok "内网/回环目标屏蔽：始终启用（routing geoip:private → blackhole + freedom finalRules）"
  ok "BitTorrent 屏蔽：$([[ ${BLOCK_BT} -eq 1 ]] && echo 启用 || echo 关闭)"

  if [[ -z "${NFT_CONNLIMIT}" ]]; then
    local nd=0; [[ -n "${OLD_NFT}" ]] && nd=1
    if [[ "${INTERACTIVE}" -ne 1 || "${STAGING}" -eq 1 ]]; then
      NFT_CONNLIMIT="${OLD_NFT:-0}"
    elif yes_no "启用 nftables 每 IP 并发连接数限制？" "${nd}"; then
      while true; do
        ask "每个源 IP 最大并发连接数" "${OLD_NFT:-64}"
        [[ "${REPLY}" =~ ^[1-9][0-9]{0,5}$ ]] && break
        warn "请输入正整数"
      done
      NFT_CONNLIMIT="${REPLY}"
    else
      NFT_CONNLIMIT=0
    fi
  fi
  [[ "${NFT_CONNLIMIT}" =~ ^[0-9]{1,6}$ ]] || die "NFT_CONNLIMIT 必须是数字"
  if [[ "${NFT_CONNLIMIT}" != 0 ]]; then ok "nftables 每 IP 并发上限：${NFT_CONNLIMIT}"; else ok "nftables 连接限制：不启用"; fi

  ACCESS_LOG="${ACCESS_LOG:-${OLD_ACCESS:-0}}"
  is_true "${ACCESS_LOG}" && ACCESS_LOG=1 || ACCESS_LOG=0
  [[ "${ACCESS_LOG}" -eq 0 ]] || warn "访问日志已开启（ACCESS_LOG=1）：客户端 IP 与访问目标会写入 journal"

  LISTEN_ADDR="${LISTEN_ADDR:-${OLD_LISTEN:-}}"
  if [[ -n "${LISTEN_ADDR}" ]]; then
    is_ipv4 "${LISTEN_ADDR}" || is_ipv6 "${LISTEN_ADDR}" || die "LISTEN_ADDR 必须是 IP 地址"
    ok "监听地址：${LISTEN_ADDR}"
  fi
}

# ── 生成配置 ───────────────────────────────────────────────────────────────
build_config() {
  local out="$1" inbounds='[]' sniff='null' sni_json
  if [[ "${BLOCK_BT}" -eq 1 ]]; then
    sniff='{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}'
  fi
  if [[ "${DO_REALITY}" -eq 1 ]]; then
    sni_json="$(printf '%s\n' "${R_SNIS[@]}" | jq -R . | jq -s .)"
    inbounds="$(jq -n --argjson acc "${inbounds}" --arg tag "${TAG_REALITY}" --argjson port "${R_PORT}" \
      --arg id "${R_UUID}" --arg target "${R_TARGET}" --argjson sni "${sni_json}" \
      --arg pk "${R_PRIV}" --arg sid "${R_SID}" --argjson sniff "${sniff}" '
      $acc + [{
        tag: $tag, port: $port, protocol: "vless",
        settings: { clients: [{ id: $id, flow: "xtls-rprx-vision" }], decryption: "none" },
        streamSettings: {
          network: "raw", security: "reality",
          realitySettings: { show: false, target: $target, xver: 0, serverNames: $sni, privateKey: $pk, shortIds: [$sid] }
        }
      } + (if $sniff then { sniffing: $sniff } else {} end)]')"
  fi
  if [[ "${DO_ENC}" -eq 1 ]]; then
    # flow=xtls-rprx-vision：Vision 填充 + 内层 TLS 直连复制；native/xorpub 可 splice，
    # random 不会 splice（inbound.go:563-565），但整条流量（含 5 字节记录头）全随机，无 TLS 特征
    inbounds="$(jq -n --argjson acc "${inbounds}" --arg tag "${TAG_ENC}" --argjson port "${E_PORT}" \
      --arg id "${E_UUID}" --arg dec "${E_DEC}" --arg flow "${E_FLOW}" --argjson sniff "${sniff}" '
      $acc + [{
        tag: $tag, port: $port, protocol: "vless",
        settings: { clients: [{ id: $id, flow: $flow }], decryption: $dec },
        streamSettings: { network: "raw", security: "none" }
      } + (if $sniff then { sniffing: $sniff } else {} end)]')"
  fi
  if [[ -n "${LISTEN_ADDR}" ]]; then
    inbounds="$(jq --arg l "${LISTEN_ADDR}" 'map(. + { listen: $l })' <<< "${inbounds}")"
  fi
  local access="none"; is_true "${ACCESS_LOG}" && access=""
  jq -n --argjson inbounds "${inbounds}" --arg access "${access}" --argjson bt "${BLOCK_BT}" --arg ds "${DOMAIN_STRATEGY}" '{
    log: { loglevel: "warning", access: $access, dnsLog: false },
    inbounds: $inbounds,
    outbounds: [
      { tag: "direct", protocol: "freedom",
        settings: { finalRules: [ { action: "block", ip: ["geoip:private"] } ] },
        streamSettings: { sockopt: { domainStrategy: $ds } } },
      { tag: "block", protocol: "blackhole" }
    ],
    routing: {
      domainStrategy: "AsIs",
      rules: ([ { ip: ["geoip:private"], outboundTag: "block" } ]
              + (if $bt == 1 then [ { protocol: ["bittorrent"], outboundTag: "block" } ] else [] end))
    }
  }' > "${out}"
}

test_config() {
  local bin="$1" cfg="$2" log
  info "正在执行 xray run -test 校验配置..."
  if ! log="$(XRAY_LOCATION_ASSET="${XRAY_SHARE}" "${bin}" run -test -config "${cfg}" 2>&1)"; then
    # 输出可能包含私钥，只显示错误行并去掉长字符串
    grep -iE 'fail|error|invalid' <<< "${log}" | sed -E 's/[A-Za-z0-9_-]{40,}/<已隐藏>/g' >&2 || true
    return 1
  fi
  if grep -q '\[Warning\]' <<< "${log}"; then
    warn "xray run -test 输出了警告："
    grep '\[Warning\]' <<< "${log}" | sed -E 's/^[0-9\/]+ [0-9:.]+ //; s/[A-Za-z0-9_-]{40,}/<已隐藏>/g' | while IFS= read -r l; do warn "  ${l}"; done
    if grep -qi 'deprecated' <<< "${log}"; then
      info "配置含已弃用字段：重新运行安装并选择保留现有密钥即可迁移到新写法"
    fi
  fi
  ok "配置校验通过"
}

write_unit() {
  install -d -m 0755 "${ROOT}/etc/systemd/system"
  cat > "${XRAY_UNIT}.tmp" <<'EOF'
# 由 xray-install-script 生成
[Unit]
Description=Xray-core Service (VLESS REALITY / VLESS Encryption)
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStartPre=/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3s
RestartPreventExitStatus=23
LimitNOFILE=1048576
TasksMax=4096

# 只授予绑定低端口所需的能力
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# 文件系统隔离：整个系统只读；xray 不需要任何可写路径（日志走 journal）
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadOnlyPaths=/usr/local/etc/xray /usr/local/share/xray
UMask=0077

# 其他加固
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RemoveIPC=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${XRAY_UNIT}.tmp"
  mv -f "${XRAY_UNIT}.tmp" "${XRAY_UNIT}"
  ok "systemd 服务已写入 ${XRAY_UNIT#"${ROOT}"}"
}

write_nft() {
  local ports=()
  [[ "${DO_REALITY}" -eq 1 ]] && ports+=("${R_PORT}")
  [[ "${DO_ENC}" -eq 1 ]] && ports+=("${E_PORT}")
  local plist
  plist="$(IFS=','; echo "${ports[*]}")"
  plist="${plist//,/, }"
  if [[ "${NFT_CONNLIMIT}" == 0 ]]; then
    if [[ -f "${NFT_UNIT}" ]]; then
      if [[ "${USE_SYSTEMD}" -eq 1 ]]; then systemctl disable --now xray-connlimit.service >/dev/null 2>&1 || true; fi
      rm -f "${NFT_UNIT}" "${NFT_FILE}"
      info "已移除旧的 nftables 连接限制"
    fi
    return 0
  fi
  cat > "${NFT_FILE}" <<EOF
#!/usr/sbin/nft -f
# 由 xray-install-script 生成：Xray 端口每源 IP 并发 TCP 连接上限 ${NFT_CONNLIMIT}
# 独立的表，不影响已有规则；重新加载前先删除自身。
table inet xray_connlimit
delete table inet xray_connlimit

table inet xray_connlimit {
	set v4 {
		type ipv4_addr
		size 65535
		flags dynamic
	}
	set v6 {
		type ipv6_addr
		size 65535
		flags dynamic
	}
	chain input {
		type filter hook input priority filter - 5; policy accept;
		tcp dport { ${plist} } ct state new add @v4 { ip saddr ct count over ${NFT_CONNLIMIT} } counter reject with tcp reset
		tcp dport { ${plist} } ct state new add @v6 { ip6 saddr ct count over ${NFT_CONNLIMIT} } counter reject with tcp reset
	}
}
EOF
  chmod 0644 "${NFT_FILE}"
  if [[ "${STAGING}" -eq 0 ]] && ! command -v nft >/dev/null 2>&1; then
    info "正在安装 nftables ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends nftables >/dev/null
  fi
  cat > "${NFT_UNIT}" <<'EOF'
# 由 xray-install-script 生成
[Unit]
Description=Per-IP connection limit for Xray ports (nftables)
After=nftables.service
Before=xray.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /usr/local/etc/xray/connlimit.nft
ExecStop=/usr/sbin/nft delete table inet xray_connlimit

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${NFT_UNIT}"
  if [[ "${STAGING}" -eq 0 ]]; then
    nft -c -f "${NFT_FILE}" || die "nftables 规则校验失败"
  fi
  ok "nftables 连接限制已写入 ${NFT_FILE#"${ROOT}"}"
}

restart_service() {
  if [[ "${USE_SYSTEMD}" -eq 0 ]] || is_true "${SKIP_START}"; then
    warn "已跳过启动服务（SKIP_START / 无 systemd / 暂存模式）"
    return 0
  fi
  info "正在启动 xray 服务..."
  systemctl daemon-reload
  if [[ -f "${NFT_UNIT}" ]]; then
    systemctl enable xray-connlimit.service >/dev/null 2>&1
    # 连接数限制是可选加固：失败时不中止（否则新配置已写入但 xray 未重启、客户端文件未更新）
    if ! systemctl restart xray-connlimit.service; then
      warn "nftables 连接限制加载失败，xray 仍会启动；排查：journalctl -u xray-connlimit（容器内通常缺少 CAP_NET_ADMIN）"
    fi
  fi
  systemctl enable xray.service >/dev/null 2>&1
  systemctl reset-failed xray.service >/dev/null 2>&1 || true
  if ! systemctl restart xray.service; then
    journalctl -u xray.service -n 20 --no-pager >&2 || true
    die "xray 服务启动失败，请检查上方日志"
  fi
  sleep 2
  if ! systemctl is-active --quiet xray.service; then
    journalctl -u xray.service -n 20 --no-pager >&2 || true
    die "xray 服务未能保持运行"
  fi
  ok "xray 服务运行中"
}

# ── 客户端信息 ─────────────────────────────────────────────────────────────
detect_address() {
  if [[ -z "${SERVER_ADDRESS}" && "${DETECT_PUBLIC_IP}" == 1 ]]; then
    SERVER_ADDRESS="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    is_ipv4 "${SERVER_ADDRESS}" || SERVER_ADDRESS="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${SERVER_ADDRESS}" ]]; then
    SERVER_ADDRESS="$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
  fi
  SERVER_ADDRESS="${SERVER_ADDRESS:-YOUR_SERVER_IP}"
  [[ "${SERVER_ADDRESS}" =~ ^[A-Za-z0-9.:_-]+$ ]] || die "SERVER_ADDRESS 只能是 IP 或域名"
}

resolve_client_fp() {
  # 优先级：CLIENT_FP 环境变量 > 已有 YAML 中的 client-fingerprint > chrome
  if [[ -z "${CLIENT_FP}" && -f "${CLIENT_YAML}" ]]; then
    CLIENT_FP="$(awk '/^    client-fingerprint: / { print $2; exit }' "${CLIENT_YAML}" | tr -d '"')"
  fi
  CLIENT_FP="${CLIENT_FP:-chrome}"
  [[ "${CLIENT_FP}" =~ ^[a-z0-9_]+$ ]] || die "CLIENT_FP 无效：${CLIENT_FP}"
}

write_client_files() {
  # 只使用客户端需要的公开参数（UUID、公钥、shortId、encryption）
  # 格式（字段集合、顺序、取值风格）与 mihomo 一键脚本输出一致；额外保留 reality-opts.support-x25519mlkem768
  local host_link="${SERVER_ADDRESS}" yaml links srv
  is_ipv6 "${SERVER_ADDRESS}" && host_link="[${SERVER_ADDRESS}]"
  srv="$(yaml_val "${SERVER_ADDRESS}")"
  resolve_client_fp
  yaml="proxies:"
  links=""
  if [[ "${DO_ENC}" -eq 1 ]]; then
    yaml+="
  - name: ${NAME_ENC}
    type: vless
    server: ${srv}
    port: ${E_PORT}
    udp: true
    uuid: ${E_UUID}"
    # 新配置总是 flow=xtls-rprx-vision；仅 1.1.0 旧配置（未 reconfigure）的 info 显示不带 flow
    [[ -z "${E_FLOW:-}" ]] || yaml+="
    flow: ${E_FLOW}"
    yaml+="
    packet-encoding: xudp
    network: tcp
    encryption: ${E_ENC}"
    links+="vless://${E_UUID}@${host_link}:${E_PORT}?encryption=${E_ENC}${E_FLOW:+&flow=${E_FLOW}}&security=none&type=tcp&headerType=none#${NAME_ENC}
"
  fi
  if [[ "${DO_REALITY}" -eq 1 ]]; then
    yaml+="
  - name: ${NAME_REALITY}
    type: vless
    server: ${srv}
    port: ${R_PORT}
    udp: true
    uuid: ${R_UUID}
    flow: xtls-rprx-vision
    packet-encoding: xudp
    network: tcp
    tls: true
    servername: ${R_SNIS[0]}
    reality-opts:
      public-key: ${R_PUB}
      short-id: $(yaml_val "${R_SID}")
      support-x25519mlkem768: true
    skip-cert-verify: false
    client-fingerprint: ${CLIENT_FP}"
    # 仅当旧版（1.1.0）REALITY 入站仍带 decryption 时（未 reconfigure 的 info 显示）输出 encryption
    [[ -z "${R_ENC:-}" ]] || yaml+="
    encryption: ${R_ENC}"
    links+="vless://${R_UUID}@${host_link}:${R_PORT}?encryption=${R_ENC:-none}&flow=xtls-rprx-vision&security=reality&sni=${R_SNIS[0]}&fp=${CLIENT_FP}&pbk=${R_PUB}&sid=${R_SID}&type=tcp&headerType=none#${NAME_REALITY}
"
  fi
  ( umask 077; printf '%s\n' "${yaml}" > "${CLIENT_YAML}"; printf '%s' "${links}" > "${LINKS_FILE}" )
  own 0600 root:root "${CLIENT_YAML}" "${LINKS_FILE}"
}

print_client_info() {
  local ports=()
  [[ "${DO_ENC}" -eq 1 ]] && ports+=("${E_PORT}")
  [[ "${DO_REALITY}" -eq 1 ]] && ports+=("${R_PORT}")
  section "客户端配置（mihomo proxies）"
  printf '\n' >&2
  cat "${CLIENT_YAML}"
  section "分享链接（vless://）"
  printf '\n' >&2
  cat "${LINKS_FILE}"
  printf '\n' >&2
  info "服务器地址：${C_BOLD}${SERVER_ADDRESS}${C_RESET}"
  info "服务端出站 domainStrategy：${DOMAIN_STRATEGY:-AsIs（未设置）}"
  [[ "${DO_ENC}" -eq 1 && -n "${ENC_MODE:-}" ]] && info "Encryption 外观：${ENC_MODE}（客户端 encryption 字段需一致）"
  info "请在防火墙/安全组放行 TCP 端口：${C_BOLD}${ports[*]}${C_RESET}"
  info "客户端 YAML：${CLIENT_YAML#"${ROOT}"}（权限 600）；链接：${LINKS_FILE#"${ROOT}"}"
  info "以上仅含客户端所需的公开参数，服务端私钥只保存在 ${XRAY_CONFIG#"${ROOT}"}（640 root:xray）"
  if [[ "${DO_REALITY}" -eq 1 ]]; then
    info "mihomo 连接 Xray >= v26.9.9 的 REALITY 必须保留 support-x25519mlkem768: true"
    if [[ "${CLIENT_FP}" != "chrome" ]]; then
      warn "client-fingerprint 为 ${CLIENT_FP}：mihomo（utls v1.8.8）中只有 chrome 发送 X25519MLKEM768，其他指纹会被 Xray REALITY 拒绝；"
      warn "  mihomo 客户端请用默认的 chrome：CLIENT_FP=chrome bash install.sh info"
    fi
  fi
  if [[ "${DO_ENC}" -eq 1 || -n "${R_ENC:-}" ]]; then
    info "VLESS Encryption 0-RTT：服务端重启后客户端缓存的 ticket 失效，首个连接可能失败，随后自动恢复"
  fi
  if [[ -n "${R_ENC:-}" || ( "${DO_ENC}" -eq 1 && ( ! "${E_DEC:-${OLD_E_DEC:-}}" =~ ${ENC_DEC_RE} || "${E_FLOW:-}" != "${VISION_FLOW}" ) ) ]]; then
    warn "当前为旧版（<1.2.0）配置，建议运行 reconfigure 升级（Encryption 改为单个 ML-KEM-768 + Vision；REALITY 不叠加 Encryption），之后客户端需要更新"
  fi
}

success_box() {
  printf '\n%s%s  ════════════════════════════════════════════════════\n' "${C_GREEN}" "${C_BOLD}" >&2
  printf '    ✔  %s\n' "$1" >&2
  printf '  ════════════════════════════════════════════════════%s\n' "${C_RESET}" >&2
}

# ── 动作 ───────────────────────────────────────────────────────────────────
do_install() {
  ensure_deps
  prompt_github_proxy
  load_existing

  KEEP=0
  if [[ -f "${XRAY_CONFIG}" ]]; then
    if [[ -n "${KEEP_KEYS}" ]]; then is_true "${KEEP_KEYS}" && KEEP=1
    elif yes_no "检测到已有配置，沿用现有 UUID 与密钥（客户端无需更新）？" 1; then KEEP=1; fi
    if [[ "${KEEP}" -eq 1 ]]; then ok "将沿用已有密钥"; else warn "将生成全新密钥，旧客户端配置将失效"; fi
  fi

  # 先收集并校验所有输入，再下载，避免输错后白白下载
  choose_mode
  R_PORT=""
  if [[ "${DO_REALITY}" -eq 1 ]]; then configure_reality; fi
  if [[ "${DO_ENC}" -eq 1 ]]; then configure_enc; fi
  configure_dns
  configure_misc

  resolve_release
  TEMP_DIR="$(mktemp -d)"
  local cur=""; cur="$(installed_version || true)"
  section "下载安装"
  if [[ "${cur}" == "${TARGET_VERSION}" ]] && ! is_true "${FORCE_DOWNLOAD}"; then
    ok "已安装 Xray v${cur}，跳过下载（FORCE_DOWNLOAD=1 可强制重新下载并校验）"
  else
    download_verify
    install_binary
  fi
  ensure_user

  section "生成密钥"
  if [[ "${DO_REALITY}" -eq 1 ]]; then reality_keys; fi
  if [[ "${DO_ENC}" -eq 1 ]]; then enc_keys; fi

  section "写入配置"
  local cand="${TEMP_DIR}/config.json"
  ( umask 077; build_config "${cand}" )
  test_config "${XRAY_BIN}" "${cand}" || die "生成的配置未通过校验，未做更改"

  install -d -m 0750 "${XRAY_ETC}"
  [[ "${STAGING}" -eq 1 ]] || chown root:"${XRAY_USER}" "${XRAY_ETC}"
  if [[ -f "${XRAY_CONFIG}" ]] && ! cmp -s "${cand}" "${XRAY_CONFIG}"; then
    local bak
    bak="${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "${XRAY_CONFIG}" "${bak}"
    chmod 0600 "${bak}"
    info "已备份旧配置 → ${bak#"${ROOT}"}"
  fi
  install -m 0640 "${cand}" "${XRAY_CONFIG}.new"
  [[ "${STAGING}" -eq 1 ]] || chown root:"${XRAY_USER}" "${XRAY_CONFIG}.new"
  mv -f "${XRAY_CONFIG}.new" "${XRAY_CONFIG}"
  ok "配置已写入 ${XRAY_CONFIG#"${ROOT}"}（640 root:${XRAY_USER}）"
  write_unit
  write_nft

  section "启动服务"
  restart_service

  if [[ -z "${SERVER_ADDRESS}" && -f "${CLIENT_YAML}" ]]; then
    SERVER_ADDRESS="$(awk '/^    server: / { print $2; exit }' "${CLIENT_YAML}" | tr -d '"')"
    [[ "${SERVER_ADDRESS}" != "YOUR_SERVER_IP" ]] || SERVER_ADDRESS=""
  fi
  detect_address
  write_client_files
  success_box "安装完成：Xray-core v${TARGET_VERSION}"
  print_client_info
}

do_update() {
  [[ -x "${XRAY_BIN}" ]] || die "未检测到已安装的 Xray，请先安装"
  ensure_deps
  prompt_github_proxy
  resolve_release
  local cur; cur="$(installed_version || true)"
  section "更新 Xray-core"
  if [[ "${cur}" == "${TARGET_VERSION}" ]] && ! is_true "${FORCE_DOWNLOAD}"; then
    ok "当前已是 v${cur}，无需更新"
    return 0
  fi
  info "升级路径：v${cur:-未知} → ${C_BOLD}v${TARGET_VERSION}${C_RESET}"
  TEMP_DIR="$(mktemp -d)"
  download_verify
  if [[ -f "${XRAY_CONFIG}" ]]; then
    XRAY_LOCATION_ASSET="${TEMP_DIR}/pkg" "${TEMP_DIR}/pkg/xray" run -test -config "${XRAY_CONFIG}" >/dev/null 2>&1 \
      || die "新版本无法通过现有配置校验，已中止（旧版本保持不变）"
    ok "新版本已通过现有配置校验"
  fi
  install_binary
  restart_service
  success_box "更新完成：Xray-core v${TARGET_VERSION}"
  info "现有配置已保留：${XRAY_CONFIG#"${ROOT}"}"
}

load_for_info() {
  [[ -f "${XRAY_CONFIG}" ]] || die "未找到 ${XRAY_CONFIG#"${ROOT}"}"
  load_existing
  DO_REALITY=0; DO_ENC=0
  if [[ -n "${OLD_R_PRIV}" ]]; then
    DO_REALITY=1; R_PORT="${OLD_R_PORT}"; R_UUID="${OLD_R_UUID}"; R_SID="${OLD_R_SID}"
    R_PUB="$(reality_pubkey "${OLD_R_PRIV}")"
    R_ENC=""
    if [[ -n "${OLD_R_DEC}" && "${OLD_R_DEC}" != "none" ]]; then
      R_ENC="$(enc_client_from_dec "${OLD_R_DEC}")" || die "无法推导 REALITY encryption"
    fi
    IFS=',' read -r -a R_SNIS <<< "${OLD_R_SNI}"
  fi
  DOMAIN_STRATEGY="${OLD_DS}"
  if [[ -n "${OLD_E_DEC}" ]]; then
    DO_ENC=1; E_PORT="${OLD_E_PORT}"; E_UUID="${OLD_E_UUID}"; E_FLOW="${OLD_E_FLOW}"; ENC_MODE="${OLD_E_MODE}"
    E_ENC="$(enc_client_from_dec "${OLD_E_DEC}")" || die "无法推导 encryption"
  fi
}

do_info() {
  if [[ -z "${SERVER_ADDRESS}" && -f "${CLIENT_YAML}" ]]; then
    SERVER_ADDRESS="$(awk '/^    server: / { print $2; exit }' "${CLIENT_YAML}" | tr -d '"')"
  fi
  load_for_info
  detect_address
  write_client_files
  print_client_info
}

do_uninstall() {
  section "卸载 Xray-core"
  if [[ "${INTERACTIVE}" -eq 1 ]]; then
    yes_no "确认卸载 Xray-core？" 0 || { info "已取消"; return 0; }
    [[ "${PURGE}" == 1 ]] || { yes_no "同时删除配置目录 ${XRAY_ETC#"${ROOT}"} 与 xray 用户？" 0 && PURGE=1; } || true
  fi
  if [[ "${USE_SYSTEMD}" -eq 1 ]]; then
    systemctl disable --now xray.service >/dev/null 2>&1 || true
    systemctl disable --now xray-connlimit.service >/dev/null 2>&1 || true
  fi
  rm -f "${XRAY_UNIT}" "${NFT_UNIT}" "${XRAY_BIN}"
  rm -rf "${XRAY_SHARE}"
  if [[ "${USE_SYSTEMD}" -eq 1 ]]; then
    systemctl daemon-reload || true
    # 清掉已删除单元残留的 failed 状态（systemctl --failed 中不再显示）
    systemctl reset-failed xray.service xray-connlimit.service >/dev/null 2>&1 || true
  fi
  # 单元未运行时 ExecStop 不会执行，这里再确保删除 nft 表
  if [[ "${STAGING}" -eq 0 ]] && command -v nft >/dev/null 2>&1 && nft list table inet xray_connlimit >/dev/null 2>&1; then
    nft delete table inet xray_connlimit 2>/dev/null || true
  fi
  ok "已删除二进制、数据文件与 systemd 服务"
  if [[ "${PURGE}" == 1 ]]; then
    rm -rf "${XRAY_ETC}"
    if [[ "${STAGING}" -eq 0 ]] && id -u "${XRAY_USER}" >/dev/null 2>&1; then
      userdel "${XRAY_USER}" 2>/dev/null || true
    fi
    ok "已删除配置目录与 ${XRAY_USER} 用户"
  else
    info "配置已保留：${XRAY_ETC#"${ROOT}"}（PURGE=1 或 --purge 可一并删除）"
  fi
}

main_menu() {
  section "检测到已安装 Xray-core v$(installed_version || echo 未知)"
  menu_item "1" "更新 Xray-core" "保留配置，校验 SHA256"
  menu_item "2" "重新配置" "可沿用现有密钥"
  menu_item "3" "查看客户端信息"
  menu_item "4" "卸载"
  menu_item "0" "退出"
  printf '\n' >&2
  while true; do
    ask "请输入选项 [0-4]" ""
    case "${REPLY}" in
      1) XRAY_ACTION=update; return ;;
      2) XRAY_ACTION=reconfigure; return ;;
      3) XRAY_ACTION=info; return ;;
      4) XRAY_ACTION=uninstall; return ;;
      0) info "已退出"; exit 0 ;;
      *) warn "选项无效，请重新输入" ;;
    esac
  done
}

main() {
  while (($# > 0)); do
    case "$1" in
      install|update|reconfigure|info|uninstall) XRAY_ACTION="$1" ;;
      --purge) PURGE=1 ;;
      -y|--yes) NONINTERACTIVE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "未知参数：$1" ;;
    esac
    shift
  done
  if is_true "${NONINTERACTIVE}" || [[ ! -t 0 ]]; then INTERACTIVE=0; fi
  is_true "${PURGE}" && PURGE=1 || PURGE=0

  banner
  info "脚本版本 ${SCRIPT_VERSION}$([[ ${INTERACTIVE} -eq 0 ]] && echo '（非交互模式）')"
  preflight

  if [[ -z "${XRAY_ACTION}" ]]; then
    if [[ -x "${XRAY_BIN}" && "${INTERACTIVE}" -eq 1 ]]; then main_menu; else XRAY_ACTION=install; fi
  fi
  case "${XRAY_ACTION}" in
    install|reconfigure) do_install ;;
    update) do_update ;;
    info) do_info ;;
    uninstall) do_uninstall ;;
    *) die "未知操作：${XRAY_ACTION}" ;;
  esac
  printf '\n' >&2
}

main "$@"
