# aibox 模块系统增强规格

> 状态：设计稿。本文档收录端口声明、Dashboard、共享基础组件、模块开发指南、module.yaml 声明规范等增强需求，作为后续实现的依据。
>
> 定位：aibox 是本地开发 + 单机部署运维的轻量模块管理器（纯 bash、零运行时依赖、兼容 macOS bash 3.2）。模块从当前 4 个增长到几十个时的终态设计。

---

## 1. 背景与目标

当前 aibox 模块声明集中在 `registry.sh`（shell-sourced 变量），适合 4-5 个模块。随着模块增长到几十个，集中文件臃肿、merge 冲突多、加模块要改全局。同时需要：端口不冲突、模块状态可视化、共享组件省资源、开发指南助 AI 升级。

本规格定义：

1. **module.yaml 规范** —— 每模块一个 YAML 声明文件，结构化、自治
2. **端口声明与冲突检测** —— 设计时静态声明，CI 加测挡冲突
3. **Dashboard TUI** —— 模块状态 + endpoint + 凭据可视化
4. **共享基础组件** —— PG/Redis 单实例多库，省资源
5. **模块开发指南** —— AI 据此升级模块
6. 依赖管理、自启动约定（已实现，收录现状）

---

## 2. module.yaml 规范（模块声明）

### 2.1 位置与发现

- **位置**：`tools/<name>/module.yaml`（和模块代码同目录，自治）
- **发现**：主 CLI 扫 `tools/*/module.yaml` 自动发现模块（**不再需要 registry.sh 列模块名**）。加模块 = 建 `tools/<name>/` + `module.yaml`，零改全局。

### 2.2 YAML 子集（awk 可解析）

为保持主 CLI 零依赖（纯 bash + awk），module.yaml 限制为 awk 可靠解析的子集：

- `key: value`（标量，引号可选）
- `key:` 下 `- item`（列表）
- `key:` 下 `subkey: value`（浅嵌套，最多 2 层）
- `#` 注释
- **禁止**：锚点/引用（`&`/`*`）、多行字符串（`|`/`>`）、流式（`{}`/`[]`）、复杂类型

这个子集覆盖模块声明所有字段。

### 2.3 字段规范

```yaml
# tools/<name>/module.yaml —— 模块声明 source of truth
name: pi-web                      # 必填。模块名（连字符）
version: 1.0.0                    # 必填。模块版本
description: "..."                # 必填。一句话描述
platform: ""                      # 可选。空=跨平台；darwin=macOS 专有
dir: tools/pi-web                 # 必填。仓库内目录

deps:                             # 可选。运行依赖（命令@平台:版本）
  - "node:22"                     #   node:22 = 主版本 >=22
  - npm                           #   @linux = 仅 Linux 检查
  - "docker@linux"                #   空 = 无依赖（如 clash，mihomo 下发）

ports:                            # 可选。占用端口（端口/协议:用途）—— CI 检测冲突
  - 30141/tcp:http
  - 9090/tcp:api

files:                            # 必填。仓库内文件（aibox 下载缓存到 ~/.aibox/modules/<name>/）
  - lib.sh
  - install.sh
  - uninstall.sh
  - update.sh
  - svc.sh

hooks:                            # 必填。钩子文件名
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                          # 可选。svc 支持的动作
  - start
  - stop
  - restart
  - status
  - logs
  - diagnose

upstream:                         # 可选。开发指南链接（见 §6）
  homepage: https://github.com/agegr/pi-web
  docs: https://github.com/agegr/pi-web#readme
  install: https://github.com/agegr/pi-web#installation
  test: https://github.com/agegr/pi-web#development

dashboard:                        # 可选。Dashboard 展示信息（见 §4）
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "用户名 pi / 密码见 aibox pi-web status"
```

### 2.4 解析方案（方案 A：内置 awk，零依赖）

主 CLI `load_registry` 改为扫 `tools/*/module.yaml` + awk 解析：

```bash
load_registry() {
  AIBOX_MODULES=""
  local f name
  for f in "$AIBOX_REPO_DIR"/tools/*/module.yaml; do
    [ -f "$f" ] || continue
    name="$(parse_yaml_field "$f" name)"
    [ -n "$name" ] || continue
    AIBOX_MODULES="${AIBOX_MODULES:+$AIBOX_MODULES }$name"
    parse_yaml_module "$f" "$name"   # awk 解析 → eval 注入 AIBOX_MODULE_<name>_* 变量
  done
}
```

`parse_yaml_module`（awk 实现，~80 行）：

