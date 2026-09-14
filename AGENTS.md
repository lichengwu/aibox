# AGENTS.md

> 给 AI coding agent 和人类贡献者的项目协作指南。读完再动手。

## 项目简介

aibox 是纯 bash 的轻量模块管理器（零运行时依赖，兼容 macOS 自带 bash 3.2）。`curl|bash` 一行装好，按需安装 / 更新 / 卸载各模块。每个「模块」是仓库 `tools/<name>/` 下的一个目录，自带 `install / uninstall / update / svc` 钩子，由 `aibox` 主 CLI 统一调度。

## 仓库结构

```text
bin/aibox            主 CLI（install.sh 下载到 ~/.local/bin/aibox）
install.sh           bootstrap（curl|bash 安装 / 自更新，幂等）
registry.sh          模块清单（shell-sourced 变量；模块名连字符→下划线）
tools/<name>/        模块目录：lib.sh + install/uninstall/update/svc.sh
docs/module-spec.md  模块钩子契约
.github/workflows/   CI（release 自动化）
```

## 核心命令

```text
aibox install <module>
aibox uninstall <module>
aibox update <module> [--all] | --all     # --all 同时更新 aibox 自身
aibox list / list-available
aibox <module> <action> [args]            # 透传模块 svc.sh
aibox self {update|uninstall|version|help}
```

## 贡献约定

### bash 编码规范（强制）

1. **`set -euo pipefail`**：所有脚本顶部启用。
2. **变量引用一律用 `${VAR}`（花括号），禁止裸 `$VAR`** —— 尤其当变量后紧跟**非 ASCII 字符**（中文、全角标点 `，。、；：`）时必中招。详见下方《踩坑记录 #1》，本项目头号坑。
3. **本地变量先 `local` 声明再赋值**。
4. **幂等**：`install.sh` / `update.sh` 必须可重复执行不报错。
5. **不引入 `jq` / `python`**：registry 用 shell-sourced 格式，主 CLI 直接 source，兼容 bash 3.2。
6. **中文文案保留全角标点**，但变量边界用 `${VAR}` 显式分隔。

### commit 风格

Conventional Commits：`fix:` / `feat:` / `docs:` / `style:` / `chore:`。

### 版本号与发布流程

- 主 CLI 版本：`bin/aibox` 顶部 `AIBOX_VERSION`。
- 模块版本：`registry.sh` 里 `AIBOX_MODULE_<name>_version`。
- **发 release = 改 `AIBOX_VERSION` → push main**。GitHub Actions（`.github/workflows/release.yml`）自动：读取 `AIBOX_VERSION`，若远程无对应 `v<version>` tag，则自动建 tag + 发 release（notes 从上一 tag 自动生成）。版本号未变则跳过（幂等，可重复 push）。
- 自更新仍走 `curl install.sh | bash`（幂等重装），**不依赖 release** —— release 仅作发布记录与变更追溯。

## 踩坑记录

### #1 bash 3.2 + UTF-8 locale：全角标点紧跟 `$VAR` → unbound variable

**症状**：`set -u` 下，形如 `log "当前 $name，继续"` 的行报 `name<替换字符>: unbound variable`（变量名后带乱码）并退出。仅 UTF-8 locale 触发，`C` locale 不触发，故在部分环境 / CI 复现不出。

**根因**：macOS 自带 bash 3.2.57 存在多字节变量名解析缺陷。`$VAR` 后紧跟 UTF-8 多字节字符（中文、全角标点 `，。、；：！？` 等）时，bash 会把其字节错误吞入变量名，拼出不存在的变量，在 `set -u` 下报 unbound。`C` locale 按单字节处理，`0xEF` 等首字节非名称字符会终止变量名，故不报。

**修复**：变量引用一律 `${VAR}` 显式界定 —— `当前 ${name}，继续` 即可。

**历史**：`ad7cfed` 曾用 perl 全仓扫修 9 处，但 `876206d` 新增的 `cmd_self_update` 里 `$before，` 漏网，2026-09 由 `e5311bf` 补修。

**排查手法**：

```bash
sed -n <行号>p <文件> | xxd   # 看变量名后是否紧跟 ef bc 8c 等全角字节
LC_ALL=zh_CN.UTF-8 bash <脚本> # 用 UTF-8 locale 复现（C locale 复现不出）
```

## 开发新模块

1. 建 `tools/<name>/`，至少含 `install.sh`（钩子契约见 [`docs/module-spec.md`](docs/module-spec.md)）。
2. 在 `registry.sh` 登记（模块名连字符 → 下划线，如 `pi-web` → `AIBOX_MODULE_pi_web_*`）。
3. 如要服务常驻，实现 `svc.sh` 的 `start/stop/restart/status/logs/diagnose`。
4. 模块脚本会被下载缓存到 `~/.aibox/modules/<name>/`，可复用 `lib.sh`。

## License

MIT。
