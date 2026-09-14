# aibox

> AI coding 工具集 —— 一个轻量模块管理器 + 若干独立工具，`curl|bash` 一行装好，按需安装 / 更新 / 卸载各模块。

`aibox` 是一个纯 bash 的模块管理器（零运行时依赖，兼容 macOS 自带 bash 3.2）。每个「模块」是仓库 `tools/<name>/` 下的一个目录，自带 `install / uninstall / update / svc` 钩子，由 `aibox` 统一调度。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

装好 `aibox` 主 CLI 到 `~/.local/bin/aibox`（自动处理 PATH）。然后装首个模块：

```bash
aibox install pi-web
```

## 命令一览

```
aibox install <module>           安装模块
aibox uninstall <module>         卸载模块
aibox update <module> [--restart|--no-restart] [--all] | --all   更新模块；带 --all 则一并更新 aibox 自身
aibox list                       已安装模块
aibox list-available             可用模块
aibox <module> <action> [args]   调用模块服务动作（如 aibox pi-web start）
aibox self update                 更新 aibox 主程序（幂等重装）
aibox self uninstall             卸载 aibox
aibox self version | version | help
```

## 模块

| 模块 | 说明 |
| --- | --- |
| [`pi-web`](tools/pi-web/README.md) | 把 `@agegr/pi-web` 部署为 macOS launchd 常驻服务（HTTP Basic Auth + 自动重启） |
| [`openmaic`](tools/openmaic/README.md) | [OpenMAIC](https://github.com/THU-MAIC/OpenMAIC) 统一运维 CLI，分发到 Linux 部署主机（安装 / 升级 / 备份 / 自检） |

## 开发新模块

模块 = `tools/<name>/` 目录 + 在 `registry.sh` 登记。钩子契约见 [`docs/module-spec.md`](docs/module-spec.md)。最小模块只需一个 `install.sh`。

## 设计取舍

- **registry 用 shell 可 source 格式而非 JSON**：零运行时依赖、兼容 macOS 自带 bash 3.2，主 CLI 直接 source 即可，无需 `jq` / `python`。
- **模块脚本落地缓存**：`aibox` 把模块脚本下载到 `~/.aibox/modules/<name>/` 再执行，钩子可复用 `lib.sh`，`svc.sh` 透传不每次联网。
- **自更新 = 幂等重装**：`aibox self update` 重新 `curl|bash install.sh` 覆盖主 CLI，无 git / Releases 依赖。
- **平台由模块自报**：`platform=darwin` 的模块在非 macOS 仅警告，实际限制由模块钩子自身报错。
- **`AIBOX_RAW` 可覆盖**：支持本地源 / 镜像（如 `AIBOX_RAW=file:///path/to/aibox aibox list-available`）。
- **模块不一定带常驻服务**：`pi-web` 管 launchd 服务，而 `openmaic` 只分发一个 CLI 并把 `aibox openmaic <action>` 透传给它 —— 模块契约里 `svc.sh` 是「动作入口」，不是「必须是守护进程」。
- **模块运行环境自报**：安装落点跨平台的模块（如 `openmaic`）不设 `platform`，由 CLI 在执行时拒绝不支持的平台并给出提示，比安装期硬拦截更清楚（安装本身在任何系统都无副作用）。

## License

[MIT](LICENSE)
