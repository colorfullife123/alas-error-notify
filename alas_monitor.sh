#!/usr/bin/env bash

set -uo pipefail

VERSION="1.0.0"
CONFIG_FILE="${ALAS_MONITOR_CONFIG:-/etc/alas-monitor.conf}"

# Defaults may be overridden by CONFIG_FILE.
CONTAINER="alas"
MQTT_PORT="1883"
MQTT_TOPIC="nas/alas/error"
MQTT_QOS="1"
MQTT_TIMEOUT_SECONDS="10"
ERROR_DIR=""
IMAGE_TARGET=""
IMAGE_MAX_AGE_MINUTES="30"
STATE_DIR="/var/lib/alas-manual-alert"
LOCK_FILE="/run/alas-manual-alert.lock"
LOOKBACK="15m"
HOST_LABEL="$(hostname 2>/dev/null || printf 'NAS')"
MANUAL_PATTERN='Request human takeover|Manual intervention required'

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

if [[ ! -r "$CONFIG_FILE" ]]; then
    die "配置文件不可读：${CONFIG_FILE}"
fi

# The configuration is installed as root-owned mode 600 by install.sh.
# shellcheck source=/dev/null
source "$CONFIG_FILE"

for command_name in docker mosquitto_pub timeout flock sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || \
        die "缺少命令：${command_name}"
done

[[ -n "${MQTT_HOST:-}" ]] || die "MQTT_HOST 未配置"
[[ -n "${MQTT_TOPIC:-}" ]] || die "MQTT_TOPIC 未配置"
[[ "$MQTT_QOS" =~ ^[012]$ ]] || die "MQTT_QOS 必须是 0、1 或 2"
[[ "$MQTT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
    die "MQTT_TIMEOUT_SECONDS 必须是正整数"
[[ "$IMAGE_MAX_AGE_MINUTES" =~ ^[1-9][0-9]*$ ]] || \
    die "IMAGE_MAX_AGE_MINUTES 必须是正整数"

umask 077

publish_mqtt() {
    local message="$1"
    local -a args=(
        -h "$MQTT_HOST"
        -p "$MQTT_PORT"
        -q "$MQTT_QOS"
        -t "$MQTT_TOPIC"
        -m "$message"
    )

    if [[ -n "${MQTT_USER:-}" ]]; then
        args+=( -u "$MQTT_USER" )
    fi

    if [[ -n "${MQTT_PASS:-}" ]]; then
        args+=( -P "$MQTT_PASS" )
    fi

    # Intentionally omit -r: stale alerts must not be replayed after HA restarts.
    timeout "${MQTT_TIMEOUT_SECONDS}s" mosquitto_pub "${args[@]}"
}

container_running() {
    [[ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$CONTAINER" 2>/dev/null
    )" == "true" ]]
}

recent_logs() {
    docker logs \
        --since "$LOOKBACK" \
        --timestamps \
        "$CONTAINER" 2>&1 || true
}

clean_control_codes() {
    # Remove common ANSI terminal escape sequences from notification text.
    sed -E $'s/\x1B\[[0-9;?]*[ -\/]*[@-~]//g'
}

manual_matches() {
    grep -Ei "$MANUAL_PATTERN" || true
}

find_recent_image() {
    [[ -n "$ERROR_DIR" && -d "$ERROR_DIR" ]] || return 0

    find "$ERROR_DIR" \
        -type f \
        -name '*.png' \
        -mmin "-${IMAGE_MAX_AGE_MINUTES}" \
        -printf '%T@ %p\n' \
        2>/dev/null |
        sort -nr |
        head -n 1 |
        cut -d' ' -f2-
}

show_check() {
    local logs matches

    printf '版本：%s\n' "$VERSION"
    printf '配置：%s\n' "$CONFIG_FILE"
    printf '容器：%s (%s)\n' \
        "$CONTAINER" \
        "$(container_running && printf '运行中' || printf '未运行')"
    printf 'MQTT：%s:%s → %s (QoS %s)\n' \
        "$MQTT_HOST" "$MQTT_PORT" "$MQTT_TOPIC" "$MQTT_QOS"
    printf '日志窗口：%s\n' "$LOOKBACK"
    printf '人工接管规则：%s\n' "$MANUAL_PATTERN"

    logs="$(recent_logs | clean_control_codes)"
    matches="$(printf '%s\n' "$logs" | manual_matches)"

    if [[ -n "$matches" ]]; then
        printf '\n最近发现明确人工接管标志：\n%s\n' "$matches"
    else
        printf '最近没有人工接管标志\n'
    fi

    if [[ -f "$STATE_DIR/last_event.sha256" ]]; then
        printf '去重状态：已记录上一次告警\n'
    else
        printf '去重状态：尚无告警记录\n'
    fi
}

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

case "${1:-}" in
    --test)
        TEST_MESSAGE="$(
            printf '%s\n' \
                'ALAS 人工接管通知测试' \
                "设备：${HOST_LABEL}" \
                'MQTT → Home Assistant 通知链工作正常。' \
                '实际运行只会在 ALAS 明确请求人工接管时推送。'
        )"

        if publish_mqtt "$TEST_MESSAGE"; then
            printf 'MQTT 人工接管通知测试发送成功\n'
            exit 0
        fi

        die "MQTT 人工接管通知测试发送失败"
        ;;

    --check)
        show_check
        exit 0
        ;;

    --version)
        printf '%s\n' "$VERSION"
        exit 0
        ;;

    "")
        ;;

    *)
        printf '用法：%s [--check|--test|--version]\n' "$0" >&2
        exit 2
        ;;
