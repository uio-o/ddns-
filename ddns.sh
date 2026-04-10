#!/bin/bash

# Cloudflare DDNS Script
# 修订版：重写了 IPv4/v6 获取逻辑，增强多环境适应性（无视奇葩网卡绑定）

# 检查依赖项是否存在，如不存在则尝试自动安装
check_dependencies() {
    missing_dependencies=""
    for dependency in curl wget awk sed grep; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            missing_dependencies="$missing_dependencies $dependency"
        fi
    done

    if [ -n "$missing_dependencies" ]; then
        echo "[提示]缺少依赖项：$missing_dependencies"
        echo "[提示]正在尝试自动安装依赖项..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update
            apt-get install -y $missing_dependencies
        elif command -v yum >/dev/null 2>&1; then
            yum install -y $missing_dependencies
        elif command -v apk >/dev/null 2>&1; then
            apk add $missing_dependencies
        else
            echo "[错误]无法自动安装依赖项，请手动安装后重试。"
            exit 1
        fi
        echo "[信息]依赖项安装完成！"
    fi
}

check_dependencies

config_file="/etc/DDNS/.config"

# 检查配置文件是否存在，如果不存在则进入向导
if [ ! -f "$config_file" ]; then
    echo "[提示]DDNS 未配置文件，现在开始配置..."
    mkdir -p /etc/DDNS
    
    echo ""
    read -p "请输入您的Cloudflare邮箱: " CF_Email
    echo "[信息]你的邮箱：$CF_Email"
    echo ""
    read -p "请输入您的Cloudflare API密钥: " CF_Key
    echo "[信息]你的密钥：$CF_Key"
    
    echo ""
    read -p "请输入您的 Telegram Bot Token，如果不使用 请直接按 Enter 跳过: " TG_Bot_Token
    if [ -n "$TG_Bot_Token" ]; then
        read -p "请输入您的 Telegram Chat ID: " TG_Chat_ID
        echo "[信息]Telegram 配置已录入。"
    else
        echo "[信息]跳过 Telegram 通知配置。"
    fi

    # 生成基础配置文件
    cat <<EOF > "$config_file"
# 多域名支持
Domains=()     # 你要解析的IPv4域名数组
Domains6=()    # 你要解析的IPv6域名数组

# Cloudflare 凭证
Email="$CF_Email"
Key="$CF_Key"

# Telegram通知配置
TG_Bot_Token="$TG_Bot_Token"
TG_Chat_ID="$TG_Chat_ID"

# IP 记录
Old_Public_IPv4=""
Old_Public_IPv6=""
EOF

    echo -e "\n[提示]接下来配置需要解析的域名。"
    
    # 引导添加 IPv4 域名
    read -p "是否需要配置 IPv4 域名解析？(y/n): " opt_v4
    if [[ "$opt_v4" == "y" || "$opt_v4" == "Y" ]]; then
        read -p "请输入要解析的 IPv4 域名 (多个域名用空格隔开): " input_domains
        if [ -n "$input_domains" ]; then
            # 转换为数组格式替换
            formatted_domains=$(echo "$input_domains" | awk '{for(i=1;i<=NF;i++) printf "\"%s\" ", $i}' | sed 's/ $//')
            sed -i "s/^Domains=().*/Domains=(${formatted_domains})/" "$config_file"
            echo "[信息]IPv4 域名已记录。"
        fi
    fi

    # 引导添加 IPv6 域名
    read -p "是否需要配置 IPv6 域名解析？(y/n): " opt_v6
    if [[ "$opt_v6" == "y" || "$opt_v6" == "Y" ]]; then
        read -p "请输入要解析的 IPv6 域名 (多个域名用空格隔开): " input_domains6
        if [ -n "$input_domains6" ]; then
            formatted_domains6=$(echo "$input_domains6" | awk '{for(i=1;i<=NF;i++) printf "\"%s\" ", $i}' | sed 's/ $//')
            sed -i "s/^Domains6=().*/Domains6=(${formatted_domains6})/" "$config_file"
            echo "[信息]IPv6 域名已记录。"
        fi
    fi

    # 添加 crontab 任务
    echo "[信息]创建 ddns 定时任务..."
    script_path=$(readlink -f "$0")
    if ! crontab -l 2>/dev/null | grep -q "$script_path"; then
        (crontab -l 2>/dev/null; echo "* * * * * bash $script_path >> /var/log/ddns.log 2>&1") | crontab -
        echo "[信息]ddns 定时任务已创建，每1分钟执行一次！"
    fi

    echo "[信息]配置完成！系统将开始首次执行同步。"
    sleep 2
fi

# 开始主执行逻辑
source "$config_file"

Public_IPv4=""
Public_IPv6=""
ipv4Regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
ipv6Regex="^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$"

