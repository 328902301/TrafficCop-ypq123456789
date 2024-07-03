#!/bin/bash

CONFIG_FILE="/root/tg_notifier_config.txt"
LOG_FILE="/root/traffic_monitor.log"
LAST_NOTIFICATION_FILE="/tmp/last_traffic_notification"
SCRIPT_PATH="/root/tg_notifier.sh"
CRON_LOG="/root/tg_notifier_cron.log"

echo "版本号：2.5"  

# 清除旧的通知状态文件
clear_notification_state() {
    if [ -f "$LAST_NOTIFICATION_FILE" ]; then
        rm "$LAST_NOTIFICATION_FILE"
        echo "清除了旧的通知状态文件。"
    fi
}

# 函数：获取非空输入
get_valid_input() {
    local prompt="${1:-"请输入："}"
    local input=""
    while true; do
        read -p "${prompt}" input
        if [[ -n "${input}" ]]; then
            echo "${input}"
            return
        else
            echo "输入不能为空，请重新输入。"
        fi
    done
}


# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

# 写入配置
write_config() {
    cat > "$CONFIG_FILE" << EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
DAILY_REPORT="$DAILY_REPORT"
EOF
    echo "配置已保存到 $CONFIG_FILE"
}

# 初始配置
initial_config() {
    TG_BOT_TOKEN=$(get_valid_input "请输入Telegram Bot Token: ")
    [[ -z "$TG_BOT_TOKEN" ]] && TG_BOT_TOKEN=$(grep "TG_BOT_TOKEN" "$CONFIG_FILE" | cut -d'"' -f2)  # 新增：使用旧值

    TG_CHAT_ID=$(get_valid_input "请输入Telegram Chat ID: ")
    [[ -z "$TG_CHAT_ID" ]] && TG_CHAT_ID=$(grep "TG_CHAT_ID" "$CONFIG_FILE" | cut -d'"' -f2)  # 新增：使用旧值

    daily_report_choice=$(get_valid_input "是否启用每日流量报告？(y/n) ")
    [[ -z "$daily_report_choice" ]] && daily_report_choice=$(grep "DAILY_REPORT" "$CONFIG_FILE" | cut -d'"' -f2)  # 新增：使用旧值
    DAILY_REPORT=$([ "$daily_report_choice" = "y" ] || [ "$daily_report_choice" = "true" ] && echo "true" || echo "false")
    write_config
}

send_telegram_message() {
    local message="${1:-"默认消息"}"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="Markdown"
}

test_telegram_notification() {
    local test_message="🔔 这是一条测试消息。如果您收到这条消息，说明Telegram通知功能正常工作。"
    send_telegram_message "$test_message"
    echo "测试消息已发送，请检查您的Telegram。"
}

check_and_notify() {
    local interactive=\$1
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始检查流量状态..." >> "$CRON_LOG"
    if [ "$interactive" = "true" ]; then
        echo "开始检查流量状态..."
    fi
    
    local status_found=false
    local latest_log=$(tail -n 50 "$LOG_FILE")

    if echo "$latest_log" | grep -q "使用 TC 模式限速"; then
        local message="⚠️ 限速警告：流量已达到限制，已启动 TC 模式限速。"
        if [ ! -f "$LAST_NOTIFICATION_FILE" ] || [ "$(cat "$LAST_NOTIFICATION_FILE")" != "限速" ]; then
            send_telegram_message "$message"
            echo "限速" > "$LAST_NOTIFICATION_FILE"
        fi
        echo "$message"
        status_found=true
    elif echo "$latest_log" | grep -q "系统将在 1 分钟后关机"; then
        local message="🚨 关机警告：流量已达到限制，系统将在 1 分钟后关机！"
        if [ ! -f "$LAST_NOTIFICATION_FILE" ] || [ "$(cat "$LAST_NOTIFICATION_FILE")" != "关机" ]; then
            send_telegram_message "$message"
            echo "关机" > "$LAST_NOTIFICATION_FILE"
        fi
        echo "$message"
        status_found=true
    elif echo "$latest_log" | grep -q "流量正常，清除所有限制"; then
        local message="✅ 流量正常：流量目前处于正常水平，所有限制已清除。"
        if [ -f "$LAST_NOTIFICATION_FILE" ]; then
            send_telegram_message "$message"
            rm "$LAST_NOTIFICATION_FILE"
        fi
        echo "$message"
        status_found=true
    fi
    
    if [ "$status_found" = "false" ]; then
        echo "✅ 流量状态正常：未触发任何限制或警告。"
    fi
    
     echo "$(date '+%Y-%m-%d %H:%M:%S') : 流量检查完成。" >> "$CRON_LOG"
}

# 设置定时任务
setup_cron() {
    local cron_job="*/5 * * * * /bin/bash $SCRIPT_PATH cron >> $CRON_LOG 2>&1"
    
    # 检查是否已存在正确的定时任务
    if crontab -l 2>/dev/null | grep -Fq "$cron_job"; then
        echo "定时任务已存在，无需添加。"
    else
        # 添加新的定时任务
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        echo "定时任务已添加。脚本将每5分钟执行一次检查。"
    fi
}


daily_report() {
    local current_usage=$(grep "当前流量" "$LOG_FILE" | tail -n 1 | cut -d ' ' -f 4)
    local limit=$(grep "流量限制" "$LOG_FILE" | tail -n 1 | cut -d ' ' -f 4)
    local message="📊 每日流量报告\n当前使用流量：$current_usage\n流量限制：$limit"
    send_telegram_message "$message"
}

# 主任务
main() {
    clear_notification_state
    if [ "\$1" = "cron" ]; then
        read_config
        check_and_notify false
    else
        # 读取配置
        if ! read_config; then
            echo "配置文件不存在，请进行初始配置。"
            initial_config
        fi

        # 每次运行时检查并设置 crontab
        setup_cron

        while true; do
            echo "脚本正在运行中。按 'q' 退出，按 'c' 检查流量，按 'r' 重新加载配置，按 't' 发送测试消息，按 'm' 修改配置。"
            read -n 1 -r input
            if [ -n "$input" ]; then
                echo
                echo "您输入的是: $input"
                case $input in
                    q|Q) 
                        echo "退出脚本。"
                        exit 0
                        ;;
                    c|C)
                        check_and_notify true
                        ;;
                    r|R)
                        read_config
                        echo "配置已重新加载。"
                        ;;
                    t|T)
                        test_telegram_notification
                        ;;
                    m|M)
                        initial_config
                        ;;
                    *)
                        echo "无效的输入: $input"
                        ;;
                esac
                echo "处理完成，返回主循环"
            fi
        done
    fi
}
# 执行主函数
main "$@"
echo "$(date '+%Y-%m-%d %H:%M:%S') : 脚本执行完毕，退出" >> "$CRON_LOG"
