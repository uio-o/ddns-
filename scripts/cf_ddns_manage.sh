#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
WORKER="$BASE_DIR/cf_ddns.sh"
ROTATE_WORKER="$BASE_DIR/cf_ddns_rotate.sh"
CHANGER="$BASE_DIR/cf_change_ip.sh"
BOT_WORKER="$BASE_DIR/cf_ddns_bot.sh"
LOG_FILE="/var/log/cf_ddns.log"
BIN_LINK="/usr/local/bin/ddns"
SERVICE_FILE="/etc/systemd/system/cf-ddns.service"
TIMER_FILE="/etc/systemd/system/cf-ddns.timer"
BOT_SERVICE_FILE="/etc/systemd/system/cf-ddns-bot.service"
ROTATE_CRON_FILE="/etc/cron.d/cf-ddns-rotate"
ROTATE_CRON_DISABLED_FILE="/etc/cron.d/cf-ddns-rotate.disabled"
LEGACY_CRON_FILE="/etc/cron.d/cf-ddns"
LEGACY_CRON_DISABLED_FILE="/etc/cron.d/cf-ddns.disabled"
UPDATE_ENV_FILE="$BASE_DIR/update.env"
CF_API_BASE="https://api.cloudflare.com/client/v4"
INSTALL_URL="${DDNS_INSTALL_URL:-}"
if [[ -f "$UPDATE_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$UPDATE_ENV_FILE"
  INSTALL_URL="${DDNS_INSTALL_URL:-$INSTALL_URL}"
fi
CUSTOM_PANEL_BASENAME="panel_custom"
PANEL_IMAGE_MIN_BYTES=1000
PANEL_IMAGE_MAX_BYTES=$((10 * 1024 * 1024))   # Telegram 上传图片上限 10MB

# 颜色（仅在交互终端启用）。
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 用户执行：ddns"
    exit 1
  fi
}

pause() {
  echo
  read -r -p "按回车返回菜单..." _ || true
}

load_env() {
  CF_API_TOKEN=""
  ZONE_NAME=""
  RECORD_NAME=""
  RECORD_NAME_V6=""
  RECORD_TYPE="A"
  TTL="120"
  PROXY="false"
  TG_ENABLED="false"
  TG_BOT_TOKEN=""
  TG_CHAT_ID=""
  TG_EXTRA_CHAT_IDS=""
  TG_GROUP_ENABLED="false"
  TG_GROUP_BOT_TOKEN=""
  TG_GROUP_CHAT_IDS=""
  TG_GROUP_SILENT="false"
  GEO_ENABLED="true"
  PANEL_AUTO_REFRESH_SECONDS="120"
  PANEL_IMAGE_FILE=""
  IP_CHANGE_ENABLED="false"
  IP_CHANGE_API_ENDPOINT=""
  IP_CHANGE_API_METHOD="POST"
  IP_CHANGE_API_TOKEN=""
  IP_CHANGE_API_URL=""
  IP_CHANGE_API_FORMAT_JSON="true"
  IP_CHANGE_WAIT_SECONDS="8"
  CRON_EXPRESSION=""
  ROTATE_CRON_EXPRESSION="0 3 * * 3"
  DDNS_TIMER_INTERVAL_MINUTES="5"

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
  fi
  if [[ -f "$ENV_FILE" ]] && ! grep -q '^ROTATE_CRON_EXPRESSION=' "$ENV_FILE" && grep -q '^CRON_EXPRESSION=' "$ENV_FILE"; then
    ROTATE_CRON_EXPRESSION="$CRON_EXPRESSION"
  fi
}

prompt_secret_keep() {
  local var="$1"
  local prompt="$2"
  local old="${!var:-}"
  local input=""

  if [[ -n "$old" ]]; then
    read -r -s -p "$prompt [已配置，回车保留；输入新值则覆盖]: " input || true
    echo
    if [[ -n "$input" ]]; then
      printf -v "$var" '%s' "$input"
    fi
  else
    while [[ -z "${!var:-}" ]]; do
      read -r -s -p "$prompt: " input || true
      echo
      if [[ -n "$input" ]]; then
        printf -v "$var" '%s' "$input"
      else
        echo "不能为空。"
      fi
    done
  fi
}

prompt_sensitive_text_keep() {
  local var="$1"
  local prompt="$2"
  local example="$3"
  local old="${!var:-}"
  local input=""

  if [[ -n "$old" ]]; then
    read -r -p "$prompt [已配置，回车保留；输入新值则覆盖，例如 ${example}]: " input || true
    if [[ -n "$input" ]]; then
      printf -v "$var" '%s' "$input"
    fi
  else
    while true; do
      read -r -p "$prompt，例如 ${example}: " input || true
      if [[ -n "$input" ]]; then
        printf -v "$var" '%s' "$input"
        return 0
      fi
      echo "不能为空。"
    done
  fi
}

prompt_num_keep() {
  local var="$1"
  local prompt="$2"
  local default_value="$3"
  local old="${!var:-$default_value}"
  local input=""

  while true; do
    read -r -p "$prompt [$old]: " input || true
    input="${input:-$old}"
    if [[ "$input" =~ ^[0-9]+$ && "$input" -ge 1 ]]; then
      printf -v "$var" '%s' "$input"
      return 0
    fi
    echo "请输入大于等于 1 的数字。"
  done
}

prompt_bool_keep() {
  local var="$1"
  local prompt="$2"
  local default_value="$3"
  local old="${!var:-$default_value}"
  local input=""

  case "$old" in
    true|false) ;;
    *) old="$default_value" ;;
  esac

  while true; do
    local hint="n"
    [[ "$old" == "true" ]] && hint="y"
    read -r -p "$prompt [${hint}]: " input || true
    input="${input:-$hint}"

    case "${input,,}" in
      y|yes|true|1)
        printf -v "$var" '%s' "true"
        return 0
        ;;
      n|no|false|0)
        printf -v "$var" '%s' "false"
        return 0
        ;;
      *)
        echo "请输入 y 或 n。"
        ;;
    esac
  done
}

prompt_record_type_keep() {
  local old="${RECORD_TYPE:-A}"
  local input=""

  while true; do
    read -r -p "请输入记录类型：A=IPv4，AAAA=IPv6，BOTH=双栈同时更新 [$old]: " input || true
    input="${input:-$old}"
    input="${input^^}"
    case "$input" in
      A|AAAA|BOTH)
        RECORD_TYPE="$input"
        return 0
        ;;
      DUAL)
        RECORD_TYPE="BOTH"
        return 0
        ;;
      *)
        echo "请输入 A、AAAA 或 BOTH。"
        ;;
    esac
  done
}

# 把 RECORD_TYPE 展开成实际要处理的类型列表（与 cf_ddns.sh 保持一致）。
record_types_list() {
  # 与 cf_ddns.sh 的 resolve_record_types 保持同样的宽松匹配（大写归一 + 多种写法）。
  local raw="${RECORD_TYPE:-A}"
  case "${raw^^}" in
    AAAA) printf 'AAAA' ;;
    BOTH|DUAL|A,AAAA|AAAA,A|"A AAAA"|"AAAA A") printf 'A AAAA' ;;
    *)    printf 'A' ;;
  esac
}

