# openmaic 模块

把 [OpenMAIC](../..) 的统一运维 CLI（`openmaic`）通过 aibox 分发到目标主机。

CLI 本体是仓库里的 `tools/openmaic/openmaic`（单文件 bash），**本仓库即它的唯一源头**：改这里、`aibox update openmaic`，各处同步。

## 它管的是什么

OpenMAIC 是一套 Docker Compose 部署（应用 + PostgreSQL + 视频渲染服务）。这个 CLI 把它的日常运维收敛成一个入口：安装、升级回滚、备份恢复、配置管理、环境自检。

## 运行位置

CLI 需 **docker + compose**（不限 OS：Linux 部署主机、macOS Docker Desktop 都行），默认部署目录 `$AIBOX_HOME/apps/openmaic`。

- 有 docker：`up/install/upgrade/backup` 等服务命令全可用
- 无 docker：只 `help / version / doctor` 等只读命令可用，服务命令明确拒绝（退出码 `3`）而非抛 docker 报错

`aibox install openmaic` 会自动检查 docker 依赖（缺则提示装）。

```bash
OPENMAIC_BIN_DIR=/usr/local/bin aibox install openmaic
```

## 安装 / 更新 / 卸载

```bash
aibox install openmaic      # 安装（幂等）
aibox update openmaic       # 内容有变化才覆盖，一致则跳过
aibox uninstall openmaic    # 只删 CLI 本体
```

`aibox uninstall openmaic` **不会**删 `/etc/openmaic`（密钥、访问密码）与部署根 `$AIBOX_HOME/apps/openmaic`（部署目录）—— 那些属于「这套部署」而非「这个命令」。要清部署请用 `openmaic clean`。

## 动作透传

模块没有自己的常驻服务，`aibox openmaic <action>` 直接透传给本机的 `openmaic`：

```bash
aibox openmaic status           # 等价于 openmaic status
aibox openmaic doctor
aibox openmaic upgrade --check
aibox openmaic backup list
```

> ⚠️ 命名撞车：`aibox install openmaic` 是**装这个模块**；`aibox openmaic install` 是**部署 OpenMAIC 本体**（从源码 clone + 构建 + 起容器）。差一个词序，语义完全不同。

## 环境变量

安装落点：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `OPENMAIC_BIN_DIR` | `$AIBOX_BIN_DIR` 或 `~/.local/bin` | CLI 安装目录；部署主机上常用 `/usr/local/bin` |

CLI 运行时（也可写进 `/etc/openmaic/openmaic.conf`，环境变量优先级更高）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `OPENMAIC_CONF_DIR` | `/etc/openmaic` | 配置与密钥目录 |
| `OPENMAIC_BASE_DIR` | `$AIBOX_HOME/apps/openmaic` | 部署根目录（见下方《落点》） |
| `OPENMAIC_PROXY_URL` | 空 | 拉取源码用的代理，接受完整 URL（`http://host:port` / `socks5://host:port`）。**优先于下面的旧键** |
| `OPENMAIC_PROXY_HOST` | 空 | 同上（旧键，兼容保留）。值可写裸 `host:port`，会自动补 `http://` |
| `OPENMAIC_HEALTH_URL` | `http://127.0.0.1:3000/api/health` | 健康检查地址 |
| `OPENMAIC_HEALTH_TIMEOUT` | `300` | 健康检查等待上限（秒） |
| `OPENMAIC_BACKUP_KEEP` | `14` | 备份保留份数 |
| `OPENMAIC_RENDER_ENABLED` | `1` | 是否启用视频渲染容器 profile |
| `OPENMAIC_BUILD_TIMEOUT_MAIN` | `3600` | 主镜像构建超时（秒） |
| `OPENMAIC_BUILD_TIMEOUT_RENDER` | `2400` | 渲染镜像构建超时（秒） |

仓库里不含任何站点地址；主机相关的值一律由此显式传入。

## 落点

| 平台 | 身份 | 部署根 |
| --- | --- | --- |
| Linux | root | `/root/.aibox/apps/openmaic` |
| macOS | 普通用户 | `~/.aibox/apps/openmaic` |

