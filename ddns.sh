#!/bin/bash
# 修复核心版 Cloudflare DDNS 
# 特性：防呆极客交互 / 鲜明色彩 / IP前置探测 / 状态记忆判断

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
bold_magenta='\e[1;95m'
bold_green='\e[1;92m'
none='\e[0m'
config_file="/etc/DDNS/.config"

# ==============================================================
# 安装/更新执行体：自动全局接管
# ==============================================================
if [[ "$0" != "/usr/bin/ddns" ]]; then
    echo -e "${green}开始安装 DDNS 脚本至系统全局命令...${none}"
    cp -f "$0" /usr/bin/ddns
    chmod +x /usr/bin/ddns
    echo -e "${green}安装完成！开始执行向导...${none}"
    exec /usr/bin/ddns
fi

# ==============================================================
# 核心业务执行（静默执行：用于Crontab定时任务/强制同步）
# ==============================================================
if [[ "$1" == "cron" || "$1" == "force" ]]; then
    if [[ ! -f "$config_file" ]]; then exit 0; fi
    source "$config_file" 2>/dev/null
    
    # 智能获取混合环境 IP
    temp_ipv4=$(curl -s -4 --max-time 10 icanhazip.com || curl -s -4 --max-time 10 ifconfig.me/ip || true)
    temp_ipv6=$(curl -s -6 --max-time 10 icanhazip.com | grep -E -v '^(2a09|104\.28|fd|fe80)' || curl -s -6 --max-time 10 ifconfig.co/ip | grep -E -v '^(2a09|104\.28|fd|fe80)' || true)

    ipv4Regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    ipv6Regex="^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$"
    Public_IPv4=""; Public_IPv6=""

    if [[ "$temp_ipv4" =~ $ipv4Regex ]]; then Public_IPv4="$temp_ipv4"; fi
    if [[ "$temp_ipv6" =~ $ipv6Regex ]]; then Public_IPv6="$temp_ipv6"; fi

    send_tg() {
        if [[ -n "$TG_Bot_Token" && -n "$TG_Chat_ID" ]]; then
            curl -s -X POST "https://api.telegram.org/bot$TG_Bot_Token/sendMessage" -d "chat_id=$TG_Chat_ID" -d "text=$1" > /dev/null 2>&1
        fi
    }

    # ------------- IPv4 逻辑判断 -------------
    if [ -n "$Public_IPv4" ] && [ ${#Domains[@]} -gt 0 ] && [ "$Public_IPv4" != "$Old_Public_IPv4" ]; then
        for Domain in "${Domains[@]}"; do
            Root_domain=$(echo "$Domain" | awk -F '.' '{print $(NF-1)"."$NF}')
            Zone_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain&status=active" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            Record_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records?type=A&name=$Domain" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            if [[ -n "$Record_ID" ]]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records/$Record_ID" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" --data '{"type":"A","name":"'"$Domain"'","content":"'"$Public_IPv4"'","ttl":1,"proxied":false}' > /dev/null
                send_tg "Cloudflare DDNS (IPv4)%0A域名: $Domain%0A新IP: $Public_IPv4"
                echo -e "${green}[IPv4 同步成功] $Domain -> $Public_IPv4${none}"
            else
                echo -e "${red}[错误] 找不到 $Domain 的 A 记录。${none}"
            fi
        done
        sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=\"$Public_IPv4\"/" "$config_file"
    elif [[ -n "$Public_IPv4" && "$1" == "force" ]]; then
        echo -e "${yellow}[无变动] IPv4: $Public_IPv4 (无变化或未设域名)${none}"
    fi

    # ------------- IPv6 逻辑判断 -------------
    if [ -n "$Public_IPv6" ] && [ ${#Domains6[@]} -gt 0 ] && [ "$Public_IPv6" != "$Old_Public_IPv6" ]; then
        for Domain in "${Domains6[@]}"; do
            Root_domain=$(echo "$Domain" | awk -F '.' '{print $(NF-1)"."$NF}')
            Zone_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain&status=active" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            Record_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records?type=AAAA&name=$Domain" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            if [[ -n "$Record_ID" ]]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records/$Record_ID" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" --data '{"type":"AAAA","name":"'"$Domain"'","content":"'"$Public_IPv6"'","ttl":1,"proxied":false}' > /dev/null
                send_tg "Cloudflare DDNS (IPv6)%0A域名: $Domain%0A新IP: $Public_IPv6"
                echo -e "${magenta}[IPv6 同步成功] $Domain -> $Public_IPv6${none}"
            else
                echo -e "${red}[错误] 找不到 $Domain 的 AAAA 记录。${none}"
            fi
        done
        sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=\"$Public_IPv6\"/" "$config_file"
    elif [[ -n "$Public_IPv6" && "$1" == "force" ]]; then
        echo -e "${yellow}[无变动] IPv6: $Public_IPv6 (无变化或未设域名)${none}"
    fi
    exit 0
fi

# ==============================================================
# UI 界面：保姆级首次引导配置
# ==============================================================
configure() {
    clear
    echo -e "${yellow}===============================${none}"
    echo -e "${yellow}   DDNS 防呆高可用配置向导   ${none}"
    echo -e "${yellow}===============================${none}"
    mkdir -p /etc/DDNS
    
    # 1. 邮箱确认环
    while true; do
        read -p "请输入 Cloudflare 邮箱: " Email
        if [[ -z "$Email" ]]; then continue; fi
        read -p "$(echo -e "是否确认邮箱为：${bold_magenta}${Email}${none}，(y/n): ")" confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] && break
    done
    echo ""

    # 2. Key 确认环
    while true; do
        read -p "请输入 Cloudflare API Key (Global): " Key
        if [[ -z "$Key" ]]; then continue; fi
        read -p "$(echo -e "是否确认 API Key 为：${bold_magenta}${Key}${none}，(y/n): ")" confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] && break
    done
    echo ""

    # 3. TG 确认环
    while true; do
        read -p "请输入 TG Bot Token (直接回车跳过): " TG_Token
        if [[ -z "$TG_Token" ]]; then 
            echo -e "${yellow}[!] 已跳过 Telegram 通知项${none}"
            TG_Chat_ID=""
            break; 
        fi
        read -p "请输入 TG Chat ID: " TG_Chat_ID
        read -p "$(echo -e "是否确认输入？ Token=${bold_magenta}$TG_Token${none} , ChatID=${bold_magenta}$TG_Chat_ID${none}，(y/n): ")" confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] && break
    done
    
    echo -e "\n${green}[+] 基础服务连通就绪。开始网卡出口探测...${none}"
    
    # ================= IP 域名侦测向导 ================= #
    formatted_v4=""
    formatted_v6=""

    # IPv4 探测与确认
    sys_ipv4=$(curl -s -4 --max-time 4 icanhazip.com || true)
    if [[ -n "$sys_ipv4" ]]; then
        echo -e "\n------------------------------------------------"
        echo -e "${cyan}系统解析到本机 IPv4 地址为：${bold_green}${sys_ipv4}${none}"
        while true; do
            read -p "$(echo -e "是否需要解析 IPv4 域名？(y/n, 默认n): ")" opt_v4
            if [[ "$opt_v4" == "y" || "$opt_v4" == "Y" ]]; then
                read -p "请输入要解析的 IPv4 域名 (多个用空格隔开): " input_domains
                if [[ -n "$input_domains" ]]; then
                    read -p "$(echo -e "是否确认绑定IPv4域名为：${bold_magenta}${input_domains}${none}，(y/n): ")" confirm
                    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                        formatted_v4=$(echo "$input_domains" | awk '{for(i=1;i<=NF;i++) printf "\"%s\" ", $i}' | sed 's/ $//')
                        break
                    fi
                fi
            else
                echo -e "${yellow}[!] 跳过 IPv4 配置。${none}"
                break
            fi
        done
    else
        echo -e "\n${red}[!] 系统未检测到全局 IPv4，已跳过 IPv4 选项。${none}"
    fi

    # IPv6 探测与确认
    sys_ipv6=$(curl -s -6 --max-time 4 icanhazip.com | grep -E -v '^(2a09|104\.28|fd|fe80)' || true)
    if [[ -n "$sys_ipv6" ]]; then
        echo -e "\n------------------------------------------------"
        echo -e "${cyan}系统解析到本机 IPv6 地址为：${bold_magenta}${sys_ipv6}${none}"
        while true; do
            read -p "$(echo -e "是否需要解析 IPv6 域名？(y/n, 默认y): ")" opt_v6
            if [[ -z "$opt_v6" || "$opt_v6" == "y" || "$opt_v6" == "Y" ]]; then
                read -p "请输入要解析的 IPv6 域名 (多个用空格隔开): " input_domains6
                if [[ -n "$input_domains6" ]]; then
                    read -p "$(echo -e "是否确认绑定IPv6域名为：${bold_magenta}${input_domains6}${none}，(y/n): ")" confirm
                    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                        formatted_v6=$(echo "$input_domains6" | awk '{for(i=1;i<=NF;i++) printf "\"%s\" ", $i}' | sed 's/ $//')
                        break
                    fi
                fi
            else
                 echo -e "${yellow}[!] 跳过 IPv6 配置。${none}"
                 break
            fi
        done
    else
        echo -e "\n${red}[!] 系统未检测到全局 IPv6，已跳过 IPv6 选项。${none}"
    fi

    # =========== 将确认好的所有变量保存 =========== #
    cat <<EOF > "$config_file"
Domains=($formatted_v4)
Domains6=($formatted_v6)
Email="$Email"
Key="$Key"
TG_Bot_Token="$TG_Token"
TG_Chat_ID="$TG_Chat_ID"
Old_Public_IPv4=""
Old_Public_IPv6=""
EOF

    echo -e "\n${green}[+] 配置全盘锁定！正在拉起后台系统...${none}"
    
    # 挂载 Crontab
    if ! crontab -l 2>/dev/null | grep -q "ddns cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /usr/bin/ddns cron >> /var/log/ddns.log 2>&1") | crontab -
    fi
    
    echo -e "${cyan}正在执行首次通信同步...${none}"
    /usr/bin/ddns force
    echo ""
    read -p "设置完成！按回车进入管理控制台..."
    menu
}

