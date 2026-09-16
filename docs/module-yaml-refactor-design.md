# module.yaml 重构与公共组件依赖传播设计

> 状态：设计稿（spec-only，本轮不改任何 `.sh` / `module.yaml` / `docker-compose*.yml` 实际内容）
> 日期：2026-09-16
> 范围：① module.yaml 字段去冗余（actions / files / dashboard）；② 公共组件（PG/Redis）依赖声明 + 连接信息传播规范
> 关联：本设计是对 [`docs/module-system-spec.md`](module-system-spec.md) 的增量修订，落地后 spec 相应章节同步更新

---

## 0. TL;DR

- **files**：标准 5 文件（`lib.sh install.sh uninstall.sh update.sh svc.sh`）隐式默认，module.yaml 只列**额外**文件。awk 解析器取「标准集 ∪ files」做 union。
- **actions**：保留全列，新增《公共动作契约》定义 lifecycle 集语义；CLI 转发前校验声明 ∈ actions（修当前「从不读 actions」的漏洞）。
- **dashboard**：yaml 只留 `endpoints[]` + `hint`（pre-install fallback），运行时一律走 `lib.sh` 的 `dashboard_info()`（已装覆盖 yaml）。
- **公共组件**：`base` 作为 **provider**，单一信息源 = `base/docker-compose.yml` + `base/lib.sh` 的 `base_conn_info <component>`。消费模块在 module.yaml 用全名声明 `services: [base:postgres#<db>]`。
- **传播**：`aibox <module> sync-deps` 读取 `services` → 调 provider 的 `base_conn_info` → 生成 `.env.aibox`（`AIBOX_POSTGRES_*` 等全名变量）+ `docker-compose.override.deps.yml`。模块 compose 只引用变量，绝不硬编码凭据/host。改 base 一处 → 重跑 sync-deps → 多处自动重连。
- **组件名一律全名**：`postgres`、`redis`，不用 `pg` 这类简称（env 变量、component key、compose service/container 命名全程一致）。

---

## 1. 背景：当前的冗余与脆弱点

### 1.1 actions 纯声明、从不被读

`bin/aibox` 的 `cmd_module_action` 把动作直接转发给 `svc.sh`，**从不读 module.yaml 的 `actions` 字段**（grep `_actions` / `module_field … action` 在 CLI 中零命中）。后果：

- 每个模块重复列近似的动作表，但表本身没有约束力；
- `start/stop/restart/status/logs` 在 5 个模块里语义不统一（`status` 各写各的）；
- 写错动作名不会被任何环节挡住。

5 个模块的动作分布（2026-09-16 现状）：

| 模块 | 公共 core | 专有 |
| --- | --- | --- |
| base | start/stop/restart/status | createdb |
| clash | start/stop/restart/status/logs | refresh/set/select/test/doctor |
| pi-web | start/stop/restart/status/logs | diagnose |
| openmaic | status/logs | up/down/restart/upgrade/rollback/backup/restore/db/config/models/install/clean/health/doctor/version/render/powerlog/url（透传 CLI） |
| windmill | status/logs | up/down/restart/shell/credentials/systemd/destroy/backup/upgrade/rollback/check/deploy/restore/drill/snapshots/init/version/doctor |

**结论**：`start/stop/restart/status/logs` 是近乎通用的 lifecycle core；其余真正模块专有。所以「公共层定义」的对象是**这套 lifecycle 契约**，不是把动作清单上提到全局（清单仍须模块自治、可变）。

### 1.2 files 重复列标准集

5 个模块的 `files:` 都含同一份 `lib.sh install.sh uninstall.sh update.sh svc.sh`，外加零星额外项（`openmaic`/`windmill` 各自的 CLI、`base/docker-compose.yml`、`openmaic|windmill/docker-compose.shared.yml`）。标准集是 spec §2.3 既定默认，却被复制粘贴。

### 1.3 dashboard 的 hint 与 runtime 重复

spec §4.4 已规定运行时信息来自 `lib.sh` 的 `dashboard_info()`。module.yaml 的 `dashboard` 段原本定位是「未装时的静态 fallback」，但 `hint` 字符串常常把 `dashboard_info()` 会算出的凭据/端口再抄一遍。两处真值 → 漂移。

### 1.4 公共组件连接信息散落硬编码（最严重）

