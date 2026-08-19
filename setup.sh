#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO="Jasper4860/v2bx-anti-abuse"
readonly REF="${V2BX_INSTALL_REF:-main}"
readonly BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"
readonly COMMAND_DIR="/usr/local/lib/v2bx-anti-abuse"
readonly COMMAND_PATH="/usr/local/sbin/v2bx-abuse"

TMP_DIR=""

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

step() {
    printf '\n%s\n' "$*"
}

detail() {
    printf '  %b%s%b\n' "${COLOR_MUTED}" "$*" "${COLOR_RESET}"
}

success() {
    printf '%b完成%b  %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

die() {
    printf '%b错误%b  %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
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
    "install.sh"
    "remove.sh"
    "v2bx-abuse"
)

printf 'V2bX Anti-Abuse\n'
printf '%b%s%b\n' "${COLOR_MUTED}" '----------------' "${COLOR_RESET}"
step "下载组件"

for file in "${files[@]}"; do
    detail "${file}"

    curl -fsSL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 10 \
        "${BASE_URL}/${file}" \
        -o "${TMP_DIR}/${file}"

    [[ -s "${TMP_DIR}/${file}" ]] || die "${file} 下载失败或文件为空"
done

chmod 700 \
    "${TMP_DIR}/install.sh" \
    "${TMP_DIR}/remove.sh"

chmod 755 "${TMP_DIR}/v2bx-abuse"

step "安装命令"
install -d -m 700 "${COMMAND_DIR}"
install -m 700 "${TMP_DIR}/install.sh" "${COMMAND_DIR}/install.sh"
install -m 700 "${TMP_DIR}/remove.sh" "${COMMAND_DIR}/remove.sh"
install -m 755 "${TMP_DIR}/v2bx-abuse" "${COMMAND_PATH}"

step "应用保护规则"

"${COMMAND_DIR}/install.sh"

printf '\n'
success "安装完成"
detail "状态  v2bx-abuse status"
detail "自检  v2bx-abuse check"
detail "计数  v2bx-abuse counters"