view_config() {
   clear
   source "$config_file" 2>/dev/null
   echo -e "${yellow}=== 当前系统工作参数 ===${none}"
   echo -e "绑定的 CF 邮箱: ${green}${Email:-未配置}${none}"
   echo -e "绑定的 CF Key: ${magenta}****************${none}"
   
   if [[ -n "${Domains[*]}" ]]; then
       echo -e "设定的 IPv4 域名: ${cyan}${Domains[*]}${none}"
   else
       echo -e "设定的 IPv4 域名: ${cyan}未设置${none}"
   fi
   
   if [[ -n "${Domains6[*]}" ]]; then
       echo -e "设定的 IPv6 域名: ${magenta}${Domains6[*]}${none}"
   else
       echo -e "设定的 IPv6 域名: ${magenta}未设置${none}"
   fi
   
   echo -e "-------------------------"
   echo -e "当前已云同步的 IPv4: ${yellow}${Old_Public_IPv4:-无}${none}"
   echo -e "当前已云同步的 IPv6: ${yellow}${Old_Public_IPv6:-无}${none}"
   echo -e ""
   read -p "按回车返回主菜单..."
}

force_run() {
    echo -e "${cyan}正在前台强制通信 API...${none}"
    /usr/bin/ddns force
    echo ""
    read -p "按回车返回菜单..."
    menu
}