save_env() {
  local tmp=""
  tmp="$(mktemp)"

  {
    cat <<'COMMENT_EOF'
# Cloudflare DDNS 配置文件
# 文件权限应保持 600：
# chmod 600 /usr/local/ddns/cf_ddns.env
#
# Cloudflare API Token 权限建议：
# Zone:Read + DNS:Edit，并尽量只限定到对应 Zone。
#
# RECORD_NAME 支持多条记录，用逗号或空格分隔，例如：
# RECORD_NAME='a.example.com b.example.com'
#
# RECORD_NAME_V6：AAAA 记录使用的域名（留空则与 RECORD_NAME 相同，即普通双栈）。
# 若填不同域名，主域名就只会有 A 记录——客户端/探针不会优先走 IPv6，
# 适合 IPv6 线路延迟明显高于 IPv4 的机器，例如：
# RECORD_NAME='hkt.example.com'      → 只有 A（探针测这个，走 IPv4）
# RECORD_NAME_V6='hkt6.example.com'  → 只有 AAAA（需要 IPv6 时用这个）
# RECORD_TYPE=A 更新 IPv4；AAAA 更新 IPv6；BOTH 同时更新 A 与 AAAA（双栈）。
# 双栈下同一域名会同时拥有 A 与 AAAA 记录，各自跟踪对应协议的公网地址；
# 某一协议暂时取不到地址时只跳过该协议，不影响另一协议。
COMMENT_EOF

    printf 'CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
    printf 'ZONE_NAME=%q\n' "$ZONE_NAME"
    printf 'RECORD_NAME=%q\n' "$RECORD_NAME"
    printf 'RECORD_NAME_V6=%q\n' "$RECORD_NAME_V6"
    printf 'RECORD_TYPE=%q\n' "$RECORD_TYPE"
    printf 'TTL=%q\n' "$TTL"
    printf 'PROXY=%q\n' "$PROXY"

    echo

    cat <<'COMMENT_EOF'
# 换 IP API 配置（通用，适配 Boil 及其它面板）
# IP_CHANGE_API_ENDPOINT：换 IP 端点 URL（留空回退默认 Boil 端点
#   https://ippanel.boil.network/api/v1/changeIP）。非 Boil 机器改成自己面板的地址。
# IP_CHANGE_API_METHOD：请求方法 POST 或 GET（Boil 为 POST）。
# IP_CHANGE_API_TOKEN：可选；非空则以 Authorization: Bearer <token> 发送。
# IP_CHANGE_API_URL：旧版 GET 专属链接（Boil 已停用，仅兼容；未设端点时按 GET 请求它）。
COMMENT_EOF

    printf 'IP_CHANGE_ENABLED=%q\n' "$IP_CHANGE_ENABLED"
    printf 'IP_CHANGE_API_ENDPOINT=%q\n' "$IP_CHANGE_API_ENDPOINT"
    printf 'IP_CHANGE_API_METHOD=%q\n' "$IP_CHANGE_API_METHOD"
    printf 'IP_CHANGE_API_TOKEN=%q\n' "$IP_CHANGE_API_TOKEN"
    printf 'IP_CHANGE_API_URL=%q\n' "$IP_CHANGE_API_URL"
    printf 'IP_CHANGE_API_FORMAT_JSON=%q\n' "$IP_CHANGE_API_FORMAT_JSON"
    printf 'IP_CHANGE_WAIT_SECONDS=%q\n' "$IP_CHANGE_WAIT_SECONDS"
    printf 'ROTATE_CRON_EXPRESSION=%q\n' "$ROTATE_CRON_EXPRESSION"
    printf 'DDNS_TIMER_INTERVAL_MINUTES=%q\n' "$DDNS_TIMER_INTERVAL_MINUTES"

    echo

    cat <<'COMMENT_EOF'
# Telegram 通知配置
# TG_ENABLED=true 时，仅在 DNS 记录创建或 IP 变化更新成功后推送。
# 安装 Telegram Bot 命令服务后，可通过 /changeip 触发换 IP API。
#
# 多人共用：TG_EXTRA_CHAT_IDS 填额外授权的 Chat ID（逗号或空格分隔）。
# 列表中的人可操作 Bot 并接收通知，与主用户同权限，例如：
# TG_EXTRA_CHAT_IDS='123456789 987654321'
COMMENT_EOF

    printf 'TG_ENABLED=%q\n' "$TG_ENABLED"
    printf 'TG_BOT_TOKEN=%q\n' "$TG_BOT_TOKEN"
    printf 'TG_CHAT_ID=%q\n' "$TG_CHAT_ID"
    printf 'TG_EXTRA_CHAT_IDS=%q\n' "$TG_EXTRA_CHAT_IDS"
    printf 'TG_GROUP_ENABLED=%q\n' "$TG_GROUP_ENABLED"
    printf 'TG_GROUP_BOT_TOKEN=%q\n' "$TG_GROUP_BOT_TOKEN"
    printf 'TG_GROUP_CHAT_IDS=%q\n' "$TG_GROUP_CHAT_IDS"
    printf 'TG_GROUP_SILENT=%q\n' "$TG_GROUP_SILENT"

    echo
    cat <<'COMMENT_EOF'
# 面板显示选项
# PANEL_AUTO_REFRESH_SECONDS：Telegram 面板自动重绘间隔（秒），让「上次检测」等
# 信息保持最新。编辑已有消息不会产生新通知，不打扰；设为 0 关闭自动刷新。
#
# GEO_ENABLED=true 时，Telegram 面板会显示公网 IP 的地区 / ISP 归属。
# 该功能会把本机公网 IP 发送给第三方地理库（ip-api.com / ipwho.is）查询。
#
# PANEL_IMAGE_FILE：自定义面板图片的绝对路径（留空则用内置默认图）。
# 建议通过菜单「i) 更换 Telegram 面板图片」设置，会自动下载校验并填好本项。
COMMENT_EOF

    printf 'GEO_ENABLED=%q\n' "$GEO_ENABLED"
    printf 'PANEL_AUTO_REFRESH_SECONDS=%q\n' "$PANEL_AUTO_REFRESH_SECONDS"
    printf 'PANEL_IMAGE_FILE=%q\n' "$PANEL_IMAGE_FILE"
  } > "$tmp"

  install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"

  chmod 700 "$BASE_DIR"
  echo "已保存配置：$ENV_FILE"
}

ensure_deps() {
  local missing=()
  local cmd=""

  for cmd in curl jq flock; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  echo "缺少依赖：${missing[*]}"

  if command -v apt-get >/dev/null 2>&1; then
    read -r -p "是否自动安装 curl jq util-linux ca-certificates？[Y/n]: " ans || true
    ans="${ans:-Y}"

    case "${ans,,}" in
      y|yes)
        apt-get update
        apt-get install -y curl jq util-linux ca-certificates
        ;;
      *)
        echo "已取消自动安装。"
        return 1
        ;;
    esac
  else
    echo "未检测到 apt-get，请手动安装：curl jq util-linux ca-certificates"
    return 1
  fi
}

