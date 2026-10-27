#!/bin/bash
# ============================================================
# 本地自查：push 前跑一遍，提前发现路径/语法/配置问题
#   用法：bash check.sh
#   CI 的 Validate 步骤调用同一个脚本，本地和线上结果一致
#   只做静态检查，不需要 Docker
# ============================================================
set -uo pipefail
cd "$(dirname "$0")"

pass=0
fail=0
ok() { echo "  [OK]   $*"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $*"; fail=$((fail + 1)); }
skip() { echo "  [SKIP] $*"; }
warn() { echo "  [WARN] $*"; }
section() { printf '\n== %s ==\n' "$*"; }

# ------------------------------------------------------------
# 1. 必备文件
# ------------------------------------------------------------
section "必备文件"
files=(
    install/app.conf
    install/install.sh
    startup/prepare.sh
    startup/once.sh
    startup/main.sh
    template/Dockerfile
    template/start.sh
    docker-compose.yml
    .github/workflows/build-image.yml
)
for f in "${files[@]}"; do
    if [ -f "$f" ]; then ok "$f"; else bad "缺少 $f"; fi
done

# ------------------------------------------------------------
# 2. 脚本语法
# ------------------------------------------------------------
section "脚本语法"
for f in check.sh install/*.sh startup/*.sh template/start.sh; do
    [ -f "$f" ] || continue
    if err=$(bash -n "$f" 2>&1); then
        ok "$f"
    else
        bad "$f 语法错误：${err}"
    fi
done

# ------------------------------------------------------------
# 3. install/app.conf 内容
# ------------------------------------------------------------
section "install/app.conf"
err_file=$(mktemp)
if source install/app.conf 2>"$err_file"; then
    ok "可正常 source"
else
    bad "source 失败：$(cat "$err_file")"
fi
rm -f "$err_file"

[ -n "${IMAGE_REPO:-}" ] && ok "IMAGE_REPO=${IMAGE_REPO}" || bad "IMAGE_REPO 未设置"
[ -n "${IMAGE_TAG:-}" ] && ok "IMAGE_TAG=${IMAGE_TAG}" || bad "IMAGE_TAG 未设置"

case "${PLATFORMS:-}" in
    linux/*) ok "PLATFORMS=${PLATFORMS}" ;;
    "") bad "PLATFORMS 未设置" ;;
    *) bad "PLATFORMS 应以 linux/ 开头（当前：${PLATFORMS}）" ;;
esac

for k in INSTALL_7Z INSTALL_CUSTOM; do
    case "${!k:-false}" in
        true | false) ok "$k=${!k:-false}" ;;
        *) bad "$k 只能是 true / false（当前：${!k:-}）" ;;
    esac
done

if [ "${INSTALL_CUSTOM:-false}" = "true" ]; then
    if [ ! -f install/custom-install.sh ]; then
        bad "INSTALL_CUSTOM=true，但缺少 install/custom-install.sh"
    elif err=$(bash -n install/custom-install.sh 2>&1); then
        ok "install/custom-install.sh"
    else
        bad "custom-install.sh 语法错误：${err}"
    fi
fi

# ------------------------------------------------------------
# 4. Dockerfile 与仓库文件是否对得上
# ------------------------------------------------------------
section "Dockerfile 引用"
while read -r p; do
    [ -n "$p" ] || continue
    # 带变量的路径（如 startup/${f}）在下面单独校验
    case "$p" in *'${'*) continue ;; esac
    if [ -f "$p" ]; then ok "下载 $p"; else bad "Dockerfile 下载的 $p 在仓库中不存在"; fi
done < <(grep -o '\${REPO_URL}/[^" ]*' template/Dockerfile | sed 's#\${REPO_URL}/##')

dl_names=$(sed -n 's/.*for f in \(.*\); do.*/\1/p' template/Dockerfile | xargs -n1 2>/dev/null | sort)
repo_names=$(ls startup/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | sort)
if [ "$dl_names" = "$repo_names" ]; then
    ok "startup 列表一致：$(echo "$repo_names" | tr '\n' ' ')"
else
    bad "Dockerfile 的 startup 列表与 startup/ 目录不一致"
    echo "         Dockerfile: $(echo "$dl_names" | tr '\n' ' ')" >&2
    echo "         仓库目录  : $(echo "$repo_names" | tr '\n' ' ')" >&2
fi

# 运行期脚本目录：start.sh 的 DIR 必须与 Dockerfile 的安装路径一致
start_dir=$(sed -n 's/^DIR=//p' template/start.sh)
if [ -n "$start_dir" ] && grep -q "\"${start_dir}/" template/Dockerfile; then
    ok "start.sh DIR=${start_dir} 与 Dockerfile 安装路径一致"
else
    bad "start.sh 的 DIR=${start_dir} 在 Dockerfile 里找不到对应安装路径"
fi

# 构建期配置：install.sh 读的 app.conf 必须是 Dockerfile 下载到的位置
conf_path=$(sed -n 's/^CONF=//p' install/install.sh)
if [ -n "$conf_path" ] && grep -q -- "$conf_path" template/Dockerfile; then
    ok "install.sh CONF=${conf_path} 在 Dockerfile 中有对应下载"
else
    bad "install.sh 的 CONF=${conf_path} 在 Dockerfile 里找不到对应下载"
fi

# 入口：ENTRYPOINT 指向的路径必须是 Dockerfile 里 start.sh 的安装位置
entry=$(sed -n 's/^ENTRYPOINT \["\(.*\)"\]$/\1/p' template/Dockerfile)
if [ -n "$entry" ] && grep -qF "template/start.sh\" ${entry}" template/Dockerfile; then
    ok "ENTRYPOINT ${entry} 与 start.sh 安装路径一致"
else
    bad "ENTRYPOINT 指向 ${entry:-未定义}，但 Dockerfile 没有把 start.sh 安装到该路径"
fi

# ------------------------------------------------------------
# 5. docker-compose.yml 与 app.conf 的镜像名是否一致
# ------------------------------------------------------------
section "docker-compose.yml"
compose_img=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' docker-compose.yml | head -1)
compose_img="${compose_img//\"/}"
compose_img="${compose_img//\'/}"
expected_img="${IMAGE_REPO:-}:${IMAGE_TAG:-}"
if [ "$compose_img" = "$expected_img" ]; then
    ok "镜像名与 app.conf 一致：${expected_img}"
else
    bad "compose 镜像 ${compose_img} ≠ app.conf 的 ${expected_img}"
fi

compose_name=$(sed -n 's/^[[:space:]]*container_name:[[:space:]]*//p' docker-compose.yml | head -1)
compose_name="${compose_name//\"/}"
compose_name="${compose_name//\'/}"
if [ "$compose_name" = "my-image" ]; then
    warn "container_name 还是模板默认值 my-image，部署前记得改（不强制校验）"
else
    ok "container_name=${compose_name}（不校验唯一性）"
fi

# ------------------------------------------------------------
# 6. YAML 解析
# ------------------------------------------------------------
section "YAML"
yamls=(docker-compose.yml .github/workflows/build-image.yml)
if python3 -c 'import yaml' 2>/dev/null; then
    for f in "${yamls[@]}"; do
        if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null; then
            ok "$f"
        else
            bad "$f 解析失败"
        fi
    done
elif command -v node >/dev/null 2>&1 && node -e 'require("yaml")' 2>/dev/null; then
    if node -e 'const y=require("yaml"),fs=require("fs");for(const f of process.argv.slice(1))y.parse(fs.readFileSync(f,"utf8"))' "${yamls[@]}" 2>/dev/null; then
        ok "YAML 解析通过"
    else
        bad "YAML 解析失败"
    fi
else
    skip "没有 python3-yaml / node-yaml，跳过"
fi

# ------------------------------------------------------------
# 7. 可选：装了才检查
# ------------------------------------------------------------
section "可选工具"
# 只提示，不算失败（不同环境装不装、版本不同，避免影响构建）
if command -v shellcheck >/dev/null 2>&1; then
    if out=$(shellcheck -S error install/*.sh startup/*.sh template/start.sh 2>&1); then
        ok "shellcheck"
    else
        warn "shellcheck 报错：${out}"
    fi
else
    skip "未安装 shellcheck"
fi

# ------------------------------------------------------------
# 汇总
# ------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo
    echo "全部通过（${pass} 项）"
    exit 0
else
    echo
    echo "失败 ${fail} 项，通过 ${pass} 项"
    exit 1
fi
