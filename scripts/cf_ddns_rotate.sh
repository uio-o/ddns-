#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
CHANGER="$BASE_DIR/cf_change_ip.sh"
WORKER="$BASE_DIR/cf_ddns.sh"
LOG_FILE="/var/log/cf_ddns.log"
LOCK_FILE="/run/cf-ddns-rotate.lock"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$1" | tee -a "$LOG_FILE" >&2
}

die() {
  log "错误：$1"
  exit 1
}

main() {
  command -v flock >/dev/null 2>&1 || die "缺少依赖：flock"
  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  [[ -x "$CHANGER" && -x "$WORKER" ]] || die "DDNS 脚本不完整，请重新安装项目。"

  # 阻止手动换 IP、Bot 按钮和定时任务同时执行，避免重复拨号。
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个 DDNS/换 IP 任务正在运行。"

  # 保留原项目行为：未启用换 IP API 时，定时器仍可只执行 DDNS 检测。
  # 启用 IP_CHANGE_ENABLED 后，定时器严格执行“换 IP -> 等待 -> 更新 DDNS”。
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  if [[ "${IP_CHANGE_ENABLED:-false}" == "true" ]]; then
    log "定时任务：开始调用换 IP API。"
    bash "$CHANGER"
    wait_seconds="${IP_CHANGE_WAIT_SECONDS:-8}"
    [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds=8
    log "定时任务：换 IP 完成，等待 ${wait_seconds} 秒后更新 DDNS。"
    sleep "$wait_seconds"
  else
    log "定时任务：IP_CHANGE_ENABLED 未启用，仅执行 DDNS 检测。"
  fi

  log "定时任务：开始更新 DDNS。"
  bash "$WORKER"
}

main "$@"
