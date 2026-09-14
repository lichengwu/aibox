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

## 设计取舍

- **registry 用 shell 可 source 格式而非 JSON**：零运行时依赖、兼容 macOS 自带 bash 3.2，主 CLI 直接 source 即可，无需 `jq`/`python`。
- **模块脚本落地缓存**：aibox 把模块脚本下载到本地再执行，钩子可复用 `lib.sh`，`svc.sh` 透传不每次联网。
- **平台由模块自报**：`platform=darwin` 的模块在非 macOS 仅警告不阻断（模块自身在执行时报错更清晰）。
