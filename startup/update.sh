#!/bin/bash
# ============================================================
# 自动更新 opencode（启动时检查 + 运行期按天检查）
#   由 template/start.sh 在 prepare 之后调用；UPDATE_INTERVAL_DAYS > 0 时
#   运行期也会按固定天数重复调用。流程：
#     1. 取当前版本（opencode --version）
#     2. 取官方更新接口的最新版本
#     3. 版本不同就用安装器装到指定版本
#   退出码：
#     0   = 已是最新（没有变化）
#     10  = 装了新版本（模板在 UPDATE_CHECK_AT 检查，装好立即重启服务）
#     其它 = 失败（默认只告警，旧版本继续跑）
#   安装器装到 $HOME/.opencode/bin，start.sh 已把这个目录加入 PATH。
#   安装器用 mv 原子替换二进制，不会影响正在运行的旧进程。
# ============================================================
set -euo pipefail

# 日志模块（构建时下载到 /opt/startup/log.sh）
. "$(dirname "${BASH_SOURCE[0]}")/log.sh"

cur=$(opencode --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//' || true)
latest=$(curl -fsSL --max-time 10 https://opencode.ai/update/api/latest/cli/npm 2>/dev/null \
    | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1 || true)

if [ -z "$latest" ]; then
    log -f warn "获取 opencode 最新版本失败，跳过更新"
elif [ "$cur" = "$latest" ]; then
    log info "opencode 已是最新（${cur}）"
else
    log -f success "更新 opencode：${cur:-未安装} -> ${latest}"
    curl -fsSL --max-time 300 https://opencode.ai/v2/install | bash -s -- --version "$latest"
    exit 10
fi