# 保存后立即验证 Cloudflare Token / Zone / 记录，尽早暴露配置错误。
verify_cloudflare() {
  command -v jq >/dev/null 2>&1 || return 0
  [[ -n "${CF_API_TOKEN:-}" && -n "${ZONE_NAME:-}" ]] || return 0

  echo
  echo "正在验证 Cloudflare 配置..."

  local resp status
  resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
    "$CF_API_BASE/user/tokens/verify" \
    -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
  status="$(printf '%s' "$resp" | jq -r '.result.status // empty' 2>/dev/null || true)"
  if [[ "$status" == "active" ]]; then
    echo "  ${C_GREEN}✓${C_RESET} API Token 有效。"
  else
    echo "  ${C_RED}✗${C_RESET} API Token 验证未通过：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null || echo '无法连接')"
    return 1
  fi

  local zone_resp zone_id
  zone_resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
    "$CF_API_BASE/zones?name=$(jq -rn --arg v "$ZONE_NAME" '$v|@uri')&status=active" \
    -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
  zone_id="$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  if [[ -z "$zone_id" ]]; then
    echo "  ${C_RED}✗${C_RESET} 未找到 Zone：$ZONE_NAME（请确认域名与 Token 权限）。"
    return 1
  fi
  echo "  ${C_GREEN}✓${C_RESET} Zone 已找到：$ZONE_NAME"

  local rtype name rec_resp content raw
  # 双栈时对 A 与 AAAA 各校验一遍；AAAA 若配了独立域名则校验它。
  for rtype in $(record_types_list); do
    if [[ "$rtype" == "AAAA" && -n "${RECORD_NAME_V6:-}" ]]; then
      raw="${RECORD_NAME_V6// /,}"
    else
      raw="${RECORD_NAME// /,}"
    fi
    IFS=',' read -r -a _recs <<<"$raw"
    for name in "${_recs[@]}"; do
      [[ -n "$name" ]] || continue
      rec_resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
        "$CF_API_BASE/zones/${zone_id}/dns_records?type=${rtype}&name=$(jq -rn --arg v "$name" '$v|@uri')" \
        -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
      content="$(printf '%s' "$rec_resp" | jq -r '.result[0].content // empty' 2>/dev/null || true)"
      if [[ -n "$content" ]]; then
        echo "  ${C_GREEN}✓${C_RESET} ${rtype} 记录 ${name} 当前值：${content}"
      else
        echo "  ${C_YELLOW}!${C_RESET} ${rtype} 记录 ${name} 尚不存在，首次运行将自动创建。"
      fi
    done
  done
}

configure_env() {
  load_env

  echo
  echo "=== Cloudflare DDNS 配置 ==="
  echo "说明：下面不会回显已保存的真实域名、记录名或密钥。"
  echo

  prompt_secret_keep CF_API_TOKEN "请输入 Cloudflare API Token"
  prompt_sensitive_text_keep ZONE_NAME "请输入 Cloudflare Zone Name" "example.com"
  prompt_sensitive_text_keep RECORD_NAME "请输入需 DDNS 更新的完整记录域名（多条用逗号/空格分隔）" "ddns.example.com"
  prompt_record_type_keep

  # 只有涉及 IPv6 时才问 AAAA 域名，避免拉长纯 IPv4 用户的配置流程。
  if [[ "$(record_types_list)" == *AAAA* ]]; then
    local _v6=""
    echo
    echo "AAAA（IPv6）可以用与 A 不同的域名。"
    echo "留空 = 与上面相同（普通双栈）；填不同域名 = 主域名只保留 A 记录，"
    echo "这样探针/客户端不会优先走 IPv6（适合 IPv6 延迟明显更高的机器）。"
    read -r -p "AAAA 记录域名 [当前：${RECORD_NAME_V6:-与 A 相同}，回车保留；输入 - 清空]: " _v6 || true
    case "$_v6" in
      "") : ;;
      -)  RECORD_NAME_V6="" ;;
      *)  RECORD_NAME_V6="$_v6" ;;
    esac
  fi

  prompt_num_keep TTL "请输入 TTL，常用 120；若使用 Cloudflare 自动 TTL 可填 1" "${TTL:-120}"
  prompt_bool_keep PROXY "是否开启 Cloudflare 小云朵代理 proxied？DDNS 通常建议 n" "${PROXY:-false}"

  echo
  echo "=== 换 IP API（通用）==="
  echo "Boil 机器：端点用默认，填入 Boil 面板的 API Token 即可。"
  echo "其它面板：把端点改成对方的换 IP 地址，按其要求选 POST/GET 及是否需要 Token。"
  echo "Token 作为密钥保存，不回显。"
  echo

  prompt_bool_keep IP_CHANGE_ENABLED "是否启用换 IP API？" "${IP_CHANGE_ENABLED:-false}"

  if [[ "$IP_CHANGE_ENABLED" == "true" ]]; then
    local _ep_default _mt_default _in
    _ep_default="${IP_CHANGE_API_ENDPOINT:-https://ippanel.boil.network/api/v1/changeIP}"
    read -r -p "换 IP API 端点 URL [${_ep_default}]: " _in || true
    IP_CHANGE_API_ENDPOINT="${_in:-$_ep_default}"

    _mt_default="${IP_CHANGE_API_METHOD:-POST}"
    read -r -p "请求方法 POST/GET [${_mt_default}]: " _in || true
    _in="${_in:-$_mt_default}"; _in="${_in^^}"
    [[ "$_in" == "GET" || "$_in" == "POST" ]] || _in="POST"
    IP_CHANGE_API_METHOD="$_in"

    # Token 可选：允许留空（有些面板靠 IP 或链接内密钥鉴权）。
    _in=""
    if [[ -n "${IP_CHANGE_API_TOKEN:-}" ]]; then
      read -r -s -p "API Token（Bearer）[已配置，回车保留；输入新值覆盖；输入 - 清空]: " _in || true; echo
      case "$_in" in "") : ;; -) IP_CHANGE_API_TOKEN="" ;; *) IP_CHANGE_API_TOKEN="$_in" ;; esac
    else
      read -r -s -p "API Token（可选，作为 Authorization: Bearer 发送；无则直接回车）: " _in || true; echo
      IP_CHANGE_API_TOKEN="$_in"
    fi

    prompt_num_keep IP_CHANGE_WAIT_SECONDS "换 IP 后等待多少秒再更新 Cloudflare DDNS" "${IP_CHANGE_WAIT_SECONDS:-8}"
  else
    IP_CHANGE_API_ENDPOINT=""
    IP_CHANGE_API_METHOD="POST"
    IP_CHANGE_API_TOKEN=""
    IP_CHANGE_API_URL=""
    IP_CHANGE_API_FORMAT_JSON="true"
    IP_CHANGE_WAIT_SECONDS="8"
  fi

  echo
  echo "=== Telegram 变更通知 ==="
  echo "如需推送："
  echo "1. 在 Telegram 搜索 @BotFather"
  echo "2. 发送 /newbot 创建机器人并获得 Bot Token"
  echo "3. 先给机器人发一条消息"
  echo "4. 使用 getUpdates 获取 chat_id"
  echo "5. 群组通知则需先把机器人拉进群"
  echo

  prompt_bool_keep TG_ENABLED "是否启用 Telegram 通知？" "${TG_ENABLED:-false}"

  if [[ "$TG_ENABLED" == "true" ]]; then
    prompt_secret_keep TG_BOT_TOKEN "请输入 Telegram Bot Token"
    prompt_sensitive_text_keep TG_CHAT_ID "请输入 Telegram Chat ID（主用户）" "123456789"
    prompt_bool_keep TG_GROUP_ENABLED "是否向指定群聊推送 IP 变更通知？" "${TG_GROUP_ENABLED:-false}"
    if [[ "$TG_GROUP_ENABLED" == "true" ]]; then
      echo "群通知必须使用独立 Bot Token；只把群通知 Bot 加入群聊，不要把管理员 Bot 加群。"
      prompt_secret_keep TG_GROUP_BOT_TOKEN "请输入群通知专用 Telegram Bot Token"
      if [[ -n "${TG_BOT_TOKEN:-}" && "$TG_GROUP_BOT_TOKEN" == "$TG_BOT_TOKEN" ]]; then
        echo "群通知 Bot Token 不能与管理员 Bot Token 相同。"
        return 1
      fi
      prompt_sensitive_text_keep TG_GROUP_CHAT_IDS "请输入仅接收通知的群聊 Chat ID（多个用空格或逗号分隔）" "-1001234567890"
      prompt_bool_keep TG_GROUP_SILENT "群聊通知是否静默发送？" "${TG_GROUP_SILENT:-false}"
    else
      TG_GROUP_BOT_TOKEN=""
      TG_GROUP_CHAT_IDS=""
      TG_GROUP_SILENT="false"
    fi
    prompt_bool_keep GEO_ENABLED "是否在面板显示 IP 地区/ISP 归属？（会向第三方查询本机公网 IP）" "${GEO_ENABLED:-true}"
    echo "（多人共用：主菜单 c) 管理授权用户，或在 Telegram 用 /adduser、/deluser 快速增删。）"
  else
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_EXTRA_CHAT_IDS=""
    TG_GROUP_ENABLED="false"
    TG_GROUP_BOT_TOKEN=""
    TG_GROUP_CHAT_IDS=""
    TG_GROUP_SILENT="false"
  fi

  save_env
  verify_cloudflare || echo "${C_YELLOW}提示：Cloudflare 验证未完全通过，可重新选择 1 修改配置。${C_RESET}"
}

