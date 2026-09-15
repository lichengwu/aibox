# 把 windmill 运维 CLI 适配为 aibox 模块 —— 方案

> 状态：**已实施**（windmill v1.1.0，见 registry.sh；部署根/配置落点已按 docs/module-spec.md 约定对齐。本文档为历史设计记录）
> 目标：在 aibox 仓库新增 `tools/windmill/` 模块，把 Windmill 自托管运维 CLI 纳管

## 修订说明

### v1 → v2

按反馈修订了三处前提：

| 项 | v1 假设 | v2 修订 |
| --- | --- | --- |
| 运行位置 | Mac 上的 aibox 远程管 Linux 主机 | **都是本机**，模块只做「安装到本机」，不涉及 scp / ssh |
| 平台 | 仅 Linux 部署主机 | **需同时适配 macOS 与 Linux**（为后续工作预留，本期先打通 Linux） |
| 代理 | 新增 `windmill proxy` 子命令管 daemon 代理 | **不新增**，代理统一走 aibox 全局配置（论证见 §4.4） |

### v2 → v3

| 项 | v2 方案 | v3 修订 |
| --- | --- | --- |
| 配置落点 | 按平台分两处（Linux `/etc/`、macOS XDG `~/.config/`） | **统一 `/etc/windmill/windmill.conf`**，macOS 允许安装期提权一次 → 平台分支取消（见 §3.3） |
| 部署目录 | 只说了「macOS 要挪走」，没给够理由 | 补上硬理由：**必须在 `/Users` 下**（`~/windmill`）—— Docker Desktop 默认不共享 `/opt`，`./Caddyfile` 的相对挂载会 `Mounts denied`（见 §3.3） |

### v3 → v4

| 项 | v3 方案 | v4 修订 |
| --- | --- | --- |
| 部署目录 | Linux `/opt/windmill`、macOS `~/windmill` —— 仍留**一处平台分支** | **两平台统一 `$AIBOX_HOME/apps/windmill`**（= Linux `/root/.aibox/apps/windmill`、macOS `~/.aibox/apps/windmill`），平台分支彻底消失；备份抢救目录一并统一到 `$AIBOX_HOME/backups/` |
| 前提 | 未提 | 新增两个**前置条件**（不做就是事故）：① `aibox self uninstall` 改 fail-closed（现在裸 `rm -rf "$AIBOX_HOME"`，会连坐删库）；② systemd 单元必须显式 `Environment=`（**实测系统服务里没有 `HOME`**） |
| 规范范围 | 只写本模块 | 部署根作为**跨模块约定**写进 `docs/module-spec.md` |

### v4 → v5

| 项 | v4 方案 | v5 修订 |
| --- | --- | --- |
| 存量实例 | 阶段 7 做显式**迁移**（`/opt/windmill` → 新落点） | **不迁移，直接重装** —— 存量还少，清空重来的成本低于长期维护一条一次性迁移路径（见 §六 阶段 7） |
| 存量模块对齐 | openmaic 的 `/opt/openmaic` 列为「后续对齐项」 | **已对齐**：openmaic 部署根改为 `$AIBOX_HOME/apps/openmaic`；`pi-web` 确认为安装型、**不引入部署根** |
| 前置条件 | 只写在风险表里 | `cmd_self_uninstall` 的 fail-closed **已实现并测试通过**（阶段 0 完成） |

## 一、结论

有现成模板：**`tools/openmaic/` 与 windmill 同构**（单文件 bash 运维 CLI、Docker Compose 部署、
命令分域、退出码分级、已有并发锁）。模块骨架照抄即可。

真正的工作量在 CLI 自身：

| # | 改造项 | 必要性 |
| --- | --- | --- |
| 1 | 剥离内网代理绑定（还会落进生成的 compose 文件） | **必须** |
| 2 | 版本变量加前缀（`CLI_VERSION` → `WINDMILL_CLI_VERSION`） | **必须** |
| 3 | 落点约定：配置统一 `/etc/windmill/windmill.conf`、部署统一 `$AIBOX_HOME/apps/windmill` | 推荐 |
| 4 | 平台抽象层（为 macOS 适配打底，共 8 处） | 本期打底，后续填充 |
| 5 | `aibox self uninstall` 改 fail-closed（**前置条件**，见 §3.3） | **必须** |

