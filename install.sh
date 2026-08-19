#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# V2bX/Xray host-side outbound anti-abuse baseline.
# Supported target: Debian/Ubuntu with a host-run V2bX/Xray process.
# This script manages only its own V2BX_ABUSE_OUT chains and tagged OUTPUT jump.

readonly ABUSE_CHAIN="V2BX_ABUSE_OUT"
readonly ABUSE_TAG="v2bx-abuse"
readonly ABUSE_STATE_DIR="/var/lib/v2bx-anti-abuse"
readonly ABUSE_BACKUP_DIR="/var/backups/v2bx-anti-abuse"
readonly ABUSE_BACKUP_LIMIT=20

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly COLOR_GREEN=$'\033[32m'
  readonly COLOR_YELLOW=$'\033[33m'
  readonly COLOR_RED=$'\033[31m'
  readonly COLOR_MUTED=$'\033[2m'
  readonly COLOR_RESET=$'\033[0m'
else
  readonly COLOR_GREEN=""
  readonly COLOR_YELLOW=""
  readonly COLOR_RED=""
  readonly COLOR_MUTED=""
  readonly COLOR_RESET=""
fi

log() {
  printf '  %b-%b %s\n' "${COLOR_MUTED}" "${COLOR_RESET}" "$*"
}

warn() {
  printf '  %b!%b %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"
}

success() {
  printf '%b完成%b  %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

die() {
  printf '%b错误%b  %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
  exit 1
}

if [[ ${EUID} -ne 0 ]]; then
  die "请使用 root 运行：sudo bash $0"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  die "检测到 UFW 正在管理防火墙。请先把规则合并到 UFW，不要叠加本脚本。"
fi

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
  die "检测到 firewalld 正在管理防火墙。请先把规则合并到 firewalld，不要叠加本脚本。"
fi

install_dependencies() {
  if command -v iptables >/dev/null 2>&1 \
    && command -v ip6tables >/dev/null 2>&1 \
    && command -v netfilter-persistent >/dev/null 2>&1; then
    return
  fi

  command -v apt-get >/dev/null 2>&1 \
    || die "缺少 iptables/netfilter-persistent，且系统不是 apt 系列；未自动修改防火墙。"

  log "安装 iptables 持久化组件"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y iptables iptables-persistent netfilter-persistent
}

install_dependencies

command -v iptables-save >/dev/null 2>&1 || die "找不到 iptables-save"
command -v iptables-restore >/dev/null 2>&1 || die "找不到 iptables-restore"

mkdir -p "${ABUSE_STATE_DIR}" "${ABUSE_BACKUP_DIR}"

if iptables -nL "${ABUSE_CHAIN}" >/dev/null 2>&1 \
  && [[ ! -f "${ABUSE_STATE_DIR}/installed" ]]; then
  die "已存在同名链 ${ABUSE_CHAIN}，但不是本脚本登记的规则；为避免覆盖，已停止。"
fi

ABUSE_IPV6_ENABLED=0
if ip6tables -S OUTPUT >/dev/null 2>&1; then
  ABUSE_IPV6_ENABLED=1
fi

if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]] \
  && ip6tables -nL "${ABUSE_CHAIN}" >/dev/null 2>&1 \
  && [[ ! -f "${ABUSE_STATE_DIR}/installed" ]]; then
  die "IPv6 已存在同名链 ${ABUSE_CHAIN}，但不是本脚本登记的规则；为避免覆盖，已停止。"
fi

ABUSE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ABUSE_V4_BACKUP="${ABUSE_BACKUP_DIR}/pre-apply-${ABUSE_STAMP}.v4"
ABUSE_V6_BACKUP="${ABUSE_BACKUP_DIR}/pre-apply-${ABUSE_STAMP}.v6"

iptables-save >"${ABUSE_V4_BACKUP}"
if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  ip6tables-save >"${ABUSE_V6_BACKUP}"
fi

rollback_failed_apply() {
  local exit_code=$?
  trap - ERR INT TERM
  log "应用失败，恢复本次操作前的防火墙规则"
  iptables-restore <"${ABUSE_V4_BACKUP}" || true
  if [[ ${ABUSE_IPV6_ENABLED} -eq 1 && -s "${ABUSE_V6_BACKUP}" ]]; then
    ip6tables-restore <"${ABUSE_V6_BACKUP}" || true
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
  exit "${exit_code}"
}
trap rollback_failed_apply ERR INT TERM

prune_backups() {
  prune_backup_family v4
  prune_backup_family v6
}

