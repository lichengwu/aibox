# aibox 模块规范

aibox 的每个「模块」是一个独立工具，放在仓库 `tools/<name>/` 下，由主 CLI `aibox` 统一安装 / 更新 / 卸载 / 调度。

## 目录结构

```
tools/<name>/
├── lib.sh          # 共享函数（可选，各钩子 source 它复用）
├── install.sh      # 必需：安装
├── uninstall.sh    # 推荐：卸载
├── update.sh       # 可选：更新
├── svc.sh          # 可选：动作入口，$1=动作（常驻服务；也可仅透传给下发的命令）
└── README.md       # 模块说明
```

## 注册到 registry.sh

在仓库根 `registry.sh` 追加（模块名含连字符时，变量名用下划线：`pi-web` → `AIBOX_MODULE_pi_web_*`）：

```sh
AIBOX_MODULES="$AIBOX_MODULES <name>"
AIBOX_MODULE_<name>_version="x.y.z"
AIBOX_MODULE_<name>_description="一句话描述"
AIBOX_MODULE_<name>_platform="darwin"          # 可选；空=跨平台
AIBOX_MODULE_<name>_dir="tools/<name>"
AIBOX_MODULE_<name>_files="lib.sh install.sh uninstall.sh update.sh svc.sh"
AIBOX_MODULE_<name>_install="install.sh"
AIBOX_MODULE_<name>_uninstall="uninstall.sh"
AIBOX_MODULE_<name>_update="update.sh"
AIBOX_MODULE_<name>_svc="svc.sh"
AIBOX_MODULE_<name>_actions="start stop ..."     # svc 支持的动作
AIBOX_MODULE_<name>_deps="docker python3"          # 可选；运行依赖（命令名，空格分隔）
                                                     # 可带 @平台（docker@linux 仅该平台检查）或 :版本（node:22 主版本约束）
```

## 钩子契约

- aibox 把 `files` 列出的脚本下载到 `~/.aibox/modules/<name>/`，再以 `bash <dest>/<hook>.sh [args]` 调用。
- 钩子内可 `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"` 复用共享函数。
- aibox 注入以下环境变量：

  | 变量 | 说明 |
  | --- | --- |
  | `AIBOX_HOME` | aibox 状态目录 |
  | `AIBOX_MODULE` | 当前模块名 |
  | `AIBOX_RAW` | 仓库 raw 基址（可能是 `file://` 本地源） |
  | `AIBOX_BIN_DIR` | 主 CLI 安装目录，模块落点从这里起手 |
  | `AIBOX_PROXY_URL` | 当前生效的代理 URL；未启用时为空。可能来自 aibox 配置，也可能来自用户已有的环境变量 |
  | `AIBOX_NO_PROXY` | 不走代理的地址列表 |
  | `AIBOX_PROXY_ENABLED` | `1` 启用 / `0` 未启用 |

  同时导出标准变量 `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy`，**小写与大写都给** —— curl 只认小写的 `http_proxy`（大写 `HTTP_PROXY` 会被它忽略），而 apt 之类只认大写，实测两者认的集合不同。详见下方《代理》。
- `install.sh` 负责把模块自身装好（落点自治，例如 pi-web 写 launchd plist）。
- `svc.sh`：`$1` = 动作，其余参数透传。
  - 常驻服务型模块（如 pi-web）实现 `start/stop/restart/status/logs/diagnose`。
  - 分发型模块（如 openmaic）可以只做透传：`exec <下发的命令> "$1" "$@"`，动作集就是那个命令的子命令。
- 安装落点请从 `${AIBOX_BIN_DIR:-$HOME/.local/bin}` 起手，并留一个模块专属覆盖变量（部署主机上常要 `/usr/local/bin`）。
- 平台差异建议只告警不硬拦：安装通常跨平台，真正跑不动的限制由脚本执行时报清楚。

## 部署目录与配置落点约定

模块分两类，**判据是「有没有随部署实例生死的运行时数据」**：

- **安装型**（如 `pi-web`）：只往 `${AIBOX_BIN_DIR}` 放东西，外加把服务交给平台托管
  （launchd plist 必须放 `~/Library/LaunchAgents`、日志在 `~/Library/Logs`）。
  **不引入部署根** —— 沿用平台约定位置即可，硬塞进 `apps/` 反而破坏平台惯例。
- **部署型**（如 `openmaic`、`windmill`）：除 CLI 外还要在目标机落一份运行时数据
  （compose 文件、`.env`、数据卷、备份、锁、日志）。**落点按下述约定，别各自发明。**

### 部署根：`$AIBOX_HOME/apps/<name>`

```sh
APPS_ROOT="${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}"
BASE_DIR="${<MODULE>_BASE_DIR:-$APPS_ROOT/<name>}"
```

> ⚠️ 展开时**别丢 `.aibox` 那一层**。写成 `${AIBOX_HOME:-$HOME}` 会解析出
> `$HOME/apps/<name>` 而不是 `$HOME/.aibox/apps/<name>` —— 脚本不报错，路径却是错的
> （这个坑实际踩到过，靠断言具体路径的测试才抓出来）。
> 更稳的写法是 `${AIBOX_HOME:-${HOME:+$HOME/.aibox}}`：`HOME` 为空时整体为空，交给守卫报错。