esac

# Container/ADB recovery belongs to a separate watchdog. Avoid evaluating stale
# logs while ALAS is stopped.
container_running || exit 0

ALL_LOG="$(recent_logs | clean_control_codes)"
MANUAL_MATCHES="$(printf '%s\n' "$ALL_LOG" | manual_matches)"

# WARNING, Traceback, AttributeError and GameStuckError are deliberately ignored.
[[ -n "$MANUAL_MATCHES" ]] || exit 0

LATEST_MATCH="$(printf '%s\n' "$MANUAL_MATCHES" | tail -n 1)"
EVENT_ID="$(printf '%s\n' "$LATEST_MATCH" | sha256sum | awk '{print $1}')"
LAST_EVENT_FILE="$STATE_DIR/last_event.sha256"

if [[ -f "$LAST_EVENT_FILE" ]] && \
   [[ "$(head -n 1 "$LAST_EVENT_FILE" 2>/dev/null)" == "$EVENT_ID" ]]; then
    exit 0
fi

IMAGE="$(find_recent_image)"

if [[ -n "$IMAGE" && -n "$IMAGE_TARGET" ]]; then
    mkdir -p "$(dirname "$IMAGE_TARGET")"

    if install -m 644 "$IMAGE" "$IMAGE_TARGET"; then
        printf '错误截图已更新：%s\n' "$IMAGE"
    else
        printf '错误截图更新失败：%s\n' "$IMAGE" >&2
    fi
fi

CONTEXT="$(printf '%s\n' "$ALL_LOG" | tail -n 60)"

if (( ${#CONTEXT} > 3000 )); then
    CONTEXT="${CONTEXT: -3000}"
fi

MESSAGE="$(
    printf '%s\n' \
        'ALAS 需要手动接管' \
        "设备：${HOST_LABEL}" \
        "检测时间：$(date '+%F %T %Z')" \
        '' \
        'ALAS 已完成自动重试，但仍无法恢复。' \
        "最终状态：${LATEST_MATCH}" \
        '' \
        '最近日志：' \
        "$CONTEXT"
)"

if publish_mqtt "$MESSAGE"; then
    TEMPORARY_STATE="${LAST_EVENT_FILE}.tmp.$$"
    printf '%s\n' "$EVENT_ID" >"$TEMPORARY_STATE"
    chmod 600 "$TEMPORARY_STATE"
    mv -f "$TEMPORARY_STATE" "$LAST_EVENT_FILE"

    printf '人工接管通知已发送：%s\n' "$LATEST_MATCH"
    exit 0
fi

printf '人工接管通知发送失败，下次计划任务会重试\n' >&2
exit 1
