#!/bin/bash
# ============================================================
# 容器启动入口，同时充当 main.sh 的 supervisor（固定模板，无需修改）
#   start.sh 是容器主进程（配了 init: true 时由 tini 当 PID 1），
#   main.sh 作为子进程运行，可以单独重启而不影响容器。
#   1. startup/prepare.sh  每次启动容器都执行（重启也执行）
#   2. startup/update.sh   可选，每次启动检查服务更新（失败不阻塞启动）
#   3. startup/once.sh     只执行一次（标记文件 /data/.startup-once.done）
#   4. startup/main.sh     服务进程，由 start.sh 监管并按需重启
#   脚本在仓库 startup/ 目录，构建时下载到 /opt/startup
# ============================================================
set -euo pipefail

DIR=/opt/startup
ONCE_MARK=/data/.startup-once.done

mkdir -p /data

# ------------------------------------------------------------
# 日志模块：构建时从 common 仓库下载到 /opt/startup/log.sh
#   log <级别> <消息>     只写文件（${LOG_BASE_DIR}/<脚本名>/年/月/日/）
#   log -f <级别> <消息>  同时打印到控制台，即出现在 docker logs 里
# 这里的取舍：正常步骤（prepare / once）只进文件，
#   启动成功留一行 main，失败和重试全部进控制台
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
#    不会加载这些文件，直接用命令会「未找到」。这里只补常见目录：
#    不做全盘 find，避免 node_modules/.bin 之类拖慢启动、遮蔽系统命令。
#    其它目录用 EXTRA_PATH_DIRS 追加，冒号分隔，
#    如 EXTRA_PATH_DIRS=/opt/tools/bin:/workspace/bin
# ------------------------------------------------------------
path_dirs=(
    "${HOME:-/root}/.local/bin"
    "${HOME:-/root}/bin"
    "${HOME:-/root}/.opencode/bin"
    "${HOME:-/root}/.bun/bin"
    "${HOME:-/root}/.cargo/bin"
)
if [ -n "${EXTRA_PATH_DIRS:-}" ]; then
    IFS=: read -r -a extra_dirs <<<"$EXTRA_PATH_DIRS"
    path_dirs+=("${extra_dirs[@]}")
fi
path_prefix=""
for dir in "${path_dirs[@]}"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    case ":${path_prefix}:${PATH}:" in *":${dir}:"*) continue ;; esac
    path_prefix="${path_prefix:+${path_prefix}:}${dir}"
done
[ -z "$path_prefix" ] || PATH="${path_prefix}:${PATH}"
export PATH

# ------------------------------------------------------------
# 0.1 启动失败处理
#   启动阶段的错误（端口占用、配置写错、依赖没装）重试不会自己好。
#   「重试」是 Docker 的 restart 策略在拉起容器，不是脚本自己循环，
#   所以脚本只负责判断：还要不要继续让它拉起。
#   STARTUP_RETRY 指定最多重试几次（默认 0 = 不重试）：
#     未超限 -> 等待 STARTUP_RETRY_DELAY 秒后退出，让 restart 策略重新拉起
#     已超限 -> 打印原因后停住，不再重启，避免刷屏
#   计数存在 /data/.startup-attempts，启动成功后自动清除
# ------------------------------------------------------------
STARTUP_RETRY=${STARTUP_RETRY:-0}
case "$STARTUP_RETRY" in '' | *[!0-9]*) STARTUP_RETRY=0 ;; esac
STARTUP_RETRY_DELAY=${STARTUP_RETRY_DELAY:-5}
case "$STARTUP_RETRY_DELAY" in '' | *[!0-9]*) STARTUP_RETRY_DELAY=5 ;; esac
ATTEMPT_FILE=/data/.startup-attempts

