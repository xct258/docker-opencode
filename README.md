# Docker 镜像模板

只通过 GitHub Actions 构建：**改文件 → push → 在 Actions 页面手动触发构建多架构镜像并推送 Docker Hub**，本地不需要安装 Docker。

## 目录结构

```
.
├── install/              # 构建时：装依赖
│   ├── app.conf          # 配置：镜像名/架构/依赖
│   ├── install.sh        # apt / pip / 快捷安装
│   └── custom-install.sh # 可选：apt / pip 之外的操作
├── startup/              # 运行时：启动流程
│   ├── prepare.sh        # 每次启动都执行
│   ├── update.sh         # 可选：每次启动检查服务更新（失败不阻塞）
│   ├── once.sh           # 只执行一次
│   └── main.sh           # 服务管理脚本（自定义 start / stop）
├── template/             # 固定模板，无需修改
│   ├── Dockerfile
│   └── start.sh          # 依次调用 startup/ 下的三个脚本
├── check.sh              # 本地自查（push 前跑，CI 也用）
├── docker-compose.yml    # 部署配置（默认 host 网络）
└── .github/workflows/build-image.yml
```

`template/` 下的文件构建时从仓库下载，**不需要改**。

## 启动流程

容器启动时 `template/start.sh` 按顺序执行 `startup/` 下的脚本，最后 `exec main.sh`：

| 脚本 | 执行时机 | 放什么 |
|---|---|---|
| `prepare.sh` | **每次**启动（含 `docker restart`） | 设密码、改配置、建目录等可重复执行的操作 |
| `update.sh` | **每次**启动（可选，`prepare` 之后）；`UPDATE_INTERVAL_DAYS > 0` 时运行期按天定时执行 | 检查服务有没有新版本，有就更新（失败默认不阻塞） |
| `once.sh` | **只执行一次**（标记文件 `/data/.startup-once.done`） | 初始化数据、生成配置、建表/迁移等不能重复执行的操作 |
| `main.sh` | 启动时 `exec`，之后一直常驻 | 服务管理：`start_service` / `stop_service` 两个函数 |

`main.sh` 是常驻的服务管理脚本：

- 更新装好后收到 `USR1` → 调 `stop_service`，再 `start_service`（只重启服务，容器不动）
- `docker stop` 收到 `TERM` → 调 `stop_service`，然后退出
- 服务自己崩溃/退出 → `main.sh` 跟着退出，容器由 restart 策略拉起

- `once.sh` 成功后才写标记；想重新执行就删掉 `/data/.startup-once.done` 再重启
- 标记在 `/data` 里，跟着数据卷走；没挂卷时等同于每个容器一次
- `update.sh` 失败默认只告警、不阻塞启动（`UPDATE_STRICT=1` 时才按启动失败处理）
- 其余脚本失败（非 0 退出）容器就不会启动，日志里会打印**哪个脚本失败、退出码多少**

## 自动更新（启动时 + 定时，可选）

每次启动先跑 `startup/update.sh`：查当前版本 → 查最新版本 → 有更新就装。设置 `UPDATE_INTERVAL_DAYS` 之后，运行期间每隔 N 天在 `UPDATE_CHECK_AT`（默认凌晨 `04:00`）再检查一次。模板不知道你的服务怎么升级，所以只负责调度，逻辑写在 `startup/update.sh` 里（仓库自带空实现，以及 opencode / GitHub Releases 两个示例，取消注释即可用）。

**检查到新版本会立即重启服务**：`update.sh` 装好后返回 10，后台循环直接给 `main.sh` 发 `USR1`，由它调用 `stop_service` / `start_service`。因为检查本身就在凌晨 4 点，所以重启也发生在低峰期。

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `UPDATE_ON_START` | `1` | 启动时是否检查；`0` / `false` / `off` 关闭 |
| `UPDATE_INTERVAL_DAYS` | `0` | 运行期每多少**天**检查一次；`0` = 不启用，只在启动时查一次 |
| `UPDATE_CHECK_AT` | `04:00` | 定时检查时间，`HH:MM`（容器本地时间，配合 `TZ`） |
| `UPDATE_TIMEOUT` | `60` | 单次检查最长秒数（`0` = 不限时），超时按失败处理 |
| `UPDATE_STRICT` | `0` | `1` 时**启动时**检查失败按启动失败处理（走「启动失败与重试」） |
| `UPDATE_RESTART` | `1` | 装到新版本后立即重启 `main.sh`；`0` = 只装不重启 |