`tools/base/docker-compose.yml` 是 PG/Redis 实例的真实定义（`aibox:aibox@…:35432`），但 `openmaic/docker-compose.shared.yml` 与 `windmill/docker-compose.shared.yml` **逐字重抄**了连接串：

```yaml
# tools/openmaic/docker-compose.shared.yml
- DATABASE_URL=postgres://aibox:aibox@aibox-base-pg:5432/openmaic
```

改 base 的端口（35432→35000）、用户、密码、镜像版本 → 依赖模块静默坏掉，无任何环节报警。且 **没有任何 module.yaml 字段**声明「我依赖 base 的 postgres，库名叫 X」——spec §5 只写了意图，把传播甩给人工维护 compose override。

---

## 2. 取舍：为何选这些方案

| 决策点 | 选定 | 为何不选另一条 |
| --- | --- | --- |
| **actions** | spec 定义公共 lifecycle 契约，模块仍列全部 | ❌「只列额外动作、标准集隐式注入」：actions 不再自描述，看 yaml 看不全一个模块能做什么；help/runtime/CI 都要再补一套注入逻辑。DRY 应体现在「契约」而非「省字段」。 |
| **files** | 标准集隐式，只列额外 | ❌「显式全列 + lint 强制标准集存在」：仍重复列 5 行，新增标准文件要改所有模块。隐式 union 向后兼容（旧 yaml 列全也能跑）。 |
| **dashboard** | yaml 只留 endpoints+hint（pre-install） | ❌「完全移除 yaml 字段」：未装时主 CLI 无任何 endpoint 提示，UX 退化。保留极简静态 fallback，runtime 由 `dashboard_info()` 覆盖即可消除重复。 |
| **公共组件** | module.yaml 声明 `services` + 模板化生成 override | ❌「共享 env 变量约定 + lint 禁硬编码」：模块仍须手写 override，只是把硬编码从字面量挪到约定变量；增删组件要人工改多处。生成化才真正「一处改多处自动」。 ❌「只写规范不建机制」：靠人工同步，治标不治本。 |
| **组件命名** | 全名 `postgres`/`redis` | ❌ 简称 `pg`：可读性差、与 env 变量/compose service 命名割裂。全名全程一致，env 变量也成 `AIBOX_POSTGRES_*`。 |

---

## 3. module.yaml 新字段表（schema 增量）

### 3.1 字段一览（★=本轮变更/新增）

```yaml
# tools/<name>/module.yaml —— 模块声明 source of truth
name: windmill
version: 1.1.0
description: "..."
platform: ""                      # 空=跨平台
dir: tools/windmill

deps:                             # 运行依赖（命令@平台:版本），不变
  - docker
  - docker-compose
  - python3

ports:                            # 端口/协议:用途，不变
  - 8080/tcp:http

files:                            # ★ 改：只列「额外」文件；标准 5 文件隐式
  - windmill                      #   模块自带 CLI

services:                         # ★ 新增：公共组件依赖（provider:component#dbname，全名）
  - base:postgres#windmill
  - base:redis

hooks:                            # 不变（install/uninstall/update/svc）
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                          # ★ 改：仍列全部；lifecycle 集受契约约束（见 §4）
  - start
  - stop
  - restart
  - status
  - logs
  - ...模块专有动作

upstream:                         # 不变
  homepage: ...
  docs: ...

dashboard:                        # ★ 改：瘦身，只留两子字段
  endpoints:
    - "http://127.0.0.1:${PORT}"  #   静态模板（可用 ${PORT} 占位）
  hint: "凭据见 CREDENTIALS.txt + .env"  #   一行 pre-install fallback
```

### 3.2 `provides`（仅 provider 模块，如 base）

```yaml
# tools/base/module.yaml
provides:                         # ★ 新增：声明对外提供的组件（全名）
  - postgres
  - redis
ports:
  - 35432/tcp:postgres
  - 36379/tcp:redis
```

