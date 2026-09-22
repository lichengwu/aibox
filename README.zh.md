# aibox（中文）

> AI coding 工具集 —— 一个轻量模块管理器 + 若干独立工具，`curl|bash` 一行装好，按需安装 / 更新 / 卸载各模块。

> English is the primary language of this project; this Chinese README is an auxiliary translation. For the canonical version see [README.md](README.md).

`aibox` 是一个纯 bash 的模块管理器（零运行时依赖，兼容 macOS 自带 bash 3.2）。每个「模块」是仓库 `tools/<name>/` 下的一个目录，自带 `install / uninstall / update / svc` 钩子，由 `aibox` 统一调度。

> **范围说明**：`windmill` 与 `openmaic` 模块在本仓库内捆绑了完整的自托管运维 CLI（各数千行）——它们是这些运维工具的源头，而非第三方副本。核心管理器本身是 `bin/aibox`（单文件约 3.4k 行——单文件是 curl|bash 一行安装的部署约束）。见[捆绑的运维 CLI](#捆绑的运维-cli)。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

装好 `aibox` 主 CLI 到 `~/.local/bin/aibox`（自动处理 PATH）。然后装首个模块：

```bash
aibox install pi-web
```

可选的校验和验证（为 `curl|bash` bootstrap 增加纵深防御）：

```bash
# 固定 bin/aibox 的 SHA256：
AIBOX_SHA256=<hex> curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash

# 或对照 release 的 SHA256SUMS 附件校验（不存在则跳过）：
AIBOX_VERIFY=1 curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

## 命令一览

```text
aibox install <module> [--skip-checks]   安装模块（前置检查把关；--skip-checks 跳过）
aibox uninstall <module>|self [--purge] [--yes]
                                 卸载模块（先确认卸载、再确认是否连数据一起删；
                                 --purge = 预答"删数据"，--yes = 脚本场景跳过确认）。
                                 self = 管理器本身：默认只删 aibox（服务/数据保留，apps/ 保留可继续管理）；
                                 --purge = 级联全拆：逐模块 uninstall --purge，再删管理器 + rc 块
aibox update <module>|self|--all [--restart|--no-restart] [--skip-checks]
                                 更新模块；self = aibox 自身；--all = 全部模块 + aibox 自身
aibox upgrade <module> [--check] [--to <版本>] [--yes]
                                 组件升级：不依赖 aibox 发版，把部署实例的组件升到上游新版本
                                 （仓库钉安装地板，deploy .env 活版本浮动；失败自动回滚）
                                 —— update 刷新模块脚本；upgrade 升组件版本
aibox check <module>|self        前置检查：模块安装/更新就绪度；self = 环境检查（出口/核心域名/docker/磁盘）
aibox dashboard [--available] [<module>]
                                 总览（模块+版本+端点+凭据+端口表）/ --available 全部可用 / <module> 详情+健康
aibox purge [<module>...|self] [--apply] [--stop] [--yes]
                                 残留扫描/清理（默认 dry-run 报告）：卸载后遗留的卷、apps/、
                                 /etc 目录、服务单元、二进制。--apply 先确认；遇到运行中容器
                                 会内联询问是否一并停掉（--stop = 预答"停"）
aibox <module> <action> [args]   调用模块动作（如 aibox pi-web start）
aibox <module> --help             模块级帮助：动作表（离线渲染）；动作级：aibox <module> <action> --help

安装/更新前会强制跑 preflight（各模块 module.yaml 的 checks: 声明：磁盘/域名可达/命令/base 服务就绪）；
域名不通时会自动在已配置的路由（直连/clash/gh 镜像/静态代理）里试出一个可达的并本次采用。
详见 docs/module-spec.md 的 Preflight checks 一节。

aibox proxy                       查看代理配置与状态
aibox proxy set <url> [--no-test|--no-check]
                                  设置代理：测试 → 保存 → 校验站点连通性
aibox proxy check [url]           不带 url：开发站点连通性矩阵；带 url：单点可达性（含"直连对照"）
aibox proxy on | off              启用 / 停用（配置保留）
aibox proxy unset                 清除配置
aibox proxy env [--remote]        输出 export 语句 / 远端下发格式
aibox --no-proxy <命令>

aibox clash set <订阅URL>          存订阅 + 生成 config（mihomo 内核，自动测速/切换）
aibox clash on | off               启停（on 后 aibox 出口自动切到本地 mihomo）
aibox clash status | refresh       状态/当前节点 | 强制刷新订阅（超 1 周自动）
aibox clash select <节点>          手动切节点
aibox clash test | logs | doctor   探测/日志/自检
```

## 代理

aibox 有两种代理出口：

- **静态代理**（`aibox proxy set`）：手动指定一个 http/https/socks5 代理，见下。
- **clash 订阅池**（`aibox install clash` + `aibox clash set <订阅URL>`）：编排本地 mihomo 内核，订阅节点自动测速选最快、失败切换，详见 [clash 模块](tools/clash/README.md)。clash 开启时优先于静态代理。

有些环境下（比如国内直连 GitHub）`aibox` 拉不到模块，或模块钩子里的 git / npm 出不去。配置一次静态代理，`aibox` 自身与它派生的模块钩子都走它：

```bash
aibox proxy set http://10.0.0.2:7897           # 设置 → 测试 → 保存 → 校验站点
aibox proxy check                              # 随时复检站点连通性
aibox --no-proxy list --available                # 单次绕过
```

配置存在 `~/.aibox/config`（权限 600），**不写入你的 shell 配置** —— 想让终端里的 git / brew 也走代理，用 `eval "$(aibox proxy env)"` 自己决定。

### 设置完会立刻校验站点连通性

单点探针只证明"这个 url 能出去"，证明不了"你要用的站点都能出去" —— 代理常常是**部分可用**的（能到 GitHub 但到不了 Docker Hub）。所以 `set` 保存后会自动过一次站点清单：

```text
  连通性检查（经代理 http://10.0.0.2:7897）
  能拿到应答即算通 —— 401/404/405 都只说明链路到了对端
  开发依赖
  ✓ github.com                   200   0.65s
  ✓ docker hub                   401   1.45s
  ✓ ghcr.io                      405   0.86s
  ✗ google                       000   8.00s  连接失败或超时
  国内镜像
  ✓ npmmirror                    200   0.09s
  ✓ tuna                         200   0.18s

  14 项：13 通过 · 1 失败
  流量已确认全部经代理（curl %{proxy_used}）
  不通：
    google
       排查：aibox proxy check <url> 看直连对照；或换一个代理再试
```

**有不通的会问你是否撤销**，撤销会原样退回设置前的状态（原本没配就回到未配置，原本有别的代理就退回那个）。不想被问：

```bash
aibox proxy set <url> --no-check    # 只做单点测试，不跑站点校验
aibox proxy set <url> --no-test     # 什么都不测，直接存
```

判定规则是**能拿到 HTTP 响应就算通**：`401`（私有 registry 要认证）、`404`（根路径无内容）、`405`（不支持 HEAD）都只说明对端在正常应答。只有连接层失败（`000`）才算不通，`5xx` 记为可疑。

默认清单 14 项：GitHub（主页 / API / raw）、Docker Hub、GHCR、npm、PyPI、Go proxy、Google、Hugging Face、Maven Central，外加 npmmirror / 清华源 / dashscope 三个国内对照。换成你自己的：

```bash
export AIBOX_PROBE_SITES='我的源|https://example.com|自定分组
另一个|https://example.org|自定分组'
aibox proxy check
```

标签建议用 ASCII —— 对齐按字节数算，中文标签会错位。超时默认 8 秒，`AIBOX_PROBE_TIMEOUT` 可调。

生效分三层，其中前两层自动：

| 层 | 覆盖什么 | 怎么生效 |
| --- | --- | --- |
| 1. 主进程 | `aibox` 自己拉 registry / 模块 / self update | 启动时导出环境变量 |
| 2. 子进程 | 模块钩子（`install.sh` 等）里的 curl / git / npm | 环境变量被子进程继承 |
| 3. 持久化 | 模块在**别的机器、别的时间**执行时的联网 | 模块把代理写进自己的配置文件，需模块主动配合 |

第 3 层为什么必要：`openmaic` 模块分发的 CLI 会在部署主机上、`aibox` 完全不在场时执行 `openmaic upgrade` 去拉 GitHub 源码，环境变量跨不了这个边界。所以 `aibox install openmaic` 会顺带把代理写进 `/etc/openmaic/openmaic.conf`。

### 代理失效时会怎样

**配了就强制**：代理不通即报错，不会静默回退直连（否则表现为每次都先等超时再回退，慢且查不出原因）。四个出口：

```bash
aibox proxy check     # 站点级连通性（默认 14 项）
aibox proxy check <url>   # 单点可达性 + 直连对照
aibox proxy off       # 全局停用（配置保留）
aibox --no-proxy ...  # 单次绕过
```

`set` 时若检查有失败项，会直接问你要不要撤销这次配置 —— 不必自己记住原来填的是什么。

`proxy check <url>` 会额外跑一次"直连对照"并明确告诉你当前网络下代理是否必需 —— 因为**只看"能不能访问"会骗人**，详见 [`AGENTS.md`](AGENTS.md) 踩坑记录 #3。

### 不覆盖什么

代理是**进程级环境变量**，只影响遵循 `*_proxy` 的工具（curl / git / wget / npm / pip / apt）。**Docker daemon 的 pull 走 `/etc/docker/daemon.json`，不受影响**；已在运行的常驻服务也改不了，需重启。

## 模块

| 模块 | 说明 |
| --- | --- |
| [`pi-web`](tools/pi-web/README.md) | 把 `@agegr/pi-web` 部署为 macOS launchd 常驻服务（HTTP Basic Auth + 自动重启） |
| [`openmaic`](tools/openmaic/README.md) | [OpenMAIC](https://github.com/THU-MAIC/OpenMAIC) 统一运维 CLI，分发到 Linux 部署主机（安装 / 升级 / 备份 / 自检） |
| [`windmill`](tools/windmill/README.md) | [Windmill](https://www.windmill.dev) 自托管运维 CLI，docker compose 部署（初始化 / 升级 / 备份 / 演练 / 自检） |
| [`clash`](tools/clash/README.md) | Clash 订阅代理池，编排本地 mihomo 内核（自动测速选最快 / 失败切换 / 超 1 周自动刷新） |
| [`base`](tools/base/README.md) | 共享基础组件（PostgreSQL 18 + Redis 7），各模块独立数据库 |
| [`gitlab`](tools/gitlab/README.md) | [GitLab CE](https://about.gitlab.com/) 自托管（omnibus docker）：Web UI + git over SSH，内置 PG/Redis |
| [`dify`](tools/dify/README.md) | [Dify](https://github.com/langgenius/dify) 自托管（docker compose）：LLM 应用构建平台，api/worker/web/nginx + weaviate（v1.17.1） |
| [`new-api`](tools/new-api/README.md) | [New API](https://github.com/QuantumNous/new-api) 自托管（docker compose）：大模型 API 网关 —— OpenAI 兼容中继、令牌/额度管理、用量分析（v0.13.2） |
| [`xiaozhi`](tools/xiaozhi/README.md) | [小智 ESP32 服务端](https://github.com/xinnan-tech/xiaozhi-esp32-server) 自托管（docker compose）：小智 ESP32 语音设备后端 —— 智控台 + ws 中继 + 自带 MySQL（v0.9.6） |

### 捆绑的运维 CLI

`tools/windmill/cli/windmill` 与 `tools/openmaic/cli/openmaic` 是为本仓库编写的完整单文件运维 CLI（分别约 3.6k 和 1.7k 行）—— 它们是运维 Windmill/OpenMAIC 部署的源头，不是第三方副本。它们之所以这么大，是因为掌管了整个生命周期（init/upgrade/rollback/backup/restore/migrate/drill/doctor，含 Docker 镜像源黑洞探测与拉取停滞处理）。核心 `aibox` 管理器不受其体积影响。

## 开发新模块

模块 = `tools/<name>/` 目录 + 一个 `module.yaml` 声明（源头；registry 从 `tools/*/module.yaml` 自动发现）。钩子契约见 [`docs/module-spec.md`](docs/module-spec.md)。最小模块只需一个 `install.sh`。

```bash
# 本地源试跑（不联网）：
AIBOX_RAW=file:///path/to/aibox aibox dashboard --available
AIBOX_RAW=file:///path/to/aibox aibox install <your-module>
```

## 设计取舍

- **registry 用 shell 可 source 格式而非 JSON**：零运行时依赖、兼容 macOS 自带 bash 3.2，主 CLI 直接 source 即可，无需 `jq` / `python`。
- **模块脚本落地缓存**：`aibox` 把模块脚本下载到 `~/.aibox/modules/<name>/` 再执行，钩子可复用 `lib.sh`，`svc.sh` 透传不每次联网。
- **自更新 = 幂等重装**：`aibox update self` 重新 `curl|bash install.sh` 覆盖主 CLI，无 git / Releases 依赖。可选的 `AIBOX_SHA256` / `AIBOX_VERIFY=1` 增加校验和纵深防御。
- **平台由模块自报**：`platform=darwin` 的模块在非 macOS 仅警告，实际限制由模块钩子自身报错。
- **`AIBOX_RAW` 可覆盖**：支持本地源 / 镜像（如 `AIBOX_RAW=file:///path/to/aibox aibox dashboard --available`）。远程 registry 结果带 TTL 缓存，避开未认证 GitHub API 的限流。
- **模块不一定带常驻服务**：`pi-web` 管 launchd 服务，而 `openmaic` 只分发一个 CLI 并把 `aibox openmaic <action>` 透传给它 —— 模块契约里 `svc.sh` 是「动作入口」，不是「必须是守护进程」。
- **模块运行环境自报**：安装落点跨平台的模块（如 `openmaic`）不设 `platform`，由 CLI 在执行时拒绝不支持的平台并给出提示，比安装期硬拦截更清楚（安装本身在任何系统都无副作用）。
- **代理配置与运行时分离**：配置写 `~/.aibox/config`（600），启动时导出为环境变量。因此它既覆盖 `aibox` 自身，也覆盖它派生的模块钩子（子进程继承），无需改任何现有模块代码。跨机器 / 跨时间那一层（模块在别处自己联网）必须由模块把值写进自己的配置文件 —— 环境变量本来就跨不过去，这不是取巧，是边界。
- **代理失效选确定性，不做静默回退**：代理不通就报错。静默回退会让"代理已坏"表现成"每次都慢一点"，比直接失败更难查。配套给了 `test` / `off` / `--no-proxy` 三个出口，不至于走投无路。
- **不碰用户的 shell 配置**：`aibox proxy set` 只写自己的配置，不往 `~/.zshrc` 注入 —— 全局代理会影响本不该走代理的服务，超出 aibox 的职责。要全局生效用 `eval "$(aibox proxy env)"`。
- **clash 池不自解析订阅 yaml**：`aibox clash` 把订阅 URL 写进 mihomo 的 `proxy-providers`，拉取/解析/测速/切换全交给内核——纯 bash 不写 yaml 解析（脆弱），订阅格式变化由 mihomo 适配。

## License

[MIT](LICENSE)
