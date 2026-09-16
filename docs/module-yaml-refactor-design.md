# module.yaml 重构与公共组件依赖传播设计

> 状态：设计稿（spec-only，本轮不改任何 `.sh` / `module.yaml` / `docker-compose*.yml` 实际内容）
> 日期：2026-09-16
> 范围：① module.yaml 字段去冗余（actions / files / dashboard）；② 公共组件（PG/Redis）依赖声明 + 连接信息传播规范
> 关联：本设计是对 [`docs/module-system-spec.md`](module-system-spec.md) 的增量修订，落地后 spec 相应章节同步更新
> 原则：**尽量简单、有扩展性**。公共组件传播不引入 codegen —— 一份共享 env 文件 + compose `--env-file` live 读 + 模块引用变量。

---

## 0. TL;DR

- **files**：标准 5 文件（`lib.sh install.sh uninstall.sh update.sh svc.sh`）隐式默认，module.yaml 只列**额外**文件。awk 解析器取「标准集 ∪ files」做 union。
- **actions**：保留全列，新增《公共动作契约》定义 lifecycle 集语义；服务型 = 派生自 `actions` 含 `start`（无额外字段）；CLI 在 `aibox <module>`（无动作）时把声明的 actions 列出来当 help，不做每次调用校验。
- **dashboard**：yaml 只留 `endpoints[]` + `hint`（pre-install fallback），运行时一律走 `lib.sh` 的 `dashboard_info()`（已装覆盖 yaml）。
- **公共组件**：`base` 作为 **provider**，`base start` 写一份 `$AIBOX_HOME/base.env`（`AIBOX_POSTGRES_*` / `AIBOX_REDIS_*`，单一源）。消费模块 module.yaml 声明 `services: [base:postgres#windmill]`。
- **传播（无生成器）**：aibox 调度 compose 时，为声明了 `services` 的模块自动追加 `--env-file $AIBOX_HOME/base.env`；模块**手写一份稳定**的 `docker-compose.shared.yml`（网络 join + `replicas:0` + `environment` 里用 `${AIBOX_POSTGRES_*}` 构造 `DATABASE_URL`，**零硬编码凭据**）；模块自己 `.env` 写 `AIBOX_POSTGRES_DB=<module>`。改 base 凭据/端口 → `base restart` 重写 base.env → 下一次 `aibox <module> restart`（compose up）插值取新值。**一处改，零模块文件改动。**
- **组件名一律全名**：`postgres`、`redis`，不用 `pg` 这类简称（env 变量、component key、compose service/container 命名全程一致）。

---

## 1. 背景：当前的冗余与脆弱点

### 1.1 actions 纯声明、从不被读

`bin/aibox` 的 `cmd_module_action` 把动作直接转发给 `svc.sh`，**从不读 module.yaml 的 `actions` 字段**（grep `_actions` / `module_field … action` 在 CLI 中零命中）。后果：

- 每个模块重复列近似的动作表，但表本身没有约束力；
- `start/stop/restart/status/logs` 在 5 个模块里语义不统一（`status` 各写各的）；
- 写错动作名不会被任何环节挡住；
- `aibox <module>`（无动作）只打印「用法」，不告诉用户该模块支持哪些动作。

5 个模块的动作分布（2026-09-16 现状）：

| 模块 | 公共 core | 专有 |
| --- | --- | --- |
| base | start/stop/restart/status | createdb |
| clash | start/stop/restart/status/logs | refresh/set/select/test/doctor |
| pi-web | start/stop/restart/status/logs | diagnose |
| openmaic | status/logs | up/down/restart/upgrade/rollback/backup/restore/db/config/models/install/clean/health/doctor/version/render/powerlog/url（透传 CLI，**不含 start**） |
| windmill | status/logs | up/down/restart/shell/credentials/systemd/destroy/backup/upgrade/rollback/check/deploy/restore/drill/snapshots/init/version/doctor |

**结论**：`start/stop/restart/status/logs` 是近乎通用的 lifecycle core；其余真正模块专有。所以「公共层定义」的对象是**这套 lifecycle 契约**，不是把动作清单上提到全局（清单仍须模块自治、可变）。

### 1.2 files 重复列标准集

5 个模块的 `files:` 都含同一份 `lib.sh install.sh uninstall.sh update.sh svc.sh`，外加零星额外项（`openmaic`/`windmill` 各自的 CLI、`base/docker-compose.yml`、`openmaic|windmill/docker-compose.shared.yml`）。标准集是 spec §2.3 既定默认，却被复制粘贴。

