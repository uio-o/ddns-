#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/usr/local/ddns"
ENV_FILE="$BASE_DIR/cf_ddns.env"
LOG_FILE="/var/log/cf_ddns.log"
LOCK_FILE="/run/cf-ddns.lock"
BOT_WORKER="$BASE_DIR/cf_ddns_bot.sh"
CF_API_BASE="https://api.cloudflare.com/client/v4"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-2097152}"   # 2 MiB，超过则只保留最后 1000 行

# 公网 IP 检测的整组重试：换 IP 瞬间出口 NAT 链路会短暂重建，
# 单次查询很容易失败。整组数据源轮询失败后等待数秒再重试，
# 避免一次网络空窗就让本轮检测整轮作废。
IP_LOOKUP_ROUNDS="${IP_LOOKUP_ROUNDS:-3}"
IP_LOOKUP_RETRY_GAP="${IP_LOOKUP_RETRY_GAP:-3}"

# 公网 IP 数据源（多源容错，任一可用即可）。
PUBLIC_IP4_SOURCES=(
  "https://api.ipify.org"
  "https://ipv4.icanhazip.com"
  "https://ifconfig.me/ip"
)
PUBLIC_IP6_SOURCES=(
  "https://api6.ipify.org"
  "https://ipv6.icanhazip.com"
  "https://ifconfig.co/ip"
)

log() {
  local message="$1"
  # 控制台副本写到 stderr：update_one_record 通过 $(...) 捕获 stdout 来判断
  # “本条记录是否有变更”，若 log 也写 stdout，未变化的“IP 未变化”日志会被
  # 误当成变更，导致每轮都推送面板。写到 stderr 即可两不相扰（日志文件照常写入）。
  printf '[%s] %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE" >&2
}

die() {
  log "错误：$1"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"
}

# 日志轮转：超过上限只保留最后 1000 行，避免无限增长。
cap_log_file() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  if [[ "$size" -gt "$MAX_LOG_BYTES" ]]; then
    local tmp
    tmp="$(mktemp)"
    tail -n 1000 "$LOG_FILE" > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$LOG_FILE" 2>/dev/null || true
    rm -f "$tmp"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
}

# 所有通知目标 Chat ID：主 ID + 额外 ID（TG_EXTRA_CHAT_IDS，逗号/空格分隔），去重。
tg_chat_ids() {
  local raw="${TG_CHAT_ID:-} ${TG_EXTRA_CHAT_IDS:-}"
  raw="${raw//,/ }"
  local id seen=" "
  for id in $raw; do
    [[ -n "$id" ]] || continue
    [[ "$seen" == *" $id "* ]] && continue
    seen+="$id "
    printf '%s\n' "$id"
  done
}

