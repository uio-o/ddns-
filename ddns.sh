#!/bin/bash
# 修复核心版 Cloudflare DDNS (修复多网卡IP抓取失败、优化交互逻辑)

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
config_file="/etc/DDNS/.config"

# ==============================================================
# 安装/更新执行体：如果不是被调用在 /usr/bin/ddns，则触发安装逻辑
# ==============================================================
if [[ "$0" != "/usr/bin/ddns" ]]; then
    echo -e "${green}开始安装 DDNS 脚本至系统全局命令...${none}"
    cp -f "$0" /usr/bin/ddns
    chmod +x /usr/bin/ddns
    echo -e "${green}安装完成！以后请直接输入: ddns 来呼出菜单。${none}"
    /usr/bin/ddns
    exit 0
fi

# ==============================================================
# 核心业务执行（静默执行：用于Crontab定时任务触发/手动强制执行）
# ==============================================================
if [[ "$1" == "cron" ]]; then
    if [[ ! -f "$config_file" ]]; then exit 0; fi
    source "$config_file" 2>/dev/null
    
    # 获取 IPv4
    temp_ipv4=$(curl -s -4 --max-time 10 icanhazip.com || curl -s -4 --max-time 10 ifconfig.me/ip || true)
    # 获取 IPv6
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

    # 执行更新
    # --------- IPv4 更新 ---------
    if [ -n "$Public_IPv4" ] && [ ${#Domains[@]} -gt 0 ] && [ "$Public_IPv4" != "$Old_Public_IPv4" ]; then
        for Domain in "${Domains[@]}"; do
            Root_domain=$(echo "$Domain" | awk -F '.' '{print $(NF-1)"."$NF}')
            Zone_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain&status=active" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            Record_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records?type=A&name=$Domain" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            if [[ -n "$Record_ID" ]]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records/$Record_ID" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" --data '{"type":"A","name":"'"$Domain"'","content":"'"$Public_IPv4"'","ttl":1,"proxied":false}' > /dev/null
                send_tg "Cloudflare DDNS (IPv4)\n域名: $Domain\n新IP: $Public_IPv4"
                echo -e "${green}[IPv4 成功] $Domain -> $Public_IPv4${none}"
            else
                echo -e "${red}[错误] $Domain 找不到 A 解析记录，请先在 CF 手动创建。${none}"
            fi
        done
        sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=\"$Public_IPv4\"/" "$config_file"
    elif [[ -n "$Public_IPv4" ]] && [[ "$1" == "force" ]]; then
        echo -e "${yellow}[无变动] 当前 IPv4: $Public_IPv4 ，未发生变化或未配置域名。${none}"
    fi

    # --------- IPv6 更新 ---------
    if [ -n "$Public_IPv6" ] && [ ${#Domains6[@]} -gt 0 ] && [ "$Public_IPv6" != "$Old_Public_IPv6" ]; then
        for Domain in "${Domains6[@]}"; do
            Root_domain=$(echo "$Domain" | awk -F '.' '{print $(NF-1)"."$NF}')
            Zone_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain&status=active" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            Record_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records?type=AAAA&name=$Domain" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" | sed -E "s/.*\"id\":\"([a-zA-Z0-9]*)\".*/\1/")
            if [[ -n "$Record_ID" ]]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_ID/dns_records/$Record_ID" -H "X-Auth-Email: $Email" -H "X-Auth-Key: $Key" -H "Content-Type: application/json" --data '{"type":"AAAA","name":"'"$Domain"'","content":"'"$Public_IPv6"'","ttl":1,"proxied":false}' > /dev/null
                send_tg "Cloudflare DDNS (IPv6)\n域名: $Domain\n新IP: $Public_IPv6"
                echo -e "${magenta}[IPv6 成功] $Domain -> $Public_IPv6${none}"
            else
                echo -e "${red}[错误] $Domain 找不到 AAAA 解析记录，请先在 CF 手动创建。${none}"
            fi
        done
        sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=\"$Public_IPv6\"/" "$config_file"
    elif [[ -n "$Public_IPv6" ]] && [[ "$1" == "force" ]]; then
         echo -e "${yellow}[无变动] 当前 IPv6: $Public_IPv6 ，未发生变化或未配置域名。${none}"
    fi
    exit 0
fi

# ==============================================================
# UI 界面：首次引导配置 与 交互菜单
# ==============================================================
configure() {
    clear
    echo -e "${yellow}===============================${none}"
    echo -e "${yellow}      DDNS 初始配置向导      ${none}"
    echo -e "${yellow}===============================${none}"
    mkdir -p /etc/DDNS
    
    # 防呆：确保至少输入了必填项
    while [[ -z "$Email" ]]; do read -p "请输入 Cloudflare 邮箱: " Email; done
    while [[ -z "$Key" ]]; do read -p "请输入 Cloudflare API Key (Global): " Key; done
    read -p "请输入 Telegram Bot Token (直接回车跳过): " TG_Token
    if [[ -n "$TG_Token" ]]; then read -p "请输入 Telegram Chat ID: " TG_Chat_ID; fi
    
    cat <<EOF > "$config_file"
Domains=()
Domains6=()
Email="$Email"
Key="$Key"
TG_Bot_Token="$TG_Token"
TG_Chat_ID="$TG_Chat_ID"
Old_Public_IPv4=""
Old_Public_IPv6=""
EOF
    
    echo -e "\n${green}[+] 账户配置已保存。下面开始添加域名...${none}"
    manage_domains
    
    # 写出 Crontab
    if ! crontab -l 2>/dev/null | grep -q "ddns cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /usr/bin/ddns cron >> /var/log/ddns.log 2>&1") | crontab -
        echo -e "\n${green}[+] 已挂载后台每分钟监测。${none}"
    fi
    echo -e "\n${green}正在执行首次状态同步...${none}"
    /usr/bin/ddns force
    echo ""
    read -p "配置完成！按回车返回主菜单..."
    menu
}

manage_domains() {
    # 确保文件存在，不然 sed 替换会出问题
    if [[ ! -f "$config_file" ]]; then
        echo -e "${red}未找到配置文件，请先完成主配置！${none}"
        return
    fi
    source "$config_file" 2>/dev/null
    
    read -p "配置 IPv4 解析域名? (输入多个用空格分割, 回车跳过): " input_domains
    if [[ -n "$input_domains" ]]; then
        formatted=$(echo "$input_domains" | awk '{for(i=1;i<=NF;i++) printf "\"%s\" ", $i}' | sed 's/ $//')
        sed -i "s/^Domains=.*/Domains=(${formatted})/" "$config_file"
    fi
    read -p "配置 IPv6 解析域名? (输入多个用空格分割, 回车跳过): " input_domains6
    if [[ -n "$input_domains6" ]]; then
        formatted6=$(echo "$input_domains6" | awk '{for(i=1;i<=NF;i++) printf "\"%s\" ", $i}' | sed 's/ $//')
        sed -i "s/^Domains6=.*/Domains6=(${formatted6})/" "$config_file"
    fi
    echo -e "${green}[+] 域名配置已保存。${none}"
    sleep 1
}

force_run() {
    echo -e "${cyan}正在前台强制运行解析检查 (带详细输出)...${none}"
    /usr/bin/ddns force
    echo ""
    read -p "按回车返回菜单..."
    menu
}

uninstall_ddns() {
    crontab -l 2>/dev/null | grep -v "ddns cron" | crontab -
    rm -rf /etc/DDNS
    rm -f /usr/bin/ddns
    echo -e "${red}已彻底清理本脚本，任务已终止。${none}"
    exit 0
}

view_config() {
   clear
   if [[ ! -f "$config_file" ]]; then
       echo -e "${red}[错误] ${none}尚未进行配置，找不到配置文件！"
       sleep 2
       return
   fi
   
   # 使用特殊的解析方式确保安全的读取数组内容
   source "$config_file" 2>/dev/null
   
   echo -e "${yellow}=== 当前系统加载的配置 ===${none}"
   echo -e "用户邮箱: ${green}${Email:-未配置}${none}"
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
   echo -e "系统记录的旧 IPv4: ${yellow}${Old_Public_IPv4:-无}${none}"
   echo -e "系统记录的旧 IPv6: ${yellow}${Old_Public_IPv6:-无}${none}"
   echo -e ""
   read -p "按回车返回主菜单..."
}

menu() {
    clear
    # 每次开菜单检测一下当前系统的外网信息展示一下
    ipv4=$(curl -s -4 --max-time 3 icanhazip.com || echo "未检测到")
    ipv6=$(curl -s -6 --max-time 3 icanhazip.com | grep -E -v '^(2a09|104\.28|fd|fe80)' || echo "未检测到")
    
    echo -e "${cyan} =================================================${none}"
    echo -e "${cyan}   Cloudflare DDNS 后台动态解析脚本 (重置修复版)${none}"
    echo -e "${cyan} =================================================${none}"
    echo -e "   [本机 当前出口 IPv4] : ${green}$ipv4${none}"
    echo -e "   [本机 当前出口 IPv6] : ${magenta}$ipv6${none}"
    echo -e " -------------------------------------------------"
    echo -e "  ${yes}1.${none}  重新引导配置 (修改邮箱/API/域名)"
    echo -e "  ${yes}2.${none}  立即手动强制运行一次同步"
    echo -e "  ${yes}3.${none}  查看当前系统配置的挂载域名"
    echo -e "  ${yes}0.${none}  完全卸载并清除任务"
    echo -e "  ${yes}99.${none} 退出菜单\n"
    read -p "请输入对应的数字 > " choice
    case $choice in
        1) configure ;;
        2) force_run ;;
        3) view_config; menu ;;
        0) uninstall_ddns ;;
        99) exit 0 ;;
        *) echo "[!] 无效选项"; sleep 1; menu ;;
    esac
}

# 启动入口判定
if [[ ! -f "$config_file" ]]; then
    configure
else
    menu
fi