**macOS 与 Linux 用同一个表达式，不做平台分支。** 解析结果：

| 平台 | 身份 | 部署目录 |
| --- | --- | --- |
| macOS | 普通用户 | `~/.aibox/apps/<name>` |
| Linux | root | `/root/.aibox/apps/<name>` |

换根前请逐条复核下面三条约束（前两条是实测结论，不是风格偏好）：

1. **必须在容器运行时的默认共享列表内。** Docker Desktop（macOS）默认只共享 `/Users`、
   `/Volumes`、`/private`、`/tmp`、`/var/folders` —— 部署目录放 `/opt` 会让 compose 里的
   **相对挂载**（如 `- ./Caddyfile:/etc/caddy/Caddyfile`）报 `Mounts denied`。
   这条与提权无关，`sudo` 解决不了。
2. **日常命令的执行者身份必须可写。** 锁文件、日志、备份都在部署目录里，**每条命令都会写** ——
   放到需要提权的路径，`status` 这种只读命令也得 sudo，等于不可用。
   （对比：配置是「写一次、天天读」，所以才允许放 `/etc`。）
3. **集中但不混命名空间。** 放在 `$AIBOX_HOME` 下便于 aibox 统一枚举、统计与清理
   （`$AIBOX_HOME/apps/*`），但**必须用 `apps/` 这类子目录**与
   `$AIBOX_HOME/modules/<name>/`（下载的钩子脚本）分开 —— 否则两者同名、只差一层，误删风险高。

> ⚠️ `apps/` 里是**部署实例**，不是「aibox 状态」：它的生命周期比 aibox 本身长。

### 配套强制项（缺一即事故）

- **`aibox self uninstall` 必须 fail-closed。** `apps/` 非空时**默认拒绝**并列出将被删除的
  部署（数据库、备份），必须显式 `--yes` 才继续。裸 `rm -rf "$AIBOX_HOME"` 前面加一行提示
  不算保护。（与「非交互下危险操作返回 2」的既有规则一致。）
  **已实现**：`aibox self uninstall [--yes]` —— `apps/` 非空时列出部署并要求交互确认，
  非交互且无 `--yes` 时返回 `2` 且不做任何改动；`--yes` 放子命令前后都认。
- **systemd / launchd 单元必须把解析后的绝对路径显式烘进去**，例如
  `Environment="AIBOX_HOME=/root/.aibox"`。
  **实测：systemd 系统服务里没有 `HOME` 变量**（`systemd-run /usr/bin/env` 只输出 `USER=root`）。
  任何靠 `$HOME` 派生的路径在服务上下文里都会解析成空 → 指向错误目录。
- **解析不到就报错，不要拼路径。** `HOME` 为空且无显式值时直接失败退出，
  而不是算出 `/.aibox/apps/<name>` 这种路径。
- **模块卸载只删自己的本体**，`apps/<name>` 与配置文件要保留（属于「这套部署」）。

### 配置落点：`/etc/<name>/<name>.conf`（跨平台同名）

| | 配置目录 | 部署目录 |
| --- | --- | --- |
| 写入频率 | 写一次、天天读 | **每条命令都写** |
| 落点 | `/etc/<name>/` | `$AIBOX_HOME/apps/<name>` |
| 能否放特权路径 | 能（安装期提权一次） | 不能（日常命令会全部要 sudo） |

- 权限：目录 `755 root:root`、文件 **`644`** —— **写只发生在安装期**（可提权），
  **读发生在每次命令**（不可提权）。**因此不要往里放凭据。**
- 由 `install.sh` **播种**（从 aibox 全局设置生成），策略**只补不覆盖**；CLI **只读不写**。
- 不放 `/opt/<name>.conf`：`/opt` 的约定是「一个包一个目录」，孤立的配置文件归属不清，
  卸载时不知道该不该删。
- 配置文件不存在时全部走内置默认 —— 行为与引入前完全一致。

> 存量模块状态：
>
> - `openmaic` **已按本约定对齐**（部署根 `$AIBOX_HOME/apps/openmaic`、配置 `/etc/openmaic`）；
> - `windmill` **已按本约定对齐**（部署根 `$AIBOX_HOME/apps/windmill`、配置 `/etc/windmill/windmill.conf`；CLI 兼容 bash 3.2，定时任务用 systemd 单元）；
> - `clash` **已按本约定对齐**（部署根 `$AIBOX_HOME/apps/clash`；无 `/etc` 配置——订阅含 token，state/config/pool.yaml 均 600 落部署根；mihomo 二进制由 install 钩子从 GitHub 下载）；
> - `pi-web` 属安装型，不需要部署根，落点保持平台约定。

## 代理

用户可用 `aibox proxy set <url>` 配一个全局代理（见仓库 README）。模块有两种消费方式：

**1. 靠环境变量（多数情况，什么都不用写）**

钩子是 aibox 的子进程，代理已由父进程导出，直接调 `curl` / `git` / `npm` 即生效。

**2. 持久化到自己的配置（跨机器、跨时间时必须做）**