# ------------------------------------------------------------
# 0.2 信号与子进程管理
#   start.sh 负责当 supervisor（配了 init: true 时由 tini 当 PID 1），
#   main.sh 作为子进程运行，不再接管 PID 1。
#   - 收到 TERM / INT：通知子进程退出，等宽限期后退出容器
#   - 收到 USR1       ：只重启 main.sh，容器保持运行（更新后用它生效）
# ------------------------------------------------------------
child_pid=""
stopping=0
restart_requested=0
SUPERVISOR_PID=$$
export SUPERVISOR_PID

# 每个子脚本单独起一个进程组：停止时能一次通知到脚本和它拉起的子进程。
# 没有 setsid 就退化成普通后台进程。
start_child() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" &
    else
        "$@" &
    fi
    child_pid=$!
    # 信号可能刚好在 fork 前到达（那时还没有子进程可通知），这里补一刀
    if [ "${stopping:-0}" -eq 1 ]; then
        kill -TERM -- "-$child_pid" 2>/dev/null || kill -TERM "$child_pid" 2>/dev/null || true
    fi
}

request_stop() {
    stopping=1
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM -- "-$child_pid" 2>/dev/null || kill -TERM "$child_pid" 2>/dev/null || true
    fi
}
request_restart() {
    restart_requested=1
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM -- "-$child_pid" 2>/dev/null || kill -TERM "$child_pid" 2>/dev/null || true
    fi
}
trap request_stop TERM INT
trap request_restart USR1

stop_exit() {
    log -f warn "收到停止信号，退出" || true
    exit 143
}

# 等子进程退出并回收它。
#   带 trap 时 wait 会被信号打断提前返回，所以不能把「wait 返回」
#   当成「进程已退出」，要循环等到进程真的没了。
#   收到停止/重启请求后最多等 grace 秒，超时强杀；grace=0 表示不强制。
wait_child() {
    local pid=$1 grace=$2 code=0 i=0 ticks=$(( ${2:-0} * 5 ))
    while :; do
        code=0
        wait "$pid" 2>/dev/null || code=$?
        kill -0 "$pid" 2>/dev/null || return "$code"

        if [ "$stopping" -eq 1 ] || [ "$restart_requested" -eq 1 ]; then
            if [ "$grace" -gt 0 ]; then
                while [ "$i" -lt "$ticks" ] && kill -0 "$pid" 2>/dev/null; do
                    sleep 0.2
                    i=$((i + 1))
                done
                if kill -0 "$pid" 2>/dev/null; then
                    log -f warn "子进程 ${pid} 在 ${grace}s 内没有退出，强制结束"
                    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
            code=0
            wait "$pid" 2>/dev/null || code=$?
            return "$code"
        fi
    done
}

# ------------------------------------------------------------
# 0.3 自动更新参数（更新逻辑写在 startup/update.sh，模板只负责调度）
#   UPDATE_ON_START       启动时是否检查，默认 1；0 / false / off 关闭
#   UPDATE_INTERVAL_DAYS  运行期每隔多少天检查一次，0 = 关闭（默认 0）
#   UPDATE_TIMEOUT        单次检查最长秒数，默认 60；超时按失败处理
#   UPDATE_STRICT         1 = 启动时检查失败按启动失败处理，默认 0（只告警）
#   UPDATE_RESTART        1 = 装到新版本后按 UPDATE_RESTART_AT 重启服务，默认 1
#   UPDATE_RESTART_AT     重启时间 HH:MM，默认 04:00（容器本地时间）
#   UPDATE_RESTART_GRACE  重启服务时等它退出的秒数，超时强杀；0 = 不强制
# ------------------------------------------------------------
UPDATE_ON_START=${UPDATE_ON_START:-1}
case "$UPDATE_ON_START" in '' | 0 | false | no | off) UPDATE_ON_START=0 ;; *) UPDATE_ON_START=1 ;; esac
UPDATE_INTERVAL_DAYS=${UPDATE_INTERVAL_DAYS:-0}
case "$UPDATE_INTERVAL_DAYS" in '' | *[!0-9]*) UPDATE_INTERVAL_DAYS=0 ;; esac
UPDATE_TIMEOUT=${UPDATE_TIMEOUT:-60}
case "$UPDATE_TIMEOUT" in '' | *[!0-9]*) UPDATE_TIMEOUT=60 ;; esac
UPDATE_STRICT=${UPDATE_STRICT:-0}
UPDATE_RESTART=${UPDATE_RESTART:-1}
case "$UPDATE_RESTART" in 0 | false | no | off) UPDATE_RESTART=0 ;; *) UPDATE_RESTART=1 ;; esac
UPDATE_RESTART_AT=${UPDATE_RESTART_AT:-04:00}
if ! date -d "today ${UPDATE_RESTART_AT}" +%s >/dev/null 2>&1; then
    log -f warn "UPDATE_RESTART_AT=${UPDATE_RESTART_AT} 不是有效的 HH:MM，改用 04:00"
    UPDATE_RESTART_AT=04:00