## 二、同构性

### 2.1 可直接复用 openmaic 的部分

目标平台（Linux + docker compose）、CLI 形态（单文件 bash）、命令分域、退出码分级、
并发锁、以及整套钩子契约与 `lib.sh` 结构。

### 2.2 差异点

| # | 维度 | openmaic | windmill 现状 | 处理 |
| --- | --- | --- | --- | --- |
| 1 | 落点 | 配置 `/etc/openmaic`、部署 `/opt/openmaic`（分离） | 全在 `/opt/windmill`（配置与运行时不分离） | 配置 → `/etc/windmill/windmill.conf`；部署 → `$AIBOX_HOME/apps/windmill`，见 §3.3 |
| 2 | 内网绑定 | 无 | 硬编码内网代理，且**写进生成的 compose** | 必须剥离 |
| 3 | 版本变量 | `OPENMAIC_CLI_VERSION` | `CLI_VERSION`（通用名） | 加前缀 |
| 4 | 平台守卫 | 有（退出码 3） | 无 | 新增 |
| 5 | `--json` | 有 | 无 | 可选，本期不做 |
| 6 | macOS 解析 | 需规避 bash 4 语法 | **实测 `bash -n` 通过** | 无需处理 |

> **第 6 条是个好消息**：windmill CLI 在 macOS 自带 bash 3.2 下能完整解析，
> 意味着执行期守卫能给出清晰提示，不会像 openmaic 那样先撞语法错误。

## 三、CLI 需要改造的 4 项

### 3.1 剥离内网绑定（必须）

```bash
# 第 23 行
DEFAULT_PROXY="http://<内网IP>:7897"
# 第 1146 行 —— 更严重
WM_PROXY=${DEFAULT_PROXY}      # 会落进 windmill init 生成的 docker-compose.yml
```

第 1146 行意味着**每次生成 compose 都带着内网地址**，并随部署留在目标机上。

改法：

- 删除 `DEFAULT_PROXY`，`PROXY_URL` 改为「命令行 > 环境变量 > conf」三级读取，**默认空**
- 渲染时 `WM_PROXY=` 留空值，且**依赖它的分支要能优雅跳过**（空值时不做 `curl -x http://`）
- 自查：`grep -rn '192\.168\.' tools/windmill/` 必须为 0

### 3.2 版本变量加前缀

`CLI_VERSION` → `WINDMILL_CLI_VERSION`（含第 2801、2819 行引用）。
模块 `lib.sh` 用 `sed -nE 's/^WINDMILL_CLI_VERSION="([^"]+)".*/\1/p'` 读取，与
`OPENMAIC_CLI_VERSION` 保持同一约定。

### 3.3 落点约定 —— 配置 `/etc/windmill/`、部署 `$AIBOX_HOME/apps/windmill`

**结论：两者都两平台同形，不做平台分支。** 配置写 `/etc/windmill/windmill.conf` 需要
`sudo`，但**只在安装那一次**（模块的 `install.sh` 钩子）——装完之后 `status` / `up` /
`logs` / `backup` 等日常命令一律不需要提权；部署目录落在 `$AIBOX_HOME/apps/` 下，
日常命令也不需要提权。

**为什么是 `/etc/windmill/` 而不是 `/opt`**

先把「放 `/opt` 下面」的三种含义分开：

| 放法 | 结果 |
| --- | --- |
| 放 `/opt/windmill/` 内（现状：`.env`、`backups/`） | **无效** —— `destroy` 就是 `rm -rf "$WM_DIR"`，换个更深的子目录照样删 |
| 放 `/opt/` 根下（如 `/opt/windmill.conf`） | 能活下来（不在 `WM_DIR` 内），但归属不清：`/opt` 的约定是「一个包一个目录」（`/opt/<package>/`）。孤零零一个配置文件，没人知道它属于谁、卸载时该不该删 |
| **放 `/etc/windmill/`（推荐）** | 见下 |

