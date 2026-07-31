#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO="Jasper4860/v2bx-anti-abuse"
readonly REF="${V2BX_INSTALL_REF:-main}"
readonly BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"

TMP_DIR=""

log() {
    printf '[v2bx-anti-abuse] %s\n' "$*"
}

die() {
    printf '[v2bx-anti-abuse] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
}

trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
    die "请使用 root 或 sudo 运行本脚本"
fi

command -v curl >/dev/null 2>&1 || die "系统没有安装 curl"

TMP_DIR="$(mktemp -d /tmp/v2bx-anti-abuse.XXXXXX)"

files=(
    "install-v2bx-anti-abuse.sh"
    "remove-v2bx-anti-abuse.sh"
    "v2bx-abuse"
)

log "正在下载防滥用脚本"

for file in "${files[@]}"; do
    log "下载 ${file}"

    curl -fsSL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 10 \
        "${BASE_URL}/${file}" \
        -o "${TMP_DIR}/${file}"

    [[ -s "${TMP_DIR}/${file}" ]] || die "${file} 下载失败或文件为空"
done

chmod 700 \
    "${TMP_DIR}/install-v2bx-anti-abuse.sh" \
    "${TMP_DIR}/remove-v2bx-anti-abuse.sh"

chmod 755 "${TMP_DIR}/v2bx-abuse"

log "开始安装防滥用规则"

bash "${TMP_DIR}/install-v2bx-anti-abuse.sh"

log "一键安装完成"
log "查看状态：v2bx-abuse status"
log "查看计数：v2bx-abuse counters"
log "关闭规则：v2bx-abuse off"
log "重新启用：v2bx-abuse on"