validate_cron_expression() {
  [[ "$(awk '{print NF}' <<<"$1")" -eq 5 ]]
}

ensure_cron_service() {
  if ! command -v crontab >/dev/null 2>&1; then
    echo "缺少 crontab，正在安装 cron..."
    apt-get update
    apt-get install -y cron
  fi
  systemctl enable --now cron
}

migrate_legacy_schedule() {
  if [[ -f "$LEGACY_CRON_FILE" && ! -e "$ROTATE_CRON_FILE" ]]; then
    mv "$LEGACY_CRON_FILE" "$ROTATE_CRON_FILE"
  fi
  if [[ -f "$LEGACY_CRON_DISABLED_FILE" && ! -e "$ROTATE_CRON_DISABLED_FILE" ]]; then
    mv "$LEGACY_CRON_DISABLED_FILE" "$ROTATE_CRON_DISABLED_FILE"
  fi
}

install_rotate_cron() {
  ensure_deps || return 1
  load_env

  if [[ "${IP_CHANGE_ENABLED:-false}" != "true" ]]; then
    echo "换 IP API 未启用。请先选择 1 配置 API，再安装链路一。"
    return 1
  fi

  local expression="${ROTATE_CRON_EXPRESSION:-0 3 * * 3}" input=""
  read -r -p "链路一 cron 表达式 [${expression}]（例如每周三 03:00：0 3 * * 3）: " input || true
  expression="${input:-$expression}"
  if ! validate_cron_expression "$expression"; then
    echo "cron 表达式必须包含 5 个字段：分钟 小时 日期 月份 星期。"
    return 1
  fi

  ensure_cron_service || return 1
  ROTATE_CRON_EXPRESSION="$expression"
  rm -f "$ROTATE_CRON_DISABLED_FILE" "$LEGACY_CRON_FILE" "$LEGACY_CRON_DISABLED_FILE"
  cat > "$ROTATE_CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${ROTATE_CRON_EXPRESSION} root $ROTATE_WORKER
EOF
  chmod 644 "$ROTATE_CRON_FILE"
  save_env
  echo "已安装链路一：cron 换 IP API -> 等待 -> DDNS。"
  echo "表达式：$ROTATE_CRON_EXPRESSION"
  echo "本次只安装调度，不立即执行换 IP 或 DDNS。"
}

install_ddns_timer() {
  ensure_deps || return 1
  load_env

  local minutes="${DDNS_TIMER_INTERVAL_MINUTES:-5}" input=""
  read -r -p "链路二 DDNS 检测间隔（分钟）[${minutes}]: " input || true
  minutes="${input:-$minutes}"
  if [[ ! "$minutes" =~ ^[1-9][0-9]*$ ]]; then
    echo "间隔必须是大于 0 的整数分钟。"
    return 1
  fi

  DDNS_TIMER_INTERVAL_MINUTES="$minutes"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare DDNS check only
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$WORKER
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Cloudflare DDNS check every ${minutes} minutes

[Timer]
OnBootSec=${minutes}min
OnUnitActiveSec=${minutes}min
AccuracySec=10s
Persistent=false
Unit=cf-ddns.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cf-ddns.timer
  save_env
  echo "已安装链路二：每 ${minutes} 分钟只检测并更新 DDNS。"
  echo "首次检测在 ${minutes} 分钟后，本次安装不会立即执行 DDNS。"
}

configure_schedules() {
  while true; do
    clear 2>/dev/null || true
    echo "${C_BOLD}${C_CYAN}=== 两条独立自动链路 ===${C_RESET}"
    echo "  a) 安装/更新链路一：cron 换 IP + 等待 + DDNS"
    echo "  b) 安装/更新链路二：systemd timer 仅 DDNS 检测"
    echo "  c) 依次配置两条链路"
    echo "  0) 返回上级面板"
    echo
    read -r -p "请选择: " choice || true
    case "$choice" in
      a|A) install_rotate_cron; pause ;;
      b|B) install_ddns_timer; pause ;;
      c|C) install_rotate_cron; pause; install_ddns_timer; pause ;;
      0) return 0 ;;
      *) echo "无效选择。"; sleep 1 ;;
    esac
  done
}