默认行为：**没网、接口变了、装失败，都只打一条 warn，旧版本继续跑**，不会因为更新检查把服务弄挂。

```yaml
    environment:
      # UPDATE_ON_START: 1
      # UPDATE_INTERVAL_DAYS: 1    # 每天查一次
      # UPDATE_CHECK_AT: "04:00"   # 凌晨 4 点检查（注意加引号）
      # UPDATE_TIMEOUT: 60
      # UPDATE_STRICT: 0
      # UPDATE_RESTART: 1          # 有更新立即重启（默认开）
```

`update.sh` 的退出码约定：

| 退出码 | 含义 | 模板怎么处理 |
|---|---|---|
| `0` | 没变化 / 已是最新 | 继续 |
| `10` | **装了新版本** | 启动时直接生效；定时检查时立即重启服务 |
| 其它 | 失败（没网、接口变了） | 启动时默认只告警；定时检查只告警 |

其它约定：

- 正常检查用 `log info`（只进文件）；**真的更新了**才用 `log -f success`（进 `docker logs`）
- 网络请求加 `--max-time`，没网时尽快跳过
- 运行期替换二进制用 `mv` 原子替换（`mktemp` + `mv`），直接覆盖正在执行的文件会 `ETXTBSY`
- 多个实例不要共用 `/data`（更新和日志都在里面）
- 定时循环是常驻进程，日志会一直追加到同一个文件（按文件数的 `LOG_MAX_FILES` 管不到它），长期运行注意日志大小

⚠️ **检查在 `UPDATE_CHECK_AT`，装完立即重启（容器不动）**：Linux 上替换正在运行的二进制不会影响已启动的进程（内存里还是旧的），所以检查到新版本、装完后马上给 `main.sh` 发 `USR1`，由它调用 `stop_service` / `start_service`。容器一直保持运行，`prepare` / `once` 不重跑，定时循环也不中断。

- 检查时间是容器本地时间，靠 `TZ` 决定；`UPDATE_CHECK_AT: "04:00"` 记得加引号（YAML 会把 `04:00` 当成数字）
- 间隔 N 天表示「每 N 天的这个时间检查一次」，不是从容器启动时间开始数
- `stop_service` 要确保服务真的停掉（有专用停止命令就直接用，别只 `kill` 一下）
- 想「只装、下次重启容器再生效」就设 `UPDATE_RESTART=0`
- `main.sh` 自己退出（崩溃/正常结束）时容器结束，由 restart 策略拉起

⚠️ **更新装进的是容器可写层**：`docker restart` 还在，但容器重建（`docker compose down/up`、换镜像）会回到镜像里构建时的版本，下次启动会重新检查。要永久保留就把二进制装到挂载卷（如 `/data/bin`），再用 `EXTRA_PATH_DIRS` 加进 `PATH`。

> 只想要「镜像本身更新」的场景不该用这个：重新构建/拉取镜像更干净。这个功能适合发布频繁、又不想每次重新出镜像的 CLI 服务。

## 启动失败与重试

**重试是 Docker 干的，不是脚本在循环。** `restart: unless-stopped` 下容器一退出就会被拉起，所以端口占用这类错误会一遍遍刷日志。

模板用一个变量决定「还让不让 Docker 继续拉起」：

```yaml
    environment:
      # 启动失败后最多重试几次，0 = 不重试
      STARTUP_RETRY: 0
      # 每次重试前等几秒再退出（默认 5），避免立即重启刷屏
      # STARTUP_RETRY_DELAY: 5
```

