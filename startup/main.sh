#!/bin/bash
# ============================================================
# 服务管理脚本：启动 opencode Web / API 服务
#   更新装好后收到 USR1：停掉旧进程，重新启动（容器不退出）
#   docker stop 收到 TERM：停掉服务后退出
#   服务自己退出时容器结束，由 restart 策略拉起
#   有专用的停止/启动命令时，直接替换下面两个函数即可。
# ============================================================
set -euo pipefail

# 日志模块（构建时下载到 /opt/startup/log.sh）
. "$(dirname "${BASH_SOURCE[0]}")/log.sh"

svc_pid=""

# ------------------------------------------------------------
# 自定义区
# ------------------------------------------------------------
start_service() {
    opencode serve --hostname 0.0.0.0 --port "${PORT:-4096}" &
    svc_pid=$!
}

stop_service() {
    # 有专用停止命令（如 opencode service stop）就直接写在这里；
    # 当前服务是前台进程，默认发 TERM 等它退出。
    [ -z "$svc_pid" ] || kill -TERM "$svc_pid" 2>/dev/null || true
    [ -z "$svc_pid" ] || wait "$svc_pid" 2>/dev/null || true
}
# ------------------------------------------------------------

restart_requested=0
trap 'restart_requested=1; stop_service' USR1
trap 'stop_service; exit 143' TERM INT

while :; do
    restart_requested=0
    start_service
    if [ -z "$svc_pid" ]; then
        log -f error "start_service 没有设置 svc_pid"
        exit 1
    fi

    wait "$svc_pid" 2>/dev/null || true

    if [ "$restart_requested" -eq 1 ]; then
        log -f success "重启 opencode（应用更新）"
        continue
    fi

    log -f warn "opencode 已退出，容器结束"
    exit 0
done