- 遍历 YAML 行，按缩进 + `-` 识别层级
- 标量 → `AIBOX_MODULE_<name>_<key>="value"`
- 列表 → `AIBOX_MODULE_<name>_<key>="item1 item2 ..."`（空格分隔，兼容 module_field 读取）
- 浅嵌套（hooks/upstream/dashboard）→ `AIBOX_MODULE_<name>_<parent>_<subkey>="value"`
- 输出 `eval`-able 的变量赋值，主 CLI eval 注入

awk 解析器只支持 §2.2 子集；CI 保证 YAML 合规（见 §2.5）。

### 2.5 CI 校验（module-lint）

```yaml
  module-lint:
    name: module.yaml lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: install yq
        run: sudo wget -qO/usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
      - name: 校验 module.yaml
        run: |
          set -e
          fail=0
          for f in tools/*/module.yaml; do
            [ -f "$f" ] || continue
            # 1. 必填字段：name/version/dir/files/hooks.install 非空
            # 2. YAML 子集合规：无锚点(&/*)、无多行(|/>)、无流式({}/[])
            # 3. ports 格式：端口/协议:用途
            yq -e '.name' "$f" >/dev/null || { echo "::error file=$f::缺 name"; fail=1; }
            ...
          done
          exit $fail
```

CI 用 yq（权威解析）校验；主 CLI 用 awk（零依赖）运行时解析。CI 保证 YAML 在 awk 子集内。

---

## 3. 端口声明与冲突检测

### 3.1 目标

模块在设计时静态声明占用端口，aibox 登记，单机多模块不冲突。**不是运行时报错，是 CI 加测挡提交**。

### 3.2 声明（module.yaml ports 字段）

```yaml
ports:
  - 30141/tcp:http      # 端口/协议:用途
  - 9090/tcp:api
```

格式：`端口/协议:用途`。CI 按 **端口+协议** 唯一检测。

### 3.3 分配策略：静态声明 + 优先分配占用（不随机）

- **静态声明**：端口在 module.yaml 写死（设计时定），稳定可预测
- **优先分配占用**：先声明的先得，新模块声明已占端口 → CI fail，开发者改新模块端口
- **不随机**：随机端口适合多租户/容器，不适合本地开发（endpoint 不稳定、用户记不住、dashboard 要动态查）
- **端口段**：aibox 模块用 30000-49999（避开系统常用 <1024、80、443、3000、5432、6379、8080、9000 等）

### 3.4 CI 冲突检测（port-conflict job）

```yaml
  port-conflict:
    name: port conflict
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: install yq
        run: sudo wget -qO/usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
      - name: 检测模块间端口冲突
        run: |
          set -e
          declare -A owner
          dup=0
          for f in tools/*/module.yaml; do
            [ -f "$f" ] || continue
            m=$(yq '.name' "$f")
            for p in $(yq -o=ts '.ports[]' "$f" 2>/dev/null || true); do
              pp="${p%%/*}"
              if [ -n "${owner[$pp]:-}" ]; then
                echo "::error::端口 $pp 冲突：${owner[$pp]} 与 $m"
                dup=1
              else owner[$pp]="$m"; fi
            done
          done
          [ $dup -eq 0 ] && echo "✅ 端口无冲突"
          exit $dup
```

冲突 → `::error` + exit 1 → PR 检查失败，代码不能 merge。

### 3.5 `aibox ports` 命令（查分配表）

```bash
$ aibox ports
模块        端口/协议     用途      可覆盖(示例)
pi-web      30141/tcp    http      PI_WEB_PORT
clash       7890/tcp     mixed     CLASH_PORT
clash       9090/tcp     api       CLASH_API_PORT
windmill    8080/tcp     http      WM_HTTP_PORT
openmaic    3000/tcp     app       —
openmaic    5432/tcp     pg        —
```

开发者加模块前 `aibox ports` 看已分配，选空闲端口。主 CLI 从 module.yaml ports 字段实时收集（动态，无需维护 docs/ports.md）。

### 3.6 运行时探测（install 时，可选）

`aibox install <module>` 读模块 ports，`lsof -iTCP:端口` 探测实际占用 → 被非 aibox 服务占则 warn（"端口 X 被外部占用，可用 PI_WEB_PORT 覆盖"）。这层不挡提交，只提示。用户可用环境变量（`PI_WEB_PORT` 等）覆盖实际端口。

### 3.7 共享组件端口

共享 PG/Redis（§5）的端口也在 base 模块的 module.yaml 声明 + CI 检测。建议用非默认（PG 35432、Redis 36379）避免和系统服务撞。

---