prune_backup_family() {
  local family=$1
  local backup_files=()

  mapfile -t backup_files < <(
    find "${ABUSE_BACKUP_DIR}" -maxdepth 1 -type f \
      -name "pre-*.${family}" \
      -printf '%T@ %p\n' \
      | sort -nr \
      | cut -d ' ' -f 2-
  )

  if (( ${#backup_files[@]} > ABUSE_BACKUP_LIMIT )); then
    rm -f -- "${backup_files[@]:ABUSE_BACKUP_LIMIT}"
  fi
}

reset_managed_chain() {
  local firewall_cmd=$1

  if "${firewall_cmd}" -nL "${ABUSE_CHAIN}" >/dev/null 2>&1; then
    "${firewall_cmd}" -F "${ABUSE_CHAIN}"
  else
    "${firewall_cmd}" -N "${ABUSE_CHAIN}"
  fi

  while "${firewall_cmd}" -C OUTPUT \
    -m comment --comment "${ABUSE_TAG}:jump" \
    -j "${ABUSE_CHAIN}" >/dev/null 2>&1; do
    "${firewall_cmd}" -D OUTPUT \
      -m comment --comment "${ABUSE_TAG}:jump" \
      -j "${ABUSE_CHAIN}"
  done

  while "${firewall_cmd}" -C OUTPUT \
    -o lo \
    -m comment --comment "${ABUSE_TAG}:loopback" \
    -j ACCEPT >/dev/null 2>&1; do
    "${firewall_cmd}" -D OUTPUT \
      -o lo \
      -m comment --comment "${ABUSE_TAG}:loopback" \
      -j ACCEPT
  done

  # 清理旧版本留在 OUTPUT 顶层的 loopback ACCEPT，仅保留受管链跳转。
  # jump 固定放在第一条，链内第一条规则负责放行 lo。
  "${firewall_cmd}" -I OUTPUT 1 \
    -m comment --comment "${ABUSE_TAG}:jump" \
    -j "${ABUSE_CHAIN}"
}

add_loopback_exception() {
  local firewall_cmd=$1

  "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
    -o lo \
    -m comment --comment "${ABUSE_TAG}:loopback" \
    -j RETURN
}

add_operator_allowlist() {
  local firewall_cmd=$1
  local address_family=$2
  local allowlist=""

  if [[ "${address_family}" == "4" ]]; then
    allowlist="${V2BX_ALLOW_V4_CIDRS:-}"
  else
    allowlist="${V2BX_ALLOW_V6_CIDRS:-}"
  fi

  local allow_cidr
  for allow_cidr in ${allowlist}; do
    "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
      -d "${allow_cidr}" \
      -m comment --comment "${ABUSE_TAG}:operator-allow" \
      -j RETURN
  done
}

add_dns_exceptions() {
  local firewall_cmd=$1
  local address_family=$2
  local dns_server
  local normalized_dns

  while read -r dns_server; do
    [[ -n "${dns_server}" ]] || continue
    normalized_dns="${dns_server%\%*}"

    if [[ "${address_family}" == "4" && "${normalized_dns}" == *:* ]]; then
      continue
    fi
    if [[ "${address_family}" == "6" && "${normalized_dns}" != *:* ]]; then
      continue
    fi

    "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
      -p udp -d "${normalized_dns}" --dport 53 \
      -m comment --comment "${ABUSE_TAG}:system-dns" \
      -j RETURN
    "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
      -p tcp -d "${normalized_dns}" --dport 53 \
      -m comment --comment "${ABUSE_TAG}:system-dns" \
      -j RETURN
  done < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null || true)
}

add_time_sync_exceptions() {
  local firewall_cmd=$1
  local account
  local account_uid
  declare -A seen_uids=()

  # 只允许常见的非 root 时间同步服务访问 UDP/123。
  # V2bX 通常以 root 运行，因此代理用户仍会被后面的 UDP/123 规则拦截。
  if ! "${firewall_cmd}" -m owner -h >/dev/null 2>&1; then
    warn "${firewall_cmd} 不支持 owner 模块，系统 NTP 不做进程例外"
    return
  fi

  for account in systemd-timesync _chrony chrony ntp ntpsec; do
    if ! getent passwd "${account}" >/dev/null 2>&1; then
      continue
    fi
    account_uid="$(id -u "${account}")"
    if [[ -n "${seen_uids[${account_uid}]:-}" ]]; then
      continue
    fi
    seen_uids["${account_uid}"]=1

    "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
      -p udp --dport 123 \
      -m owner --uid-owner "${account_uid}" \
      -m comment --comment "${ABUSE_TAG}:system-ntp" \
      -j RETURN
  done
}

add_port_blocks() {
  local firewall_cmd=$1

  "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
    -p tcp -m multiport --dports 25,465,587 \
    -m comment --comment "${ABUSE_TAG}:smtp" \
    -j REJECT

  "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
    -p tcp -m multiport --dports 22,23,135,139,445,3389,5900,5985,5986 \
    -m comment --comment "${ABUSE_TAG}:remote-admin" \
    -j REJECT

  "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
    -p udp -m multiport --dports 19,111,123,137,138,161,389,1900,3389,3702,5353,11211 \
    -m comment --comment "${ABUSE_TAG}:udp-reflection" \
    -j REJECT
}

add_bittorrent_blocks() {
  local firewall_cmd=$1

  "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
    -p tcp \
    -m multiport --dports 6881:6999,2710,6969,51413 \
    -m comment --comment "${ABUSE_TAG}:bt-common-tcp" \
    -j REJECT

  "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
    -p udp \
    -m multiport --dports 6881:6999,2710,6969,51413 \
    -m comment --comment "${ABUSE_TAG}:bt-common-udp" \
    -j REJECT

  if "${firewall_cmd}" -m string -h >/dev/null 2>&1; then
    "${firewall_cmd}" -A "${ABUSE_CHAIN}" \
      -p tcp \
      -m string \
      --algo bm \
      --hex-string '|13426974546f7272656e742070726f746f636f6c|' \
      --from 0 \
      --to 256 \
      -m comment --comment "${ABUSE_TAG}:bt-handshake" \
      -j REJECT
  else
    warn "${firewall_cmd} 不支持 string 模块，跳过 BT 握手检测"
  fi
}

add_ipv4_destination_blocks() {
  local blocked_cidr
  local blocked_v4_cidrs=(
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.0.2.0/24"
    "192.88.99.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/3"
  )

  for blocked_cidr in "${blocked_v4_cidrs[@]}"; do
    iptables -A "${ABUSE_CHAIN}" \
      -d "${blocked_cidr}" \
      -m comment --comment "${ABUSE_TAG}:special-v4" \
      -j REJECT
  done
}

add_ipv6_destination_blocks() {
  local blocked_cidr
  local blocked_v6_cidrs=(
    "::/96"
    "::ffff:0:0/96"
    "100::/64"
    "2001:2::/48"
    "2001:10::/28"
    "2001:20::/28"
    "2001:db8::/32"
    "3fff::/20"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
  )

  # Xray/V2bX 不转发裸 ICMPv6；放行它可保留邻居发现、路由发现和 PMTU。
  ip6tables -A "${ABUSE_CHAIN}" \
    -p ipv6-icmp \
    -m comment --comment "${ABUSE_TAG}:ipv6-control" \
    -j RETURN

  for blocked_cidr in "${blocked_v6_cidrs[@]}"; do
    ip6tables -A "${ABUSE_CHAIN}" \
      -d "${blocked_cidr}" \
      -m comment --comment "${ABUSE_TAG}:special-v6" \
      -j REJECT
  done
}

log "建立 IPv4 受管链"
reset_managed_chain iptables
add_loopback_exception iptables
add_operator_allowlist iptables 4
add_dns_exceptions iptables 4
add_time_sync_exceptions iptables
add_port_blocks iptables
if [[ "${V2BX_BLOCK_BT:-0}" == "1" ]]; then
  add_bittorrent_blocks iptables
fi
add_ipv4_destination_blocks
iptables -A "${ABUSE_CHAIN}" \
  -m comment --comment "${ABUSE_TAG}:end" \
  -j RETURN

if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  log "建立 IPv6 受管链"
  reset_managed_chain ip6tables
  add_loopback_exception ip6tables
  add_operator_allowlist ip6tables 6
  add_dns_exceptions ip6tables 6
  add_time_sync_exceptions ip6tables
  add_port_blocks ip6tables
  if [[ "${V2BX_BLOCK_BT:-0}" == "1" ]]; then
    add_bittorrent_blocks ip6tables
  fi
  add_ipv6_destination_blocks
  ip6tables -A "${ABUSE_CHAIN}" \
    -m comment --comment "${ABUSE_TAG}:end" \
    -j RETURN
else
  log "IPv6 在本机不可用，已跳过 IPv6 规则"
fi

iptables -C OUTPUT \
  -m comment --comment "${ABUSE_TAG}:jump" \
  -j "${ABUSE_CHAIN}"
if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  ip6tables -C OUTPUT \
    -m comment --comment "${ABUSE_TAG}:jump" \
    -j "${ABUSE_CHAIN}"
fi

log "保存持久化规则"
netfilter-persistent save
systemctl enable netfilter-persistent >/dev/null 2>&1 || true

touch "${ABUSE_STATE_DIR}/installed"
printf '%s\n' "${ABUSE_STAMP}" >"${ABUSE_STATE_DIR}/last-apply"

trap - ERR INT TERM

if ! prune_backups; then
  warn "旧备份清理失败，请检查 ${ABUSE_BACKUP_DIR}"
fi

success "出站保护已启用"
log "未修改 INPUT/FORWARD，也未重启 V2bX"
log "IPv4 备份：${ABUSE_V4_BACKUP}"
if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  log "IPv6 备份：${ABUSE_V6_BACKUP}"
fi
if [[ "${V2BX_BLOCK_BT:-0}" == "1" ]]; then
  log "BitTorrent 可选规则：已启用"
fi

if [[ "${V2BX_VERBOSE:-0}" == "1" ]]; then
  printf '\nIPv4 受管规则\n--------------\n'
  iptables -L "${ABUSE_CHAIN}" -n -v --line-numbers
  if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
    printf '\nIPv6 受管规则\n--------------\n'
    ip6tables -L "${ABUSE_CHAIN}" -n -v --line-numbers
  fi
else
  log "运行 v2bx-abuse status 查看状态"
  log "运行 v2bx-abuse counters 查看规则明细"
fi
