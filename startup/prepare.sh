#!/bin/bash
# ============================================================
# 启动前的准备：每次启动容器都执行（docker restart 也会执行）
#   适合：设密码、改配置、建目录这类可重复执行的操作
#   环境变量来自 docker-compose 的 environment
# ============================================================
set -euo pipefail

# 示例：把环境变量落到 /data，供主进程读取
# [ -z "${APP_PASSWORD:-}" ] || printf '%s\n' "$APP_PASSWORD" > /data/password

echo "[prepare] 完成"
