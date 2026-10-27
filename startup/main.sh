#!/bin/bash
# ============================================================
# 容器主进程：前台运行 opencode 的 Web / API 服务
#   exec 之后 serve 接管 PID 1，docker stop 的 SIGTERM 才能直接送达
#   日志直接输出到 docker logs
#   密码取自 OPENCODE_PASSWORD；没设置时会随机生成并打印在日志里
# ============================================================
set -euo pipefail

exec opencode serve --hostname 0.0.0.0 --port "${PORT:-4096}"