`/etc` 在四个维度上都对：

| 维度 | 依据 |
| --- | --- |
| 语义 | FHS（`man 5 hier`）：`/etc` = *host-specific system configuration*。代理、镜像源、端口正是**主机专属、跨部署实例不变**的设置 |
| 先例 | `/etc/docker/daemon.json`、`/etc/caddy/`、`/etc/nginx/` —— 同类「单机部署的守护服务」都这么放 |
| 双平台 | macOS 的 `/etc` 是 `/private/etc` 的符号链接，`sudo` 可写；Linux 上部署本身就由 root 操作。**同一路径成立，无需分支** |
| 不随部署消失 | 在 `$WM_DIR` 之外，`destroy --all` 动不到 |

`/opt/windmill.conf` 还有一条实际硬伤：Linux 服务器上 `/opt` 同样是 `root:root 755`，
**你能写只是因为你以 root 操作**。一旦要双平台，这个「能写」的感觉立刻破产；而 `/etc`
不依赖这个假设 —— 它明确就是「需要特权才能改的文件放这儿」，语义自洽。

**权限：目录 `755 root:root`，文件 `644 root:root`**

关键是读写分离：**写只发生在安装期（需要 sudo），读发生在每次命令（不能需要 sudo）**，
所以文件必须 `644`，让普通用户能读到。

> 直接后果：**不要把凭据写进这个文件**（644 等于全机可读）。若日后真要放代理凭据，
> 只能改 `600`，代价是 macOS 上每次运行都提权 —— 这笔账不划算，凭据留在 aibox 自己
> 的配置里。当前代理无凭据，安全。

**关键区分：配置可以统一到 `/etc`，部署目录不行**

两者对「谁写、写多频繁」的要求完全不同：

| | 配置目录 | 部署目录 `WM_DIR` |
| --- | --- | --- |
| CLI 对它的动作 | **写一次，天天读** | **每条命令都写** |
| 内容 | 代理 / 镜像源 / 端口 | `.env`、`docker-compose.yml`、`Caddyfile`、`CREDENTIALS.txt`、`backups/`、`logs/`、`.lock`（L66–72 实测全在 `$WM_DIR` 内） |
| 放 `/etc`、`/opt` | 能（sudo 一次可接受） | **不能** —— `status` 这种只读命令也得提权 |

**部署目录：两平台统一 `$AIBOX_HOME/apps/windmill`**（跨模块约定已写进 `docs/module-spec.md`）

```bash
APPS_ROOT="${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}"
WM_DIR="${WM_DIR:-$APPS_ROOT/windmill}"
WM_CONF_FILE="${WM_CONF_FILE:-/etc/windmill/windmill.conf}"   # 无平台分支
```

| 平台 | 身份 | 部署目录 |
| --- | --- | --- |
| macOS | 普通用户 | `~/.aibox/apps/windmill` |
| Linux | root | `/root/.aibox/apps/windmill` |

同一个表达式、无平台分支。三条硬约束中的前两条来自实测（详见 module-spec）：

1. **macOS 被 Docker Desktop 的共享列表卡死** —— 默认只共享 `/Users`、`/Volumes`、
   `/private`、`/tmp`、`/var/folders`（官方文档）。而 compose 里有
   `- ./Caddyfile:/etc/caddy/Caddyfile`（L1047）这种**相对挂载**，源就是 `$WM_DIR` →
   放 `/opt` 会直接 `Mounts denied`。这与 sudo 无关，提权解决不了。
2. **日常命令不能要 sudo** —— 锁 / 日志 / 备份都在 `$WM_DIR` 内，放进 `root:wheel` 的
   `/opt` 意味着 `windmill status` 也要提权。
3. **必须与 `$AIBOX_HOME/modules/` 分命名空间** —— 那里放的是下载的钩子脚本；若部署目录
   写成 `$AIBOX_HOME/windmill`，与 `$AIBOX_HOME/modules/windmill/` 同名、只差一层，误删风险高。

**两个前置条件（不是可选优化）**

