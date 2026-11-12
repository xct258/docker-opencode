#!/bin/bash
# ============================================================
# 启动前的准备：每次启动容器都执行（docker restart 也会执行）
#   检查 GIT_PUSH_TOKEN：
#   有的话配置 git 凭据和提交身份，容器里可以直接 clone / push。
#   这个变量只用于 git；GITHUB_TOKEN / GH_TOKEN 是 OpenCode 的
#   GitHub Copilot 认证变量，不要拿来配置推送。
#   没设置就跳过，不影响启动。
# ============================================================
set -euo pipefail

# 日志模块（构建时下载到 /opt/startup/log.sh）
. "$(dirname "${BASH_SOURCE[0]}")/log.sh"

TOKEN=${GIT_PUSH_TOKEN:-}

if [ -z "$TOKEN" ]; then
    log info "未设置 GIT_PUSH_TOKEN，跳过 git 凭据配置"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    log -f warn "设置了 Git 推送令牌，但镜像里没有 git"
    exit 0
fi

# 提交身份：可用环境变量覆盖
git config --global user.name "${GIT_USER_NAME:-opencode}"
git config --global user.email "${GIT_USER_EMAIL:-opencode@users.noreply.github.com}"

# 允许容器里操作挂载进来的仓库（避免 dubious ownership）
git config --global --add safe.directory '*'

# HTTPS 推送凭据：token 只放 600 的凭据文件，不写进 .gitconfig
git config --global credential.helper store
umask 077
printf 'https://x-access-token:%s@github.com\n' "$TOKEN" > "${HOME:-/root}/.git-credentials"
chmod 600 "${HOME:-/root}/.git-credentials"

log info "已配置 Git 推送令牌（git push 可用）"