两平台同一表达式 `${AIBOX_APPS_ROOT:-${AIBOX_HOME:-$HOME/.aibox}/apps}/openmaic`，
**不做平台分支** —— 约定见仓库 `docs/module-spec.md`《部署目录与配置落点约定》。

- 配置目录 `/etc/openmaic`（写一次、天天读）与部署根（**每条命令都写**）刻意分离：
  后者必须落在「日常身份可写」且「容器运行时默认共享」的路径下 —— 否则 `status` 这类
  只读命令也要提权，且 compose 里的相对挂载会 `Mounts denied`。
- **不把部署根放 `/opt` 下**：macOS 上 Docker Desktop 默认不共享 `/opt`（这条与 sudo 无关）。
- 解析不到 `HOME` 且未给显式值时，CLI **直接报错退出（`3`）**，不会拼出 `/.aibox/...`。

## 代理

部署主机常直连不了 GitHub，而「拉源码」这一步（`openmaic install` / `upgrade`）必须过网络。这个代理**一般不用手工配**：

```bash
# 在部署主机上（aibox 已装）
aibox proxy set http://10.0.0.2:7897           # 配一次，aibox 自身与模块钩子都走它
OPENMAIC_BIN_DIR=/usr/local/bin aibox install openmaic
#   └─ 模块钩子会自动把代理写进 /etc/openmaic/openmaic.conf 的 OPENMAIC_PROXY_URL
```

**为什么必须落盘到 conf**：`openmaic upgrade` 是在部署主机上、**aibox 不在场**时执行的 —— 环境变量跨不过这个边界（跨主机、跨时间）。写进 conf 之后，此后每次升级拉源码都会自动用它。

也可以不经 aibox，直接编辑 `/etc/openmaic/openmaic.conf`：

```ini
OPENMAIC_PROXY_URL="http://10.0.0.2:7897"
```

拉源码是**多通道**的，代理只是第一条：

1. 经代理直连 GitHub（仅在配了代理时才尝试）
2. 无代理直连
3. `ghproxy.net`
4. `gh-proxy.com`

所以代理不可达、或代理所在机器关机，都**不会让升级卡死** —— 还有公共镜像兜底。当前生效的代理可在 `openmaic doctor` 里看到（已脱敏）。

## 常用命令

```bash
openmaic status / health / doctor       # 总览、健康检查、环境自检
openmaic up / down / restart / logs     # 生命周期
openmaic upgrade [--check] / rollback   # 升级与回滚
openmaic backup [list|verify] / restore # 备份与恢复
openmaic config show|get|set|diff       # 配置管理
openmaic models                         # 模型连通性探测
openmaic powerlog                       # 异常断电检测（journalctl）
openmaic install [--tag <tag>] / clean  # 从零部署 / 清理部署
openmaic completion bash                # 补全脚本
```

全局选项：`--json` / `--yes` / `--dry-run` / `--quiet` / `--no-color`。
退出码分级：`0` 成功、`1` 运行错误、`2` 用法错误、`3` 依赖缺失、`4` 前置校验失败、`10` 失败已回滚、`20` 需人工介入、`30` 未就绪、`40` 并发冲突、`50` 用户取消。

## 钩子结构

| 文件 | 作用 |
| --- | --- |
| `openmaic` | CLI 本体（单文件 bash，约 1500 行） |
| `lib.sh` | 共享：落点解析、版本读取、语法检查、`host_notice`、代理下发（`sync_proxy_to_conf`） |
| `install.sh` | 安装 |
| `uninstall.sh` | 卸载（只删本体） |
| `update.sh` | 更新（内容比对，幂等） |
| `svc.sh` | 动作透传 |

## 平台

跨平台：安装是拷一个文件；CLI 兼容 bash 3.2（用固定 fd 而非 bash 4 的 `exec {fd}>`）。服务命令需 docker（macOS 用 Docker Desktop / Linux 用 docker），不限 OS —— 无 docker 时只读命令仍可用。