fi
UPDATE_RESTART_GRACE=${UPDATE_RESTART_GRACE:-10}
case "$UPDATE_RESTART_GRACE" in '' | *[!0-9]*) UPDATE_RESTART_GRACE=10 ;; esac
RESTART_AT_FILE=/data/.restart-at

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
        log -f warn "第 ${used}/${STARTUP_RETRY} 次重试：${STARTUP_RETRY_DELAY}s 后退出，等待 restart 策略重新拉起"
        # 不在脚本里循环：退出后由 Docker 拉起。先等一会儿，避免立即重启刷屏
        sleep "$STARTUP_RETRY_DELAY"
        exit "$code"
    fi
    log -f error "不再重试（STARTUP_RETRY=${STARTUP_RETRY}）；修复后执行 docker compose restart"
    # 停住等排查。不直接 exec sleep：exec 之后 bash 的 TERM handler 就没了，
    # docker stop 又会等 10 秒硬杀。放后台再 wait，信号仍由上面的 trap 处理。
    sleep infinity &
    child_pid=$!
    wait_child "$child_pid" 3 || true
    child_pid=""
    [ "$stopping" -eq 0 ] || stop_exit
    exit 0
}

run_step() {
    local name=$1 script=$2 code=0
    # 后台启动 + wait：这样收到停止信号时才能把 SIGTERM 转给子脚本。
    start_child bash "$script"
    wait_child "$child_pid" 3 || code=$?
    child_pid=""
    [ "$stopping" -eq 0 ] || stop_exit
    [ "$code" -eq 0 ] || fail_start "$name" "$code"
}

# ------------------------------------------------------------
# 自动更新（可选）
#   由 startup/update.sh 自己决定查什么、怎么更新（模板不知道具体服务）。
#   约定：
#     - 退出码 0      ：没有变化 / 已是最新
#     - 退出码 10     ：已装了新版本（定时检查据此只重启 main.sh 应用更新）
#     - 其它非 0      ：检查失败（没网、接口变了），默认只告警
#     - 超过 UPDATE_TIMEOUT 秒会被 timeout 终止（exit 124）
#   多实例共用 /data 时用 flock 串行，避免同时写同一个二进制。
# ------------------------------------------------------------

# 执行一次检查，原样返回 update.sh 的退出码（0 / 10 / 其它）
check_update_once() {
    local script="${DIR}/update.sh" code=0 lock=/data/.update.lock lock_opened=0

    [ -f "$script" ] || return 0

    if command -v flock >/dev/null 2>&1 && exec 9>"$lock" 2>/dev/null; then
        lock_opened=1
        if ! flock -n 9 2>/dev/null; then
            log warn "另一个更新进程在跑，跳过本轮"
            exec 9>&-
            return 0
        fi
    fi

    if [ "$UPDATE_TIMEOUT" -eq 0 ]; then
        log info "检查更新（不限时）"
    else
        log info "检查更新（最长 ${UPDATE_TIMEOUT}s）"
    fi
    if command -v timeout >/dev/null 2>&1; then
        start_child timeout "$UPDATE_TIMEOUT" bash "$script"
    else
        start_child bash "$script"
    fi
    # 后台 + wait：更新期间收到停止信号，trap 能立即中断，而不是等脚本跑完
    wait_child "$child_pid" 3 || code=$?
    child_pid=""
    [ "$lock_opened" -eq 0 ] || exec 9>&-

    return "$code"
}