⚠️ **① `aibox self uninstall` 必须改成 fail-closed。** `apps/` 里放的是**部署实例**
（数据库、备份），生命周期比 aibox 本身长；而现在是裸 `rm -rf "$AIBOX_HOME"`
（`bin/aibox:851`）—— 卸掉管理器就把所有部署连数据一起删。必须：`apps/` 非空时**默认拒绝**、
列出将丢失的部署，要显式 `--yes` 才继续。（与「非交互下危险操作返回 2」的既有规则一致。）

⚠️ **② systemd 单元必须显式带 `Environment=`。** 实测（`systemd-run /usr/bin/env`）：

```
USER=root          ← 系统服务里只有这个，没有 HOME，也没有 SHELL
```

**systemd 系统服务里不存在 `HOME` 变量** → 任何 `$HOME` 派生的路径在服务上下文里会解析成
空。现有单元之所以没事，纯因为 `WM_DIR` 是常量 `/opt/windmill`。改成派生值后必须把解析
结果烘进单元：

```ini
Environment="AIBOX_HOME=/root/.aibox"
```

CLI 侧配套：解析不到就**报错退出**，绝不拼出 `/.aibox/apps/windmill` 这种路径。

**顺带统一了备份抢救目录**：`evacuate_backups()` 现在落 `/var/backups/`（Linux 专有目录、
需 root、macOS 没有），改用同一个根就两台通吃 —— `${AIBOX_HOME}/backups/`，平台分支消失。

**conf 里放什么、不放什么**

| 放 | 不放 |
| --- | --- |
| `WM_PROXY`、`WM_GHCR_MIRROR`、`WM_HUB_MIRROR`、`HTTP_PORT` —— **人配的、跨部署实例不变的** | 数据库口令、admin 口令 —— 它们是**部署实例的状态**，`init` 重新生成本就是设计意图，放进 conf 反而制造矛盾 |

配置文件不存在时全部走内置默认 → 服务器上现有部署行为**完全不变**。

> 旁证：这个 CLI 自己已经在为「不分离」打补丁了 —— `BACKUP_DIR="$WM_DIR/backups"` 放在
> 部署目录内，于是 `destroy` 必须先用 `evacuate_backups()` 把备份抢救到
> `/var/backups/windmill-pre-destroy-*`。「有些东西不该随部署一起消失」这个判断，代码里
> **早就存在**，只是用了「事后抢救」而不是「一开始就分开」。这个补丁本身还带两个平台问题：
> `/var/backups` 是 Linux 专有目录（macOS 没有），且创建它需要 root。
>
> 顺带一处小冗余：`--keep-backups` 与默认行为完全相同（L1674 的三元表达式两分支输出一致）。

### 3.4 平台抽象层（macOS 适配打底）

实测你本机（Darwin arm64）：`flock` ✗、`ss` ✗、`free` ✗、`lsof` ✓、`launchctl` ✓、
docker CLI ✓（compose v5.5.1）、但 **daemon 未运行**。

CLI 里需要适配的共 **8 处**：

| # | 位置 | 现状（Linux） | macOS 差异 | 处理 |
| --- | --- | --- | --- | --- |
| 1 | L639 并发锁 | `flock -n 9` | macOS 无 `flock` | 抽象 `with_lock()`：有 flock 用它，否则 `mkdir` 原子锁 |
| 2 | L299 停滞检测 | `du -sm /var/lib/docker` | Docker Desktop 的镜像层在 VM 内，宿主看不见该目录 | 换进度信号：解析 `docker pull` 输出行的时间戳 |
| 3 | L166 写 .env | `sed -i "s\|…\|"` | BSD sed 需 `sed -i ''` | 改 `awk + mv`（无平台差异，比适配 sed 更稳） |
| 4 | L541 / L1920 端口探测 | `ss -ltn` | 无 `ss` | 抽象 `port_listening()`：`ss` → `lsof -iTCP -sTCP:LISTEN` → `netstat -an` |
| 5 | L722 / L1436 取本机 IP | `hostname -I` | 无 `-I` | 抽象 `primary_ip()`：`hostname -I` → `ipconfig getifaddr en0` |
| 6 | L1870 内存显示 | `free -h` | 无 `free` | 抽象 `mem_used()`：`/proc/meminfo` → `vm_stat` |
| 7 | L821 备份转移 | `/var/backups/` | macOS 无此目录，且创建需 root | 统一到 `${AIBOX_HOME}/backups/` —— **两平台同一表达式，分支消失**（见 §3.3） |
| 8 | systemd 17 处 | `systemctl` + timer | macOS 用 launchd | `windmill systemd` 在 macOS 上译为 launchd（**参考 `tools/pi-web/lib.sh` 的 plist 写法**） |

