#!/bin/bash
# ============================================================
# 自定义安装脚本（构建时执行一次）
#   apt / pip 之外的操作写在这里：下载二进制、编译安装等
#   由 install.sh 在 apt / pip 之后调用
#   装到 $HOME 下 bin 目录的可执行文件，运行期会自动加入 PATH（见 template/start.sh）
#   下面示例用 curl / tar，app.conf 的 APT_PACKAGES 里要有 curl（默认已包含）
#   不需要时把 app.conf 的 INSTALL_CUSTOM 设为 false
# ============================================================
set -euo pipefail

# 目标架构：buildx 注入 TARGETARCH（amd64 / arm64）；单独执行时回退 uname
target_arch="${TARGETARCH:-}"
if [ -z "$target_arch" ]; then
    case "$(uname -m)" in
        x86_64) target_arch=amd64 ;;
        aarch64|arm64) target_arch=arm64 ;;
        *) target_arch="$(uname -m)" ;;
    esac
fi
echo "[custom] 目标架构: ${target_arch}"

# ------------------------------------------------------------
# 架构命名映射：arch_name <amd64 的写法> <arm64 的写法>
#   Docker 只会告诉我们是 amd64 / arm64，但各项目发版命名不同，
#   下载前先换成项目自己的写法：
#     arch_name x64     arm64      → linux-x64      / linux-arm64
#     arch_name x86_64  aarch64    → x86_64         / aarch64
#     arch_name amd64   arm64      → 项目本来就用 Docker 命名（可直接用 ${target_arch}）
#   遇到未知架构直接失败，避免下错包到运行时才报 exec format error
# ------------------------------------------------------------
arch_name() {
    case "$target_arch" in
        amd64) echo "$1" ;;
        arm64) echo "$2" ;;
        *)
            echo "[custom] 不支持的架构: ${target_arch}" >&2
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# 示例 1：项目本来就用 amd64 / arm64（OpenList）
#   资产名 = openlist-linux-${target_arch}.tar.gz，包内只有 openlist 一个文件
#   加 -lite 后缀可换成精简版（体积更小）
# ------------------------------------------------------------
# echo "[custom] 正在安装 OpenList..."
# url="https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-linux-${target_arch}.tar.gz"
# curl -fsSL --retry 3 --retry-delay 5 "$url" | tar -xzO openlist > /usr/local/bin/openlist
# chmod +x /usr/local/bin/openlist
# echo "[custom] OpenList 安装完成"

# ------------------------------------------------------------
# 示例 2：项目用 x64 / aarch64 命名（不是 amd64 / arm64）
#   先 arch_name 换成项目命名，再拼资产名
#   注意：资产名里带版本号的项目不能用 latest/download，要查 API 后拼完整 URL
# ------------------------------------------------------------
# echo "[custom] 正在安装 foo..."
# foo_arch=$(arch_name x64 aarch64)
# url="https://github.com/owner/foo/releases/latest/download/foo-linux-${foo_arch}.tar.gz"
# curl -fsSL --retry 3 --retry-delay 5 "$url" | tar -xzO foo > /usr/local/bin/foo
# chmod +x /usr/local/bin/foo
# echo "[custom] foo 安装完成"

# ------------------------------------------------------------
# 示例 3：资产名带版本号时，先取 tag 再拼 URL（无需 jq）
#   适用于 7-Zip、Node.js 这类把版本写进文件名的项目
# ------------------------------------------------------------
# foo_ver=$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
#     https://github.com/owner/foo/releases/latest | sed 's#.*/tag/##')
# url="https://github.com/owner/foo/releases/download/${foo_ver}/foo-${foo_ver}-linux-${foo_arch}.tar.gz"

echo "[custom] 自定义安装完成"
