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
│   ├── once.sh           # 只执行一次
│   └── main.sh           # 容器主进程
├── template/             # 固定模板，无需修改
│   ├── Dockerfile
│   └── start.sh          # 依次调用 startup/ 下的三个脚本
├── check.sh              # 本地自查（push 前跑，CI 也用）
├── docker-compose.yml    # 部署配置（默认 host 网络）
└── .github/workflows/build-image.yml
```

`template/` 下的文件构建时从仓库下载，**不需要改**。

## 启动流程

容器启动时 `template/start.sh` 按顺序执行 `startup/` 下的三个脚本：

| 脚本 | 执行时机 | 放什么 |
|---|---|---|
| `prepare.sh` | **每次**启动（含 `docker restart`） | 设密码、改配置、建目录等可重复执行的操作 |
| `once.sh` | **只执行一次**（标记文件 `/data/.startup-once.done`） | 初始化数据、生成配置、建表/迁移等不能重复执行的操作 |
| `main.sh` | 每次启动，作为容器主进程 | 真正的启动命令，最后一行用 `exec` |

- `once.sh` 成功后才写标记；想重新执行就删掉 `/data/.startup-once.done` 再重启
- 标记在 `/data` 里，跟着数据卷走；没挂卷时等同于每个容器一次
- 任一脚本失败（非 0 退出）容器就不会启动，日志里会打印**哪个脚本失败、退出码多少**

## 启动失败与重试

**重试是 Docker 干的，不是脚本在循环。** `restart: unless-stopped` 下容器一退出就会被拉起，所以端口占用这类错误会一遍遍刷日志。

模板用一个变量决定「还让不让 Docker 继续拉起」：

```yaml
    environment:
      # 启动失败后最多重试几次，0 = 不重试
      STARTUP_RETRY: 0
```

`template/start.sh` 的逻辑：

| `STARTUP_RETRY` | 失败时 |
|---|---|
| `0`（默认） | 打印失败脚本和退出码，然后**停住**（`sleep infinity`），不再重启 |
| `N > 0` | 未超限时退出，让 restart 策略重新拉起；超过 N 次后停住 |

失败日志长这样：

```
[start] prepare
[start] prepare 失败（exit 1）
[start] 不再重试（STARTUP_RETRY=0）；修复后执行 docker compose restart
```

计数在 `/data/.startup-attempts`，启动成功后自动删除。修好配置后：

```bash
docker compose restart
```

容器停住时，`start.sh` 会写 `/data/.startup-failed`，compose 的 healthcheck 据此把状态标成 `unhealthy`，不会伪装成健康：

```bash
$ docker compose ps
NAME   STATUS
app    Up 2 minutes (unhealthy)

$ docker logs app | tail -1
[start] 不再重试（STARTUP_RETRY=0）；修复后执行 docker compose restart
```

healthcheck 的定义在 `docker-compose.yml`：

```yaml
    healthcheck:
      test: ["CMD-SHELL", "test ! -f /data/.startup-failed"]
      interval: 30s
      start_period: 60s
```

启动成功时标记被删除、状态恢复 `healthy`；`start_period` 给 `prepare.sh` / `once.sh` 留出执行时间，期间不做判定。

`STARTUP_RETRY` 只管**启动阶段**；主进程跑起来之后再崩溃，仍由 `restart: unless-stopped` 拉起。

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
- `install/app.conf` 必填项（`IMAGE_REPO` / `PLATFORMS`）与开关取值（`true` / `false`）
- Dockerfile 里 `wget` 的下载路径在仓库中是否真的存在、`startup/` 脚本列表是否一致
- 三处路径是否对得上：`start.sh` 的 `DIR`、`install.sh` 的 `CONF`、`ENTRYPOINT` 指向的文件，都必须和 Dockerfile 里的下载位置一致
- compose 的 `healthcheck` 用的失败标记是否和 `start.sh` 的 `FAIL_MARK` 一致
- `docker-compose.yml` 的镜像名是否与 `install/app.conf` 的 `IMAGE_REPO:IMAGE_TAG` 一致（`container_name` 只提醒不校验）
- `docker-compose.yml` 与 workflow 的 YAML 解析
- 装了 `shellcheck` / `hadolint` 时顺带检查（只提示，不影响结果）

## 部署

```bash
docker compose up -d
```

部署前把 `docker-compose.yml` 里的两行改成自己的名字（和 `install/app.conf` 对应）：

```yaml
    image: xct258/my-image:latest
    container_name: my-image
