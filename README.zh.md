<div align="center">

# aibox

**零依赖、纯 bash 的 AI 编码工具模块管理器。**

[![Latest Release](https://img.shields.io/github/v/release/lichengwu/aibox?color=blue&label=release)](https://github.com/lichengwu/aibox/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/lichengwu/aibox/lint.yml?label=CI)](https://github.com/lichengwu/aibox/actions/workflows/lint.yml)
[![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-lightgrey)](#环境要求)

[安装](#安装) · [快速上手](#快速上手) · [CLI 语法](#cli-语法) · [模块列表](#模块) · [English](README.md)

</div>

`aibox` 把你部署的每个自托管工具 —— GitLab、Dify、Clash 代理池 —— 都当作一个
**模块**：一个目录自带 `install / uninstall / update / svc` 钩子，由一个约 3.4k 行的
单文件 CLI 统一调度。零运行时依赖、无包管理器、macOS 自带的 bash 3.2 即可运行。

## 特性

- **统一语法** —— 一切都是 `aibox <动词> <模块>`：install / update / uninstall /
  check / upgrade / dashboard / purge。一个心智模型，没有子命令家族。
- **预检门控的安装** —— 依赖、磁盘、域名、docker 守护进程可达性、共享服务就绪度
  全部在动手前探测；坏网络自动尝试备选路由（直连 / clash / 镜像）。
- **下载源池** —— 每个下载族（GitHub raw/releases/API、docker.io、npm、ghcr、
  node-dist）并发竞速、按实测吞吐排序、逐源故障转移。健康网络零开销。
- **内置镜像加速** —— GitHub / docker.io / npm 镜像按你机器上的真实下载排序，
  不是拍脑袋。校验门控：镜像返回坏包体会被丢弃并换下一个源。
- **阶梯升级** —— `aibox upgrade <module>` 无需 aibox 发版即可升级部署的上游版本：
  健康门 + 自动回滚。GitLab 官方的必经停靠点规则已自动化（多跳路径计算、
  每跳最新 patch、跳间就绪门）。
- **本地优先的仪表板** —— `aibox dashboard` 从本地元数据渲染状态（✓ ok /
  ⚠ starting / ○ stopped）、端点、凭据、端口监听；异步探测永不阻塞视图。
- **逐模块离线帮助** —— `aibox <module> --help` 渲染动作表（来自模块自己的
  `usage:` 映射）；`aibox <module> <action> --help` 渲染单个动作。
- **默认安全** —— 每个破坏性动词都有交互确认（卸载先确认、再确认是否删数据；
  purge 先确认、再确认是否停容器）；脚本场景无 `--yes` 一律拒绝并 exit 2。
- **残留清理** —— `aibox purge` 扫描并清除卸载钩子遗留物（卷、`/etc` 目录、
  服务单元、二进制），aibox 本身卸载后也能清理。

## 环境要求

- **macOS 或 Linux**，bash 3.2+（macOS 自带版本即可）。
- `curl`。Docker 仅容器部署型模块需要（预检会告诉你）。
- 其余零运行时依赖；不需要 jq/python。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

raw.githubusercontent.com 被墙的网络（国内常见）加镜像前缀 —— 引导脚本自身的所有
下载也是直连+镜像竞速的：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/lichengwu/aibox/main/install.sh | bash
```

安装到 `~/.local/bin/aibox`（PATH 自动处理）。

可选的 `curl | bash` 校验：

```bash
AIBOX_SHA256=<hex>     curl -fsSL …/install.sh | bash   # 钉住精确二进制
AIBOX_VERIFY=1         curl -fsSL …/install.sh | bash   # 校验 release 的 SHA256SUMS
```

## 快速上手

```bash
aibox install pi-web        # 预检门控的模块安装
aibox pi-web start          # 服务生命周期：start / stop / restart / status / logs
aibox dashboard             # 全部模块：状态、端点、凭据、端口
```

部署共享的 PostgreSQL + Redis 基座，再装一个消费它的模块：

```bash
aibox install base          # 共享 PG18 + Redis7（每个模块独立数据库）
aibox base create postgres dify
aibox install dify
aibox dify start
```

## CLI 语法

一个语法：**`aibox <动词> <模块>`** —— "self" 也是一个模块（管理器本身）。

### 管理器动词（模块生命周期）

```text
aibox install <module> [flags]    预检门控安装（--skip-checks 跳过）
aibox uninstall <module>|self     先确认卸载、再确认是否删数据（--purge 预答
                                  "删"；--yes 为脚本场景跳过确认）
aibox update <module>|self|--all  刷新模块脚本（仓库钉住的版本底线）
aibox upgrade <module> [flags]    升级部署的上游版本（dockerhub/github-release
                                  解析、健康门、自动回滚、gitlab 阶梯多跳）。
                                  update ≠ upgrade：脚本版本 vs 上游应用版本
aibox check <module>|self         预检演练；self = 环境检查
aibox dashboard [--available]     总览（已安装模块）/ 目录
aibox dashboard <module>          单模块详情 + 健康探测
aibox purge [<module>...|self]    残留扫描/清理（默认 dry-run；--apply 先确认、
                                  再问是否停运行中容器）
aibox proxy {show|set|on|off|…}   静态出口代理配置（全局）
aibox --no-proxy <command>        单条命令绕过代理
```

### 模块动词（透传到模块的 svc.sh）

```text
aibox <module> <action> [args]    如 aibox pi-web start · aibox clash select <节点>
aibox <module> --help             动作表（离线，来自模块的 usage: 映射）
aibox <module> <action> --help    单个动作的用法（参数 + 描述）
```

每个服务模块实现标准生命周期（`start / stop / restart / status / logs`）加自己的
领域动作（`base create postgres <db>`、`gitlab credentials`、`clash select <节点>`…）。
`status` 展示运维事实**和富视图**（容器、健康、端点、凭据、端口监听）——
模块级的 `dashboard` 是 `status` 的别名。

### 端口与端点

> **注意：aibox 部署的服务端口与上游默认值不一定一致。**
> 内部端口注册表防止跨模块端口冲突 —— 例如 new-api 用 **30300**（上游默认 3000）、
> GitLab 用 **8929**、dify 用 **8088**。profile 会进一步派生端口
> （`--profile prod` 把 base 挪到 35177/36336）。

随时查看实际端口和端点：

```bash
aibox dashboard            # 端口表 + 每个已安装模块的监听状态
aibox dashboard <module>   # 单模块端点 + 健康
aibox <module> status      # 同上，来自模块本身
```

## 模块

| 模块 | 部署什么 | 文档 |
| --- | --- | --- |
| [`base`](tools/base/) | 共享 PostgreSQL 18 + Redis 7；每模块独立库 | [README](tools/base/README.md) |
| [`clash`](tools/clash/) | Clash 订阅代理池（mihomo 内核，自动测速/故障转移） | [README](tools/clash/README.md) |
| [`dify`](tools/dify/) | [Dify](https://github.com/langgenius/dify) LLM 应用构建器 | [README](tools/dify/README.md) |
| [`gitlab`](tools/gitlab/) | [GitLab CE](https://gitlab.com/gitlab-org/gitlab) omnibus（阶梯升级） | [README](tools/gitlab/README.md) |
| [`new-api`](tools/new-api/) | [New API](https://github.com/QuantumNous/new-api) LLM 网关 | [README](tools/new-api/README.md) |
| [`pi-web`](tools/pi-web/) | [@agegr/pi-web](https://github.com/agegr/pi-web) launchd/systemd 服务 | [README](tools/pi-web/README.md) |
| [`openmaic`](tools/openmaic/) | [OpenMAIC](https://github.com/THU-MAIC/OpenMAIC) 部署主机运维 CLI | [README](tools/openmaic/README.md) |
| [`windmill`](tools/windmill/) | [Windmill](https://github.com/windmill-labs/windmill) 自托管运维 CLI | [README](tools/windmill/README.md) |
| [`xiaozhi`](tools/xiaozhi/) | [Xiaozhi ESP32 服务端](https://github.com/xinnan-tech/xiaozhi-esp32-server) | [README](tools/xiaozhi/README.md) |

> **范围说明**：`windmill` 与 `openmaic` 模块在仓库内捆绑了完整的自托管运维
> CLI（各数千行）——它们是这些运维工具的源头而非第三方副本。核心管理器本身是
> `bin/aibox`（单文件 —— curl|bash 一行安装的部署约束）。

## 进阶

<details>
<summary><b>出口代理</b>（aibox proxy on/off/set、clash 托管）</summary>

`aibox proxy set <url>` 存储静态代理供所有 aibox 下载使用；`aibox clash on`
把出口切到本地托管的 mihomo。`set` 之后立刻做站点连通性验证，带直连对照，
判定不会出现假阳性。详见 [clash README](tools/clash/README.md)。
</details>

<details>
<summary><b>下载源池</b>（镜像加速的工作原理）</summary>

每个下载族维护候选池。安装时用真实资产的**有界部分下载**并发竞速候选、
按实测 bytes/sec 排序、失败逐源转移。完成的包体先校验再接受（gzip 完整性 +
可执行 + 版本钉住）；坏镜像被丢弃而非致命。实战案例见
[tools/clash/README](tools/clash/README.md)。
</details>

<details>
<summary><b>开发新模块</b>（脚手架 + 验证器 + 规范）</summary>

```bash
scripts/new-module.sh mytool            # 生成合规骨架
scripts/validate-module.sh mytool       # 一致性门禁（CI 跑 --all）
```

契约见 [`docs/module-spec.md`](docs/module-spec.md)（规范）：module.yaml 模式
（ports/checks/usage/includes/upgrade）、钩子规则、预检契约、残留地图、出口码、
交互门。参考实现：[`tools/gitlab/`](tools/gitlab/)。
</details>

<details>
<summary><b>设计取舍</b></summary>

- **单文件主 CLI**（约 3.4k 行）：curl|bash 一行安装的约束。内部分区组织。
- **纯 bash、零依赖**：在 macOS 原生 bash 3.2 上运行；坑日志（AGENTS.md）把
  每个平台陷阱变成 CI 断言。
- **注册表 = `tools/*/module.yaml`**：加模块=建目录；无需中心注册表。
- **本地优先仪表板**：默认视图零网络；版本探测异步。

</details>

## 贡献

欢迎 PR。先读 [`AGENTS.md`](AGENTS.md) —— bash 编码规范、坑日志（带最小复现的
平台陷阱）、模块规范入口。Conventional Commits；每次发版遵循
[changelog 标准](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)
