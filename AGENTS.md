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
                     现有：pi-web（macOS launchd 服务）、openmaic（Linux 部署主机的运维 CLI）、windmill（Windmill 自托管 docker compose 运维 CLI）、clash（Clash 订阅代理池，mihomo 内核编排）
docs/module-spec.md  模块钩子契约
.github/workflows/   CI（release 自动化 + lint 质量门：bash -n / shellcheck / 踩坑 #1 #8 扫描）
```

## 核心命令

```text
aibox install <module>
aibox uninstall <module>
aibox update <module> [--restart|--no-restart] [--all] | --all     # --all 同时更新 aibox 自身
aibox list / list-available
aibox <module> <action> [args]            # 透传模块 svc.sh
aibox self {update|uninstall|version|help}
aibox proxy {show|set <url>|unset|on|off|test|env}   # 静态代理配置（全局，见 README「代理」）
aibox --no-proxy <命令>                              # 单次绕过代理
aibox clash {set <订阅URL>|on|off|status|refresh|select|test|logs|doctor}  # clash 订阅池（mihomo，见 tools/clash/README）
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

- 主 CLI 版本：`bin/aibox` 顶部 `AIBOX_VERSION`。**主 CLI 与各模块版本号独立**，各自迭代（模块随附的 CLI 自带 `*_CLI_VERSION`）。
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

**自查一行**（正则要求非 ASCII 紧贴变量名才算命中）：

```bash
grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[，。、；：！？（）「」]' <文件>
```

### #2 下发到别的机器的脚本，别用 bash 4 专有语法

**症状**：模块里 `svc.sh` 只是转发给下发的脚本，但在 macOS 上连 `--version` 都跑不起来，报
`syntax error near unexpected token '>'`，看不出跟本机 bash 版本有关。

**根因**：macOS 自带 bash 3.2，而脚本用了 bash 4 的 `exec {fd}>file`（自动分配文件描述符）
语法。注意这属于**解析阶段**错误 —— 整个文件都执行不了，任何分支都进不去，所以不是"某个功能
不可用"，而是"这个命令完全不存在"。

**修复**：改用固定 fd（`exec 9>file` / `flock -n 9`）。若确实需要 bash 4+，那就必须保证脚本
只在目标机器上被解析 —— 别让它出现在会在 macOS 上被 source 或执行的路径里。

**为什么值得为"可解析"让步**：保持可解析，才能在不受支持的平台上给出明确提示
（"此命令需要在 Linux 部署主机上运行"），而不是甩一个语法错误。参见 `tools/openmaic/openmaic`
里的 `require_deploy_host`。

### #3 代理测试：只看"能不能访问"必然是假阳性

**症状**：给 CLI 加代理支持后，`proxy test` 报"代理可用"（HTTP 200），但把端口填错、代理根本没开，测试**照样报 200**。

**根因**：测试写成"经代理访问 GitHub 成功 = 代理好使"。但在能直连的网络里，这个 200 是**直连**给的 —— 代理可能压根没被用上。同一台机器换个网络环境（Clash 开 TUN / 关 TUN），结论就翻转，而测试代码一行没改。

**修复**：用 curl 的 `%{proxy_used}` 判定（`1` = 确实走了代理，`0` = 直连），而不是 HTTP 状态码：

```bash
curl -s -x "$url" -o /dev/null -w '%{http_code} %{proxy_used}' "$target"
```

并且**额外跑一次直连对照**（`curl --noproxy '*'`），把"当前网络下代理到底必不必需"一并告诉用户。判断依据本身会过期，所以让命令每次现测。

**顺带记下的大小写差异**（实测，curl 8.7.1 / macOS 自带）：

| 变量 | curl 是否采用 |
| --- | --- |
| `http_proxy`（小写） | 采用 |
| `HTTP_PROXY`（大写） | **忽略** |
| `https_proxy` / `HTTPS_PROXY` | 均采用 |

所以导出代理时**大小写都要给**，否则总有一类工具用不上。另外 `file://` 源不受 `http_proxy` 影响（curl 直接读文件），本地 / 内网源无需特判 —— 但内网 HTTP 源会被代理绕出去，靠 `no_proxy` 默认覆盖私网段来解决。

### #4 环境变量传不过"进程边界"，跨机器/跨时间得靠落盘

**症状**：给 `aibox` 配了代理，`aibox install openmaic` 也走了代理；但之后在部署主机上跑 `openmaic upgrade` 拉源码，**又连不上了**。

**根因**：代理是通过环境变量注入的，而 `openmaic upgrade` 是**另一台机器、另一个时刻**的进程 —— 那时 `aibox` 早退出了，环境变量无从继承。

**修复**：这类"模块自己在别处联网"的场景，必须由模块**把值写进自己的配置文件**（`tools/openmaic/lib.sh` 的 `sync_proxy_to_conf` 写 `/etc/openmaic/openmaic.conf`）。

**判断准则**：钩子里**当场**跑的网络请求 → 环境变量够用；钩子**分发的命令以后在别处**跑的 → 必须落盘。别指望 `export` 能跨过进程和主机。

### #5 curl 的三个反直觉语义（都让判定悄悄失真）

写 `aibox proxy check` 时连踩三个，共同点是**都表现为"看起来正常，结论是错的"**：

1. **连接失败时 `-w` 什么都不输出。** 指向一个没人监听的端口，`curl -w '%{http_code}'` 不会给出
   `000` —— 它什么都不打印，`code` 就变成空字符串。按 `code == 000` 判失败会全部漏判。必须
   `|| out=""` 加空值兜底，再自己补 `000`。
