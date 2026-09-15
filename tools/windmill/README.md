# windmill

Windmill 自托管实例的**单文件运维 CLI** 分发模块（与 `openmaic` 同构）。
CLI 本体是 `windmill`（自包含 bash 脚本，所有 compose/Caddyfile/systemd 模板内嵌），
本模块负责把它装到目标机器并播种主机级配置。

## 适用场景

- Linux 部署主机（推荐：`WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill`）
- macOS 本机亦可安装（CLI 已做平台适配：锁/端口/IP/内存/备份抢救均有回退实现）；
  唯一未适配项是 **launchd 定时任务**（每日备份/版本检查在 macOS 上暂不可用，`systemd` 子命令会明确报错）

## 落点（module-spec《部署目录与配置落点约定》）

| 项 | 路径 | 说明 |
| --- | --- | --- |
| CLI 本体 | `${WINDMILL_BIN_DIR:-${AIBOX_BIN_DIR:-~/.local/bin}}/windmill` | 安装型落点 |
| 部署根 | `$AIBOX_HOME/apps/windmill` | `.env`、compose、`backups/`、`logs/`、凭据；`destroy` 的删除边界 |
| 主机级配置 | `/etc/windmill/windmill.conf` | 键白名单 `PROXY_URL` / `WM_GHCR_MIRROR` / `WM_HUB_MIRROR` / `HTTP_PORT`；install 播种、只补不覆盖、CLI 只读；**不放凭据** |

部署根两平台同一表达式（Linux `/root/.aibox/apps/windmill`，macOS `~/.aibox/apps/windmill`）。

## 快速开始（部署主机上）

```bash
aibox install windmill                 # 或 WINDMILL_BIN_DIR=/usr/local/bin aibox install windmill
windmill doctor                        # 环境自检
windmill init --version 1.811.1        # 从零部署（国内网络建议先给 docker daemon 配代理）
windmill systemd install               # 每日备份 + 每周版本检查 + 开机对齐
```

日常：`windmill status / doctor / backup --full / drill`；升级：`windmill check` → `windmill upgrade <ver>`。

## 网络要点（实测）

- ghcr.io 直连国内约 0.5 MB/s，**首选给 docker daemon 配 HTTP 代理**（systemd drop-in，
  实测 66 MB/s）；`--ghcr-mirror` / `--hub-mirror` 为备选
- daemon 的 `registry-mirrors` 若混入黑洞源，`docker pull` 会静默挂死 —— CLI 的拉取
  自带停滞检测与重试，也可用 `--hub-mirror` 绕开

## 卸载语义

`aibox uninstall windmill` 只删 CLI 本体；`/etc/windmill/windmill.conf` 与
`$AIBOX_HOME/apps/windmill`（数据库卷、备份）**保留** —— 它们属于「这套部署」。
彻底清场用 `windmill --yes destroy --all`（先转移备份到 `$AIBOX_HOME/backups/`）。

## 与 aibox 的关系

- 代理：aibox 全局代理（`aibox proxy set`）在 install/update 时播种进
  `/etc/windmill/windmill.conf` 的 `PROXY_URL`，供部署主机上离线执行 `windmill check` 使用
- `aibox windmill <action>` 透传给本机 `windmill` CLI
- `aibox self uninstall` 对 `apps/` 有 fail-closed 保护，不会误删部署实例
