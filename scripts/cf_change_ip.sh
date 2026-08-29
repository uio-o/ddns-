#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
LOG_FILE="/var/log/cf_ddns.log"
LOCK_FILE="/run/cf-change-ip.lock"

log() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE"
}

die() {
  log "错误：$1"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"
}

api_url_with_format() {
  local url="$1"

  if [[ "${IP_CHANGE_API_FORMAT_JSON:-true}" != "true" ]]; then
    printf '%s\n' "$url"
    return 0
  fi

  if [[ "$url" == *"format="* ]]; then
    printf '%s\n' "$url"
  elif [[ "$url" == *"?"* ]]; then
    printf '%s&format=json\n' "$url"
  else
    printf '%s?format=json\n' "$url"
  fi
}

summarize_response() {
  local response="$1"
  local summary=""

  if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$response"; then
    summary="$(jq -r '
      .message // .msg // .status // .code // .data.message // .data.msg // empty
    ' <<<"$response" | head -n 1)"
    if [[ -n "$summary" && "$summary" != "null" ]]; then
      printf '%s\n' "$summary"
    else
      printf 'API 已返回 JSON 结果。\n'
    fi
  else
    printf '%s\n' "$response" | head -c 400
    printf '\n'
  fi
}

CHANGE_IP_STATUS=""

# 默认端点仅为方便 Boil 用户；非 Boil 机器请在配置里改成自己面板的换 IP 地址。
DEFAULT_API_ENDPOINT="https://ippanel.boil.network/api/v1/changeIP"

# 通用换 IP 请求：可指定 method(GET/POST) 与可选 Bearer token。
# 响应体写入 body_file，HTTP 状态码存入 CHANGE_IP_STATUS。2xx 返回 0。
# 必须直接调用（勿放进 $(...)），否则全局赋值会在子shell丢失。
change_ip_request() {
  local url="$1" body_file="$2" method="${3:-POST}" token="${4:-}"
  local -a args=(-sS --retry 2 --connect-timeout 10 --max-time 90 -o "$body_file" -w '%{http_code}' -X "$method")
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")
  CHANGE_IP_STATUS="$(curl "${args[@]}" "$url" 2>/dev/null)" || CHANGE_IP_STATUS="000"
  [[ "$CHANGE_IP_STATUS" == 2* ]]
}

main() {
  require_cmd curl
  require_cmd flock

  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  [[ "${IP_CHANGE_ENABLED:-false}" == "true" ]] || die "换 IP API 未启用，请先执行 ddns 配置。"

  # 通用三要素：端点 URL + 请求方法 + 可选 Bearer Token（适配 Boil 及其它面板）。
  local endpoint="${IP_CHANGE_API_ENDPOINT:-}"
  local method="${IP_CHANGE_API_METHOD:-POST}"
  local token="${IP_CHANGE_API_TOKEN:-}"

  # 向后兼容：只配了旧版 GET 专属链接（IP_CHANGE_API_URL）时，按 GET 直接请求它。
  if [[ -z "$endpoint" && -n "${IP_CHANGE_API_URL:-}" ]]; then
    endpoint="$IP_CHANGE_API_URL"
    method="GET"
  fi
  # 端点仍为空则回退默认（Boil）。
  [[ -n "$endpoint" ]] || endpoint="$DEFAULT_API_ENDPOINT"
  case "${method^^}" in GET|POST) method="${method^^}" ;; *) method="POST" ;; esac

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个换 IP 任务正在运行。"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  local body_file response summary body
  body_file="$(mktemp)"
  log "正在请求换 IP API（${method} ${endpoint}）。"

  if ! change_ip_request "$endpoint" "$body_file" "$method" "$token"; then
    body="$(head -c 400 "$body_file" 2>/dev/null | tr -d '\r\n')"
    rm -f "$body_file"
    die "换 IP API 请求失败（HTTP ${CHANGE_IP_STATUS}）：${body:-无响应体，请确认端点/方法/Token 是否正确}"
  fi

  response="$(cat "$body_file" 2>/dev/null || true)"
  rm -f "$body_file"
  summary="$(summarize_response "$response")"
  log "换 IP API 请求完成：$summary"
  printf '%s\n' "$summary"
}

main "$@"
