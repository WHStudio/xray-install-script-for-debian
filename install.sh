#!/usr/bin/env bash
# Xray-core 服务端一键部署脚本（Debian 13）
# VLESS + REALITY + Vision  /  VLESS Encryption (mlkem768x25519plus.native) + Vision
#
# 交互界面与流程参考 WHStudio/mihomo-install-script-for-debian（mihomo 版），
# 本脚本为针对 Xray-core 的独立重写实现。详见 README.zh_CN.md。

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"

# ── 可通过环境变量覆盖的参数 ────────────────────────────────────────────────
XRAY_ACTION="${XRAY_ACTION:-}"            # install | update | reconfigure | info | uninstall
NONINTERACTIVE="${NONINTERACTIVE:-0}"     # 1 = 全部从环境变量读取，不提问
XRAY_VERSION="${XRAY_VERSION:-}"          # 固定版本，如 26.10.21；留空 = 最新稳定版
GITHUB_PROXY="${GITHUB_PROXY:-}"          # 下载前缀代理，如 https://ghfast.top/
DEPLOY_MODE="${DEPLOY_MODE:-}"            # both | reality | enc
REALITY_PORT="${REALITY_PORT:-}"
ENC_PORT="${ENC_PORT:-}"
REALITY_TARGET="${REALITY_TARGET:-}"      # host[:port]，port 默认 443
REALITY_SNI="${REALITY_SNI:-}"            # 逗号分隔的 serverNames，默认 = target 主机名
CHECK_TARGET="${CHECK_TARGET:-}"          # 1/0：是否用 openssl 检查 target 支持 TLS1.3 + h2
SERVER_ADDRESS="${SERVER_ADDRESS:-}"      # 客户端连接用的地址（IP 或域名）
DETECT_PUBLIC_IP="${DETECT_PUBLIC_IP:-1}" # 1 = SERVER_ADDRESS 为空时请求 api.ipify.org 探测
LISTEN_ADDR="${LISTEN_ADDR:-}"            # 留空 = 监听所有地址
BLOCK_BT="${BLOCK_BT:-}"                  # 1/0：屏蔽 BitTorrent（默认 1）
ACCESS_LOG="${ACCESS_LOG:-0}"             # 1 = 访问日志写入 journal（默认关闭，保护隐私）
NFT_CONNLIMIT="${NFT_CONNLIMIT:-}"        # 每 IP 并发连接上限；0/空 = 不启用
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

random_port() {
  local p
  while true; do
    p=$((20000 + RANDOM % 40000))
    port_in_use "${p}" || { echo "${p}"; return; }
  done
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
  curl -fsSL --retry 2 --connect-timeout 15 -o "${dgst}" "$(proxy_url "${base}.dgst")" \
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
  OLD_E_PORT=""; OLD_E_UUID=""; OLD_E_DEC=""; OLD_BT=""; OLD_LISTEN=""
  [[ -f "${XRAY_CONFIG}" ]] || return 0
  local r=".inbounds[]? | select(.tag==\"${TAG_REALITY}\")" e=".inbounds[]? | select(.tag==\"${TAG_ENC}\")"
  OLD_R_PORT="$(jq_cfg "${r} | .port")"
  OLD_R_UUID="$(jq_cfg "${r} | .settings.clients[0].id")"
  OLD_R_PRIV="$(jq_cfg "${r} | .streamSettings.realitySettings.privateKey")"
  OLD_R_SID="$(jq_cfg "${r} | .streamSettings.realitySettings.shortIds[0]")"
  OLD_R_TARGET="$(jq_cfg "${r} | .streamSettings.realitySettings.target")"
  OLD_R_SNI="$(jq_cfg "${r} | .streamSettings.realitySettings.serverNames | join(\",\")")"
  OLD_E_PORT="$(jq_cfg "${e} | .port")"
  OLD_E_UUID="$(jq_cfg "${e} | .settings.clients[0].id")"
  OLD_E_DEC="$(jq_cfg "${e} | .settings.decryption")"
  OLD_LISTEN="$(jq_cfg '[.inbounds[]? | .listen // empty][0] // empty')"
  if [[ -n "$(jq_cfg '.routing.rules[]? | select(.protocol? | index("bittorrent")) | .outboundTag')" ]]; then OLD_BT=1; else OLD_BT=0; fi
}

