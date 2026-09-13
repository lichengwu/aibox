# pi-web 模块

把 [`@agegr/pi-web`](https://www.npmjs.com/package/@agegr/pi-web) 部署为 macOS 用户级 launchd 常驻服务（HTTP Basic Auth + 崩溃自动重启）。本模块由原 `pi-web-ctl` 单脚本拆解而来，功能等价。

## 安装 / 卸载 / 更新（经 aibox）

```bash
aibox install pi-web              # 安装并启动服务
aibox update pi-web               # 有更新则询问是否重启（无更新不重启）
aibox update pi-web --restart     # 有更新则直接重启，不询问
aibox update pi-web --no-restart  # 有更新也不重启
aibox update --all                # 更新所有已装模块 + aibox 自身
aibox update pi-web --all         # 更新 pi-web + aibox 自身
aibox uninstall pi-web            # 停服 + 清理 plist
```

`update` 先比对 `@agegr/pi-web` 已装版本与 npm latest：**无更新则一律不重启**（无论参数）；有更新则升级 npm 包并重写 plist，再按 `--restart`（直接重启）/ `--no-restart`（不重启）/ 无参数（交互询问 `[Y/n]`，非交互默认不重启）决定是否重启服务。

## 服务运维

```bash
aibox pi-web start
aibox pi-web stop
aibox pi-web restart
aibox pi-web status
aibox pi-web logs
aibox pi-web diagnose
```

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PI_WEB_PASSWORD` | `ai-coding` | HTTP Basic Auth 密码（用户名固定 `pi`） |
| `PI_WEB_BIND` | `0.0.0.0` | 监听地址；`127.0.0.1` 仅本机 |
| `PI_WEB_PORT` | `30141` | 监听端口 |

在 `aibox install pi-web` 前导出即可，例如：

```bash
PI_WEB_PASSWORD=secret PI_WEB_BIND=127.0.0.1 aibox install pi-web
```

## 与原 pi-web-ctl 的对照

| 原 `pi-web-ctl` | 现在 |
| --- | --- |
| `pi-web-ctl install` | `aibox install pi-web` |
| `pi-web-ctl start` | `aibox pi-web start` |
| `pi-web-ctl status` | `aibox pi-web status` |
| `pi-web-ctl uninstall` | `aibox uninstall pi-web` |
| `pi-web-ctl install-cli` | （删除，由 `aibox` 主 CLI 取代） |

## 平台

仅 macOS（launchd）。在 Linux/Windows 上安装仅告警，实际执行由钩子报错。

## 钩子结构

| 文件 | 作用 |
| --- | --- |
| `lib.sh` | 共享：配置变量、`resolve_node` / `cleanup_old` / `write_plist` / `show_status` |
| `install.sh` | 安装 |
| `uninstall.sh` | 卸载 |
| `update.sh` | 更新 |
| `svc.sh` | `start/stop/restart/status/logs/diagnose` |