### 1.3 dashboard 的 hint 与 runtime 重复

spec §4.4 已规定运行时信息来自 `lib.sh` 的 `dashboard_info()`。module.yaml 的 `dashboard` 段原本定位是「未装时的静态 fallback」，但 `hint` 字符串常常把 `dashboard_info()` 会算出的凭据/端口再抄一遍。两处真值 → 漂移。

### 1.4 公共组件连接信息散落硬编码（最严重）

`tools/base/docker-compose.yml` 是 PG/Redis 实例的真实定义（`aibox:aibox@…:35432`），但 `openmaic/docker-compose.shared.yml` 与 `windmill/docker-compose.shared.yml` **逐字重抄**了连接串：

```yaml
# tools/openmaic/docker-compose.shared.yml（现状，硬编码）
- DATABASE_URL=postgres://aibox:aibox@aibox-base-pg:5432/openmaic
```

改 base 的端口（35432→35000）、用户、密码、镜像版本 → 依赖模块静默坏掉，无任何环节报警。且 **没有任何 module.yaml 字段**声明「我依赖 base 的 postgres，库名叫 X」——spec §5 只写了意图，把传播甩给人工维护 compose override。

> **本设计的解法不是再造一个生成器去替人工写 override**，而是：保留模块已有的手写 `docker-compose.shared.yml`（稳定结构：网络 join + `replicas:0`），**只把里面的硬编码凭据换成 `${AIBOX_POSTGRES_*}` 变量**，变量值由 base 写一份共享 env 文件、aibox 调 compose 时 live 注入。零生成、零额外文件。

---

## 2. 取舍：为何选这些方案

| 决策点 | 选定 | 为何不选另一条 |
| --- | --- | --- |
| **actions** | spec 定义公共 lifecycle 契约，模块仍列全部；服务型派生自含 `start` | ❌「只列额外动作、标准集隐式注入」：actions 不再自描述，看 yaml 看不全；help/CI 都要补注入逻辑。❌ 加 `lifecycle: passthrough` 字段：和「actions 里有没有 start」重复，多一处漂移。 |
| **actions 读取** | CLI 只在无动作时列 actions 当 help；不做每次调用校验 | ❌「转发前校验声明 ∈ actions、提示不拦」：不挡就没约束力，还每次调用打噪音——最差两头。 |
| **files** | 标准集隐式，只列额外 | ❌「显式全列 + lint 强制标准集存在」：仍重复列 5 行，新增标准文件要改所有模块。隐式 union 向后兼容（旧 yaml 列全也能跑）。 |
| **dashboard** | yaml 只留 endpoints+hint（pre-install） | ❌「完全移除 yaml 字段」：未装时主 CLI 无 endpoint 提示，UX 退化。 |
| **公共组件传播** | base 写一份 `base.env` + compose `--env-file` live 注入 + 模块手写稳定 override 用变量 | ❌「sync-deps 生成器模板化 override + `.env.aibox` + `base_conn_info`」：生成器要理解每个模块的 service 拓扑（哪个 join 网络、哪个 `replicas:0`）——这本就模块专有、手写最清楚；生成器等于重造模板引擎，产物要 .gitignore、要管重新生成触发、和手写文件冲突。模块已有手写 shared.yml，只需把凭据换成变量。 ❌「只写规范不建机制」：靠人工同步，治标不治本。 |
| **组件命名** | 全名 `postgres`/`redis` | ❌ 简称 `pg`：可读性差、与 env 变量/compose service 命名割裂。 |

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
  - base:postgres#windmill        #   声明 → CI 校验 + auto-createdb + compose 自动 --env-file base.env
  - base:redis