reality_pubkey() {
  # 由私钥推导公钥（兼容 "PublicKey:" 与 "Password (PublicKey):" 两种输出）
  "${XRAY_BIN}" x25519 -i "$1" | awk -F': *' '$1 ~ /PublicKey/ { print $2; exit }' | tr -d '\r'
}

enc_client_from_dec() {
  # decryption = mlkem768x25519plus.native.600s.<seed>  ->  encryption = mlkem768x25519plus.native.0rtt.<client>
  local dec="$1" seed client
  seed="${dec##*.}"
  client="$("${XRAY_BIN}" mlkem768 -i "${seed}" | awk -F': *' '$1 == "Client" { print $2; exit }' | tr -d '\r')"
  [[ "${client}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  printf 'mlkem768x25519plus.native.0rtt.%s\n' "${client}"
}

# ── 配置问答 ───────────────────────────────────────────────────────────────
choose_mode() {
  if [[ -z "${DEPLOY_MODE}" && "${INTERACTIVE}" -eq 1 ]]; then
    section "部署模式"
    menu_item "1" "两者都部署" "[默认] REALITY 直连 + Encryption 备用/中转"
    menu_item "2" "仅 VLESS + REALITY + Vision"
    menu_item "3" "仅 VLESS Encryption (ML-KEM-768) + Vision"
    printf '\n' >&2
    while true; do
      ask "请输入选项 [1-3]" "1"
      case "${REPLY}" in
        1) DEPLOY_MODE=both; break ;;
        2) DEPLOY_MODE=reality; break ;;
        3) DEPLOY_MODE=enc; break ;;
        *) warn "选项无效，请重新输入" ;;
      esac
    done
  fi
  DEPLOY_MODE="${DEPLOY_MODE:-both}"
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

  info "target 应为境外、支持 TLS1.3 + h2、非 CDN、与本机同地区的网站（不要用自己的域名，也不要用 Apple/Cloudflare 等大站）"
  tgt="${REALITY_TARGET}"
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
    R_SID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    ok "已生成新的 UUID、x25519 密钥对与 shortId"
  fi
  R_PUB="$(reality_pubkey "${R_PRIV}")"
  [[ "${R_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "UUID 无效"
  [[ "${R_PRIV}" =~ ^[A-Za-z0-9_-]{43}$ && "${R_PUB}" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "REALITY 密钥解析失败"
  [[ "${R_SID}" =~ ^[0-9a-f]{0,16}$ ]] || die "shortId 无效"
}

configure_enc() {
  section "VLESS Encryption (mlkem768x25519plus.native) + Vision"
  local def_port
  if [[ "${KEEP}" -eq 1 && -n "${OLD_E_PORT}" ]]; then def_port="${OLD_E_PORT}"; else def_port="$(random_port)"; fi
  [[ "${def_port}" != "${R_PORT:-}" ]] || def_port="$(random_port)"
  pick_port "Encryption" "${def_port}" "${R_PORT:-}" "${ENC_PORT}"
  E_PORT="${SELECTED_PORT}"
}

enc_keys() {
  if [[ "${KEEP}" -eq 1 && -n "${OLD_E_DEC}" && -n "${OLD_E_UUID}" ]]; then
    E_UUID="${OLD_E_UUID}"; E_DEC="${OLD_E_DEC}"
    E_ENC="$(enc_client_from_dec "${E_DEC}")" || die "无法从现有 decryption 推导客户端 encryption"
    info "沿用已有 Encryption UUID / 密钥"
  else
    local out
    E_UUID="$("${XRAY_BIN}" uuid | tr -d '\r\n')"
    [[ "${E_UUID}" != "${R_UUID:-}" ]] || E_UUID="$("${XRAY_BIN}" uuid | tr -d '\r\n')"
    out="$("${XRAY_BIN}" vlessenc | tr -d '\r')"
    # 取 "Authentication: ML-KEM-768, Post-Quantum" 段
    E_DEC="$(awk '/ML-KEM-768/ { f=1 } f && /"decryption"/ { gsub(/"/, "", $2); print $2; exit }' <<< "${out}")"
    E_ENC="$(awk '/ML-KEM-768/ { f=1 } f && /"encryption"/ { gsub(/"/, "", $2); print $2; exit }' <<< "${out}")"
    ok "已通过 xray vlessenc 生成 ML-KEM-768 密钥"
  fi
  [[ "${E_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "UUID 无效"
  [[ "${E_DEC}" =~ ^mlkem768x25519plus\.native\.[0-9]+(-[0-9]+)?s\.[A-Za-z0-9_-]+$ ]] || die "decryption 解析失败"
  [[ "${E_ENC}" =~ ^mlkem768x25519plus\.native\.0rtt\.[A-Za-z0-9_-]+$ ]] || die "encryption 解析失败"
}

configure_misc() {
  section "安全与其他选项"
  if [[ -z "${BLOCK_BT}" ]]; then
    local d=1; [[ "${KEEP}" -eq 1 && -n "${OLD_BT}" ]] && d="${OLD_BT}"
    if yes_no "屏蔽 BitTorrent 流量？（启用 routeOnly 嗅探）" "${d}"; then BLOCK_BT=1; else BLOCK_BT=0; fi
  fi
  is_true "${BLOCK_BT}" && BLOCK_BT=1 || BLOCK_BT=0
  ok "内网/回环目标屏蔽：始终启用（routing geoip:private → blackhole + freedom finalRules）"
  ok "BitTorrent 屏蔽：$([[ ${BLOCK_BT} -eq 1 ]] && echo 启用 || echo 关闭)"

  if [[ -z "${NFT_CONNLIMIT}" ]]; then
    if [[ "${INTERACTIVE}" -eq 1 && "${STAGING}" -eq 0 ]] && yes_no "启用 nftables 每 IP 并发连接数限制？" 0; then
      while true; do
        ask "每个源 IP 最大并发连接数" "64"
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
    inbounds="$(jq -n --argjson acc "${inbounds}" --arg tag "${TAG_ENC}" --argjson port "${E_PORT}" \
      --arg id "${E_UUID}" --arg dec "${E_DEC}" --argjson sniff "${sniff}" '
      $acc + [{
        tag: $tag, port: $port, protocol: "vless",
        settings: { clients: [{ id: $id, flow: "xtls-rprx-vision" }], decryption: $dec },
        streamSettings: { network: "raw", security: "none" }
      } + (if $sniff then { sniffing: $sniff } else {} end)]')"
  fi
  if [[ -n "${LISTEN_ADDR}" ]]; then
    inbounds="$(jq --arg l "${LISTEN_ADDR}" 'map(. + { listen: $l })' <<< "${inbounds}")"
  fi
  local access="none"; is_true "${ACCESS_LOG}" && access=""
  jq -n --argjson inbounds "${inbounds}" --arg access "${access}" --argjson bt "${BLOCK_BT}" '{
    log: { loglevel: "warning", access: $access, dnsLog: false },
    inbounds: $inbounds,
    outbounds: [
      { tag: "direct", protocol: "freedom",
        settings: { finalRules: [ { action: "block", ip: ["geoip:private"] } ] } },
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
    systemctl restart xray-connlimit.service || die "nftables 连接限制加载失败"
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

write_client_files() {
  # 只使用客户端需要的公开参数（UUID、公钥、shortId、encryption）
  local host_link="${SERVER_ADDRESS}" yaml links name_r="xray-reality" name_e="xray-vless-enc"
  is_ipv6 "${SERVER_ADDRESS}" && host_link="[${SERVER_ADDRESS}]"
  yaml="# mihomo 客户端 proxies（由 xray-install-script 生成，$(date '+%F %T %Z')）
# 注意：连接 Xray >= v26.9.9 的 REALITY 必须开启 support-x25519mlkem768
proxies:"
  links=""
  if [[ "${DO_REALITY}" -eq 1 ]]; then
    yaml+="
  - name: ${name_r}
    type: vless
    server: \"${SERVER_ADDRESS}\"
    port: ${R_PORT}
    uuid: ${R_UUID}
    network: tcp
    udp: true
    packet-encoding: xudp
    flow: xtls-rprx-vision
    encryption: \"\"
    tls: true
    servername: ${R_SNIS[0]}
    client-fingerprint: chrome
    skip-cert-verify: false
    reality-opts:
      public-key: ${R_PUB}
      short-id: \"${R_SID}\"
      support-x25519mlkem768: true"
    links+="vless://${R_UUID}@${host_link}:${R_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${R_SNIS[0]}&fp=chrome&pbk=${R_PUB}&sid=${R_SID}&type=tcp&headerType=none#${name_r}
"
  fi
  if [[ "${DO_ENC}" -eq 1 ]]; then
    yaml+="
  - name: ${name_e}
    type: vless
    server: \"${SERVER_ADDRESS}\"
    port: ${E_PORT}
    uuid: ${E_UUID}
    network: tcp
    udp: true
    packet-encoding: xudp
    flow: xtls-rprx-vision
    tls: false
    encryption: \"${E_ENC}\""
    links+="vless://${E_UUID}@${host_link}:${E_PORT}?encryption=${E_ENC}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none#${name_e}
"
  fi
  ( umask 077; printf '%s\n' "${yaml}" > "${CLIENT_YAML}"; printf '%s' "${links}" > "${LINKS_FILE}" )
  own 0600 root:root "${CLIENT_YAML}" "${LINKS_FILE}"
}

print_client_info() {
  local ports=()
  [[ "${DO_REALITY}" -eq 1 ]] && ports+=("${R_PORT}")
  [[ "${DO_ENC}" -eq 1 ]] && ports+=("${E_PORT}")
  section "客户端配置（mihomo proxies）"
  printf '\n' >&2
  cat "${CLIENT_YAML}"
  section "分享链接（vless://）"
  printf '\n' >&2
  cat "${LINKS_FILE}"
  printf '\n' >&2
  info "服务器地址：${C_BOLD}${SERVER_ADDRESS}${C_RESET}"
  info "请在防火墙/安全组放行 TCP 端口：${C_BOLD}${ports[*]}${C_RESET}"
  info "客户端 YAML：${CLIENT_YAML#"${ROOT}"}（权限 600）；链接：${LINKS_FILE#"${ROOT}"}"
  info "以上仅含客户端所需的公开参数，服务端私钥只保存在 ${XRAY_CONFIG#"${ROOT}"}（640 root:xray）"
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
    IFS=',' read -r -a R_SNIS <<< "${OLD_R_SNI}"
  fi
  if [[ -n "${OLD_E_DEC}" ]]; then
    DO_ENC=1; E_PORT="${OLD_E_PORT}"; E_UUID="${OLD_E_UUID}"
    E_ENC="$(enc_client_from_dec "${OLD_E_DEC}")" || die "无法推导 encryption"
  fi
}

do_info() {
  if [[ -z "${SERVER_ADDRESS}" && -f "${CLIENT_YAML}" ]]; then
    SERVER_ADDRESS="$(awk -F'"' '/^    server: /{ print $2; exit }' "${CLIENT_YAML}")"
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
  [[ "${USE_SYSTEMD}" -eq 0 ]] || systemctl daemon-reload || true
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