`template/start.sh` 的逻辑：

| `STARTUP_RETRY` | 失败时 |
|---|---|
| `0`（默认） | 记录失败脚本和退出码，然后**停住**（`sleep infinity`），不再重启 |
| `N > 0` | 等 `STARTUP_RETRY_DELAY` 秒（默认 5）后退出，让 restart 策略重新拉起；超过 N 次后停住 |

失败时的日志写进文件（容器内 `/data/logs/...`；宿主机要看 `data/logs/...` 需挂载 `./data`，见「部署」），长这样：

```
[2026-10-28 05:24:13] [prepare] ❌ 端口 4099 被占用
[2026-10-28 05:24:13] [start] ❌ prepare 失败（exit 1）
[2026-10-28 05:24:13] [start] ❌ 不再重试（STARTUP_RETRY=0）；修复后执行 docker compose restart
```

计数在 `/data/.startup-attempts`，启动成功后自动删除。修好配置后：

```bash
docker compose restart
```

容器停住时状态仍是 `Up`（进程是 `sleep infinity`），因为让它一直退出只会触发重启循环。判断启动是否走到服务阶段，看最新的 `start` 日志里有没有 `main`（这一行在启动 `main.sh` 前打印，只表示准备阶段完成；`main.sh` 里的命令是否真的起来了，以它自己的输出为准）：

```bash
# 需要挂载 ./data:/data，否则日志在容器内，宿主机的 data/logs 是空的
docker exec <容器名> tail -3 "$(docker exec <容器名> sh -c 'ls -t /data/logs/start/*/*/*/*.log | head -1')"
```

`STARTUP_RETRY` 只管**启动阶段**；`main.sh` 跑起来之后再崩溃/退出，容器会结束，仍由 `restart: unless-stopped` 拉起。

## 一次性准备

1. 修改 `install/app.conf` 里的 `IMAGE_REPO`（例如 `你的账号/镜像名`）
2. 仓库 Settings → Secrets and variables → Actions，添加：
   - `DOCKERACC`：Docker Hub 账号
   - `DOCKERPWD`：Docker Hub 密码或 Access Token
3. 部署前把 `docker-compose.yml` 的 `image` / `container_name` 改成自己的名字；镜像名和 `app.conf` 不一致时 `check.sh` 会报错

## 构建

| 触发方式 | 说明 |
|---|---|
| Actions 页面 → Run workflow | 手动构建（唯一触发方式） |

每次构建只推送一个标签：

```
<IMAGE_REPO>:<IMAGE_TAG>
```

`IMAGE_TAG` 在 `install/app.conf` 里改（默认 `latest`）。

构建失败或日志都在仓库的 Actions 页面查看。

## 本地自查

push 前跑一遍（不需要 Docker，只做静态检查）：

```bash
bash check.sh
```

CI 的 Validate 步骤调用的是同一个脚本，本地过了线上基本不会因为配置问题失败。查到的问题包括：

- 必备文件是否齐全
- `install/`、`startup/`、`template/` 下脚本的语法
- `install/app.conf` 必填项（`IMAGE_REPO` / `IMAGE_TAG` / `PLATFORMS` / 非空的 `LOG_LIB_URL`）与开关取值（`true` / `false`）
- Dockerfile 里 `wget` 的下载路径在仓库中是否真的存在（`update.sh` 除外，它是可选文件）、`startup/` 脚本列表是否一致
- 三处路径是否对得上：`start.sh` 的 `DIR`、`install.sh` 的 `CONF`、`ENTRYPOINT` 指向的文件，都必须和 Dockerfile 里的下载位置一致
- `docker-compose.yml` 的镜像名是否与 `install/app.conf` 的 `IMAGE_REPO:IMAGE_TAG` 一致（`container_name` 只提醒不校验）
- `docker-compose.yml` 与 workflow 的 YAML 解析
- 装了 `shellcheck` 时顺带检查（只提示，不影响结果）

