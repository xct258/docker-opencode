#!/bin/bash
# ============================================================
# 启动前的准备：每次启动容器都执行（docker restart 也会执行）
#   适合：设密码、改配置、建目录这类可重复执行的操作
#   环境变量来自 docker-compose 的 environment
# ============================================================
set -euo pipefail

# 日志模块（构建时下载到 /opt/startup/log.sh）
#   log <级别> <消息>：写文件（/data/logs）；加 -f 才会打印到 docker logs
#   级别：debug / success / info / warn / error / fatal
. "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# 示例：把环境变量落到 /data，供主进程读取
# [ -z "${APP_PASSWORD:-}" ] || printf '%s\n' "$APP_PASSWORD" > /data/password

log info "完成"
