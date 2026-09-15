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

openmaic 的 DB 连接在 `.env`（`DATABASE_URL=postgres://openmaic:...`）。连共享 base PG：

1. 启共享 base：`aibox base start`（PG 35432）
2. 建库：`aibox base createdb openmaic`
3. `.env` 配置：`DATABASE_URL=postgres://aibox:aibox@aibox-base-pg:5432/openmaic`
4. 上游 compose（OpenMAIC 源码自带）的 db service `replicas: 0` + compose 加 `aibox-base` network（external）让容器连共享 PG 服务名
5. `openmaic install` / `openmaic up`

### 存量数据迁移（独立 PG → 共享 PG）
1. `openmaic backup`（pg_dump 独立 PG）
2. `aibox base start` + `aibox base createdb openmaic`
3. 恢复：`cat dump.sql | docker exec -i aibox-base-pg psql -U aibox -d openmaic`
4. 改 `.env` DATABASE_URL 指向共享 + 上游 compose db replicas:0 + network
5. `openmaic up` + 验证数据

**降级**：`.env` DATABASE_URL 回本地 + 上游 compose db replicas:1，`openmaic up` 起独立 PG。

> 注：openmaic compose 是上游 git clone（OpenMAIC 源码自带），改 db replicas + network 需改上游 compose 或 openmaic CLI 的 patch 逻辑，spec §5.6 建议存量迁移单独迭代。当前文档化配置/迁移流程，实测待部署实例。
