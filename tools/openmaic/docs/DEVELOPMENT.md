# openmaic 开发指南

> AI 据此升级本模块。

## upstream

- 主页: <https://github.com/THU-MAIC/OpenMAIC>
- 文档: <https://github.com/THU-MAIC/OpenMAIC#readme>

## 安装手册

- aibox 模块: `aibox install openmaic`（装 CLI 到 `~/.local/bin`，跨平台拷文件）
- upstream 部署: `openmaic install`（在 Linux 部署主机，docker compose 起 OpenMAIC 本体）

## 测试手册

- 自检: `openmaic doctor`
- 状态: `openmaic status`
- 健康: `openmaic health`

## 本模块配置情况

- 端口: 3000/tcp:app（OpenMAIC http）+ 5432/tcp:pg
- 凭据: `.env.local`（API Key、访问密码）
- 落点: 部署根 `$AIBOX_HOME/apps/openmaic`；配置 `/etc/openmaic/openmaic.conf`（代理下发 `OPENMAIC_PROXY_URL`）
- 自启动: 无常驻（svc 透传 CLI）
- 依赖: docker + docker-compose + git（不限 OS，`require_docker` 检查；macOS Docker Desktop / Linux docker）
- 定制点: CLI 是仓库内 `tools/openmaic/openmaic`（单文件 bash，兼容 3.2 用固定 fd 9 而非 bash4 `exec {fd}>`）

## 升级流程

1. 查 upstream 新版: `openmaic upgrade --check`
2. `aibox update openmaic`（更新 CLI 副本）+ `openmaic upgrade`（部署主机升级 OpenMAIC 本体）
3. 验证: `openmaic status` + `openmaic health`

## 连共享 base PG（省资源，多模块共享）

openmaic 的 DB 连接在 `.env.local`（`DATABASE_URL=postgres://openmaic:...`）。连共享 base PG
**已由 CLI 驱动**（`OPENMAIC_SHARED_PG=1` 开启），不再需手工改上游 compose：

1. 启共享 base：`aibox base start`（PG 35432，容器名 `aibox-base-pg`）
2. 开启共享模式：`/etc/openmaic/openmaic.conf` 写 `OPENMAIC_SHARED_PG=1`
   （或临时 `OPENMAIC_SHARED_PG=1 openmaic install`）
3. `openmaic install` —— CLI 自动：
   - 落 `docker-compose.shared.yml` 到 `$APP_DIR`（`apply_local_patches` 内幂等生成）
   - `compose()` 调用自动 `-f` 追加该 override（up/install/upgrade/backup 等全生效）
   - 若 `aibox-base-pg` 在跑，`CREATE DATABASE openmaic`（幂等；未跑则提示不阻断）
   - override 用 `environment: DATABASE_URL=postgres://aibox:aibox@aibox-base-pg:5432/openmaic`
     覆盖 `.env.local` 的 `DATABASE_URL`（environment 优先级高于 env_file），并给 `openmaic`
     service 加 `aibox-base` network；`postgres` service `replicas: 0` 不起本地 PG
4. `.env.local` 仍需存在（放 `PERSISTENCE_DEV_TOKEN`、`QWEN_API_KEY`、`ACCESS_CODE` 等），
   只是其中的 `DATABASE_URL` 会被 override 覆盖 —— 不必改它。

**手动激活**（不经 conf）：把 `tools/openmaic/docker-compose.shared.yml` cp 到
`$APP_DIR/docker-compose.shared.yml`，CLI 检测到文件即激活（`shared_pg_active` 以文件在位为准）。

**降级**（回独立 PG）：`OPENMAIC_SHARED_PG=0` 后 `openmaic up`（CLI 会删 override），
或手工删 `$APP_DIR/docker-compose.shared.yml`。

`openmaic doctor` 在共享模式下改查 `aibox-base-pg` 容器在跑 + override 在位；
`openmaic backup/restore/db` 在共享模式下走 `docker exec aibox-base-pg pg_dump/psql`（不再找本地 postgres）。

### 存量数据迁移（独立 PG → 共享 PG）

1. `openmaic backup`（pg_dump 独立 PG）
2. `aibox base start` + `aibox base createdb openmaic`（或 `OPENMAIC_SHARED_PG=1 openmaic install` 自动建）
3. 恢复：`gunzip -c <备份> | docker exec -i aibox-base-pg psql -U aibox -d openmaic`
   （等价于切到共享模式后 `openmaic restore <备份>`）
4. `OPENMAIC_SHARED_PG=1 openmaic up` + 验证数据

**降级**：`OPENMAIC_SHARED_PG=0` + 删 override + `openmaic up` 起独立 PG。

> 注：上游 compose 是 OpenMAIC 源码自带（git clone），本模块**不修改上游文件** —— 共享 PG
> 完全靠 CLI 生成的 override 叠加（`docker compose -f docker-compose.yml -f docker-compose.shared.yml`），
> 降级只需删 override，干净可逆。override 文件 `tools/openmaic/docker-compose.shared.yml` 是
> 仓库内参考副本，与 CLI `_shared_override_write` heredoc 内容一致（改一处同步另一处）。