run_once() {
  ensure_deps || return 1

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "尚未配置，请先选择 1 初始化/修改配置。"
    return 1
  fi

  bash "$WORKER"
}

change_ip_once() {
  ensure_deps || return 1

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "尚未配置，请先选择 1 初始化/修改配置。"
    return 1
  fi

  load_env

  if [[ "${IP_CHANGE_ENABLED:-false}" != "true" || ( -z "${IP_CHANGE_API_ENDPOINT:-}" && -z "${IP_CHANGE_API_TOKEN:-}" && -z "${IP_CHANGE_API_URL:-}" ) ]]; then
    echo "换 IP API 未启用或配置不完整，请先选择 1 修改配置。"
    return 1
  fi

  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "当前系统缺少 systemd-run，无法安全提交断线后继续运行的任务。"
    return 1
  fi

  local unit="cf-ddns-manual-$(date +%s)"
  if systemd-run --quiet --collect --unit="$unit" --on-active=5s "$ROTATE_WORKER"; then
    echo "已提交后台任务：${unit}.service"
    echo "任务将在 5 秒后执行换 IP、等待和 DDNS 更新。"
    echo "换公网 IP 会使当前 SSH 连接断开，这是正常现象；后台任务不会中断。"
    echo "重连后可通过菜单 4 或 $LOG_FILE 查看结果。"
  else
    echo "提交后台任务失败，未执行换 IP。"
    return 1
  fi
}

install_bot_service() {
  ensure_deps || return 1
  load_env

  if [[ "${TG_ENABLED:-false}" != "true" || -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo "Telegram 未启用或配置不完整，请先选择 1 修改配置。"
    return 1
  fi

  cat > "$BOT_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare DDNS Telegram Command Bot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$BOT_WORKER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cf-ddns-bot.service
  systemctl restart cf-ddns-bot.service

  echo "已安装/更新 Telegram Bot 命令服务。"
  echo "可用命令：/changeip /ddns /status /log /help"
  systemctl status cf-ddns-bot.service --no-pager || true
}

test_telegram_admin() {
  ensure_deps || return 1
  load_env

  if [[ "${TG_ENABLED:-false}" != "true" || -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo "Telegram 管理员通知未启用或配置不完整，请先选择 1 修改配置。"
    return 1
  fi

  if curl -fsS --retry 3 --connect-timeout 5 --max-time 20 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=Cloudflare DDNS 管理员测试推送：$(date '+%F %T')" \
    >/dev/null; then
    echo "管理员 Telegram 测试推送成功。"
  else
    echo "管理员 Telegram 测试推送失败，请检查 Bot Token 和 TG_CHAT_ID。"
    return 1
  fi
}

test_telegram_group() {
  ensure_deps || return 1
  load_env

  if [[ "${TG_GROUP_ENABLED:-false}" != "true" || -z "${TG_GROUP_BOT_TOKEN:-}" || -z "${TG_GROUP_CHAT_IDS:-}" ]]; then
    echo "Telegram 群聊通知未启用或缺少专用 TG_GROUP_BOT_TOKEN/群 Chat ID，请先选择 1 修改配置。"
    return 1
  fi

  if [[ -n "${TG_BOT_TOKEN:-}" && "$TG_GROUP_BOT_TOKEN" == "$TG_BOT_TOKEN" ]]; then
    echo "群通知 Bot Token 不能与管理员 Bot Token 相同。"
    return 1
  fi

  local raw="${TG_GROUP_CHAT_IDS//,/ }" cid failed=0
  for cid in $raw; do
    [[ -n "$cid" ]] || continue
    if curl -fsS --retry 3 --connect-timeout 5 --max-time 20 \
      -X POST "https://api.telegram.org/bot${TG_GROUP_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${cid}" \
      --data-urlencode "text=Cloudflare DDNS 群聊通知测试：$(date '+%F %T')" \
      --data-urlencode "disable_notification=${TG_GROUP_SILENT:-false}" \
      >/dev/null; then
      echo "群聊 ${cid} 测试通知成功。"
    else
      echo "群聊 ${cid} 测试通知失败，请检查 Bot 是否已加入群聊及 Chat ID。"
      failed=1
    fi
  done
  return "$failed"
}

test_telegram() {
  while true; do
    clear 2>/dev/null || true
    echo "${C_BOLD}${C_CYAN}=== Telegram 通知测试 ===${C_RESET}"
    echo "  a) 测试管理员面板推送"
    echo "  b) 测试群聊消息通知"
    echo "  0) 返回上级面板"
    echo
    read -r -p "请选择测试项: " choice || true
    case "$choice" in
      a|A) test_telegram_admin; pause ;;
      b|B) test_telegram_group; pause ;;
      0) return 0 ;;
      *) echo "无效选择。"; sleep 1 ;;
    esac
  done
}

# 规范化 Chat ID 列表：逗号转空格、去空白、去重，输出空格分隔字符串。
normalize_chat_ids() {
  local raw="$1" id seen=" " out=""
  raw="${raw//,/ }"
  for id in $raw; do
    [[ -n "$id" ]] || continue
    [[ "$seen" == *" $id "* ]] && continue
    seen+="$id "
    out+="${out:+ }$id"
  done
  printf '%s' "$out"
}