# ==========================================================
# [修改版] 核心高可用获取全局 IP 逻辑 (不再绑定具体的 interface 名)
# ==========================================================

# 尝试获取 IPv4
temp_ipv4=$(curl -s -4 --max-time 5 icanhazip.com || true)
if [[ -z "$temp_ipv4" ]]; then
    temp_ipv4=$(curl -s -4 --max-time 5 ifconfig.me/ip || true)
fi
if [[ -z "$temp_ipv4" ]]; then
    temp_ipv4=$(curl -s -4 --max-time 5 api.ipify.org || true)
fi
if [[ -n "$temp_ipv4" && "$temp_ipv4" =~ $ipv4Regex ]]; then
    Public_IPv4="$temp_ipv4"
fi

# 尝试获取 IPv6 (过滤掉常见的内网/非全局 IPv6 前缀)
temp_ipv6=$(curl -s -6 --max-time 5 icanhazip.com | grep -E -v '^(2a09|104\.28|fe80|fd)' || true)
if [[ -z "$temp_ipv6" ]]; then
    temp_ipv6=$(curl -s -6 --max-time 5 ifconfig.co/ip | grep -E -v '^(2a09|104\.28|fe80|fd)' || true)
fi
if [[ -n "$temp_ipv6" && "$temp_ipv6" =~ $ipv6Regex ]]; then
    Public_IPv6="$temp_ipv6"
fi

# ==========================================================

# 发送 Telegram 通知函数
send_telegram_notification() {
    local message="$1"
    if [[ -n "$TG_Bot_Token" && -n "$TG_Chat_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_Bot_Token/sendMessage" \
            -d "chat_id=$TG_Chat_ID" \
            -d "text=$message" > /dev/null 2>&1
    fi
}

# 更新 IPv4
if [ -n "$Public_IPv4" ] && [ ${#Domains[@]} -gt 0 ]; then
    if [ "$Public_IPv4" != "$Old_Public_IPv4" ]; then
        for Domain in "${Domains[@]}"; do
            Root_domain=$(echo "$Domain" | awk -F '.' '{print $(NF-1)"."$NF}')
            
            # 获取Zone ID
            Zone_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain&status=active" \
                -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            
            # 获取Record ID
            Record_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records?type=A&name=$Domain" \
                -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            
            # 执行更新
            if [[ -n "$Record_ID" ]]; then
                update_result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records/$Record_ID" \
                    -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" \
                    --data '{"type":"A","name":"'"$Domain"'","content":"'"$Public_IPv4"'","ttl":1,"proxied":false}')
                    
                if echo "$update_result" | grep -q '"success":true'; then
                    echo "[INFO] $Domain (IPv4) successfully updated to $Public_IPv4."
                    send_telegram_notification "Cloudflare DDNS Update (IPv4)%0A------------------------%0ADomain: $Domain%0ANew IP: $Public_IPv4"
                else
                    echo "[ERROR] Failed to update $Domain (IPv4)."
                fi
            else
                echo "[ERROR] DNS Record not found for $Domain. Create it manually first."
            fi
        done
        sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=$Public_IPv4/" "$config_file"
    else
        echo "[INFO] IPv4 has not changed ($Public_IPv4). No update needed."
    fi
fi

# 更新 IPv6
if [ -n "$Public_IPv6" ] && [ ${#Domains6[@]} -gt 0 ]; then
    if [ "$Public_IPv6" != "$Old_Public_IPv6" ]; then
        for Domain in "${Domains6[@]}"; do
            Root_domain=$(echo "$Domain" | awk -F '.' '{print $(NF-1)"."$NF}')
            
            Zone_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain&status=active" \
                -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            
            Record_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records?type=AAAA&name=$Domain" \
                -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            
            if [[ -n "$Record_ID" ]]; then
                update_result=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records/$Record_ID" \
                    -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" \
                    --data '{"type":"AAAA","name":"'"$Domain"'","content":"'"$Public_IPv6"'","ttl":1,"proxied":false}')
                    
                if echo "$update_result" | grep -q '"success":true'; then
                    echo "[INFO] $Domain (IPv6) successfully updated to $Public_IPv6."
                    send_telegram_notification "Cloudflare DDNS Update (IPv6)%0A------------------------%0ADomain: $Domain%0ANew IP: $Public_IPv6"
                else
                    echo "[ERROR] Failed to update $Domain (IPv6)."
                fi
            else
                echo "[ERROR] AAAA Record not found for $Domain. Create it manually first."
            fi
        done
        sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=$Public_IPv6/" "$config_file"
    else
        echo "[INFO] IPv6 has not changed ($Public_IPv6). No update needed."
    fi
fi