## 部署

```bash
docker compose up -d
```

部署前把 `docker-compose.yml` 里的两行改成自己的名字（和 `install/app.conf` 对应）：

```yaml
    image: xct258/my-image:latest
    container_name: my-image
```

`start.sh` 最后会 `exec main.sh`，所以 `main.sh` 是容器主进程。如果服务会留下孤儿进程，可以自己加 `init: true`（或 `docker run --init`）让 tini 回收；不加也能正常运行。

默认使用 **host 网络**（`network_mode: host`），容器直接用宿主机端口，`ports:` 映射不生效。需要独立网络时注释掉 `network_mode`，再打开 `ports`：

```yaml
    # network_mode: host
    ports:
      - "8080:80"
```

**数据目录默认没有挂载。** `/data` 里是 `once` 标记、重试计数和日志，不挂卷时它们随容器删除而丢失，重建容器后 `once.sh` 会再执行一次。需要保留就取消注释：

```yaml
    volumes:
      - ./data:/data
```

## 工作目录

镜像里不固定 `WORKDIR`，容器默认的工作目录是 `/`。需要固定时在 compose 里取消注释：

```yaml
    # working_dir: /workspace
```

`working_dir` 同时决定 `docker exec` 进去的落点和 `start.sh` / `main.sh` 继承的 cwd。挂载代码目录时配套使用：

```yaml
    working_dir: /workspace
    volumes:
      - ./workspace:/workspace
```

镜像里的脚本不占用 `/app`、`/workspace` 这类业务目录：

| 路径 | 内容 | 生命周期 |
|---|---|---|
| `/opt/start.sh` | 启动入口（`ENTRYPOINT`） | 常驻 |
| `/opt/startup/*.sh` | `prepare.sh` / `update.sh` / `once.sh` / `main.sh` / `log.sh` | 常驻 |
| `/tmp/app.conf`、`/tmp/custom-install.sh`、`/tmp/install.sh` | 构建期配置与安装脚本 | 安装完即删 |
| `/data` | 数据卷挂载点 | 挂载 `./data` 时随卷保留；默认 compose 未挂载，随容器层丢失 |

所以 `working_dir` 可以放心指向 `/workspace`、`/app` 等任意目录，不会被镜像自带文件占用。

## 日志

启动脚本用 `log` 代替 `echo`，分两档：

| 内容 | 去哪 |
|---|---|
| 正常步骤（`prepare` / `once`） | 只写文件 |
| 启动摘要（服务已启动、访问端口、密码） | 文件 + `docker logs`（只打这一次） |
| 更新重启、异常退出 | 文件 + `docker logs` |
| 服务进程自己的 stdout/stderr | 只写 `SERVICE_LOG`（不进 `docker logs`） |

```bash
log info "prepare"                  # 只进文件
log info "main"                     # 只进文件
log -f error "prepare 失败（exit 1）" # 进 docker logs
```

规则不是按级别自动判断，而是**调用时显式写 `-f`**：写了就代表「这条出问题时必须一眼看到」。正常启动时 `docker logs` 只打印一次启动摘要：

```
$ docker logs opencode-cs
[2026-10-28 05:31:15] [main] 🎉 服务已启动（PID 123）
[2026-10-28 05:31:15] [main] ✅ 访问端口: 8080
[2026-10-28 05:31:15] [main] ✅ 密码: ********
```

之后 `docker logs` 不再输出；只有更新重启（`重启服务（应用更新）`）或异常退出（`服务异常退出（exit N）`）时才会再加一行。

失败时才把原因和重试情况带出来：

```
[2026-10-28 05:31:17] [prepare] ❌ 端口 4099 被占用
[2026-10-28 05:31:17] [start] ❌ prepare 失败（exit 1）
[2026-10-28 05:31:17] [start] ❌ 不再重试（STARTUP_RETRY=0）；修复后执行 docker compose restart
```