# 管理授权用户（多人共用）：列出 / 添加 / 删除额外 Chat ID。主用户不可在此删除。
manage_chat_ids() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "尚未配置，请先选择 1 初始化/修改配置。"
    pause
    return 1
  fi

  load_env

  local op newid sel target i found e
  local -a extras=()

  while true; do
    clear 2>/dev/null || true
    echo "${C_BOLD}${C_CYAN}=== 管理授权用户（Telegram Chat ID）===${C_RESET}"
    if [[ "${TG_ENABLED:-false}" != "true" ]]; then
      echo "${C_YELLOW}注意：Telegram 未启用，改动会保存但暂不生效。${C_RESET}"
    fi
    echo
    echo "主用户（不可删除）：${C_CYAN}${TG_CHAT_ID:-未设置}${C_RESET}"
    echo "额外授权用户："

    extras=()
    for e in $(normalize_chat_ids "${TG_EXTRA_CHAT_IDS:-}"); do
      [[ "$e" == "${TG_CHAT_ID:-}" ]] && continue
      extras+=("$e")
    done

    if [[ "${#extras[@]}" -eq 0 ]]; then
      echo "  ${C_DIM}（无）${C_RESET}"
    else
      for i in "${!extras[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${extras[$i]}"
      done
    fi

    echo
    echo "  ${C_BOLD}a)${C_RESET} 添加   ${C_BOLD}d)${C_RESET} 删除   ${C_BOLD}0)${C_RESET} 返回"
    read -r -p "请选择: " op || true

    case "${op,,}" in
      a)
        read -r -p "输入要添加的 Chat ID（个人为正整数，群组可为负，回车取消）: " newid || true
        newid="${newid//[[:space:]]/}"
        [[ -n "$newid" ]] || { continue; }
        if ! [[ "$newid" =~ ^-?[0-9]+$ ]]; then
          echo "无效 Chat ID（应为整数）。"; sleep 1; continue
        fi
        if [[ "$newid" == "${TG_CHAT_ID:-}" ]]; then
          echo "该 ID 已是主用户，无需添加。"; sleep 1; continue
        fi
        if [[ " ${extras[*]} " == *" $newid "* ]]; then
          echo "该用户已在列表中：$newid"; sleep 1; continue
        fi
        TG_EXTRA_CHAT_IDS="$(normalize_chat_ids "${TG_EXTRA_CHAT_IDS:-} $newid")"
        save_env >/dev/null
        echo "${C_GREEN}已添加并保存：$newid${C_RESET}"; sleep 1
        ;;
      d)
        if [[ "${#extras[@]}" -eq 0 ]]; then
          echo "没有可删除的额外用户。"; sleep 1; continue
        fi
        read -r -p "输入要删除的序号或 Chat ID（回车取消）: " sel || true
        sel="${sel//[[:space:]]/}"
        [[ -n "$sel" ]] || { continue; }
        if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le "${#extras[@]}" ]]; then
          target="${extras[$((sel - 1))]}"
        else
          target="$sel"
        fi
        found=0
        local rebuilt=""
        for e in "${extras[@]}"; do
          if [[ "$e" == "$target" ]]; then found=1; continue; fi
          rebuilt+="${rebuilt:+ }$e"
        done
        if [[ "$found" -eq 0 ]]; then
          echo "未找到该用户：$target"; sleep 1; continue
        fi
        TG_EXTRA_CHAT_IDS="$rebuilt"
        save_env >/dev/null
        echo "${C_GREEN}已删除并保存：$target${C_RESET}"; sleep 1
        ;;
      0)
        return 0
        ;;
      *)
        echo "无效选择。"; sleep 1
        ;;
    esac
  done
}

# 校验图片：类型(png/jpg) + 字节范围 + 魔数 + 结尾标记（截断图会让 Telegram 报错）。
# 成功时输出 png / jpg，失败返回 1。
detect_valid_image_type() {
  local f="$1" bytes magic trailer
  [[ -f "$f" ]] || return 1
  bytes="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  [[ "$bytes" -ge "$PANEL_IMAGE_MIN_BYTES" && "$bytes" -le "$PANEL_IMAGE_MAX_BYTES" ]] || return 1

  magic="$(LC_ALL=C od -An -N8 -tx1 "$f" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    89504e470d0a1a0a*)
      trailer="$(LC_ALL=C tail -c 12 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
      [[ "$trailer" == "0000000049454e44ae426082" ]] || return 1
      printf 'png\n'
      ;;
    ffd8ff*)
      trailer="$(LC_ALL=C tail -c 2 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
      [[ "$trailer" == "ffd9" ]] || return 1
      printf 'jpg\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# 更换 Telegram 面板图片：支持图片直链 URL 或服务器本地路径，下载/读取→校验→