# 启动时检查：失败默认不阻塞启动
run_update() {
    local code=0

    if [ "$UPDATE_ON_START" -eq 0 ]; then
        log info "UPDATE_ON_START=0，跳过启动时检查"
        return 0
    fi
    if [ ! -f "${DIR}/update.sh" ]; then
        log info "没有 update.sh，跳过自动更新"
        return 0
    fi

    check_update_once || code=$?
    [ "$stopping" -eq 0 ] || stop_exit

    # 10 = 已更新，同样是正常结果（此时 main.sh 还没启动，新版本直接生效）
    if [ "$code" -eq 0 ] || [ "$code" -eq 10 ]; then
        log success "更新检查完成"
        return 0
    fi
    if [ "$UPDATE_STRICT" = "1" ]; then
        fail_start update "$code"
        return 0
    fi
    if [ "$code" -eq 124 ]; then
        log -f warn "更新检查超时（${UPDATE_TIMEOUT}s），继续用当前版本启动"
    else
        log -f warn "更新检查失败（exit ${code}），继续用当前版本启动"
    fi
    return 0
}

# 计算下一次 HH:MM 的时间戳（今天的还没到就用今天，否则用明天）
next_restart_epoch() {
    local at=$1 now target
    now=$(date +%s)
    target=$(date -d "today ${at}" +%s 2>/dev/null || echo 0)
    if [ "$target" -le 0 ]; then
        echo 0
        return 0
    fi
    if [ "$target" -le "$now" ]; then
        target=$(date -d "tomorrow ${at}" +%s 2>/dev/null || echo 0)
    fi
    echo "$target"
}

# 装到新版本后不立刻重启，先记下重启时间；已有更早的安排就保留
schedule_restart() {
    local now target
    now=$(date +%s)

    if [ -f "$RESTART_AT_FILE" ]; then
        target=$(cat "$RESTART_AT_FILE" 2>/dev/null || echo 0)
        case "$target" in '' | *[!0-9]*) target=0 ;; esac
        if [ "$target" -gt "$now" ]; then
            log -f success "已更新；将在 $(date -d "@$target" '+%m-%d %H:%M') 重启服务"
            return 0
        fi
    fi

    target=$(next_restart_epoch "$UPDATE_RESTART_AT")
    if [ "$target" -le 0 ]; then
        log -f warn "无法计算重启时间（${UPDATE_RESTART_AT}），本次不安排重启"
        return 0
    fi
    # 原子写入，避免调度器读到半个文件
    echo "$target" > "${RESTART_AT_FILE}.tmp" && mv "${RESTART_AT_FILE}.tmp" "$RESTART_AT_FILE"
    log -f success "已更新；将在 $(date -d "@$target" '+%m-%d %H:%M') 重启服务"
}

# 到点后通知 supervisor 重启 main.sh，容器保持运行
restart_scheduler() {
    local target now
    while :; do
        sleep 20
        [ -f "$RESTART_AT_FILE" ] || continue
        target=$(cat "$RESTART_AT_FILE" 2>/dev/null || echo 0)
        case "$target" in '' | *[!0-9]*) rm -f "$RESTART_AT_FILE"; continue ;; esac
        now=$(date +%s)
        if [ "$now" -lt "$target" ]; then
            continue
        fi
        rm -f "$RESTART_AT_FILE"
        log -f success "到达 $(date '+%H:%M')，重启服务应用更新"
        kill -USR1 "$SUPERVISOR_PID" 2>/dev/null || true
    done
}