```

默认使用 **host 网络**（`network_mode: host`），容器直接用宿主机端口，`ports:` 映射不生效。需要独立网络时注释掉 `network_mode`，再打开 `ports`：

```yaml
    # network_mode: host
    ports:
      - "8080:80"
    volumes:
      - ./data:/data
```

## 工作目录

镜像里不固定 `WORKDIR`，容器主进程的默认工作目录是 `/`。需要固定时在 compose 里取消注释：

```yaml
    # working_dir: /workspace
```

`working_dir` 同时决定 `docker exec` 进去的落点和主进程继承的 cwd。挂载代码目录时配套使用：

```yaml
    working_dir: /workspace
    volumes:
      - ./workspace:/workspace
```

镜像里的脚本不占用 `/app`、`/workspace` 这类业务目录：

| 路径 | 内容 | 生命周期 |
|---|---|---|
| `/opt/start.sh` | 启动入口（`ENTRYPOINT`） | 常驻 |
| `/opt/startup/*.sh` | `prepare.sh` / `once.sh` / `main.sh` | 常驻 |
| `/tmp/app.conf`、`/tmp/custom-install.sh`、`/tmp/install.sh` | 构建期配置与安装脚本 | 安装完即删 |
| `/data` | 数据卷挂载点 | 随卷保留 |

所以 `working_dir` 可以放心指向 `/workspace`、`/app` 等任意目录，不会被镜像自带文件占用。

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
exec my-server --port "${PORT:-8080}"
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

- `PYTHON_PACKAGES` 非空时会自动安装 `python3`、`pip3`，并提供 `python` 命令

- 多个常驻进程请拆成多个容器，或用进程管理工具；`main.sh` 必须前台运行（`exec`），否则 `docker stop` 无法优雅退出
- apt / pip 装不了的东西写进 `install/custom-install.sh`，脚本内可用 `${TARGETARCH}` 区分 `amd64` / `arm64`
- 项目命名不是 `amd64` / `arm64` 时用脚本里的 `arch_name` 映射，如 `arch_name x64 aarch64`
- `custom-install.sh` 里装完依赖记得清理临时文件，减小镜像体积
- 安装器把二进制放进 `$HOME` 下的 `bin` 目录（如 `~/.opencode/bin`、`~/.local/bin`）时，`template/start.sh` 启动时会自动把这些目录加入 `PATH`。因为这些安装器只把 PATH 写进 `~/.bashrc` / `~/.profile`，而容器启动用的是非交互 shell，不会加载它们——不补 PATH 的话 `startup/*.sh` 里会报「命令未找到」

## 说明

- 构建流水线在 `.github/workflows/build-image.yml`，读取 `install/app.conf` 的配置，通常无需修改
- 构建前会自动校验：必备文件齐全、`install/` 与 `startup/` 下的脚本语法正确、`DOCKERACC` / `DOCKERPWD` secrets 已配置，校验失败会给出明确错误
- 构建时不用 `COPY`，而是由 CI 生成 `REPO_URL`（当前提交的 raw 地址，固定在 `github.sha`，避免分支地址的 CDN 缓存拿到旧文件），Dockerfile 用 `wget` 下载 `install/app.conf` / `install/custom-install.sh` / `install/install.sh` 到 `/tmp`（安装完删除）、`startup/*.sh` 到 `/opt/startup`、`template/start.sh` 到 `/opt/start.sh`（`custom-install.sh` 缺失时自动跳过）
- 构建**完全不使用缓存**（CI 里 `no-cache: true`），每次构建都全新执行，保证 wget 下载到最新文件
- 因此**仓库需要是公开的**（private 仓库的 raw 地址需要鉴权，wget 无法直接访问）
- 基础镜像固定为 `xct258/debian-cn`（Debian 系）；要换基础镜像需改 `template/Dockerfile` 的 `FROM`，且新镜像要带 `apt-get`
- 构建时 `wget` 报证书/SSL 错误（exit 5）：基础镜像缺 `ca-certificates`，Dockerfile 已固定一起安装；换了自定义基础镜像仍报错时，检查该镜像的 `/etc/ssl/certs/ca-certificates.crt`
- 下载失败会打印 `[fetch] 下载失败（exit N）：URL`，`exit 8` 是 404（路径或仓库名不对），`exit 5` 是证书问题，`exit 4` 是网络不通
- Actions 构建多架构时会自动安装 QEMU，无需本地处理
