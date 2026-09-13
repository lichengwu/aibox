# aibox 模块规范

aibox 的每个「模块」是一个独立工具，放在仓库 `tools/<name>/` 下，由主 CLI `aibox` 统一安装 / 更新 / 卸载 / 调度。

## 目录结构

```
tools/<name>/
├── lib.sh          # 共享函数（可选，各钩子 source 它复用）
├── install.sh      # 必需：安装
├── uninstall.sh    # 推荐：卸载
├── update.sh       # 可选：更新
├── svc.sh          # 可选：服务运维，$1=动作
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
- aibox 注入环境变量：`AIBOX_HOME`、`AIBOX_MODULE`（模块名）、`AIBOX_RAW`（仓库 raw 基址）。
- `install.sh` 负责把模块自身装好（落点自治，例如 pi-web 写 launchd plist）。
- `svc.sh`：`$1` = 动作，其余参数透传。

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