# 运行期定时检查：每 UPDATE_INTERVAL_DAYS 天跑一次，常驻后台
#   替换磁盘上的二进制不会影响已经在跑的进程，所以收到 10（装了新版本）
#   只记录重启时间，到 UPDATE_RESTART_AT 再重启；UPDATE_RESTART=0 则等下次重启。
update_loop() {
    local code=0
    while :; do
        sleep "$(( UPDATE_INTERVAL_DAYS * 86400 ))" &
        child_pid=$!
        wait "$child_pid" 2>/dev/null || true
        child_pid=""

        code=0
        check_update_once || code=$?
        if [ "$code" -eq 10 ]; then
            if [ "$UPDATE_RESTART" = "1" ]; then
                schedule_restart
            else
                log -f success "已更新；当前进程仍是旧版本，下次重启容器后生效"
            fi
        elif [ "$code" -ne 0 ]; then
            log -f warn "定时更新检查失败（exit ${code}），继续使用当前版本"
        fi
    done
}

# ------------------------------------------------------------
# 1. 启动前的准备：每次启动都执行
# ------------------------------------------------------------
log info "prepare"
run_step prepare "${DIR}/prepare.sh"

# ------------------------------------------------------------
# 2. 自动更新：每次启动检查服务是否有新版本
#    放在 prepare 之后（这时配置/代理已经就绪）、once 之前
#    （迁移/初始化最好跑在新版本上）
# ------------------------------------------------------------
log info "update"
run_update

# ------------------------------------------------------------
# 3. 只执行一次：初始化数据等，成功后写标记，之后不再执行
#    要重新执行就删掉标记文件；标记在 /data 里，随数据卷保留
# ------------------------------------------------------------
if [ -f "$ONCE_MARK" ]; then
    log info "once 已执行过，跳过"
else
    log info "once"
    run_step once "${DIR}/once.sh"
    touch "$ONCE_MARK"
fi

# ------------------------------------------------------------
# 4. 主进程管理：start.sh 当 supervisor，main.sh 作为子进程
#    走到这里说明 prepare / update / once 都成功，清掉失败计数。
#    main.sh 自己退出（崩溃/正常结束）时容器跟着结束，交给 restart 策略；
#    只有更新触发的重启（USR1）会原地重启 main.sh，容器保持运行。
# ------------------------------------------------------------
rm -f "$ATTEMPT_FILE"
# 启动时 main.sh 本来就会用磁盘上的当前版本，之前排队的重启没有意义
rm -f "$RESTART_AT_FILE" "${RESTART_AT_FILE}.tmp"

# ------------------------------------------------------------
# 4.1 定时检查：UPDATE_INTERVAL_DAYS > 0 时起一个常驻后台循环
#     在启动 main.sh 之前起好，之后它会作为 supervisor 的子进程一直跑；
#     容器停止时随命名空间一起结束。
#     UPDATE_RESTART=1 时再起一个调度器，到点只重启 main.sh。
# ------------------------------------------------------------
if [ "$UPDATE_INTERVAL_DAYS" -gt 0 ] && [ -f "${DIR}/update.sh" ]; then
    log info "启用定时更新检查：每 ${UPDATE_INTERVAL_DAYS} 天；更新后 ${UPDATE_RESTART_AT} 重启"
    update_loop &
    if [ "$UPDATE_RESTART" -eq 1 ]; then
        restart_scheduler &
    fi
fi

# 监管 main.sh：更新后只重启它，不重启容器
supervise_main() {
    local code=0
    while :; do
        [ "$stopping" -eq 0 ] || stop_exit
        restart_requested=0
        start_child bash "${DIR}/main.sh"
        code=0
        wait_child "$child_pid" "$UPDATE_RESTART_GRACE" || code=$?
        child_pid=""

        if [ "$stopping" -eq 1 ]; then
            stop_exit
        fi
        if [ "$restart_requested" -eq 1 ]; then
            log success "main 已重启（新版本生效）"
            continue
        fi
        log -f warn "main 已退出（exit ${code}），容器结束"
        exit "$code"
    done
}

log -f success "main（prepare/update/once 完成，启动 main.sh）"
supervise_main