hooks:                            # 不变（install/uninstall/update/svc）
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                          # ★ 改：仍列全部；含 start → 服务型，须满足 lifecycle 契约（见 §4）
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
| `actions` | 否 | **列全部动作**。含 `start` 的模块即服务型，须满足 lifecycle 契约（§4）；不含 `start`（如透传下发 CLI）即分布型，不强制。CLI 在 `aibox <module>`（无动作）时把 actions 列出来当 help。 |
| `services` | 否 | **公共组件依赖**，紧凑串 `provider:component[#dbname]`。`component` 用全名（`postgres`/`redis`）。`postgres` 应给 `#dbname`（建模块独立库）；`redis` 通常省略 `#dbname`。多 DB 用途：`base:postgres#windmill_jobs`。声明驱动：CI 校验 provider/component、`install` 自动 `base createdb`、compose 调度自动 `--env-file base.env`。 |
| `provides` | 否 | 仅 provider 模块填。列出对外提供的组件全名。消费模块的 `services` 引用必须命中某 provider 的 `provides`。 |
| `upstream` | 否 | 不变 |
| `dashboard` | 否 | **仅 `endpoints[]` + `hint`**。其他子字段废弃。`endpoints` 可用 `${PORT}` 等占位（解析时按模块 env 展开）。 |

### 3.4 紧凑串格式 `provider:component[#dbname]`

- 三段冒号/井号分隔，**全是标量**，落在 awk 可解析子集内（spec §2.2）。
- `dbname` 可省（`redis` 通常不分库，省略）；`postgres` 应给 `#dbname`（建模块独立库 `<module>`），省略则落到 provider 默认库（多模块混用，不推荐）。提供则按 `<module>` 或 `<module>_<用途>` 命名（spec §5.4 约定保留）。
- 例：`base:postgres#windmill`、`base:redis`、`base:postgres#windmill_jobs`。

---

## 4. 公共动作契约（lifecycle 集）

spec 新增一节《公共动作契约》。定义以下动作的**统一语义**，服务型模块（`actions` 含 `start`）必须实现：

| 动作 | 契约语义（必须满足） |
| --- | --- |
| `start` | 启动实例（幂等：已运行则 no-op + 提示）。返回 0=成功。 |
| `stop` | 优雅停止实例（幂等：已停则 no-op）。不删数据。 |
| `restart` | 等价 `stop` + `start`，或原生重启。 |
| `status` | 输出：运行/未运行 + 关键标识（PID/容器名/端口）。退出码 0=运行中。 |
| `logs` | 输出最近日志，支持 `-f` 跟随。 |

### 4.1 服务型 vs 分布型（派生，无额外字段）

- **服务型** = `actions` 含 `start`（base/clash/pi-web/windmill）：强制实现 lifecycle 集。CI 校验 `actions` 含全 lifecycle 集 且 `svc.sh` 实现之。
- **分布型** = `actions` 不含 `start`（openmaic 透传下发 CLI）：不强制 lifecycle，CI 只校验 `actions` 自洽（声明的动作在 `svc.sh` 有对应 case）。
- **无需 `lifecycle: passthrough` 字段** —— 是否含 `start` 已自描述，多一个字段是多一处漂移。

### 4.2 CLI 消费 actions（只读一处，不做每次校验）

`cmd_module_action`：

- **无动作**（`aibox <module>`）→ 打印「用法: aibox $name <action>」+ 把声明的 `actions` 列出来（让用户知道能干啥）。这是 `actions` 字段唯一真正有用的消费点。
- **有动作** → 直接转发 `svc.sh`，**不校验**声明 ∈ actions（透传模块动作多变，硬拦/提示都碍事）。

这让 `actions` 从死字段变活，且零运行期校验逻辑。

---

## 5. 公共组件 provider 模型（base + base.env）

### 5.1 角色与单一信息源

```
provider = base
   ├─ tools/base/docker-compose.yml   ← 实例真实定义（镜像/端口映射/默认凭据/卷/网络）
   └─ tools/base/lib.sh               ← 持连接常量；base start 时写 $AIBOX_HOME/base.env
                                          base.env = 各模块共享的连接信息出口（单一源）
```

**单一信息源原则**：消费模块**绝不**直接读 base 的 compose，也**绝不**硬编码 `aibox:aibox@`。唯一合法路径 = `$AIBOX_HOME/base.env`（由 base 写、aibox compose 调度时 `--env-file` 注入）。

`base.env` 的内容必须与 `docker-compose.yml` 的端口映射 + 默认 env 一致 —— base/lib.sh 持常量、同时喂给 compose 的 `${...:-默认}` 与 base.env，CI deps-lint 守护一致（见 §7.3）。

### 5.2 `base.env` 内容规范

`base start`（及 `base restart`）写 `$AIBOX_HOME/base.env`，内容形如：