uninstall_ddns() {
    crontab -l 2>/dev/null | grep -v "ddns cron" | crontab -
    rm -rf /etc/DDNS
    rm -f /usr/bin/ddns
    echo -e "${red}定时任务与底层文件已全量擦除。${none}"
    exit 0
}

menu() {
    clear
    ipv4=$(curl -s -4 --max-time 3 icanhazip.com || echo "未检测到")
    ipv6=$(curl -s -6 --max-time 3 icanhazip.com | grep -E -v '^(2a09|104\.28|fd|fe80)' || echo "未检测到")
    
    echo -e "${cyan} =================================================${none}"
    echo -e "${cyan}   Cloudflare 智能动态解析守护台 (防呆修正版)${none}"
    echo -e "${cyan} =================================================${none}"
    echo -e "   [系统出口 IPv4] : ${green}$ipv4${none}"
    echo -e "   [系统出口 IPv6] : ${magenta}$ipv6${none}"
    echo -e " -------------------------------------------------"
    echo -e "  ${yes}1.${none}  重建向导 (修改邮箱/API/域名配置) "
    echo -e "  ${yes}2.${none}  立即触发前台同步"
    echo -e "  ${yes}3.${none}  查看当前系统运行库的参数"
    echo -e "  ${yes}0.${none}  完全卸载防呆器并退出"
    echo -e "  ${yes}99.${none} 最小化至后台并退出菜单\n"
    read -p "请分配操作指令编号 > " choice
    case $choice in
        1) configure ;;
        2) force_run ;;
        3) view_config; menu ;;
        0) uninstall_ddns ;;
        99) exit 0 ;;
        *) echo "无效操作！"; sleep 1; menu ;;
    esac
}

# ================= 软启判断器：进入菜单还是配置 ================= #
# 如果文件存在，且包含完整的 Email 配置头，则认为配置跑过
if [[ -f "$config_file" ]] && grep -q "Email=" "$config_file"; then
    menu
else
    configure
fi
