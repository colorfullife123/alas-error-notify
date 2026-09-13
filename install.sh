#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="/opt/scripts/alas_monitor.sh"
CONFIG_FILE="/etc/alas-monitor.conf"
CRON_FILE="/etc/cron.d/alas-monitor"
LOG_FILE="/var/log/alas_monitor.log"

if (( EUID != 0 )); then
    printf '请使用 sudo 运行：sudo bash install.sh\n' >&2
    exit 1
fi

for command_name in docker mosquitto_pub timeout flock sha256sum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '缺少依赖：%s\n' "$command_name" >&2
        exit 1
    fi
done

timestamp="$(date '+%Y%m%d-%H%M%S')"
install -d -m 755 "$(dirname "$TARGET_SCRIPT")"

if [[ -f "$TARGET_SCRIPT" ]]; then
    backup="${TARGET_SCRIPT}.bak-${timestamp}"
    cp -a "$TARGET_SCRIPT" "$backup"
    printf '已备份原脚本：%s\n' "$backup"
fi

install -m 700 "$PROJECT_DIR/alas_monitor.sh" "$TARGET_SCRIPT"

write_config() {
    local mqtt_host mqtt_port mqtt_user mqtt_pass mqtt_topic
    local container error_dir image_target host_label temporary

    read -r -p 'ALAS 容器名 [alas]：' container
    container="${container:-alas}"

    read -r -p 'MQTT Broker 地址：' mqtt_host
    [[ -n "$mqtt_host" ]] || {
        printf 'MQTT Broker 地址不能为空\n' >&2
        exit 1
    }

    read -r -p 'MQTT 端口 [1883]：' mqtt_port
    mqtt_port="${mqtt_port:-1883}"
    read -r -p 'MQTT 用户名（允许留空）：' mqtt_user
    read -r -s -p 'MQTT 密码（允许留空）：' mqtt_pass
    printf '\n'
    read -r -p 'MQTT Topic [nas/alas/error]：' mqtt_topic
    mqtt_topic="${mqtt_topic:-nas/alas/error}"

    read -r -p 'ALAS 错误截图目录（留空则禁用截图复制）：' error_dir
    image_target=""
    if [[ -n "$error_dir" ]]; then
        read -r -p '最新截图目标路径：' image_target
    fi

    read -r -p "通知中的设备名称 [$(hostname)]：" host_label
    host_label="${host_label:-$(hostname)}"

    temporary="$(mktemp)"
    trap 'rm -f "$temporary"' RETURN

    {
        printf 'CONTAINER=%q\n' "$container"
        printf 'MQTT_HOST=%q\n' "$mqtt_host"
        printf 'MQTT_PORT=%q\n' "$mqtt_port"
        printf 'MQTT_USER=%q\n' "$mqtt_user"
        printf 'MQTT_PASS=%q\n' "$mqtt_pass"
        printf 'MQTT_TOPIC=%q\n' "$mqtt_topic"
        printf 'MQTT_QOS=%q\n' '1'
        printf 'MQTT_TIMEOUT_SECONDS=%q\n' '10'
        printf 'ERROR_DIR=%q\n' "$error_dir"
        printf 'IMAGE_TARGET=%q\n' "$image_target"
        printf 'IMAGE_MAX_AGE_MINUTES=%q\n' '30'
        printf 'LOOKBACK=%q\n' '15m'
        printf 'STATE_DIR=%q\n' '/var/lib/alas-manual-alert'
        printf 'LOCK_FILE=%q\n' '/run/alas-manual-alert.lock'
        printf 'HOST_LABEL=%q\n' "$host_label"
        printf 'MANUAL_PATTERN=%q\n' \
            'Request human takeover|Manual intervention required'
    } >"$temporary"

    install -o root -g root -m 600 "$temporary" "$CONFIG_FILE"
    trap - RETURN
    rm -f "$temporary"
}

if [[ -f "$CONFIG_FILE" ]]; then
    printf '保留现有配置：%s\n' "$CONFIG_FILE"
else
    write_config
    printf '配置已保存：%s（权限 600）\n' "$CONFIG_FILE"
fi

# Avoid creating a duplicate schedule when the legacy root crontab already
# invokes the same target script.
if crontab -l 2>/dev/null | grep -Fq "$TARGET_SCRIPT"; then
    printf '检测到现有 root crontab，未重复添加计划任务\n'
else
    printf '%s\n' \
        "*/5 * * * * root ${TARGET_SCRIPT} >> ${LOG_FILE} 2>&1" \
        >"$CRON_FILE"
    chmod 644 "$CRON_FILE"
    printf '已创建计划任务：%s\n' "$CRON_FILE"
fi

if [[ ! -e "$LOG_FILE" ]]; then
    install -o root -g root -m 640 /dev/null "$LOG_FILE"
fi

printf '\n安装完成。正在执行只读检查：\n'
"$TARGET_SCRIPT" --check

printf '\n测试手机通知：sudo %s --test\n' "$TARGET_SCRIPT"