send_telegram() {
  local text="$1"

  if [[ "${TG_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    log "Telegram 已启用但配置不完整，跳过推送。"
    return 0
  fi

  local cid
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    if ! curl -fsS --retry 3 --connect-timeout 5 --max-time 20 \
      -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${cid}" \
      --data-urlencode "text=$text" \
      >/dev/null; then
      log "Telegram 推送失败（${cid}）。"
    fi
  done < <(tg_chat_ids)
}

send_telegram_panel() {
  local note="$1"

  if [[ "${TG_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  if [[ -x "$BOT_WORKER" ]]; then
    if bash "$BOT_WORKER" --send-panel "$note" >/dev/null 2>&1; then
      return 0
    fi
    log "Telegram 面板推送失败，改发普通文字通知。"
  fi

  send_telegram "$note"
}

# 额外群聊只接收 DDNS 变更通知，不加入管理员白名单，也不经过 Bot 命令处理。
send_telegram_groups() {
  local text="$1"
  local raw="${TG_GROUP_CHAT_IDS:-}"
  local cid

  [[ "${TG_GROUP_ENABLED:-false}" == "true" ]] || return 0
  [[ -n "${TG_GROUP_BOT_TOKEN:-}" && -n "$raw" ]] || return 0
  if [[ -n "${TG_BOT_TOKEN:-}" && "$TG_GROUP_BOT_TOKEN" == "$TG_BOT_TOKEN" ]]; then
    log "拒绝群通知：TG_GROUP_BOT_TOKEN 不能与管理员 TG_BOT_TOKEN 相同。"
    return 0
  fi

  raw="${raw//,/ }"
  for cid in $raw; do
    [[ -n "$cid" ]] || continue
    if ! curl -fsS --retry 3 --connect-timeout 5 --max-time 20 \
      -X POST "https://api.telegram.org/bot${TG_GROUP_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${cid}" \
      --data-urlencode "text=$text" \
      --data-urlencode "disable_notification=${TG_GROUP_SILENT:-false}" \
      >/dev/null; then
      log "Telegram 群通知失败（${cid}）。"
    fi
  done
}

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -fsS --retry 3 --connect-timeout 8 --max-time 30 \
      -X "$method" "$CF_API_BASE$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS --retry 3 --connect-timeout 8 --max-time 30 \
      -X "$method" "$CF_API_BASE$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

json_success() {
  jq -e '.success == true' >/dev/null
}

urlencode() {
  jq -rn --arg value "$1" '$value|@uri'
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }

# 把 RECORD_TYPE 解析成要处理的记录类型列表（每行一个）。
# 支持 A、AAAA、BOTH（=A 与 AAAA 双栈，同一域名可同时存在两种记录）。
resolve_record_types() {
  local raw="${1:-A}"
  case "${raw^^}" in
    A)               printf 'A\n' ;;
    AAAA)            printf 'AAAA\n' ;;
    BOTH|DUAL|A,AAAA|AAAA,A|"A AAAA"|"AAAA A")
                     printf 'A\nAAAA\n' ;;
    *)               return 1 ;;
  esac
}

# 本机是否存在全局作用域的 IPv6 地址。用于双栈模式下快速跳过 AAAA，
# 避免纯 IPv4 机器每轮都把 IPv6 数据源重试满（浪费时间并刷日志）。
# 没有 ip 命令时返回成功，交由实际探测判断。
host_has_ipv6() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

# 根据记录类型获取公网 IP，多源轮询并整组重试。
# 失败时只返回非 0（不调用 die），由 main 跳过本轮并等待下个周期重试，
# 避免一次瞬时网络抖动直接中止整个脚本（set -e）而废掉整轮检测。
get_public_ip() {
  local record_type="${1:-A}"
  local sources=() curl_proto ip src round

  if [[ "$record_type" == "AAAA" ]]; then
    sources=("${PUBLIC_IP6_SOURCES[@]}")
    curl_proto="-6"
  else
    sources=("${PUBLIC_IP4_SOURCES[@]}")
    curl_proto="-4"
  fi

  for ((round = 1; round <= IP_LOOKUP_ROUNDS; round++)); do
    for src in "${sources[@]}"; do
      ip="$(curl -fsS "$curl_proto" --retry 2 --connect-timeout 5 --max-time 10 "$src" 2>/dev/null | tr -d '[:space:]')" || true
      if [[ "$record_type" == "AAAA" ]]; then
        is_ipv6 "$ip" && { printf '%s\n' "$ip"; return 0; }
      else
        is_ipv4 "$ip" && { printf '%s\n' "$ip"; return 0; }
      fi
    done
    [[ "$round" -lt "$IP_LOOKUP_ROUNDS" ]] && sleep "$IP_LOOKUP_RETRY_GAP"
  done

  # 注意：重定向到 stderr，避免污染调用处 $(get_public_ip) 捕获的标准输出。
  log "无法从任一数据源获取有效公网 ${record_type} 地址（已重试 ${IP_LOOKUP_ROUNDS} 轮）。" >&2
  return 1
}

# 把 RECORD_NAME 拆成数组（支持逗号/空格分隔的多条记录）。
split_records() {
  local raw="$1"
  raw="${raw//,/ }"
  printf '%s\n' $raw
}

# 取某协议族要更新的记录域名（每行一个）。
# AAAA 可用 RECORD_NAME_V6 单独指定；留空则沿用 RECORD_NAME（普通双栈同名）。
# 拆开的用处：让主域名只保留 A 记录，客户端/探针就不会优先走较慢的 IPv6 线路。
records_for_type() {
  local t="$1"
  if [[ "$t" == "AAAA" && -n "${RECORD_NAME_V6:-}" ]]; then
    split_records "$RECORD_NAME_V6"
  else
    split_records "${RECORD_NAME:-}"
  fi
}

