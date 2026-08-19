#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Surgical rollback for install.sh.
# It removes only the tagged OUTPUT hooks and V2BX_ABUSE_OUT chains created by
# the installer. Unrelated firewall rules and later administrator changes remain.

readonly ABUSE_CHAIN="V2BX_ABUSE_OUT"
readonly ABUSE_TAG="v2bx-abuse"
readonly ABUSE_STATE_DIR="/var/lib/v2bx-anti-abuse"
readonly ABUSE_BACKUP_DIR="/var/backups/v2bx-anti-abuse"
readonly ABUSE_BACKUP_LIMIT=20

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly COLOR_GREEN=$'\033[32m'
  readonly COLOR_RED=$'\033[31m'
  readonly COLOR_MUTED=$'\033[2m'
  readonly COLOR_RESET=$'\033[0m'
else
  readonly COLOR_GREEN=""
  readonly COLOR_RED=""
  readonly COLOR_MUTED=""
  readonly COLOR_RESET=""
fi

log() {
  printf '  %b-%b %s\n' "${COLOR_MUTED}" "${COLOR_RESET}" "$*"
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

command -v iptables >/dev/null 2>&1 || die "找不到 iptables"
command -v iptables-save >/dev/null 2>&1 || die "找不到 iptables-save"
command -v iptables-restore >/dev/null 2>&1 || die "找不到 iptables-restore"

mkdir -p "${ABUSE_BACKUP_DIR}"

ABUSE_IPV6_ENABLED=0
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S OUTPUT >/dev/null 2>&1; then
  ABUSE_IPV6_ENABLED=1
fi

ABUSE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ABUSE_V4_BACKUP="${ABUSE_BACKUP_DIR}/pre-remove-${ABUSE_STAMP}.v4"
ABUSE_V6_BACKUP="${ABUSE_BACKUP_DIR}/pre-remove-${ABUSE_STAMP}.v6"

iptables-save >"${ABUSE_V4_BACKUP}"
if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  ip6tables-save >"${ABUSE_V6_BACKUP}"
fi

restore_failed_remove() {
  local exit_code=$?
  trap - ERR INT TERM
  log "撤销失败，恢复撤销前的防火墙规则"
  iptables-restore <"${ABUSE_V4_BACKUP}" || true
  if [[ ${ABUSE_IPV6_ENABLED} -eq 1 && -s "${ABUSE_V6_BACKUP}" ]]; then
    ip6tables-restore <"${ABUSE_V6_BACKUP}" || true
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
  exit "${exit_code}"
}
trap restore_failed_remove ERR INT TERM

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

remove_managed_rules() {
  local firewall_cmd=$1

  # 兼容清理旧版本曾写入 OUTPUT 顶层的 loopback ACCEPT。
  while "${firewall_cmd}" -C OUTPUT \
    -m comment --comment "${ABUSE_TAG}:jump" \
    -j "${ABUSE_CHAIN}" >/dev/null 2>&1; do
    "${firewall_cmd}" -D OUTPUT \
      -m comment --comment "${ABUSE_TAG}:jump" \
      -j "${ABUSE_CHAIN}"
  done

  if "${firewall_cmd}" -nL "${ABUSE_CHAIN}" >/dev/null 2>&1; then
    "${firewall_cmd}" -F "${ABUSE_CHAIN}"
    "${firewall_cmd}" -X "${ABUSE_CHAIN}"
  fi

  while "${firewall_cmd}" -C OUTPUT \
    -o lo \
    -m comment --comment "${ABUSE_TAG}:loopback" \
    -j ACCEPT >/dev/null 2>&1; do
    "${firewall_cmd}" -D OUTPUT \
      -o lo \
      -m comment --comment "${ABUSE_TAG}:loopback" \
      -j ACCEPT
  done
}

log "撤销 IPv4 受管规则"
remove_managed_rules iptables

if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  log "撤销 IPv6 受管规则"
  remove_managed_rules ip6tables
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
  log "保存撤销后的持久化规则"
  netfilter-persistent save
fi

rm -f \
  "${ABUSE_STATE_DIR}/installed" \
  "${ABUSE_STATE_DIR}/last-apply"

trap - ERR INT TERM

if ! prune_backups; then
  log "旧备份清理失败，请检查 ${ABUSE_BACKUP_DIR}"
fi

success "受管规则已撤销"
log "其他 OUTPUT/INPUT/FORWARD 规则均未改动"
log "撤销前 IPv4 备份：${ABUSE_V4_BACKUP}"
if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  log "撤销前 IPv6 备份：${ABUSE_V6_BACKUP}"
fi