# 安装到 $BASE_DIR/panel_custom.<ext> 并写入 PANEL_IMAGE_FILE（升级不会覆盖）。
set_panel_image() {
  ensure_deps || return 1

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "尚未配置，请先选择 1 初始化/修改配置。"
    return 1
  fi

  load_env

  echo
  echo "=== 更换 Telegram 面板图片 ==="
  echo "支持：图片直链 URL（http/https）或服务器本地文件路径。"
  echo "要求：完整的 PNG 或 JPG，${PANEL_IMAGE_MIN_BYTES} 字节 ~ 10MB；建议横向、尺寸适中。"
  echo "输入 reset 可恢复内置默认图片；直接回车取消。"
  if [[ -n "${PANEL_IMAGE_FILE:-}" ]]; then
    echo "当前自定义图片：${PANEL_IMAGE_FILE}"
  else
    echo "当前：使用内置默认图片。"
  fi
  echo

  local src=""
  read -r -p "请输入图片 URL 或本地路径: " src || true
  src="${src#"${src%%[![:space:]]*}"}"   # 去掉首部空白
  src="${src%"${src##*[![:space:]]}"}"   # 去掉尾部空白
  [[ -n "$src" ]] || { echo "已取消。"; return 0; }

  case "${src,,}" in
    reset|default|-)
      rm -f "$BASE_DIR/${CUSTOM_PANEL_BASENAME}.png" "$BASE_DIR/${CUSTOM_PANEL_BASENAME}.jpg"
      PANEL_IMAGE_FILE=""
      save_env
      echo "已恢复为内置默认面板图片。"
      echo "提示：执行 sudo systemctl restart cf-ddns-bot.service 后下一次面板刷新即生效。"
      return 0
      ;;
  esac

  local tmp=""
  tmp="$(mktemp)"
  if [[ "$src" =~ ^https?:// ]]; then
    echo "正在下载图片..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp" "$src"; then
      rm -f "$tmp"
      echo "下载失败，请检查链接是否为图片直链、网络是否可达。"
      return 1
    fi
  elif [[ -f "$src" ]]; then
    cp -f "$src" "$tmp" 2>/dev/null || { rm -f "$tmp"; echo "读取本地文件失败：$src"; return 1; }
  else
    rm -f "$tmp"
    echo "无效输入：既不是 http(s) 链接，也不是存在的本地文件。"
    return 1
  fi

  local itype=""
  if ! itype="$(detect_valid_image_type "$tmp")"; then
    rm -f "$tmp"
    echo "图片校验未通过：必须是完整的 PNG 或 JPG，且大小在 ${PANEL_IMAGE_MIN_BYTES} 字节 ~ 10MB。"
    echo "（若你的图片确实有效，可用看图软件重新导出为标准 PNG/JPG 后再试。）"
    return 1
  fi

  # 只保留一种自定义图，避免新旧并存。
  rm -f "$BASE_DIR/${CUSTOM_PANEL_BASENAME}.png" "$BASE_DIR/${CUSTOM_PANEL_BASENAME}.jpg"
  local target="$BASE_DIR/${CUSTOM_PANEL_BASENAME}.${itype}"
  install -m 600 "$tmp" "$target"
  rm -f "$tmp"

  PANEL_IMAGE_FILE="$target"
  save_env
  chmod 700 "$BASE_DIR"

  echo "已更换面板图片：$target（${itype^^}，$(wc -c < "$target" | tr -d ' ') 字节）"
  echo "提示：执行 sudo systemctl restart cf-ddns-bot.service 后，发送 /panel 验证。"
  echo "若 Telegram 仍发不出图（尺寸/比例不符），Bot 会自动退回文字面板并记录原因。"
}

# 清理主域名上已不再维护的 AAAA 记录。
# 拆分 IPv6 域名（RECORD_NAME_V6）后，主域名原有的 AAAA 会变成孤儿：脚本不再更新它，
# 客户端却仍优先解析到那条过期地址，导致 ssh / 代理等全部连不上。
cleanup_orphan_aaaa() {
  ensure_deps || return 1

  if [[ ! -f "$ENV_FILE" ]]; then
    echo "尚未配置，请先选择 1 初始化/修改配置。"
    return 1
  fi
  load_env

  if [[ -z "${CF_API_TOKEN:-}" || -z "${ZONE_NAME:-}" ]]; then
    echo "Cloudflare 配置不完整，请先选择 1。"
    return 1
  fi

  if [[ -z "${RECORD_NAME_V6:-}" ]]; then
    echo "当前未拆分 IPv6 域名（RECORD_NAME_V6 为空）。"
    echo "主域名的 AAAA 由脚本正常维护，无需清理。"
    return 0
  fi

  local zone_resp zone_id
  zone_resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
    "$CF_API_BASE/zones?name=$(jq -rn --arg v "$ZONE_NAME" '$v|@uri')&status=active" \
    -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
  zone_id="$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  [[ -n "$zone_id" ]] || { echo "未找到 Zone：$ZONE_NAME"; return 1; }

  echo
  echo "正在检查主域名上残留的 AAAA 记录..."

  local raw name rec_resp rid content
  local -a ids=() labels=()
  raw="${RECORD_NAME// /,}"
  IFS=',' read -r -a _recs <<<"$raw"
  for name in "${_recs[@]}"; do
    [[ -n "$name" ]] || continue
    rec_resp="$(curl -fsS --connect-timeout 8 --max-time 20 \
      "$CF_API_BASE/zones/${zone_id}/dns_records?type=AAAA&name=$(jq -rn --arg v "$name" '$v|@uri')" \
      -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
    rid="$(printf '%s' "$rec_resp" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
    content="$(printf '%s' "$rec_resp" | jq -r '.result[0].content // empty' 2>/dev/null || true)"
    if [[ -n "$rid" ]]; then
      ids+=("$rid")
      labels+=("${name} AAAA ${content}")
    fi
  done

  if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "  ${C_GREEN}✓${C_RESET} 主域名上没有残留 AAAA，无需清理。"
    return 0
  fi

  echo
  echo "${C_YELLOW}发现以下 AAAA 记录已不再由脚本维护（IPv6 现由 ${RECORD_NAME_V6} 承载）：${C_RESET}"
  local i
  for i in "${!labels[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${labels[$i]}"
  done
  echo
  echo "删除它们后，主域名将只保留 A 记录（客户端不再优先走 IPv6）。"
  read -r -p "请输入大写 YES 确认删除: " ans || true
  if [[ "$ans" != "YES" ]]; then
    echo "已取消。"
    return 0
  fi

  local del_resp ok=0 fail=0
  for i in "${!ids[@]}"; do
    del_resp="$(curl -fsS --connect-timeout 8 --max-time 20 -X DELETE \
      "$CF_API_BASE/zones/${zone_id}/dns_records/${ids[$i]}" \
      -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null || true)"
    if printf '%s' "$del_resp" | jq -e '.success == true' >/dev/null 2>&1; then
      echo "  ${C_GREEN}✓${C_RESET} 已删除：${labels[$i]}"
      ok=$((ok + 1))
    else
      echo "  ${C_RED}✗${C_RESET} 删除失败：${labels[$i]}"
      fail=$((fail + 1))
    fi
  done
  echo
  echo "完成：成功 ${ok} 条，失败 ${fail} 条。DNS 缓存最多需等待 TTL 过期生效。"
}

show_status() {
  migrate_legacy_schedule
  echo
  echo "=== 链路一：cron 换 IP + DDNS ==="
  if [[ -f "$ROTATE_CRON_FILE" ]]; then
    cat "$ROTATE_CRON_FILE"
  elif [[ -f "$ROTATE_CRON_DISABLED_FILE" ]]; then
    echo "链路一已停用，保留的配置："
    cat "$ROTATE_CRON_DISABLED_FILE"
  else
    echo "链路一尚未安装。"
  fi

  echo
  echo "=== 链路二：systemd timer 仅 DDNS ==="
  systemctl status cf-ddns.timer --no-pager || true

  echo
  echo "=== cron service ==="
  systemctl status cron --no-pager || true

  echo
  echo "=== telegram bot service ==="
  systemctl status cf-ddns-bot.service --no-pager || true

  echo
  echo "注意：DDNS 日志可能包含真实域名、旧 IP、新 IP。"
  read -r -p "是否显示最近 80 行日志？[y/N]: " ans || true
  ans="${ans:-N}"

  case "${ans,,}" in
    y|yes)
      echo
      echo "=== recent log: $LOG_FILE ==="
      if [[ -f "$LOG_FILE" ]]; then
        tail -n 80 "$LOG_FILE"
      else
        echo "暂无日志。"
      fi
      ;;
    *)
      echo "已跳过日志显示。"
      ;;
  esac
}

follow_log() {
  if command -v journalctl >/dev/null 2>&1; then
    echo "实时跟随 Bot 服务日志，按 Ctrl+C 退出。"
    journalctl -fu cf-ddns-bot.service --no-pager || true
  elif [[ -f "$LOG_FILE" ]]; then
    echo "实时跟随 $LOG_FILE，按 Ctrl+C 退出。"
    tail -f "$LOG_FILE" || true
  else
    echo "暂无可跟随的日志。"
  fi
}

disable_schedules() {
  while true; do
    clear 2>/dev/null || true
    echo "${C_BOLD}${C_CYAN}=== 停用自动链路 ===${C_RESET}"
    echo "  a) 停用链路一：cron 换 IP + DDNS"
    echo "  b) 停用链路二：systemd timer 仅 DDNS"
    echo "  c) 停用两条链路"
    echo "  0) 返回上级面板"
    echo
    read -r -p "请选择: " choice || true
    case "$choice" in
      a|A)
        migrate_legacy_schedule
        [[ -f "$ROTATE_CRON_FILE" ]] && mv "$ROTATE_CRON_FILE" "$ROTATE_CRON_DISABLED_FILE"
        echo "已停用链路一；表达式已保留。"
        pause
        ;;
      b|B)
        systemctl disable --now cf-ddns.timer 2>/dev/null || true
        echo "已停用链路二；service/timer 文件和间隔配置仍保留。"
        pause
        ;;
      c|C)
        migrate_legacy_schedule
        [[ -f "$ROTATE_CRON_FILE" ]] && mv "$ROTATE_CRON_FILE" "$ROTATE_CRON_DISABLED_FILE"
        systemctl disable --now cf-ddns.timer 2>/dev/null || true
        echo "已停用两条自动链路。"
        pause
        ;;
      0) return 0 ;;
      *) echo "无效选择。"; sleep 1 ;;
    esac
  done
}

disable_bot_service() {
  systemctl disable --now cf-ddns-bot.service 2>/dev/null || true
  systemctl daemon-reload
  echo "已停用 cf-ddns-bot.service；配置和脚本仍保留。"
}