2. **显式 `-x` 指定的代理，仍会被 `no_proxy` 排除。** 检查脚本里若不清掉 `no_proxy`，网络里
   恰好配了排除规则时，"检查这个代理能不能到 X" 会**静默变成"检查直连能不能到 X"**，结论是假
   的却不报错。做法：`env -u no_proxy -u NO_PROXY curl -x ...`。
3. **`%{proxy_used}` 不能只判"是否为空"。** 兜底的失败结果里它是 `0`（非空），于是"代理全线挂
   掉"会被聚合成"流量已确认全部经代理"。必须严格判 `= 1`。

**教训**：代理连通性这类检查，**"失败"和"没测到"必须区分开**。用空值/非空值推断状态时，先问
一句"这个字段在失败路径下会是什么"。

### #6 多字节字符不能做子串切片（bash 3.2 + C locale）

**症状**：spinner 帧用 `spin='⠋⠙⠹⠸'` 配 `"${spin:$i:1}"` 取单帧，在 UTF-8 locale 下正常，
在 `C` locale 下输出乱码。

**根因**：bash 的子串展开在非 UTF-8 locale 下按**字节**而非字符计算，会把 3 字节的 `⠋` 切成
半个，输出无效 UTF-8。

**修复**：用数组存**完整**的帧，取元素而不是切字符串：

```bash
SPIN=( '⠋' '⠙' '⠹' )          # 每项是完整字符，怎么取都不会切坏
probe_render "${SPIN[$i]}"
```

同理，符号 `✔ ✘ ⠋` 这类多字节字符在代码里要始终作为**完整字符串字面量**传递，不要拼、不要切。

### #7 测 TTY 交互别用 `script`，用 `expect`

`script -q /dev/null cmd` 看似能把管道输入喂进 pty 来测 `read` 提示，实际不可靠：stdin 的
转发与 pty 行缓冲会错位，`read` 拿不到你以为的那一行（表现为"喂了 y 却按 N 处理"），或者
EOF 时子进程被提前终止。macOS 自带 `expect`（`/usr/bin/expect`），直接用它：

```tcl
spawn bash bin/aibox proxy set http://127.0.0.1:1
expect -re {\[y/N\]} { send "y\r" }
```

注意 Tcl 正则里 `[y/N]` 的方括号是字符类，要写成 `\[y/N\]`。

**验证要点**：pty 下输出含 ANSI 控制序列，用 `cat -v` 看真实内容；统计 `^[[<n>A`
（光标上移）的**数值是否等于块高**，是检验重绘行数算错的最快方式。

### #8 bash 3.2：`local a="x" b="${a}/y"` 同行引用，`set -u` 下报 unbound

`local` 声明多个变量时，bash 3.2 会在**执行任何赋值前先展开全部右侧表达式** ——
第二个变量的 `${a}` 展开时第一个还没赋值，配合 `set -u` 直接炸：

```bash
/bin/bash -c 'set -u; f(){ local a="/etc/w" b="${a}/windmill.conf"; echo "$b"; }; f'
# bash: a: unbound variable
```

bash 5 没这个问题，所以「本机跑得好好的下发脚本」到 macOS bash 3.2 上才会炸。
（windmill 模块 lib.sh 实际踩到，`bash -n` 查不出来 —— 纯运行期展开问题。）
**修法**：拆成两行 `local a="..."` / `local b="${a}/..."`。
**排查**：`grep -rnE 'local [a-z_]+="[^"]*"[ ]+[a-z_]+="\$\{[a-z_]+\}'`。

## 开发新模块

1. 建 `tools/<name>/`，至少含 `install.sh`（钩子契约见 [`docs/module-spec.md`](docs/module-spec.md)）。
2. 在 `registry.sh` 登记（模块名连字符 → 下划线，如 `pi-web` → `AIBOX_MODULE_pi_web_*`）。
3. 如要服务常驻，实现 `svc.sh` 的 `start/stop/restart/status/logs/diagnose`。
4. 模块脚本会被下载缓存到 `~/.aibox/modules/<name>/`，可复用 `lib.sh`。
5. **安装落点要可覆盖**：从 `${AIBOX_BIN_DIR:-$HOME/.local/bin}` 起手，并提供一个本次任务专属的覆盖变量（如 `OPENMAIC_BIN_DIR`）—— 目标机器常想装到 `/usr/local/bin`。
6. **`svc.sh` 是「动作入口」而不是「必须是守护进程」**：常驻服务（pi-web）用 `start/stop/restart`，纯 CLI 分发（openmaic）可以直接把动作透传给下发的命令。
7. **平台差异只告警不硬拦**：安装本身通常跨平台（就是拷文件），真正跑不动的限制由脚本在执行时报清楚，比安装期拦截更少误伤。
8. 本机是 macOS（bash 3.2），钩子必须兼容；钩子**下发给别的平台**的脚本则要注意别用 bash 4 语法 —— 见踩坑记录 #2。
9. **部署型模块的落点别自己发明**（详见 [`docs/module-spec.md`](docs/module-spec.md) 的《部署目录与配置落点约定》）：部署根统一 `$AIBOX_HOME/apps/<name>`（两平台同一表达式，无需分支），配置统一 `/etc/<name>/<name>.conf`。两条实测硬约束：Docker Desktop 在 macOS 默认**不共享 `/opt`**（放那儿会让 compose 的相对挂载报 `Mounts denied`）；**systemd 系统服务里没有 `HOME`**（靠 `$HOME` 派生的路径在服务上下文里会解析成空，单元必须显式 `Environment=`）。

## License

MIT。