## 4. Dashboard TUI

### 4.1 目标

每模块有 Dashboard，展示：是否已部署、endpoint（浏览器 URL/端口）、初始密码/key，方便登录和使用。

### 4.2 命令

- `aibox dashboard` —— 全局总览表（模块 / 已部署? / endpoint / 状态）
- `aibox <module> dashboard` —— 单模块详情（端口/URL/凭据/日志路径/健康）

### 4.3 TUI 实现

纯 bash（颜色 + 表格，零依赖）。**不用 dialog/whiptail**（macOS 没有）。输出形如：

```
┌─ aibox dashboard ────────────────────────────────┐
│ 模块       状态     endpoint                凭据  │
├──────────────────────────────────────────────────┤
│ pi-web     ✓ 运行   http://127.0.0.1:30141  pi/**│
│ clash      ✓ 运行   socks5://127.0.0.1:7890  —   │
│ windmill   ✗ 未装   —                        —   │
│ openmaic   ✓ 已装   http://127.0.0.1:3000   .env │
└──────────────────────────────────────────────────┘
```

### 4.4 模块接口：`dashboard_info()`

各模块 `lib.sh` 实现 `dashboard_info()`，输出 key=value（aibox 调用解析）：

```bash
# tools/<name>/lib.sh
dashboard_info() {
  # 输出 key=value，aibox dashboard 收集
  echo "endpoint=http://127.0.0.1:${PORT}"
  echo "credential=用户名 pi / 密码 ${PASSWORD}"   # 密码从 plist 读（resolve_password）
  echo "log=${LOG_DIR}/pi-web.log"
  echo "health=curl -s -u pi:${PASSWORD} http://127.0.0.1:${PORT}/"
}
```

约定写进 module-spec。模块未装时 aibox 只显示声明信息（module.yaml dashboard 段）。

### 4.5 凭据来源（各模块）

| 模块 | 凭据来源 |
| --- | --- |
| pi-web | plist `PI_WEB_PASSWORD`（resolve_password 读） |
| clash | state `CLASH_SECRET`（API 鉴权） |
| windmill | `$WM_DIR/CREDENTIALS.txt` + `.env`（POSTGRES_PASSWORD 等） |
| openmaic | `.env.local`（API Key、访问密码） |

### 4.6 健康检查

`aibox <module> dashboard` 对 endpoint 做轻量探测（curl 健康端点，2s 超时），显示 ✓/✗。依赖端口声明（§3）+ 模块 dashboard_info 的 health。

### 4.7 依赖

- 端口声明（§3）—— endpoint 端口来自 module.yaml ports
- 模块 `dashboard_info()` 接口

---

## 5. 共享基础组件（PG/Redis）

### 5.1 目标

模块依赖相同组件时只起一个实例，各模块用独立数据库（`<module>` 或 `<module>_<用途>` 命名），省资源。

### 5.2 现状

- openmaic compose 起 app + PG + render（各自 PG）
- windmill compose 起 windmill + PG + caddy（各自 PG）
- 重复 PG 实例，浪费资源

### 5.3 设计

**新增 `tools/base/` 模块**：管共享 PG 18 + Redis 7（一个 docker compose）。

```yaml
# tools/base/module.yaml
name: base
ports:
  - 35432/tcp:pg        # 非默认端口，避免撞系统 PG
  - 36379/tcp:redis
deps:
  - docker
  - docker-compose
actions:
  - start
  - stop
  - restart
  - status
```

**各部署型模块 compose 改造**：

- 去掉自己的 PG/Redis service
- 连共享实例（同 docker network + env 指向共享 PG `host:35432`）
- `init` 时在共享 PG 建自己的 DB：`<module>` 或 `<module>_<用途>`

### 5.4 DB 命名约定

- 单 DB：`<module>`（如 `windmill`、`openmaic`）
- 多 DB：`<module>_<用途>`（如 `moduleA_jobs`、`moduleA_cache`）
- 前缀 = 模块名，避免跨模块撞

约定写进 module-spec。

### 5.5 实现要点

- `tools/base/lib.sh`：共享 compose lifecycle（start/stop/status）+ DB 创建工具（`base createdb <module> [用途]`）
- 各模块 `init` 调 `base createdb <module>` 建库，compose env 指向共享
- 版本兼容：module.yaml 可声明 `deps` 含 `pg:16`（base 模块管版本，模块声明兼容版本）
- 网络：共享 compose 建 docker network `aibox-base`，各模块 compose join

### 5.6 分阶段（避免大爆炸）