自己写 `prepare.sh` / `once.sh` 时同理：正常步骤用 `log info`，出错用 `log -f error`。命令本身失败时（如 `mkdir` 报错），bash 的 stderr 会直接进 `docker logs`，不用额外处理。

| 级别 | 用途 |
|---|---|
| `debug` / `success` / `info` | 正常流程 |
| `warn` / `error` / `fatal` | 需要人看的问题 |

### 服务日志

`main.sh` 里启动服务时把输出重定向到 `SERVICE_LOG`，不要让它直接打到 `docker logs`：

```bash
start_service() {
    my-service --port "${PORT:-8080}" >> "$SERVICE_LOG" 2>&1 &
    svc_pid=$!
}
```

`main.sh` 每天 00:00 把当天日志 copytruncate 归档为 `service.log-YYYY-MM-DD`，只保留最新 N 天：

| 环境变量 | 默认值 | 作用 |
|---|---|---|
| `SERVICE_LOG` | `/data/logs/service/service.log` | 服务 stdout/stderr（当天） |
| `SERVICE_LOG_KEEP_DAYS` | `15` | 保留最近多少天的归档 |
| `SERVICE_PORT` | 空 | 启动摘要里打印访问端口 |
| `SERVICE_PASSWORD` | 空 | 启动摘要里打印密码（有才打） |

`docker logs` 只在启动时打印一次摘要，之后只在更新重启/异常退出时输出，所以不需要再给 `docker logs` 配大小限制。

### 启动脚本日志

文件位置（容器内 `/data/logs`；挂载了 `./data:/data` 才会落到宿主机，且重建容器不丢。默认 compose 没挂载，日志随容器删除）：

```
/data/logs/<脚本名>/2026/10/28/<脚本名>_HHMMSS_<pid>.log
# 例：/data/logs/start/2026/10/28/start_052428_17052.log
```

每个脚本每次启动一个文件，`LOG_MAX_FILES`（默认 30）控制每个脚本保留多少个，超出的自动删。

在宿主机上看最新的启动日志（需先挂载 `./data:/data`；没挂载时用 `docker exec` 进容器看）：

```bash
tail -f "$(ls -t data/logs/start/*/*/*/*.log | head -1)"
```

| 环境变量 | 默认值 | 作用 |
|---|---|---|
| `LOG_BASE_DIR` | `/data/logs` | 日志根目录（compose 里已设） |
| `LOG_MAX_FILES` | `30` | 每个脚本保留的日志文件数 |
| `LOG_COLOR` | `auto` | `auto` 只在终端上色；`never` 永不上色；`always` 强制上色 |

日志模块不在本仓库，构建时从 `xct258/common` 按提交 SHA 下载（见 `install/app.conf` 的 `LOG_LIB_URL`）。改了上游要同步更新那个 SHA，否则构建的还是旧版本。**这个地址不能留空**：留空时镜像里没有 `log.sh`，`template/start.sh` 会打印错误并 `exit 1`，`prepare.sh` / `once.sh` 也无条件 source 它。

## 环境变量

在 `docker-compose.yml` 的 `environment:` 下面加键值，容器里直接就能用：

```yaml
    environment:
      TZ: Asia/Shanghai
      PORT: 8080
```

改完 `docker compose up -d` 生效，不用重建镜像。容器里的脚本/程序按变量名读取：

```bash
# startup/main.sh
start_service() {
    my-server --port "${PORT:-8080}" &
    svc_pid=$!
}
```

`docker compose config` 可以直接检查环境变量有没有拼错。

## install/app.conf 约定

| 配置项 | 作用 |
|---|---|
| `IMAGE_REPO` | 推送到 Docker Hub 的镜像名，如 `账号/镜像名` |
| `IMAGE_TAG` | 镜像标签 |
| `PLATFORMS` | 构建架构，如 `linux/amd64,linux/arm64` |
| `APT_PACKAGES` | apt 系统依赖，**一行一个** |
| `INSTALL_7Z` | 快捷安装 7-Zip（`true` / `false`，自动按架构下载最新版） |
| `PYTHON_PACKAGES` | Python 依赖（pip 包，**一行一个**）；非空时自动安装 Python3 并 pip 安装 |
| `INSTALL_CUSTOM` | 是否执行 `install/custom-install.sh`（`true` / `false`），构建时执行一次 |
| `LOG_LIB_URL` | 日志模块 `log.sh` 的下载地址，固定到提交 SHA。**不能留空**：留空则镜像里没有 `log.sh`，容器启动直接失败 |

