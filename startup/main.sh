#!/bin/bash
# ============================================================
# 服务管理脚本：启动 opencode Web / API 服务
#   更新装好后收到 USR1：停掉旧进程，重新启动（容器不退出）
#   docker stop 收到 TERM：停掉服务后退出
#   服务自己退出时容器结束，由 restart 策略拉起
# ============================================================
set -euo pipefail

# 日志模块（构建时下载到 /opt/startup/log.sh）
. "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# 服务日志：opencode 的 stdout/stderr 全部写这里，不进 docker logs
#   每天 00:00 归档为 opencode.log-YYYY-MM-DD，只保留最新 15 天
SERVICE_LOG=${SERVICE_LOG:-/data/logs/opencode/opencode.log}
SERVICE_LOG_KEEP_DAYS=${SERVICE_LOG_KEEP_DAYS:-15}
mkdir -p "$(dirname "$SERVICE_LOG")"

rotate_service_log() {
    local archive
    [ -s "$SERVICE_LOG" ] || return 0

    # 00:00 执行，归档的是昨天那一份
    archive="${SERVICE_LOG}-$(date -d yesterday '+%Y-%m-%d')"
    cp "$SERVICE_LOG" "$archive" && : > "$SERVICE_LOG"

    # 只保留最新 N 天
    ls -1t -- "${SERVICE_LOG}"-* 2>/dev/null \
        | tail -n +"$(( SERVICE_LOG_KEEP_DAYS + 1 ))" \
        | xargs -r rm -f --
}

sleep_until_midnight() {
    local now target
    now=$(date +%s)
    target=$(date -d "tomorrow 00:00" +%s 2>/dev/null || echo 0)
    if [ "$target" -gt "$now" ]; then
        sleep "$(( target - now ))"
    else
        sleep 86400
    fi
}

log_rotate_loop() {
    while :; do
        sleep_until_midnight
        rotate_service_log
    done
}

# ------------------------------------------------------------
# 启动后打印一次服务信息到 docker logs（端口 / 密码）
#   其余时间 docker logs 只输出：更新重启、异常退出
# ------------------------------------------------------------
print_start_info() {
    log -f success "opencode 已启动（PID ${svc_pid}）"
    log -f info "访问端口: ${PORT:-4096}"
    if [ -n "${OPENCODE_PASSWORD:-}" ]; then
        log -f info "密码: ${OPENCODE_PASSWORD}"
    else
        log -f info "密码: 未设置，见 ${SERVICE_LOG}"
    fi
}

svc_pid=""

# ------------------------------------------------------------
# 自定义区
# ------------------------------------------------------------
start_service() {
    opencode serve --hostname 0.0.0.0 --port "${PORT:-4096}" --print-logs >> "$SERVICE_LOG" 2>&1 &
    svc_pid=$!
}

stop_service() {
    # 有专用停止命令（如 opencode service stop）就直接写在这里；
    # 当前服务是前台进程，默认发 TERM 等它退出。
    [ -z "$svc_pid" ] || kill -TERM "$svc_pid" 2>/dev/null || true
    [ -z "$svc_pid" ] || wait "$svc_pid" 2>/dev/null || true
}
# ------------------------------------------------------------

log_rotate_loop &
restart_requested=0
first_start=1
trap 'restart_requested=1; stop_service' USR1
trap 'stop_service; exit 143' TERM INT

while :; do
    restart_requested=0
    start_service
    if [ -z "$svc_pid" ]; then
        log -f error "start_service 没有设置 svc_pid"
        exit 1
    fi

    if [ "$first_start" -eq 1 ]; then
        print_start_info
        first_start=0
    else
        log info "opencode 已重启（PID ${svc_pid}）"
    fi

    code=0
    wait "$svc_pid" 2>/dev/null || code=$?

    if [ "$restart_requested" -eq 1 ]; then
        log -f success "重启 opencode（应用更新）"
        continue
    fi

    if [ "$code" -ne 0 ]; then
        log -f error "opencode 异常退出（exit ${code}），容器结束"
    else
        log info "opencode 已退出（exit 0），容器结束"
    fi
    exit "$code"
done