1. **阶段1**：建 `tools/base/` 共享 PG/Redis 模块 + DB 创建工具
2. **阶段2**：新模块用共享（compose 连共享，不再起自己的 PG）
3. **阶段3**：存量模块迁移（openmaic/windmill compose 重构 + 数据迁移 `pg_dump` 共享 PG）

存量迁移有数据风险，单独迭代。新模块直接用共享。

### 5.7 降级

某模块需要独占 PG 版本（不兼容共享 18）时，可回退独立实例（compose 自己起 PG）。module.yaml 标注 `deps: pg:14@standalone` 或类似，base 不接管。

### 5.8 依赖

- 端口声明（§3）—— 共享 PG/Redis 端口登记 + CI 检测
- module.yaml（§2）—— base 模块声明

---

## 6. 模块开发指南

### 6.1 目标

每模块有开发指南，AI 据此升级模块（项目主页、文档、安装/测试手册、配置情况）。

### 6.2 module.yaml upstream 字段

```yaml
upstream:
  homepage: https://github.com/agegr/pi-web
  docs: https://github.com/agegr/pi-web#readme
  install: https://github.com/agegr/pi-web#installation
  test: https://github.com/agegr/pi-web#development
```

aibox `aibox <module> dev-guide` 输出这些链接（AI 升级时先查 upstream 文档）。

### 6.3 `docs/DEVELOPMENT.md`（每模块）

`tools/<name>/docs/DEVELOPMENT.md`，含：

- **upstream**：主页 + 官方文档（同 module.yaml upstream，可详述）
- **安装手册**：upstream 原生安装 + aibox 模块安装（`aibox install <name>`）
- **测试手册**：如何跑测试（upstream 测试 + aibox 模块测试）
- **本模块配置情况**：端口（§3）、密码/凭据（§4）、落点（部署根/配置）、定制点（aibox 对 upstream 的改动）
- **升级流程**：AI 升级该模块的步骤（查 upstream 新版 → 改 module.yaml version → 跑测试 → `aibox update`）

### 6.4 AI 升级流程

```
1. 读 module.yaml upstream.docs → 查 upstream 新版本 + 变更
2. 读 docs/DEVELOPMENT.md → 了解本模块定制点 + 测试方法
3. 改 module.yaml version + 同步代码
4. 跑测试（DEVELOPMENT.md 测试手册）
5. aibox update <module> 验证
6. commit（CI 端口/规范校验）
```

### 6.5 依赖

- module.yaml（§2）—— upstream 字段
- 独立（纯文档）

---

## 7. 依赖管理（已实现，收录现状）

### 7.1 现状

- registry `deps` 字段 → 迁移到 module.yaml `deps`（格式不变：`命令@平台:版本`）
- `bin/aibox` 的 `check_deps` + `dep_satisfied` + `install_dep` 已实现
- `cmd_install` 调 `check_deps`（install 钩子前）
- 平台过滤：`platform` 非空非匹配跳过；`@平台` 跳过+提示
- 自动安装：轻量装（brew/apt/yum/dnf），需 sudo/GUI（Docker Desktop）提示手动，node 复用 nvm

### 7.2 迁移到 module.yaml

```yaml
deps:
  - "node:22"
  - npm
```

awk 解析为 `AIBOX_MODULE_<name>_deps="node:22 npm"`，check_deps 逻辑不变。

---

## 8. 自启动平台约定（已实现，收录）

### 8.1 约定（AGENTS.md 第 10 条）

常驻服务的自启动按平台走，**别混用**：

- **macOS → launchd**：用户级 `~/Library/LaunchAgents/<label>.plist`，`launchctl bootstrap gui/$(id -u)`，不需 root。`KeepAlive` = 自动重启，`StartCalendarInterval` = 定时。
- **Linux → systemd**：用户级 `~/.config/systemd/user/<name>.{service,timer}`，`systemctl --user` + `loginctl enable-linger` 保活，不需 root。`Restart=always` = 自动重启，`OnCalendar` = 定时。
- 同一服务两平台各写一份单元，`case "$(uname -s)"` 分支生成。系统级（需 root/开机即起）才用 `/etc/systemd/system` + `systemctl`（无 `--user`）。

### 8.2 现状

- pi-web：mac launchd + linux systemd --user（`write_plist`/`write_systemd_unit` OS 分支）
- windmill：mac launchd + linux systemd（`cmd_launchd`/`cmd_systemd`）
- clash：nohup+pid（非 init 系统，跨平台简单常驻）
- openmaic：无常驻（svc 透传 CLI）

---

## 9. 迁移路径（registry.sh → module.yaml）