### 3.3 字段语义

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` `version` `description` `dir` `hooks` | 是 | 不变 |
| `deps` `ports` `platform` | 否 | 不变 |
| `files` | 否 | **只列额外文件**。标准集（`lib.sh install.sh uninstall.sh update.sh svc.sh`）由解析器自动补。列出的项必须存在于仓库目录。 |
| `actions` | 否 | **列全部动作**。其中 lifecycle 子集（见 §4）须满足契约。分布型模块（透传下发 CLI）标 `lifecycle: passthrough` 可豁免 lifecycle。 |
| `services` | 否 | **公共组件依赖**，紧凑串 `provider:component[#dbname]`。`component` 用全名（`postgres`/`redis`）。`postgres` 应给 `#dbname`（建模块独立库）；`redis` 通常省略 `#dbname`。多 DB 用途：`base:postgres#windmill_jobs`。 |
| `provides` | 否 | 仅 provider 模块填。列出对外提供的组件全名。消费模块的 `services` 引用必须命中某 provider 的 `provides`。 |
| `upstream` | 否 | 不变 |
| `dashboard` | 否 | **仅 `endpoints[]` + `hint`**。其他子字段废弃。`endpoints` 可用 `${PORT}` 等占位（解析时按模块 env 展开）。 |

### 3.4 紧凑串格式 `provider:component[#dbname]`

- 三段冒号/井号分隔，**全是标量**，落在 awk 可解析子集内（spec §2.2）。
- `dbname` 可省（`redis` 通常不分库，省略）；`postgres` 应给 `#dbname`（建模块独立库 `<module>`），省略则落到 provider 默认库（多模块混用，不推荐）。提供则按 `<module>` 或 `<module>_<用途>` 命名（spec §5.4 约定保留）。
- 例：`base:postgres#windmill`、`base:redis`、`base:postgres#windmill_jobs`。

---

## 4. 公共动作契约（lifecycle 集）

spec 新增一节《公共动作契约》。定义以下动作的**统一语义**，服务型模块（有运行时实例）必须实现：

| 动作 | 契约语义（必须满足） |
| --- | --- |
| `start` | 启动实例（幂等：已运行则 no-op + 提示）。返回 0=成功。 |
| `stop` | 优雅停止实例（幂等：已停则 no-op）。不删数据。 |
| `restart` | 等价 `stop` + `start`，或原生重启。 |
| `status` | 输出：运行/未运行 + 关键标识（PID/容器名/端口）。退出码 0=运行中。 |
| `logs` | 输出最近日志，支持 `-f` 跟随。 |

### 4.1 服务型 vs 分布型

- **服务型**（base/clash/pi-web/windmill 的运行实例部分）：强制实现 lifecycle 集。CI 校验 `actions` 含这些且 `svc.sh` 实现之。
- **分布型**（openmaic 透传下发 CLI）：module.yaml 顶层加 `lifecycle: passthrough` 字段豁免 lifecycle（见附录 A.3）。豁免后 CI 不强制 lifecycle，但仍校验 `actions` 自洽。

### 4.2 CLI 校验（修漏洞）

`cmd_module_action` 转发前：若请求动作不在模块 `actions` 声明中 → 提示「该模块未声明此动作，仍尝试转发」并继续（不硬拦，避免挡自定义透传动作）。这让 `actions` 从死字段变成被读字段，同时保留透传灵活性。

---

## 5. 公共组件 provider 模型

### 5.1 角色与单一信息源

```
provider = base
   ├─ tools/base/docker-compose.yml   ← 实例真实定义（镜像/端口映射/默认凭据/卷/网络）
   └─ tools/base/lib.sh               ← base_conn_info <component>  ← bash 可调的信息出口
                                          输出: host=… port=… user=… password=… db_default=…
```

**单一信息源原则**：消费模块**绝不**直接读 base 的 compose，也**绝不**硬编码 `aibox:aibox@`。唯一合法路径 = 经 `base_conn_info`（运行时）或经 sync-deps 生成产物（compose/env 文件）拿到连接参数。

`base_conn_info` 与 `docker-compose.yml` 的一致性由 CI lint 守护（见 §6.3）：端口映射、默认 env（`AIBOX_BASE_POSTGRES_USER` 等）必须一致，防漂移。

### 5.2 `base_conn_info` 接口

```bash
# tools/base/lib.sh
# 用法: base_conn_info <component>   component ∈ {postgres, redis}（全名）
# 输出 key=value 行，供 sync-deps 解析；也被 aibox base status 复用
base_conn_info() {
  local comp="$1"
  case "$comp" in
    postgres)
      echo "host=aibox-base-postgres"
      echo "port=${AIBOX_BASE_POSTGRES_PORT:-35432}"
      echo "user=${AIBOX_BASE_POSTGRES_USER:-aibox}"
      echo "password=${AIBOX_BASE_POSTGRES_PASSWORD:-aibox}"
      echo "db_default=aibox"
      ;;
    redis)
      echo "host=aibox-base-redis"
      echo "port=${AIBOX_BASE_REDIS_PORT:-36379}"
      ;;
    *) return 1 ;;
  esac
}
```

> 注：env 变量也用全名（`AIBOX_BASE_POSTGRES_*`，非 `AIBOX_BASE_PG_*`）。容器名 `aibox-base-postgres`（非 `aibox-base-pg`），compose service 名同步用 `postgres`。

### 5.3 全名一致性约定（全程）

| 位置 | 旧（简称） | 新（全名） |
| --- | --- | --- |
| module.yaml `services`/`provides` component | `pg` | `postgres` |
| env 变量 | `AIBOX_PG_*` | `AIBOX_POSTGRES_*` |
| compose service 名 | `pg:` | `postgres:` |
| 容器名 | `aibox-base-pg` | `aibox-base-postgres` |
| base_conn_info 参数 | `base_conn_info pg` | `base_conn_info postgres` |
| port 用途标签 | `35432/tcp:pg` | `35432/tcp:postgres` |

`redis` 本即全名，不变。

---

## 6. 连接信息传播：`sync-deps` 生成机制

### 6.1 命令

```text
aibox <module> sync-deps      # install / update 时自动调用；也可手动重跑
```

### 6.2 流程

1. 读模块 `services:` 字段（awk，已是标量列表）。
2. 对每条 `provider:component#dbname`：
   - 解析三段；
   - `source` provider 的 `lib.sh`，调 `<provider>_conn_info <component>` → 拿 `host/port/user/password`；
   - 映射成全名 env 变量：`AIBOX_<COMPONENT_UPPER>_HOST/PORT/USER/PASSWORD`，以及 `AIBOX_<COMPONENT_UPPER>_DB=<dbname>`。
3. 生成两份产物（写入模块部署目录 `$APP_DIR/`）：
   - **`.env.aibox`**：上述 env 变量。模块的 `.env` / compose 经 `env_file` 或 `${AIBOX_POSTGRES_HOST}` 引用。
   - **`docker-compose.override.deps.yml`**：把模块 app service `join` provider 网络（`aibox-base: external: true`），并在 `environment:` 写死指向 `${AIBOX_POSTGRES_*}`（覆盖模块自有 `.env` 里的本地连接串，原理同当前手写 shared.yml）。
4. compose 调用自动追加 `-f docker-compose.override.deps.yml`（aibox 调度的 up/down/restart 等均生效）。

### 6.3 降级（回独立实例）

某模块需独占版本/配置不兼容共享 → module.yaml **不**在 `services` 声明该组件（sync-deps 即不生成 override，模块自带 compose 起本地实例）；如需锁版本，用既有 `deps` 机制声明 `postgres:14`（全名）。spec §5.7 降级约定保留，不引入额外 `@standalone` 语法。

### 6.4 一处改 → 多处自动

改 base 端口/凭据/镜像：

1. 改 `tools/base/docker-compose.yml`（+ `base/lib.sh` 的默认值）；
2. `aibox base restart`；
3. 各消费模块 `aibox <module> sync-deps`（或 update 时自动）→ 重新生成 `.env.aibox` + override；
4. `aibox <module> restart` → app 用新连接串重连。

不再有人工抄写，不再静默坏。

---

## 7. CI lint 规则

### 7.1 module-lint（扩充）

- `files` 列出的每项必须存在于 `tools/<name>/`。
- 服务型模块（非 passthrough）：`actions` 必须含 lifecycle 集（start/stop/restart/status/logs），且 `svc.sh` 中实现（grep 动作名 case 分支）。
- `dashboard` 只允许 `endpoints` + `hint` 两子字段（多余报错）。
- `services`/`provides` 的 component 名必须是全名（禁止 `pg`/`rds` 等简称——维护一份白名单 `{postgres, redis, ...}`）。

### 7.2 port-conflict（已有，保留）

含 base 的 35432/36379。用途标签同步改全名（`35432/tcp:postgres`）。

### 7.3 deps-lint（新增）

- 消费模块 `services` 里每条 `provider:component[#db]`：
  - `provider` 必须是已注册模块；
  - 该 provider 的 `provides` 必须含该 `component`；
  - `dbname` 若给，符合 `<module>` / `<module>_<用途>` 命名。
- **禁止硬编码凭据/host**：`tools/*/docker-compose*.yml`（`tools/base/` 除外）不得出现正则命中 `aibox:aibox@`、`aibox-base-postgres:5432`、`aibox-base-redis:6379`、`postgres://aibox:` 等字面量。模块必须经 `${AIBOX_POSTGRES_*}` 引用。
- **provider 一致性**：`base/lib.sh` 的 `base_conn_info` 输出的 port/user/password 默认值，必须与 `base/docker-compose.yml` 的端口映射 + 默认 env 一致（防 provider 内部两处漂移）。

### 7.4 awk 子集合规（已有，保留）

`services`/`provides` 是标量列表，落在 §2.2 子集内，无需放宽。

---

## 8. awk 解析器改动

`parse_yaml_module_stdin`（`bin/aibox`）：

1. `files` 解析后，与标准 5 文件做 union 去重（顺序：标准集在前，额外项在后），赋给 `AIBOX_MODULE_<name>_files`。向后兼容旧 yaml（列全 → union 后仍是全集，不重复下载）。
2. `services` / `provides` 作为新列表字段照常解析（`AIBOX_MODULE_<name>_services` / `_provides`，空格分隔标量）。
3. `dashboard.endpoints`（已有列表）保留；`dashboard.hint`（已有标量）保留；废弃其他子字段（CI 报错即可，解析器无需特殊处理）。
4. `module_field` 读取 `services`/`provides` 时仍返回空格分隔串，由 sync-deps 侧再 split。

零结构破坏，最小改动。

---

## 9. 迁移路径（分阶段，实现期执行，本轮仅规划）

### 阶段 A：module.yaml 字段去冗余（低风险）

1. awk 解析器加 files union + 解析 services/provides。
2. 各 module.yaml：删 `files` 标准行、`dashboard` 瘦身（删多余子字段）、`ports` 用途标签改全名。
3. CI module-lint 加新校验。
4. 旧手写 `docker-compose.shared.yml` 暂留（下一阶段才替）。

### 阶段 B：公共组件 provider + sync-deps

1. base：`lib.sh` 加 `base_conn_info`；`docker-compose.yml` service/container/env 改全名；`module.yaml` 加 `provides`。
2. CLI 加 `aibox <module> sync-deps`（+ install/update 钩入）。
3. CI deps-lint 上线（先 warn 后 fail）。
4. 一个新模块先用共享（无存量包袱）。

### 阶段 C：存量模块迁移（有数据风险，单独迭代）

1. openmaic/windmill：删手写 `docker-compose.shared.yml`，module.yaml 加 `services`，改 compose 引用 `${AIBOX_POSTGRES_*}`。
2. 数据迁移：`pg_dump` 旧独立 PG → 导入共享 PG 的 `<module>` 库。
3. 全程 lint fail → 兜底。

---

## 10. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| sync-deps 生成产物与手写 override 冲突 | 生成文件名固定（`.env.aibox` / `docker-compose.override.deps.yml`），CI lint 禁止模块仓库内出现同名手写文件；迁移期手写 shared.yml 标注 deprecated。 |
| base_conn_info 与 compose 漂移 | CI deps-lint 校验一致（§7.3）。 |
| 全名重命名波及存量 compose | 阶段 B 一次性改 base；消费模块在阶段 C 迁移时同步改。lint 在阶段 B 上线后即拦新简称。 |
| actions 校验硬拦自定义透传 | 校验只「提示不拦」（§4.2），保留透传灵活。 |
| awk 子集不足以表达 services 语义 | 紧凑串 `provider:component#db` 是标量，sync-deps 侧 split，不碰子集。 |
| 改 base 后忘记重跑 sync-deps | install/update 自动钩入 sync-deps；`aibox <module> status` 检测 override 与 base 当前值不一致时提示重跑。 |

---

## 附录 A：完整 module.yaml 示例

### A.1 provider 模块（base）

```yaml
# tools/base/module.yaml
name: base
version: 1.0.0
description: "共享基础组件（PostgreSQL 18 + Redis 7），各模块独立数据库"
platform: ""
dir: tools/base

deps:
  - docker
  - docker-compose

provides:
  - postgres
  - redis

ports:
  - 35432/tcp:postgres
  - 36379/tcp:redis

files:
  - docker-compose.yml          # 额外（标准 5 文件隐式）

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
  - createdb

upstream:
  homepage: https://www.postgresql.org/
  docs: https://www.postgresql.org/docs/

dashboard:
  endpoints:
    - "pg: postgres://127.0.0.1:35432  redis: redis://127.0.0.1:36379"
  hint: "aibox base createdb <module> 建库；凭据 aibox/aibox（见 base_conn_info）"
```

### A.2 消费模块（windmill）

```yaml
# tools/windmill/module.yaml
name: windmill
version: 1.1.0
description: "Windmill self-host ops CLI (init/upgrade/backup/drill/doctor)"
platform: ""
dir: tools/windmill

deps:
  - docker
  - docker-compose
  - python3

ports:
  - 8080/tcp:http

files:
  - windmill                   # 额外 CLI

services:
  - base:postgres#windmill
  - base:redis

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
  - shell
  - credentials
  - systemd
  - destroy
  - backup
  - upgrade
  - rollback
  - check
  - deploy
  - restore
  - drill
  - snapshots
  - init

upstream:
  homepage: https://github.com/windmill-labs/windmill
  docs: https://www.windmill.dev/docs/

dashboard:
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "凭据见 CREDENTIALS.txt + .env；DB 经 ${AIBOX_POSTGRES_HOST} 连共享 PG"
```

### A.3 分布型模块（openmaic，豁免 lifecycle）

```yaml
# tools/openmaic/module.yaml
name: openmaic
version: 1.0.0
description: "OpenMAIC ops CLI (install/upgrade/backup/doctor)"
platform: ""
dir: tools/openmaic

deps:
  - docker
  - docker-compose
  - git

ports:
  - 3000/tcp:app

files:
  - openmaic                   # 额外 CLI

services:
  - base:postgres#openmaic

lifecycle: passthrough         # 豁免公共 lifecycle 契约（透传下发 CLI）

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:
  - status
  - health
  - doctor
  - version
  - up
  - down
  - restart
  - logs
  - render
  - upgrade
  - rollback
  - backup
  - restore
  - db
  - config
  - models
  - install
  - clean
  - powerlog
  - url

upstream:
  homepage: https://github.com/THU-MAIC/OpenMAIC
  docs: https://github.com/THU-MAIC/OpenMAIC#readme

dashboard:
  endpoints:
    - "http://127.0.0.1:${PORT}"
  hint: "凭据见 .env.local；DATABASE_URL 经 sync-deps 指向共享 PG"
```

---

## 附录 B：sync-deps 生成产物示例（windmill）

### `$APP_DIR/.env.aibox`（生成）

```dotenv
# 由 aibox windmill sync-deps 生成 —— 勿手改；改 base 后重跑
AIBOX_POSTGRES_HOST=aibox-base-postgres
AIBOX_POSTGRES_PORT=35432
AIBOX_POSTGRES_USER=aibox
AIBOX_POSTGRES_PASSWORD=aibox
AIBOX_POSTGRES_DB=windmill
AIBOX_REDIS_HOST=aibox-base-redis
AIBOX_REDIS_PORT=36379
```

### `$APP_DIR/docker-compose.override.deps.yml`（生成）

```yaml
# 由 aibox windmill sync-deps 生成 —— 勿手改
services:
  db:
    deploy:
      replicas: 0
  windmill_server:
    depends_on: []
    networks: [default, aibox-base]
    environment:
      - DATABASE_URL=postgres://${AIBOX_POSTGRES_USER}:${AIBOX_POSTGRES_PASSWORD}@${AIBOX_POSTGRES_HOST}:${AIBOX_POSTGRES_PORT}/${AIBOX_POSTGRES_DB}
  windmill_worker: { depends_on: [], networks: [default, aibox-base] }
  windmill_worker_native: { depends_on: [], networks: [default, aibox-base] }
  windmill_indexer: { depends_on: [], networks: [default, aibox-base] }
networks:
  aibox-base:
    external: true
```

模块仓库内的主 compose 只用 `${DATABASE_URL}` / `${AIBOX_POSTGRES_*}`，不再出现 `aibox:aibox@`。

---

## License

MIT。