第 7 项最重 —— 现有三个单元要一一对应：

| Linux | macOS |
| --- | --- |
| `windmill-stack.service`（开机对齐） | LaunchAgent + `RunAtLoad` |
| `windmill-backup.timer` | LaunchAgent + `StartCalendarInterval` |
| `windmill-update-check.timer` | LaunchAgent + `StartCalendarInterval` |

`WM_DIR` 改成派生值（`$AIBOX_HOME/apps/windmill`），**两平台同一个表达式、无分支**。
理由与三条硬约束见 §3.3，跨模块约定见 `docs/module-spec.md`。

```bash
APPS_ROOT="${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}"
WM_DIR="${WM_DIR:-$APPS_ROOT/windmill}"
```

⚠️ 但派生值带来一个新的**服务上下文风险**，必须配套处理：实测 `systemd-run /usr/bin/env`
显示**系统服务里没有 `HOME`**（只有 `USER=root`）。因此：

- 单元模板必须显式写 `Environment="AIBOX_HOME=…"`（安装时把解析结果烘进去）
- CLI 解析不到 `HOME`/`AIBOX_HOME` 时**报错退出**，不要拼出 `/.aibox/apps/windmill`
- `windmill doctor` 增加一项：断言「单元里声明的路径」与「当前解析出的路径」一致

**建议**：本期只**抽出抽象层函数**（`with_lock` / `port_listening` / `primary_ip` / `mem_used` /
`sed_inplace` / `backup_evac_dir`），Linux 分支保持现有实现不变；macOS 分支留 `TODO`。这样本期零风险，
后续填充分支即可，不用再动主干。

## 四、模块设计

### 4.1 目录与文件

```
tools/windmill/
├── windmill         # CLI 本体（单文件 bash，129 KB）
├── lib.sh           # 落点解析、版本读取、语法检查、host_notice
├── install.sh
├── uninstall.sh
├── update.sh
├── svc.sh
└── README.md
```

> ⚠️ 仓库成为 **CLI 的唯一源头**（同 openmaic）：此后改 `tools/windmill/windmill`，
> `aibox update windmill` 各机同步。会话目录里那份不再作为源头。

### 4.2 registry.sh 登记

```sh
AIBOX_MODULES="${AIBOX_MODULES} windmill"

AIBOX_MODULE_windmill_version="1.0.0"
AIBOX_MODULE_windmill_description="Windmill self-host ops CLI (init/upgrade/backup/restore/doctor) — Docker Compose"
AIBOX_MODULE_windmill_platform=""          # 空 = 跨平台（后续补 macOS 分支）
AIBOX_MODULE_windmill_dir="tools/windmill"
AIBOX_MODULE_windmill_files="windmill lib.sh install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_windmill_install="install.sh"
AIBOX_MODULE_windmill_uninstall="uninstall.sh"
AIBOX_MODULE_windmill_update="update.sh"
AIBOX_MODULE_windmill_svc="svc.sh"
AIBOX_MODULE_windmill_actions="init deploy destroy up down status doctor check upgrade rollback backup snapshots restore drill logs shell exec psql credentials systemd version"
```

### 4.3 钩子职责

