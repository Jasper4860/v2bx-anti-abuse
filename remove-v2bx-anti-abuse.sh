#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Surgical rollback for install-v2bx-anti-abuse.sh.
# It removes only the tagged OUTPUT hooks and V2BX_ABUSE_OUT chains created by
# the installer. Unrelated firewall rules and later administrator changes remain.

readonly ABUSE_CHAIN="V2BX_ABUSE_OUT"
readonly ABUSE_TAG="v2bx-abuse"
readonly ABUSE_STATE_DIR="/var/lib/v2bx-anti-abuse"
readonly ABUSE_BACKUP_DIR="/var/backups/v2bx-anti-abuse"

log() {
  printf '[v2bx-anti-abuse] %s\n' "$*"
}

die() {
  printf '[v2bx-anti-abuse] ERROR: %s\n' "$*" >&2
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

remove_managed_rules() {
  local firewall_cmd=$1

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

log "撤销完成；其他 OUTPUT/INPUT/FORWARD 规则均未改动"
log "撤销前 IPv4 备份：${ABUSE_V4_BACKUP}"
if [[ ${ABUSE_IPV6_ENABLED} -eq 1 ]]; then
  log "撤销前 IPv6 备份：${ABUSE_V6_BACKUP}"
fi