如果模块下的命令会在**别的机器**、或 **aibox 不在场的时候**联网 —— 例如 `openmaic` 分发的 CLI 会在部署主机上跑 `openmaic upgrade` 拉源码 —— 环境变量传不过去，**必须由模块在安装/更新钩子里把代理写进自己的配置文件**。参考 `tools/openmaic/lib.sh` 的 `sync_proxy_to_conf`。

两条注意：

- 未配置代理时 `AIBOX_PROXY_URL` 为空且 `AIBOX_PROXY_ENABLED=0`，模块应**优雅跳过**而不是报错或写入空值。
- 不要假定代理是 HTTP 代理。值可能是 `socks5://host:port`，**整体透传**，别自己拼 `http://` 前缀。
- 写入配置文件时记得脱敏 —— 代理 URL 可能含 `user:pass@`，日志里别打明文（可参考 `mask_url`）。

## 用户命令 → 钩子映射

| 用户命令 | 钩子 |
| --- | --- |
| `aibox install <name>` | `install.sh` |
| `aibox uninstall <name>` | `uninstall.sh` |
| `aibox update <name>` | `update.sh` |
| `aibox <name> <action>` | `svc.sh <action>` |

## 退出码约定

钩子与透传的 CLI 应遵循统一退出码，便于自动化脚本（`aibox <module> <action>; echo $?`）稳定依赖。`aibox` 自身沿用 `die` → 退出 `1`。

| 码 | 含义 | 示例 |
| --- | --- | --- |
| 0 | 成功 | — |
| 1 | 运行错误（通用） | 命令执行失败 |
| 2 | 用法错误 / 非交互下被拒 | 参数不对；危险操作在非交互环境未获确认 |
| 3 | 依赖缺失 | 平台/命令不满足（如非 Linux 跑部署命令） |
| 4 | 前置校验失败 | 配置缺失、镜像拉不到 |
| 10 | 升级失败已回滚 | — |
| 20 | 需人工介入 | 健康检查失败、回滚后未就绪 |
| 30 | 服务未就绪 | 容器启动但未通过健康检查 |
| 40 | 并发冲突 | 拿不到锁（另一项运维在跑） |
| 50 | 用户取消 | 交互确认选了「否」 |

约定：

- `aibox <module> <action>` 会把 svc 钩子的退出码原样返回给调用方（`AIBOX_MODULE=... bash "$svc"`）。
- 危险操作在**非交互环境**下默认拒绝并返回 `2`，不静默执行（见下方《交互确认》）。
- 分发型模块（openmaic/windmill）的 CLI 主体已实现这套语义码；新模块请对齐。

## 交互确认

涉及不可逆操作（卸载部署、清空数据卷、拆除）时必须交互确认，且遵循统一模式：

- **危险操作用 `confirm "<提示>"`**：要求输入 `yes` 才继续；尊重 `--yes`/`-y`（`ASSUME_YES=1`，跳过确认直接继续）与 `--dry-run`（只显示不执行）。openmaic/windmill 的 `confirm` 已如此。
- **软选择用 `ask_yn "<提示>" [y|n]`**：默认 `n`（拒绝）或 `y`（同意）；**非交互环境（`[ -t 0 ]` 为假）一律走保守默认**并 warn 提示。
- 主 CLI 的 `ask_confirm`（`bin/aibox`）即软选择、默认拒绝、非交互返回 `1`。`aibox self uninstall` 在 `apps/` 非空时据此 fail-closed。
- **绝不静默执行危险操作**：非交互 + 无 `--yes` 时返回 `2` 而非 `0`，让脚本与 CI 能察觉。

## 依赖声明与自动检查

模块在 registry 声明 `deps` 字段（命令名，空格分隔），aibox `install` 时自动检查、缺则按平台装：

- **格式**：`命令名` / `命令名@平台`（仅该平台检查）/ `命令名:版本`（主版本约束）
- **示例**：`docker@linux docker-compose git`（仅 Linux 查 docker）、`node:22 npm`（node 22+）、`python3`
- **检查时机**：`aibox install <module>` 调 `check_deps`，在 install 钩子前
- **平台过滤**：`platform=darwin` 的模块在非 darwin 跳过；`@平台` 标记的依赖在非目标平台跳过（只提示）
- **自动安装**（`install_dep`）：
  - 轻量/有包管理器 → 装（macOS brew / Linux apt/yum/dnf）
  - 需 sudo（apt/yum）或 GUI 交互（Docker Desktop）→ **提示手动命令**，不静默 sudo
  - node 优先复用 nvm（pi-web 模式）
- **未知依赖**：提示手动安装

## 设计取舍

- **registry 用 shell 可 source 格式而非 JSON**：零运行时依赖、兼容 macOS 自带 bash 3.2，主 CLI 直接 source 即可，无需 `jq`/`python`。
- **模块脚本落地缓存**：aibox 把模块脚本下载到本地再执行，钩子可复用 `lib.sh`，`svc.sh` 透传不每次联网。
- **平台由模块自报**：`platform=darwin` 的模块在非 macOS 仅警告不阻断（模块自身在执行时报错更清晰）。