| 文件 | 职责 | 与 openmaic 的差异 |
| --- | --- | --- |
| `install.sh` | `do_install` + `ensure_path` + `host_notice` + **播种 `/etc/windmill/windmill.conf`** | 差异：openmaic 没有系统级配置落点（macOS 上需提权一次） |
| `update.sh` | `cmp -s` 内容比对，一致跳过 | 无 |
| `uninstall.sh` | 只删 CLI 本体 | 保留 `$AIBOX_HOME/apps/windmill`、`/etc/windmill/windmill.conf`、`$AIBOX_HOME/backups/` |
| `svc.sh` | 透传给本机 `windmill` | 撞车提醒：`aibox install windmill` vs `aibox windmill init / destroy` |
| `lib.sh` | 落点解析（`APPS_ROOT` / `WM_DIR` / `WM_CONF_FILE`）+ 版本读取 + `check_syntax` + `host_notice` | 变量前缀 `WINDMILL_*`；落点用统一表达式，**无平台分支**；`host_notice` 改为**双平台**提示 |

**落点**：`WINDMILL_BIN_DIR` → `AIBOX_BIN_DIR` → `~/.local/bin` 三级回退。
装到系统目录：`WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill`。

**配置文件由谁写**：`install.sh` 负责**首次播种** —— 把 aibox 的全局设置（代理 / 镜像源 /
端口）落成 `/etc/windmill/windmill.conf`。策略是**只补不覆盖**：文件已存在就跳过，避免冲掉
手改过的值。CLI 自己**只读不写**这个文件，因此 `644` 足够，日常命令不需要提权。

### 4.4 代理怎么接（不新增子命令，论证）

你提到「aibox 的 proxy 是全局的」—— 顺着这个思路，windmill **不需要自己的 proxy 命令**，
链路本来就通：

| 场景 | 走谁 | 是否自动 |
| --- | --- | --- |
| 钩子自身网络请求（下载模块文件） | aibox 导出的 `http_proxy` 等 | ✓ 自动继承 |
| `windmill check` 查上游 release | 同上（CLI 是钩子的子进程，继承环境变量） | ✓ 自动继承 |
| **`docker pull` 拉镜像** | **环境变量完全无效** | ✗ 需显式指定 |

第三行是唯一的缺口，但**恰好已被现有机制覆盖**：CLI 的 `--ghcr-mirror` / `--hub-mirror`
是「预拉 + 重打 tag」，自己接管拉取，不依赖 daemon 配置。所以闭环成立：

```
aibox 全局代理  →  覆盖 CLI 的所有 HTTP 请求
镜像源参数     →  覆盖 docker pull（绕开 daemon）
```

**卸载时的边界**：`aibox proxy unset` 不会影响 windmill 的部署状态；反之
`windmill destroy` 也不会动 aibox 的代理配置 —— 两者互不侵入，符合「只删自己」原则。

**可选加速（写进 README，不做成功能）**：受限网络下给 docker daemon 配 HTTP 代理，
实测把 ghcr.io 拉取从 2.4 KB/s 提到 66 MB/s。Linux 上落点是
`/etc/systemd/system/docker.service.d/http-proxy.conf`；macOS 上走 Docker Desktop 设置
（**不是** systemd）。这是性能优化项，不是功能依赖。

## 五、风险

| 风险 | 缓解 |
| --- | --- |
| 内网地址残留（含生成的 compose 文件） | 改造后 `grep -rn '192\.168\.' tools/windmill/` 须为 0 |
| 双源头漂移 | 确立仓库为唯一源头，会话目录那份废弃 |
| macOS 无法完整验证 | 打底阶段只抽抽象层、不改 Linux 分支行为；真机验证放后续 |
| 129 KB 单文件入库 | 与 openmaic 同模式，项目已接受 |
| 配置文件引入后行为变化 | conf 不存在时全走内置默认 → 现有部署行为不变 |
| macOS 安装期要写 `/etc`，需提权 | 只在 `install.sh` 提权一次；conf 设 `644`，日常命令不读不写就无需 sudo |
| **`apps/` 里的部署被 aibox 卸载连坐** | **前置条件**：`cmd_self_uninstall` 改 fail-closed（`apps/` 非空默认拒绝 + 列出将丢失项，`--yes` 才继续） |
| **解析不到 `HOME`（服务上下文）** | 单元显式 `Environment="AIBOX_HOME=…"`；CLI 解析失败即报错退出；`doctor` 断言「单元路径 == 当前解析路径」 |
| 现存实例在 `/opt/windmill`，与新默认不一致 | **不迁移，直接重装**：先 `windmill --yes destroy --all`，再按新落点 `init`。不引入一次性迁移路径 —— 存量少时重装成本更低，也少一处长期维护面 |
| macOS 部署根若重新落到 `/opt` | 硬约束已写入 §3.3 / §3.4 与 `module-spec`；`lib.sh` 加断言（`Darwin` 下 `WM_DIR` 必须在 `/Users` 下） |
| module-spec 新约定与 openmaic 的 `/opt/openmaic` 不一致 | **已对齐**：openmaic 部署根改 `$AIBOX_HOME/apps/openmaic`（`OPENMAIC_BASE_DIR` 默认值 + 注释 + README + uninstall 提示），落点解析加 `HOME` 缺失守卫 |

