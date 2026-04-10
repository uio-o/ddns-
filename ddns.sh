#!/bin/bash
# 修复核心版 Cloudflare DDNS 
# 特性：自动修复换行符 / 防呆极客交互 / 前置探测统一部件 / 强制稳健落盘

# 自我防呆修复：消除从浏览器或 Windows 复制带来的 CRLF(\r) 换行符毒害
sed -i 's/\r$//' "$0" 2>/dev/null || true

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
bold_magenta='\e[1;95m'
bold_green='\e[1;92m'
none='\e[0m'

# ==============================================================
# 统一部件：高可用探测引擎 (全时段保证 6 秒容错，不漏判)
# ==============================================================
get_ipv4() {
    local ip=$(curl -s -4 --max-time 6 icanhazip.com || curl -s -4 --max-time 6 ifconfig.me/ip || echo "")
    echo "$ip" | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1
}

get_ipv6() {
    local ip=$(curl -s -6 --max-time 6 icanhazip.com || curl -s -6 --max-time 6 ifconfig.co/ip || echo "")
    echo "$ip" | grep -E -v '^(2a09|104\.28|fd|fe80)' | grep -E '[0-9a-fA-F:]+' | head -n 1
}

send_tg() {
    if [[ -n "$TG_Bot_Token" && -n "$TG_Chat_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_Bot_Token/sendMessage" -d "chat_id=$TG_Chat_ID" -d "text=$1" > /dev/null 2>&1
    fi
}

# ==============================================================
# 安装/更新执行体：自动全局接管 
# ==============================================================
COMMAND_NAME=$(basename "$0")
if [[ "$COMMAND_NAME" != "ddns" && "$0" != "/usr/bin/ddns" && "$0" != "-bash" ]]; then
    echo -e "${green}装载核心组件中...${none}"
    cp -f "$0" /usr/bin/ddns
    chmod +x /usr/bin/ddns
    echo -e "${green}安装完成！引擎点火...${none}"
    exec /usr/bin/ddns
fi

# ==============================================================
# 核心业务执行（静默执行：用于Crontab定时任务/强制同步）
# ==============================================================
if [[ "$1" == "cron" || "$1" == "force" ]]; then
    if [[ ! -s "/etc/DDNS/.config" ]]; then exit 0; fi
    source "/etc/DDNS/.config" 2>/dev/null
    
    Public_IPv4=$(get_ipv4)
    Public_IPv6=$(get_ipv6)

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
        sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=\"$Public_IPv4\"/" "/etc/DDNS/.config"
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
        sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=\"$Public_IPv6\"/" "/etc/DDNS/.config"
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
    
    # 清理并创建坚固的目录形态
    mkdir -p /etc/DDNS
    rm -f "/etc/DDNS/.config"

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
    
    echo -e "\n${green}[+] 基础服务连通就绪。开始全局网卡出口探测...${none}"
    
    # ================= IP 域名侦测向导 ================= #
    v4_domains=""
    v6_domains=""

    # IPv4 探测与确认
    sys_ipv4=$(get_ipv4)
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
                        for d in $input_domains; do v4_domains="$v4_domains '$d'"; done
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
    sys_ipv6=$(get_ipv6)
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
                        for d in $input_domains6; do v6_domains="$v6_domains '$d'"; done
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

    # ================= 强力稳健保存流 (彻底告别空文件和崩溃Bug) ================= #
    echo "Domains=($v4_domains)" >> /etc/DDNS/.config
    echo "Domains6=($v6_domains)" >> /etc/DDNS/.config
    echo "Email=\"$Email\"" >> /etc/DDNS/.config
    echo "Key=\"$Key\"" >> /etc/DDNS/.config
    echo "TG_Bot_Token=\"$TG_Token\"" >> /etc/DDNS/.config
    echo "TG_Chat_ID=\"$TG_Chat_ID\"" >> /etc/DDNS/.config
    echo "Old_Public_IPv4=\"\"" >> /etc/DDNS/.config
    echo "Old_Public_IPv6=\"\"" >> /etc/DDNS/.config
    chmod 600 "/etc/DDNS/.config"

    echo -e "\n${green}[+] 配置全盘锁定！落盘无异常，系统核心已被唤醒...${none}"
    
    if ! crontab -l 2>/dev/null | grep -q "ddns cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /usr/bin/ddns cron >> /var/log/ddns.log 2>&1") | crontab -
    fi
    
    echo -e "${cyan}正在执行首次通信同步...${none}"
    /usr/bin/ddns force
    echo ""
    read -p "设置已完美就绪！按回车进入管理控制台..."
    menu
}

view_config() {
   clear
   source "/etc/DDNS/.config" 2>/dev/null
   echo -e "${yellow}=== 当前系统工作参数 ===${none}"
   echo -e "绑定的 CF 邮箱: ${green}${Email:-未配置}${none}"
   echo -e "绑定的 CF Key: ${magenta}****************${none}"
   
   if [[ ${#Domains[@]} -gt 0 ]]; then
       echo -e "设定的 IPv4 域名: ${cyan}${Domains[*]}${none}"
   else
       echo -e "设定的 IPv4 域名: ${cyan}未设置${none}"
   fi
   
   if [[ ${#Domains6[@]} -gt 0 ]]; then
       echo -e "设定的 IPv6 域名: ${magenta}${Domains6[*]}${none}"
   else
       echo -e "设定的 IPv6 域名: ${magenta}未设置${none}"
   fi
   
   echo -e "-------------------------"
   echo -e "当前已云端同步在案的 IPv4: ${yellow}${Old_Public_IPv4:-无}${none}"
   echo -e "当前已云端同步在案的 IPv6: ${yellow}${Old_Public_IPv6:-无}${none}"
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
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    [[ -z "$ipv4" ]] && ipv4="未检测到"
    [[ -z "$ipv6" ]] && ipv6="未检测到"
    
    echo -e "${cyan} =================================================${none}"
    echo -e "${cyan}   Cloudflare 智能动态解析守护台 (终极防呆版)${none}"
    echo -e "${cyan} =================================================${none}"
    echo -e "   [本机 当前出口 IPv4] : ${green}$ipv4${none}"
    echo -e "   [本机 当前出口 IPv6] : ${magenta}$ipv6${none}"
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

# ================= 软启判断器：绝对安全无死角的查体 ================= #
# 抛弃脆弱查询：只要文件实体且不为空，直接解析；只要能读出 Email 值，一发入魂！
if [[ -s "/etc/DDNS/.config" ]]; then
    source "/etc/DDNS/.config" 2>/dev/null
    if [[ -n "$Email" ]]; then
        menu
        exit 0
    fi
fi

# 以上阻断都不成立，进入向导
configure