- `PYTHON_PACKAGES` 非空时会自动安装 `python3`、`pip3`，并提供 `python` 命令

- 多个常驻进程请拆成多个容器，或用进程管理工具；`start_service` 启动的服务要能被 `stop_service` 停掉，更新时才能只重启服务
- apt / pip 装不了的东西写进 `install/custom-install.sh`，脚本内可用 `${TARGETARCH}` 区分 `amd64` / `arm64`
- 项目命名不是 `amd64` / `arm64` 时用脚本里的 `arch_name` 映射，如 `arch_name x64 aarch64`
- `custom-install.sh` 里装完依赖记得清理临时文件，减小镜像体积
- 安装器把二进制放进 `$HOME` 下的 `bin` 目录（如 `~/.opencode/bin`、`~/.local/bin`）时，`template/start.sh` 启动时会自动把这些目录加入 `PATH`。因为这些安装器只把 PATH 写进 `~/.bashrc` / `~/.profile`，而容器启动用的是非交互 shell，不会加载它们——不补 PATH 的话 `startup/*.sh` 里会报「命令未找到」
- 自动补的目录是固定白名单：`~/.local/bin`、`~/bin`、`~/.opencode/bin`、`~/.bun/bin`、`~/.cargo/bin`。其它位置用 `EXTRA_PATH_DIRS` 追加，冒号分隔（如 `EXTRA_PATH_DIRS=/opt/tools/bin:/workspace/bin`）。不会全盘扫描 `$HOME`，避免 `node_modules/.bin` 拖慢启动、遮蔽系统命令

## 说明

- 构建流水线在 `.github/workflows/build-image.yml`，读取 `install/app.conf` 的配置，通常无需修改
- 构建前会自动校验：必备文件齐全、`install/` 与 `startup/` 下的脚本语法正确、`DOCKERACC` / `DOCKERPWD` secrets 已配置，校验失败会给出明确错误
- 构建时不用 `COPY`，而是由 CI 生成 `REPO_URL`（当前提交的 raw 地址，固定在 `github.sha`，避免分支地址的 CDN 缓存拿到旧文件），Dockerfile 用 `wget` 下载 `install/app.conf` / `install/custom-install.sh` / `install/install.sh` 到 `/tmp`（安装完删除）、`startup/*.sh` 到 `/opt/startup`、`template/start.sh` 到 `/opt/start.sh`、`LOG_LIB_URL` 指向的 `log.sh` 到 `/opt/startup/log.sh`（`custom-install.sh`、`update.sh` 缺失时自动跳过）
- 构建**完全不使用缓存**（CI 里 `no-cache: true`），每次构建都全新执行，保证 wget 下载到最新文件
- 因此**仓库需要是公开的**（private 仓库的 raw 地址需要鉴权，wget 无法直接访问）
- 基础镜像固定为 `xct258/debian-cn`（Debian 系）；要换基础镜像需改 `template/Dockerfile` 的 `FROM`，且新镜像要带 `apt-get`
- 构建时 `wget` 报证书/SSL 错误（exit 5）：基础镜像缺 `ca-certificates`，Dockerfile 已固定一起安装；换了自定义基础镜像仍报错时，检查该镜像的 `/etc/ssl/certs/ca-certificates.crt`
- 下载失败会打印 `[fetch] 下载失败（exit N）：URL`，`exit 8` 是 404（路径或仓库名不对），`exit 5` 是证书问题，`exit 4` 是网络不通
- Actions 构建多架构时会自动安装 QEMU，无需本地处理
