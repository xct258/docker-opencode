#!/bin/bash
# ============================================================
# 服务进程：前台运行 opencode 的 Web / API 服务
#   由 start.sh 监管：exec 之后 serve 取代 main.sh 这个子进程，
#   容器主进程仍是 start.sh（配了 init: true 时是 tini）。
#   docker stop 的 SIGTERM、更新后的重启请求都由 start.sh 转发过来，
#   所以更新时只重启本进程，容器保持运行。
#   日志直接输出到 docker logs
#   密码取自 OPENCODE_PASSWORD；没设置时会随机生成并打印在日志里
# ============================================================
set -euo pipefail

exec opencode serve --hostname 0.0.0.0 --port "${PORT:-4096}"
