#!/bin/bash
# ============================================================
# 容器启动入口（固定模板，无需修改）
#   1. startup/prepare.sh  每次启动容器都执行（重启也执行）
#   2. startup/once.sh     只执行一次（标记文件 /data/.startup-once.done）
#   3. startup/main.sh     容器主进程（exec 前台运行）
#   三个脚本在仓库 startup/ 目录，构建时下载到 /opt/startup
# ============================================================
set -euo pipefail

DIR=/opt/startup
ONCE_MARK=/data/.startup-once.done

mkdir -p /data

# ------------------------------------------------------------
# 日志模块：构建时从 common 仓库下载到 /opt/startup/log.sh
#   log <级别> <消息>     写文件 + 打印（非终端时不打印，见 log.sh）
#   log -f <级别> <消息>  强制打印，容器里用它才能进 docker logs
#   级别：debug / success / info / warn / error / fatal
#   文件落在 ${LOG_BASE_DIR}/<脚本名>/年/月/日/，默认保留 30 个
#   来源见 install/app.conf 的 LOG_LIB_URL
# ------------------------------------------------------------
LOG_BASE_DIR=${LOG_BASE_DIR:-/data/logs}
export LOG_BASE_DIR
if [ ! -f "${DIR}/log.sh" ]; then
    echo "[start] 缺少 ${DIR}/log.sh（检查 install/app.conf 的 LOG_LIB_URL）" >&2
    exit 1
fi
. "${DIR}/log.sh"

# ------------------------------------------------------------
# 0. 补全 PATH
#    安装器（opencode / bun / uv 等）把可执行文件放在 $HOME 下的 bin 目录，
#    只把该目录写进 ~/.bashrc / ~/.profile；容器启动用的是非交互 shell，
#    不会加载这些文件，直接用命令会「未找到」。这里把目录加进 PATH，
#    命令就能直接运行。
# ------------------------------------------------------------
mapfile -t bin_dirs < <(find "${HOME:-/root}" -xdev -path '*/bin/*' \
    -type f -perm -u+x -printf '%h\n' 2>/dev/null | sort -u)
for dir in "${bin_dirs[@]}"; do
    PATH="${dir}:${PATH}"
done
export PATH

# ------------------------------------------------------------
# 0.1 启动失败处理
#   启动阶段的错误（端口占用、配置写错、依赖没装）重试不会自己好。
#   「重试」是 Docker 的 restart 策略在拉起容器，不是脚本自己循环，
#   所以脚本只负责判断：还要不要继续让它拉起。
#   STARTUP_RETRY 指定最多重试几次（默认 0 = 不重试）：
#     未超限 -> 退出，让 restart 策略重新拉起
#     已超限 -> 打印原因后停住，不再重启，避免刷屏
#   计数存在 /data/.startup-attempts，启动成功后自动清除
# ------------------------------------------------------------
STARTUP_RETRY=${STARTUP_RETRY:-0}
case "$STARTUP_RETRY" in '' | *[!0-9]*) STARTUP_RETRY=0 ;; esac
ATTEMPT_FILE=/data/.startup-attempts

fail_start() {
    local name=$1 code=$2 used=0
    if [ -f "$ATTEMPT_FILE" ]; then
        used=$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)
    fi
    case "$used" in '' | *[!0-9]*) used=0 ;; esac
    used=$((used + 1))
    echo "$used" > "$ATTEMPT_FILE"

    log -f error "${name} 失败（exit ${code}）"
    if [ "$used" -le "$STARTUP_RETRY" ]; then
        log -f warn "第 ${used}/${STARTUP_RETRY} 次重试：等待 restart 策略重新拉起"
        exit "$code"
    fi
    log -f error "不再重试（STARTUP_RETRY=${STARTUP_RETRY}）；修复后执行 docker compose restart"
    exec sleep infinity
}

run_step() {
    local name=$1 script=$2 code=0
    bash "$script" || code=$?
    [ "$code" -eq 0 ] || fail_start "$name" "$code"
}

# ------------------------------------------------------------
# 1. 启动前的准备：每次启动都执行
# ------------------------------------------------------------
log -f info "prepare"
run_step prepare "${DIR}/prepare.sh"

# ------------------------------------------------------------
# 2. 只执行一次：初始化数据等，成功后写标记，之后不再执行
#    要重新执行就删掉标记文件；标记在 /data 里，随数据卷保留
# ------------------------------------------------------------
if [ -f "$ONCE_MARK" ]; then
    log -f info "once 已执行过，跳过"
else
    log -f info "once"
    run_step once "${DIR}/once.sh"
    touch "$ONCE_MARK"
fi

# ------------------------------------------------------------
# 3. 主进程：必须前台运行，docker stop 才能优雅退出
#    走到这里说明启动成功，清掉失败计数
# ------------------------------------------------------------
rm -f "$ATTEMPT_FILE"
log -f info "main"
exec bash "${DIR}/main.sh"
