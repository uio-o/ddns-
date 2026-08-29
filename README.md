# Cloudflare DDNS Manager Plus

这是一个 Cloudflare DDNS 管理与自动更新工具，支持换 IP 设备和 NAT 上游换 IP 两种部署场景。

保留原项目全部功能，并增加 Telegram 群聊只读通知：

- `ddns` 交互管理面板
- Cloudflare `A`、`AAAA`、`BOTH` DDNS
- 原项目的换 IP API
- 支持两条独立自动链路：cron 定时换 IP + DDNS，以及 systemd timer 仅 DDNS 检测
- Telegram 管理 Bot
- 管理员 `TG_CHAT_ID`
- 原项目 `TG_EXTRA_CHAT_IDS` 授权用户
- `/start`、`/panel`、`/changeip`、`/ddns`、`/status`、`/log`
- `/users`、`/adduser`、`/deluser`
- `/restart`、面板自动刷新、地区/ISP 查询、自定义面板图片
- 新增 `TG_GROUP_BOT_TOKEN` + `TG_GROUP_CHAT_IDS` 独立群聊通知

## 群聊权限

管理员私聊和原项目授权用户仍然使用：

```bash
TG_CHAT_ID='管理员用户 Chat ID'
TG_EXTRA_CHAT_IDS='其他可管理用户 Chat ID'
```

只接收 IP 变更通知的群聊使用：

```bash
TG_GROUP_ENABLED='true'
TG_GROUP_BOT_TOKEN='群通知专用 Bot Token（必须与管理员 Bot 不同）'
TG_GROUP_CHAT_IDS='-1001234567890'
TG_GROUP_SILENT='false'
```

`TG_GROUP_CHAT_IDS` 不会加入 `TG_CHAT_ID` 或 `TG_EXTRA_CHAT_IDS`。`TG_GROUP_BOT_TOKEN` 必须使用独立机器人，不能与管理员的 `TG_BOT_TOKEN` 相同。

群通知专用 Bot 不运行本项目的 Bot 服务，代码只用它调用 Telegram `sendMessage`；管理员 Bot 的 `getUpdates` 不会接触该群。因此群聊不会被读取消息、处理命令或提供管理面板，只能接收通知。

群通知需要通过 `@BotFather` 另建一个机器人，只将这个群通知机器人加入目标群。管理员 Bot 不应加入该群；项目不会为群通知机器人启动 `getUpdates`。

支持多个群聊，使用空格或逗号分隔：

```bash
TG_GROUP_CHAT_IDS='-1001234567890 -1009876543210'
```

Bot 加入群聊后只需要能够发送消息，不需要管理员权限。

## 安装


```bash
RAW_BASE='https://raw.githubusercontent.com/uio-o/cloudflare-ddns/main'
curl -fsSL "$RAW_BASE/install-online.sh" | sudo RAW_BASE="$RAW_BASE" bash
```

也可以先下载源码再执行：

```bash
git clone 'https://github.com/uio-o/cloudflare-ddns.git'
cd 'cloudflare-ddns'
sudo bash ./install.sh
```

安装后直接执行：

```bash
ddns
```

`ddns` 指向 `/usr/local/ddns/cf_ddns_manage.sh`，可以打开原项目交互管理面板。

## 配置流程

执行：

```bash
ddns
```

选择：

```text
1) 初始化/修改 Cloudflare 与 Telegram 配置
```

配置 Cloudflare、原项目换 IP API、Telegram 管理员 Chat ID 后，再配置群通知。

配置完成后选择：

```text
3) 配置两条自动链路（cron 换 IP / timer DDNS）
5) 测试 Telegram 通知（a 管理员 / b 群聊）
7) 后台调用换 IP API 并更新 DDNS（SSH 可断开）
8) 安装/更新 Telegram Bot 命令服务
```

本项目支持两条互不干扰、可以同时启用的自动链路：

链路一用于本机可以主动换公网 IP 的机器，使用 cron 表达式调用 `cf_ddns_rotate.sh`，执行顺序为：

1. 调用 `cf_change_ip.sh` 请求换公网 IP。
2. 等待 `IP_CHANGE_WAIT_SECONDS` 秒。
3. 调用 `cf_ddns.sh` 更新 Cloudflare DNS。

链路二用于 NAT 机器或公网 IP 由上游设备更换的场景，使用独立的 systemd timer，只调用 `cf_ddns.sh` 检测当前公网 IP 并更新 Cloudflare DNS，不会调用换 IP API。该链路按分钟配置，启用后首次检测在一个完整间隔后执行。

在主菜单选择 `3` 可以分别安装链路一或链路二，也可以依次安装两条。链路一的 cron 文件为 `/etc/cron.d/cf-ddns-rotate`，链路二使用 `cf-ddns.timer` / `cf-ddns.service`。选择 `6` 可以分别停用任意一条，停用其中一条不会影响另一条。

手动选择菜单 `7` 时，管理面板会使用 transient systemd service 把完整换 IP流程提交到后台，并立即返回面板；换公网 IP 后当前 SSH TCP 连接通常会断开，这是网络地址变化的正常结果。后台任务由 PID 1 管理，SSH 断线不会中止它；重连后可通过菜单 `4` 或 `/var/log/cf_ddns.log` 查看结果。

`cf_ddns_rotate.sh` 和 `cf_ddns.sh` 使用独立的 `flock` 锁，防止两条链路或手动操作同时更新 DNS。两条链路的调度入口仍然独立，不会互相停用或覆盖。

## 文件结构

```text
scripts/cf_ddns.sh
scripts/cf_ddns_rotate.sh
scripts/cf_ddns_bot.sh
scripts/cf_ddns_manage.sh
scripts/cf_change_ip.sh
install.sh
install-online.sh
```

核心新增位置：

- `scripts/cf_ddns.sh`：新增 `send_telegram_groups`，并接入真实 DNS 变更成功流程。
- `scripts/cf_ddns_manage.sh`：增加 cron 调度、后台手动换 IP、`TG_GROUP_ENABLED`、`TG_GROUP_BOT_TOKEN`、`TG_GROUP_CHAT_IDS`、`TG_GROUP_SILENT` 配置项。

## 手工验证

查看链路一 cron：

```bash
cat /etc/cron.d/cf-ddns-rotate
systemctl status cron --no-pager
```

查看链路二 systemd timer：

```bash
systemctl status cf-ddns.timer --no-pager
systemctl list-timers cf-ddns.timer --no-pager
journalctl -u cf-ddns.service -n 100 --no-pager
```



```text
每 5 分钟：*/5 * * * *
每周三凌晨 03:00：0 3 * * 3
每周三和周日凌晨 03:00：0 3 * * 0,3
```

查看 DDNS 日志：

```bash
journalctl -u cf-ddns.service -n 100 --no-pager
cat /var/log/cf_ddns.log
```

查看 Bot 服务：

```bash
systemctl status cf-ddns-bot.service --no-pager
```

## 安全建议

Cloudflare API Token 建议仅授予目标 zone 的 `Zone Read`、`DNS Read` 和 `DNS Edit` 权限。

不要把 `/usr/local/ddns/cf_ddns.env` 提交到 GitHub。该文件包含 Cloudflare API Token、Telegram Bot Token 和换 IP API Token。

建议发布前执行：

```bash
git add install.sh install-online.sh scripts assets README.md .gitignore
git commit -m 'add group notifications for scheduled DDNS updates'
git push
```