update_self() {
  if [[ -z "$INSTALL_URL" ]]; then
    echo "尚未配置整合版 GitHub 更新地址。"
    echo "请设置 DDNS_INSTALL_URL，或使用带 RAW_BASE 的 install-online.sh 重新安装。"
    return 1
  fi

  echo "将从 GitHub 拉取最新版本并覆盖安装："
  echo "  $INSTALL_URL"
  read -r -p "确认更新？[y/N]: " ans || true
  case "${ans,,}" in
    y|yes)
      local update_raw_base="${INSTALL_URL%/install-online.sh}"
      if curl -fsSL "${INSTALL_URL}?v=$(date +%s)" | RAW_BASE="$update_raw_base" bash; then
        echo "更新完成。请重新执行 ddns 进入最新菜单。"
        exit 0
      else
        echo "更新失败，请检查网络或稍后重试。"
        return 1
      fi
      ;;
    *)
      echo "已取消更新。"
      ;;
  esac
}

uninstall_all() {
  echo "${C_RED}${C_BOLD}警告：这将彻底卸载并清理以下内容：${C_RESET}"
  echo "  - systemd 单元：cf-ddns.timer / cf-ddns.service / cf-ddns-bot.service"
  echo "  - 目录：$BASE_DIR（含配置与密钥）"
  echo "  - 命令软链：$BIN_LINK"
  echo "  - 日志：$LOG_FILE"
  read -r -p "请输入大写 YES 确认卸载: " ans || true
  if [[ "$ans" != "YES" ]]; then
    echo "已取消卸载。"
    return 0
  fi

  systemctl disable --now cf-ddns.timer 2>/dev/null || true
  systemctl disable --now cf-ddns-bot.service 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE" "$BOT_SERVICE_FILE" \
    "$ROTATE_CRON_FILE" "$ROTATE_CRON_DISABLED_FILE" \
    "$LEGACY_CRON_FILE" "$LEGACY_CRON_DISABLED_FILE"
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$BIN_LINK"
  rm -f "$LOG_FILE"
  rm -rf "$BASE_DIR"

  echo "${C_GREEN}已完成卸载与清理。${C_RESET}"
  exit 0
}

status_summary() {
  local rotate_active="inactive" ddns_timer bot rotate_state

  migrate_legacy_schedule
  [[ -f "$ROTATE_CRON_FILE" ]] && rotate_active="active"
  ddns_timer="$(systemctl is-active cf-ddns.timer 2>/dev/null || true)"
  bot="$(systemctl is-active cf-ddns-bot.service 2>/dev/null || true)"

  load_env
  if [[ "${IP_CHANGE_ENABLED:-false}" == "true" ]]; then
    rotate_state="API 已启用"
  else
    rotate_state="API 未启用"
  fi

  local rotate_disp timer_disp bot_disp
  if [[ "$rotate_active" == "active" ]]; then rotate_disp="${C_GREEN}● 换 IP cron active${C_RESET}"; else rotate_disp="${C_RED}○ 换 IP cron inactive${C_RESET}"; fi
  if [[ "$ddns_timer" == "active" ]]; then timer_disp="${C_GREEN}● DDNS timer active${C_RESET}"; else timer_disp="${C_RED}○ DDNS timer ${ddns_timer:-inactive}${C_RESET}"; fi
  if [[ "$bot" == "active" ]]; then bot_disp="${C_GREEN}● Bot active${C_RESET}"; else bot_disp="${C_RED}○ Bot ${bot:-inactive}${C_RESET}"; fi

  local record_disp
  if [[ -n "${RECORD_NAME:-}" ]]; then
    record_disp="${C_CYAN}${RECORD_TYPE:-A} ${RECORD_NAME}${C_RESET}"
  else
    record_disp="${C_YELLOW}未配置记录${C_RESET}"
  fi

  printf '  %s   %s   %s\n' "$rotate_disp" "$timer_disp" "$bot_disp"
  printf '  链路一：%s；cron=%s\n' "$rotate_state" "${ROTATE_CRON_EXPRESSION:-未读取}"
  printf '  链路二：仅 DDNS；间隔=%s 分钟\n' "${DDNS_TIMER_INTERVAL_MINUTES:-5}"
  printf '  记录：%s\n' "$record_disp"
}

print_menu() {
  clear 2>/dev/null || true
  echo "${C_BOLD}${C_CYAN}╔══════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}${C_CYAN}║      Cloudflare DDNS 交互管理面板     ║${C_RESET}"
  echo "${C_BOLD}${C_CYAN}╚══════════════════════════════════════╝${C_RESET}"
  status_summary
  echo "${C_DIM}  配置：$ENV_FILE${C_RESET}"
  echo
  echo "  ${C_BOLD}1)${C_RESET} 初始化/修改 Cloudflare 与 Telegram 配置"
  echo "  ${C_BOLD}2)${C_RESET} 立即运行一次 DDNS 检测"
  echo "  ${C_BOLD}3)${C_RESET} 配置两条自动链路（cron 换 IP / timer DDNS）"
  echo "  ${C_BOLD}4)${C_RESET} 查看状态与日志"
  echo "  ${C_BOLD}5)${C_RESET} 测试 Telegram 通知"
  echo "  ${C_BOLD}6)${C_RESET} 停用自动链路（可分别停用）"
  echo "  ${C_BOLD}7)${C_RESET} 后台调用换 IP API 并更新 DDNS（SSH 可断开）"
  echo "  ${C_BOLD}8)${C_RESET} 安装/更新 Telegram Bot 命令服务"
  echo "  ${C_BOLD}9)${C_RESET} 停用 Telegram Bot 命令服务"
  echo "  ${C_BOLD}c)${C_RESET} 管理授权用户（多人共用 Chat ID）"
  echo "  ${C_BOLD}i)${C_RESET} 更换 Telegram 面板图片"
  echo "  ${C_BOLD}v)${C_RESET} 清理主域名残留的 AAAA 记录"
  echo "  ${C_BOLD}l)${C_RESET} 实时跟随日志"
  echo "  ${C_BOLD}u)${C_RESET} 更新到最新版本"
  echo "  ${C_BOLD}x)${C_RESET} ${C_RED}彻底卸载并清理${C_RESET}"
  echo "  ${C_BOLD}0)${C_RESET} 退出"
  echo
}

main() {
  require_root
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"

  while true; do
    print_menu
    read -r -p "请选择操作: " choice || true

    case "$choice" in
      1) configure_env; pause ;;
      2) run_once; pause ;;
      3) configure_schedules ;;
      4) show_status; pause ;;
      5) test_telegram; pause ;;
      6) disable_schedules ;;
      7) change_ip_once ;;
      8) install_bot_service; pause ;;
      9) disable_bot_service; pause ;;
      c|C) manage_chat_ids ;;
      i|I) set_panel_image; pause ;;
      v|V) cleanup_orphan_aaaa; pause ;;
      l|L) follow_log; pause ;;
      u|U) update_self; pause ;;
      x|X) uninstall_all; pause ;;
      0) exit 0 ;;
      *) echo "无效选择。"; sleep 1 ;;
    esac
  done
}

main "$@"