```dotenv
# 由 aibox base start 生成 —— 勿手改；改 base 后 base restart 重写
AIBOX_POSTGRES_HOST=aibox-base-postgres
AIBOX_POSTGRES_PORT=35432
AIBOX_POSTGRES_USER=aibox
AIBOX_POSTGRES_PASSWORD=aibox
AIBOX_REDIS_HOST=aibox-base-redis
AIBOX_REDIS_PORT=36379
```

- 只放**实例级共享**信息（host/port/user/password）—— 不放库名（库名 `<module>` 是各模块自己的，由模块 `.env` 的 `AIBOX_POSTGRES_DB` 给）。
- env 变量、容器名、service 名、port 用途标签全程**全名**（见 §5.3）。
- base/lib.sh 用同样的常量构造 compose 的 `${AIBOX_BASE_POSTGRES_USER:-aibox}` 默认值，保证 base.env 与 compose 一致。

> 不引入 `base_conn_info()` 函数 —— 之前为生成器设计的接口，现在没有生成器，base.env 文件本身就是出口，`aibox base status` 直接 `cat` 或显示即可。

### 5.3 全名一致性约定（全程）

| 位置 | 旧（简称） | 新（全名） |
| --- | --- | --- |
| module.yaml `services`/`provides` component | `pg` | `postgres` |
| env 变量 | `AIBOX_PG_*` | `AIBOX_POSTGRES_*` |
| compose service 名 | `pg:` | `postgres:` |
| 容器名 | `aibox-base-pg` | `aibox-base-postgres` |
| port 用途标签 | `35432/tcp:pg` | `35432/tcp:postgres` |

`redis` 本即全名，不变。`aibox-base-postgres`（docker service 名 / 容器名）是 base 对外的**稳定契约**，模块 override 里用它做 host —— 它不是凭据，改名是契约破坏（rare，lint 守）。

---

## 6. 连接信息传播：base.env + compose `--env-file`（无生成器）

### 6.1 机制

1. **base 写一份** `$AIBOX_HOME/base.env`（§5.2），`base start`/`restart` 重写。
2. **aibox 调度 compose 时**，对声明了 `services` 的模块，自动追加 `--env-file "$AIBOX_HOME/base.env"`（与模块项目 `.env` 并列，compose v2 多 `--env-file` 合并）。于是 `${AIBOX_POSTGRES_*}` 在 compose 文件里可插值取到。
3. **模块手写一份稳定的** `docker-compose.shared.yml`（仓库内，随模块走）：
   - `db: replicas: 0`（不起本地 PG）
   - app service `networks: [default, aibox-base]`（join 共享网络，经 service 名 `aibox-base-postgres` 连）
   - `environment: DATABASE_URL=postgres://${AIBOX_POSTGRES_USER}:${AIBOX_POSTGRES_PASSWORD}@aibox-base-postgres:${AIBOX_POSTGRES_PORT}/${AIBOX_POSTGRES_DB}` —— **零硬编码凭据**，host 用稳定 service 名，其余变量插值。
4. **模块自己 `.env`** 写 `AIBOX_POSTGRES_DB=windmill`（库名是模块的）+ 模块自有变量。
5. **install**：`aibox <module> install` 见 `services` → 确保 `base` 已起（否则提示先 `aibox base start`）+ `base createdb <module>` 建库。**无 sync-deps 命令** —— 不需要。

### 6.2 一处改 → 多处自动（核心）

改 base 凭据/端口/镜像：

1. 改 `tools/base/docker-compose.yml` + `base/lib.sh` 常量；
2. `aibox base restart` → 重写 `base.env`；
3. 各消费模块 `aibox <module> restart`（compose up）→ compose 读 `--env-file base.env` 重新插值 → app 用新连接串重连。

**不再有人工抄写，不再生成文件，不再静默坏。** 模块侧唯一要维护的是那份稳定 shared.yml（网络 join + 结构），凭据/端口永远从 base.env live 读。

### 6.3 降级（回独立实例）

某模块需独占版本/配置不兼容共享 → module.yaml **不**在 `services` 声明该组件（aibox 即不加 `--env-file`、模块自带 compose 起本地实例）；如需锁版本，用既有 `deps` 机制声明 `postgres:14`（全名）。spec §5.7 降级约定保留，不引入额外 `@standalone` 语法。

---

## 7. CI lint 规则

### 7.1 module-lint（扩充）

