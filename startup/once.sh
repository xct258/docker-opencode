#!/bin/bash
# ============================================================
# 只执行一次：第一次启动时执行，成功后写标记 /data/.startup-once.done
#   适合：初始化数据目录、生成配置文件、建表/迁移这类不能重复执行的操作
#   想再执行一次：删掉 /data/.startup-once.done 后重启容器
# ============================================================
set -euo pipefail

# 日志模块（构建时下载到 /opt/startup/log.sh）
. "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# 示例：首次启动时生成配置
# mkdir -p /data/app
# if [ ! -f /data/app/config.yml ]; then
#     cp /workspace/config.example.yml /data/app/config.yml
# fi

# 正常步骤只进文件；出错时用 log -f error "..." 才会进 docker logs
log info "完成"