## 六、执行阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| 0 | **前置**：改 `bin/aibox` 的 `cmd_self_uninstall` 为 fail-closed | ✅ **已完成**：`apps/` 非空时返回 `2` 并列出将丢失项；`--yes` 放子命令前后都认 |
| 0b | **前置**：存量模块落点对齐（openmaic → `$AIBOX_HOME/apps/openmaic`） | ✅ **已完成**：落点解析 8 项断言全通过；`pi-web` 确认无需改动 |
| 1 | 搬迁 CLI 到 `tools/windmill/`；剥离内网；版本变量加前缀 | `bash -n` 通过；无内网残留 |
| 2 | 抽象层打底（6 个函数）+ 配置外置 `/etc/windmill/windmill.conf` + 部署根统一 `$AIBOX_HOME/apps/windmill` + 单元显式 `Environment=` | Linux 行为不变；conf 缺失时正常；`HOME` 缺失时报错而非拼路径；单元路径 == 解析路径 |
| 3 | 写 6 个模块文件 + registry 登记 + README + `module-spec` 约定入库 | — |
| 4 | 沙箱验证：隔离 `HOME`/`BIN_DIR` + `file://` 本地源，跑 install → 透传 → 幂等 update → uninstall | 端到端通过 |
| 5 | 实机验证：装到 `/usr/local/bin`，跑只读命令 + 一次 `--dry-run` | 零副作用 |
| 6 | **（后续）** macOS 分支填充：锁、进度信号、端口/IP/内存、launchd | macOS 本地跑通一套 |
| 7 | **实机重装**（不迁移）：存量 `/opt/windmill` 直接 `destroy --all` → 在新落点 `$AIBOX_HOME/apps/windmill` 重新 `init` | 重装后 `doctor` 全绿、`drill` 通过、8 容器 Up、UI 200 |

## 七、已确认的决策

| # | 决策 | 结论 |
| --- | --- | --- |
| 1 | 跨机器架构 | **本机运行**，无远程；模块只做本机安装 |
| 2 | 配置目录 | **外置，两平台统一 `/etc/windmill/windmill.conf`**（`755 root:root` + 文件 `644`），保留 `WM_CONF_FILE` 覆盖；macOS 由 `install.sh` 提权一次写入。**不放 `/opt`**（`destroy` 会连坐 / 归属不清，见 §3.3） |
| 3 | 部署目录 | **两平台统一 `$AIBOX_HOME/apps/windmill`**（Linux `/root/.aibox/apps/windmill`、macOS `~/.aibox/apps/windmill`），**无平台分支**；备份抢救目录同根 `${AIBOX_HOME}/backups/`。三条约束见 §3.3 |
| 4 | 部署根是否入规范 | **写进 `docs/module-spec.md`** —— 跨模块约定，含三条硬约束与两个配套强制项 |
| 5 | `aibox self uninstall` | **改为 fail-closed**（现为裸 `rm -rf "$AIBOX_HOME"`）—— 本方案前置条件 |
| 6 | `windmill proxy` 子命令 | **不新增**，代理走 aibox 全局 + CLI 镜像源参数 |
| 7 | 平台 | 本期 Linux 打通 + macOS 抽象层打底；macOS 完整适配后续 |