- `files` 列出的每项必须存在于 `tools/<name>/`。
- **服务型判定派生**：`actions` 含 `start` 的模块，须含全 lifecycle 集（start/stop/restart/status/logs）且 `svc.sh` 实现（grep 动作名 case 分支）。不含 `start` 的模块不强制。
- `dashboard` 只允许 `endpoints` + `hint` 两子字段（多余报错）。
- `services`/`provides` 的 component 名必须是全名（白名单 `{postgres, redis, ...}`）。

### 7.2 port-conflict（已有，保留）

含 base 的 35432/36379。用途标签同步全名（`35432/tcp:postgres`）。

### 7.3 deps-lint（新增）

- 消费模块 `services` 里每条 `provider:component[#db]`：
  - `provider` 必须是已注册模块；
  - 该 provider 的 `provides` 必须含该 `component`；
  - `dbname` 若给，符合 `<module>` / `<module>_<用途>` 命名。
- **禁止硬编码凭据/host**：`tools/*/docker-compose*.yml`（`tools/base/` 除外）不得出现正则命中 `aibox:aibox@`、`postgres://aibox:`、`:5432/aibox` 等字面量。模块必须经 `${AIBOX_POSTGRES_*}` 引用。（service 名 `aibox-base-postgres` 作为稳定 host 允许出现，不算凭据。）
- **base.env 一致性**：`base/lib.sh` 写 `base.env` 用的常量（host/port/user/password），必须与 `base/docker-compose.yml` 的端口映射 + 默认 env（`${AIBOX_BASE_POSTGRES_*:-...}`）一致，防 provider 内部两处漂移。

### 7.4 awk 子集合规（已有，保留）

`services`/`provides` 是标量列表，落在 §2.2 子集内，无需放宽。

---

## 8. awk 解析器改动

`parse_yaml_module_stdin`（`bin/aibox`）：

1. `files` 解析后，与标准 5 文件做 union 去重（顺序：标准集在前，额外项在后），赋给 `AIBOX_MODULE_<name>_files`。向后兼容旧 yaml（列全 → union 后仍是全集，不重复下载）。
2. `services` / `provides` 作为新列表字段照常解析（`AIBOX_MODULE_<name>_services` / `_provides`，空格分隔标量），供 CI 校验、`install` 判定 createdb、compose wrapper 判定是否加 `--env-file`。
3. `dashboard.endpoints`（已有列表）保留；`dashboard.hint`（已有标量）保留；废弃其他子字段（CI 报错即可）。
4. `module_field` 读取 `services`/`provides` 时仍返回空格分隔串，由调用方再 split。

零结构破坏，最小改动。

---

## 9. 迁移路径（分阶段，实现期执行，本轮仅规划）

### 阶段 A：module.yaml 字段去冗余（低风险）

1. awk 解析器加 files union + 解析 services/provides。
2. 各 module.yaml：删 `files` 标准行、`dashboard` 瘦身、`ports` 用途标签改全名。
3. CI module-lint 加新校验（含服务型派生判定）。
4. 旧手写 `docker-compose.shared.yml` 暂留（下一阶段才重构成用变量）。

### 阶段 B：公共组件 base.env + compose 注入

1. base：`lib.sh` 持连接常量 + `base start`/`restart` 写 `$AIBOX_HOME/base.env`；`docker-compose.yml` service/container/env 改全名；`module.yaml` 加 `provides`。
2. aibox compose wrapper：声明 `services` 的模块自动追加 `--env-file "$AIBOX_HOME/base.env"`（检测 compose v2.24+ 多 `--env-file` 支持，过旧则报错提示升级）。
3. `aibox <module> install`：见 `services` → 确保 base 起 + `base createdb <module>`。
4. CI deps-lint 上线（先 warn 后 fail）。
5. 一个新模块先用共享（无存量包袱）。

### 阶段 C：存量模块迁移（有数据风险，单独迭代）

1. openmaic/windmill：把现有手写 `docker-compose.shared.yml` 的**硬编码凭据改成 `${AIBOX_POSTGRES_*}` 变量**（结构不动），`.env` 加 `AIBOX_POSTGRES_DB=<module>`，module.yaml 加 `services`。
2. 数据迁移：`pg_dump` 旧独立 PG → 导入共享 PG 的 `<module>` 库。
3. 全程 lint fail → 兜底。

---