# 更新单条记录；输出一行变更摘要供汇总，未变化则不输出。
update_one_record() {
  local zone_id="$1" record_name="$2" record_type="$3" current_ip="$4"
  local record_query record_resp record_id old_ip payload resp
  local old_ttl old_proxied want_ttl want_proxied settings_drift

  record_query="$(urlencode "$record_name")"
  record_resp="$(cf_api GET "/zones/${zone_id}/dns_records?type=${record_type}&name=${record_query}")" \
    || { log "查询 DNS 记录失败：$record_name（$record_type）"; return 1; }
  printf '%s' "$record_resp" | json_success \
    || { log "DNS 记录查询未成功（$record_name $record_type）：$(printf '%s' "$record_resp" | jq -r '.errors[0].message // "未知错误"')"; return 1; }

  record_id="$(printf '%s' "$record_resp" | jq -r '.result[0].id // empty')"
  old_ip="$(printf '%s' "$record_resp" | jq -r '.result[0].content // empty')"
  old_ttl="$(printf '%s' "$record_resp" | jq -r '.result[0].ttl // empty')"
  old_proxied="$(printf '%s' "$record_resp" | jq -r '.result[0].proxied // false')"
  want_ttl="${TTL:-120}"
  want_proxied="${PROXY:-false}"

  payload="$(jq -n \
    --arg type "$record_type" \
    --arg name "$record_name" \
    --arg content "$current_ip" \
    --argjson ttl "${TTL:-120}" \
    --argjson proxied "${PROXY:-false}" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"

  if [[ -z "$record_id" ]]; then
    resp="$(cf_api POST "/zones/${zone_id}/dns_records" "$payload")" \
      || { log "创建 DNS 记录失败：$record_name（$record_type）"; return 1; }
    printf '%s' "$resp" | json_success \
      || { log "创建 DNS 记录未成功（$record_name $record_type）：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"')"; return 1; }
    log "已创建 $record_name（$record_type） -> $current_ip"
    printf '已创建 %s（%s） -> %s\n' "$record_name" "$record_type" "$current_ip"
    return 0
  fi

  if [[ "$old_ip" == "$current_ip" ]]; then
    # IP 一致时仍检查 TTL / proxied 是否与配置一致：手动创建的记录常是 TTL=自动，
    # 若只在 IP 变化时才 PUT，这类设置永远得不到纠正。
    # 注意：proxied=true 时 Cloudflare 强制 ttl=1，故此时不比较 TTL，避免每轮都下发 PUT。
    settings_drift="false"
    [[ "$old_proxied" != "$want_proxied" ]] && settings_drift="true"
    if [[ "$want_proxied" != "true" && -n "$old_ttl" && "$old_ttl" != "$want_ttl" ]]; then
      settings_drift="true"
    fi

    if [[ "$settings_drift" != "true" ]]; then
      log "$record_name（$record_type） IP 未变化：$current_ip"
      return 0
    fi

    resp="$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")" \
      || { log "校正 DNS 记录设置失败：$record_name（$record_type）"; return 1; }
    printf '%s' "$resp" | json_success \
      || { log "校正 DNS 记录设置未成功（$record_name $record_type）：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"')"; return 1; }
    log "已校正 $record_name（$record_type）设置：TTL ${old_ttl} -> ${want_ttl}，proxied ${old_proxied} -> ${want_proxied}（IP 未变）"
    # 不输出到 stdout：这不是 IP 变更，不触发 Telegram 推送。
    return 0
  fi

  resp="$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")" \
    || { log "更新 DNS 记录失败：$record_name（$record_type）"; return 1; }
  printf '%s' "$resp" | json_success \
    || { log "更新 DNS 记录未成功（$record_name $record_type）：$(printf '%s' "$resp" | jq -r '.errors[0].message // "未知错误"')"; return 1; }
  log "已更新 $record_name（$record_type）：$old_ip -> $current_ip"
  printf '已更新 %s（%s）：%s -> %s\n' "$record_name" "$record_type" "$old_ip" "$current_ip"
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd flock

  [[ -f "$ENV_FILE" ]] || die "找不到配置文件：$ENV_FILE，请先执行 ddns 初始化配置。"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  local record_type="${RECORD_TYPE:-A}"
  local -a types=()
  local _t
  while IFS= read -r _t; do
    [[ -n "$_t" ]] && types+=("$_t")
  done < <(resolve_record_types "$record_type" || true)
  [[ "${#types[@]}" -gt 0 ]] || die "RECORD_TYPE 必须是 A、AAAA 或 BOTH。"
  local dual="false"
  [[ "${#types[@]}" -gt 1 ]] && dual="true"

  [[ -n "${CF_API_TOKEN:-}" ]] || die "CF_API_TOKEN 不能为空。"
  [[ -n "${ZONE_NAME:-}" ]] || die "ZONE_NAME 不能为空。"
  [[ -n "${RECORD_NAME:-}" ]] || die "RECORD_NAME 不能为空。"
  [[ "${TTL:-120}" =~ ^[0-9]+$ ]] || die "TTL 必须是数字。"
  [[ "${PROXY:-false}" == "true" || "${PROXY:-false}" == "false" ]] || die "PROXY 必须是 true 或 false。"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个 DDNS 任务正在运行。"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  cap_log_file

  # 先逐个协议族探测公网 IP：某一族失败只跳过该族，不影响另一族（双栈关键）。
  # 全部失败才跳过本轮，且此时不必再去查 Cloudflare Zone。
  local zone_query zone_resp zone_id ip
  local -a ok_types=() ok_ips=()
  for _t in "${types[@]}"; do
    if [[ "$_t" == "AAAA" && "$dual" == "true" ]] && ! host_has_ipv6; then
      log "跳过 AAAA：本机没有全局 IPv6 地址。"
      continue
    fi
    if ip="$(get_public_ip "$_t")"; then
      ok_types+=("$_t")
      ok_ips+=("$ip")
    else
      log "跳过 ${_t} 记录：暂时无法获取公网 ${_t} 地址，等待下个周期重试。"
    fi
  done

  if [[ "${#ok_types[@]}" -eq 0 ]]; then
    log "本轮 DDNS 跳过：未能获取任何公网地址，等待下个周期重试。"
    return 0
  fi

  zone_query="$(urlencode "$ZONE_NAME")"

  zone_resp="$(cf_api GET "/zones?name=${zone_query}&status=active")" || die "查询 Cloudflare Zone 失败。"
  printf '%s' "$zone_resp" | json_success || die "Cloudflare Zone 查询未成功：$(printf '%s' "$zone_resp" | jq -r '.errors[0].message // "未知错误"')"
  zone_id="$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || die "未找到 Zone：$ZONE_NAME"

  # 对每个成功探测到的协议族 × 该族的记录名各更新一次。
  # AAAA 可用 RECORD_NAME_V6 指定不同域名（留空则与 A 同名，即普通双栈）。
  local changes="" line rc=0 idx
  local record _r
  local -a records=()
  for idx in "${!ok_types[@]}"; do
    records=()
    while IFS= read -r _r; do
      [[ -n "$_r" ]] && records+=("$_r")
    done < <(records_for_type "${ok_types[$idx]}")

    if [[ "${#records[@]}" -eq 0 ]]; then
      log "跳过 ${ok_types[$idx]}：未配置对应的记录域名。"
      continue
    fi

    for record in "${records[@]}"; do
      [[ -n "$record" ]] || continue
      if line="$(update_one_record "$zone_id" "$record" "${ok_types[$idx]}" "${ok_ips[$idx]}")"; then
        [[ -n "$line" ]] && changes+="${line}"$'\n'
      else
        rc=1
      fi
    done
  done

  if [[ -n "$changes" ]]; then
    local change_note="DDNS 变更：
${changes%$'\n'}"
    send_telegram_panel "$change_note"
    send_telegram_groups "$change_note"
  fi

  return "$rc"
}

main "$@"