现有 4 模块从 registry.sh 集中声明迁移到 `tools/<name>/module.yaml`：

1. 每模块建 `tools/<name>/module.yaml`，把 registry.sh 该模块字段移过去（version/platform/deps/ports/files/hooks/actions + 新增 upstream/dashboard）
2. 各模块声明 `ports`（pi-web 30141、clash 7890/9090、windmill 8080、openmaic 3000/5432）
3. 主 CLI `load_registry` 改为扫 `tools/*/module.yaml` + awk 解析（删 registry.sh source 逻辑）
4. 删 `registry.sh`（或保留为兼容 shim，source 时扫 module.yaml）
5. CI 加 module-lint（yq 校验）+ port-conflict（端口冲突）
6. module-spec 更新（module.yaml 规范 + 端口 + dashboard_info 接口 + DB 命名 + 自启动引用）

迁移成本低（4 模块，字段机械搬迁）。迁移后加新模块零改全局。

---

## 10. 优先级与依赖关系

```
§2 module.yaml 规范（基础） ──┬──> §3 端口声明（ports 字段 + CI）
                              ├──> §4 Dashboard（endpoint 来自 ports + dashboard_info）
                              ├──> §5 共享组件（base 模块声明 + 端口）
                              └──> §6 开发指南（upstream 字段）

§7 依赖管理（已实现，迁移到 module.yaml deps）
§8 自启动（已实现）
```

| 顺序 | 需求 | 难度 | 依赖 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | **module.yaml 规范 + 迁移** | 中 | 无 | 基础，所有需求依赖；awk 解析器 + CI |
| 2 | **端口声明 + CI 冲突检测** | 中 | §2 | ports 字段 + port-conflict job + `aibox ports` 命令 |
| 3 | **模块开发指南** | 低 | §2 | 独立，纯文档；可和 2 并行 |
| 4 | **Dashboard TUI** | 中 | §2 + §3 | dashboard_info 接口 + aibox dashboard 命令 |
| 5 | **共享基础组件** | 高 | §2 + §3 | 架构级，分阶段；base 模块 + compose 重构 + 存量迁移 |

建议顺序：**1 → 2 + 3（并行）→ 4 → 5**。需求5（共享组件）最大，单独迭代/分阶段。

---

## 附录 A：module.yaml 完整示例（pi-web）

```yaml
name: pi-web
version: 1.0.0
description: "Deploy @agegr/pi-web as a launchd/systemd service (HTTP Basic auth, auto-restart)"
platform: ""                      # 跨平台：mac launchd / linux systemd --user
dir: tools/pi-web

deps:
  - "node:22"
  - npm

ports:
  - 30141/tcp:http

files:
  - lib.sh
  - install.sh
  - uninstall.sh
  - update.sh
  - svc.sh

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:
  - start
  - stop
  - restart
  - status
  - logs
  - diagnose

upstream:
  homepage: https://github.com/agegr/pi-web
  docs: https://github.com/agegr/pi-web#readme
  install: https://github.com/agegr/pi-web#installation
  test: https://github.com/agegr/pi-web#development

dashboard:
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "用户名 pi / 密码见 aibox pi-web status（plist PI_WEB_PASSWORD，resolve_password 生成）"
```

## 附录 B：awk parse_yaml 解析器要点

`parse_yaml_module <file> <name>`（awk 实现）：

1. 遍历行，按缩进识别层级（0=顶层，2=列表项，2/4=嵌套）
2. 顶层 `key: value` → `AIBOX_MODULE_<name>_<key>="<value>"`
3. `key:` 无 value + 下面 `- item` → 列表，收集成 `AIBOX_MODULE_<name>_<key>="item1 item2 ..."`
4. `key:` 无 value + 下面 `subkey: value` → 嵌套，`AIBOX_MODULE_<name>_<key>_<subkey>="<value>"`
5. dashboard.endpoints（列表）→ `AIBOX_MODULE_<name>_dashboard_endpoints="url1 url2"`
6. 跳过 `#` 注释、空行
7. 输出 `eval`-able 赋值，主 CLI `eval "$(parse_yaml_module "$f" "$name")"`

awk 只处理 §2.2 子集；CI（yq）保证 YAML 合规。

## 附录 C：CI workflows 汇总

`.github/workflows/lint.yml` 增加两个 job：

- `module-lint`：yq 校验 module.yaml（必填字段 + 子集合规 + ports 格式）
- `port-conflict`：yq 收集所有 ports，检测 端口+协议 重复

现有 `bash -n` + `shellcheck` + `bash32-gotchas` 保留。

---

## License

MIT。