## 10. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| compose 不支持多 `--env-file` | 要求 compose v2.24+（Docker Desktop 自带 ≥2.29）；aibox wrapper 检测版本，过旧报错提示升级，不静默降级。 |
| `base.env` 缺失/过期 → 模块插值得到空值，连不上 | aibox compose wrapper 在加 `--env-file` 前检查 `$AIBOX_HOME/base.env` 存在；不存在则提示「先 `aibox base start`」并中止。`aibox <module> status` 检测 base.env 与 base 当前运行态不一致时提示重跑 `base restart`。 |
| 模块忘在 `.env` 写 `AIBOX_POSTGRES_DB` | CI deps-lint：声明 `base:postgres#<db>` 的模块，其 `.env`（或 compose env）须含 `AIBOX_POSTGRES_DB` 且值 = `<db>`。 |
| base.env 与 compose 默认值漂移 | CI deps-lint 校验一致（§7.3）。 |
| 全名重命名波及存量 compose | 阶段 B 一次性改 base；消费模块在阶段 C 迁移时同步改。lint 在阶段 B 上线后即拦新简称。 |
| service 名 `aibox-base-postgres` 被当凭据误拦 | deps-lint 只拦凭据字面量（`aibox:aibox@` / `postgres://aibox:`），service 名作 host 允许（§7.3）。 |

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
    - "postgres: postgres://127.0.0.1:35432  redis: redis://127.0.0.1:36379"
  hint: "aibox base createdb <module> 建库；连接信息见 $AIBOX_HOME/base.env"
```

### A.2 消费模块（windmill，服务型）

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

actions:                       # 含 start → 服务型，须满足 lifecycle 契约
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
  hint: "凭据见 CREDENTIALS.txt + .env；DB 经 ${AIBOX_POSTGRES_HOST} 连共享 PG（值由 base.env 注入）"
```

### A.3 分布型模块（openmaic，不含 start → 自动分布型，无额外字段）

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

hooks:
  install: install.sh
  uninstall: uninstall.sh
  update: update.sh
  svc: svc.sh

actions:                       # 不含 start → 分布型，不强制 lifecycle
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
  hint: "凭据见 .env.local；DATABASE_URL 由 shared.yml 用 ${AIBOX_POSTGRES_*} 构造（base.env 注入）"
```

---

## 附录 B：base.env + 手写稳定 shared.yml 示例（windmill）

### `$AIBOX_HOME/base.env`（由 `aibox base start` 生成）

```dotenv
# 由 aibox base start 生成 —— 勿手改；改 base 后 base restart 重写
AIBOX_POSTGRES_HOST=aibox-base-postgres
AIBOX_POSTGRES_PORT=35432
AIBOX_POSTGRES_USER=aibox
AIBOX_POSTGRES_PASSWORD=aibox
AIBOX_REDIS_HOST=aibox-base-redis
AIBOX_REDIS_PORT=36379
```

### 模块 `.env`（windmill 自己，仓库内或部署目录）

```dotenv
AIBOX_POSTGRES_DB=windmill      # 库名是模块的；host/port/user/password 由 base.env 注入
# ...windmill 自有变量
```

### `tools/windmill/docker-compose.shared.yml`（手写，稳定，零硬编码凭据）

```yaml
# 网络结构稳定；凭据/端口一律 ${AIBOX_POSTGRES_*}（aibox 调 compose 时 --env-file base.env 注入）
services:
  db:
    deploy:
      replicas: 0              # 不起本地 PG
  windmill_server:
    depends_on: []
    networks: [default, aibox-base]
    environment:
      - DATABASE_URL=postgres://${AIBOX_POSTGRES_USER}:${AIBOX_POSTGRES_PASSWORD}@aibox-base-postgres:${AIBOX_POSTGRES_PORT}/${AIBOX_POSTGRES_DB}
  windmill_worker: { depends_on: [], networks: [default, aibox-base] }
  windmill_worker_native: { depends_on: [], networks: [default, aibox-base] }
  windmill_indexer: { depends_on: [], networks: [default, aibox-base] }
networks:
  aibox-base:
    external: true
```

aibox 调度该模块的 compose 时实际执行（示意）：

```bash
docker compose --env-file .env --env-file "$AIBOX_HOME/base.env" \
  -f docker-compose.yml -f docker-compose.shared.yml up -d
```

`DATABASE_URL` 在 compose 解析时由 `${AIBOX_POSTGRES_*}` 插值得出 —— `.env` 给 `AIBOX_POSTGRES_DB`，`base.env` 给其余。改 base 凭据 → `base restart` 重写 base.env → 下次 `aibox windmill restart` 自动用新值。

---

## License

MIT。
