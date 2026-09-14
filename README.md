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

aibox proxy                       查看代理配置与状态
aibox proxy set <url> [--no-test] 设置代理（默认先测试可达性）
aibox proxy test [url]            测试代理（含"直连对照"）
aibox proxy on | off              启用 / 停用（配置保留）
aibox proxy unset                 清除配置
aibox proxy env [--remote]        输出 export 语句 / 远端下发格式
aibox --no-proxy <命令>           本次调用绕过代理
```

## 代理

有些环境下（比如国内直连 GitHub）`aibox` 拉不到模块，或模块钩子里的 git / npm 出不去。配置一次代理，`aibox` 自身与它派生的模块钩子都走它：

```bash
aibox proxy set http://10.0.0.2:7897           # 设置并测试
aibox proxy test                               # 随时复测
aibox --no-proxy list-available                # 单次绕过
```

配置存在 `~/.aibox/config`（权限 600），**不写入你的 shell 配置** —— 想让终端里的 git / brew 也走代理，用 `eval "$(aibox proxy env)"` 自己决定。

生效分三层，其中前两层自动：

| 层 | 覆盖什么 | 怎么生效 |
| --- | --- | --- |
| 1. 主进程 | `aibox` 自己拉 registry / 模块 / self update | 启动时导出环境变量 |
| 2. 子进程 | 模块钩子（`install.sh` 等）里的 curl / git / npm | 环境变量被子进程继承 |
| 3. 持久化 | 模块在**别的机器、别的时间**执行时的联网 | 模块把代理写进自己的配置文件，需模块主动配合 |

第 3 层为什么必要：`openmaic` 模块分发的 CLI 会在部署主机上、`aibox` 完全不在场时执行 `openmaic upgrade` 去拉 GitHub 源码，环境变量跨不了这个边界。所以 `aibox install openmaic` 会顺带把代理写进 `/etc/openmaic/openmaic.conf`。

### 代理失效时会怎样

**配了就强制**：代理不通即报错，不会静默回退直连（否则表现为每次都先等超时再回退，慢且查不出原因）。三个出口：

```bash
aibox proxy test      # 一条命令给结论：代理可达性 + 直连对照
aibox proxy off       # 全局停用（配置保留）
aibox --no-proxy ...  # 单次绕过
```

`proxy test` 会额外跑一次"直连对照"并明确告诉你当前网络下代理是否必需 —— 因为**只看"能不能访问"会骗人**，详见 [`AGENTS.md`](AGENTS.md) 踩坑记录 #3。

### 不覆盖什么

代理是**进程级环境变量**，只影响遵循 `*_proxy` 的工具（curl / git / wget / npm / pip / apt）。**Docker daemon 的 pull 走 `/etc/docker/daemon.json`，不受影响**；已在运行的常驻服务也改不了，需重启。

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
- **代理配置与运行时分离**：配置写 `~/.aibox/config`（600），启动时导出为环境变量。因此它既覆盖 `aibox` 自身，也覆盖它派生的模块钩子（子进程继承），无需改任何现有模块代码。跨机器 / 跨时间那一层（模块在别处自己联网）必须由模块把值写进自己的配置文件 —— 环境变量本来就跨不过去，这不是取巧，是边界。
- **代理失效选确定性，不做静默回退**：代理不通就报错。静默回退会让"代理已坏"表现成"每次都慢一点"，比直接失败更难查。配套给了 `test` / `off` / `--no-proxy` 三个出口，不至于走投无路。
- **不碰用户的 shell 配置**：`aibox proxy set` 只写自己的配置，不往 `~/.zshrc` 注入 —— 全局代理会影响本不该走代理的服务，超出 aibox 的职责。要全局生效用 `eval "$(aibox proxy env)"`。

## License

[MIT](LICENSE)
