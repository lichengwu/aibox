# windmill 开发指南

> AI 据此升级本模块。

## upstream

- 主页: <https://github.com/windmill-labs/windmill>
- 文档: <https://www.windmill.dev/docs/>

## 安装手册

- aibox 模块: `aibox install windmill`（装 CLI）
- upstream 部署: `windmill init --version <ver>`（docker compose 起 Windmill 本体）

## 测试手册

- 自检: `windmill doctor`
- 状态: `windmill status`
- 凭据: `windmill credentials show`

## 本模块配置情况

- 端口: 8080/tcp:http（`WM_HTTP_PORT` / `init --port` 可覆盖）
- 凭据: `CREDENTIALS.txt` + `.env`（POSTGRES_PASSWORD、admin 口令）
- 落点: 部署根 `$AIBOX_HOME/apps/windmill`；配置 `/etc/windmill/windmill.conf`
- 自启动: mac launchd（backup/update-check timer，`cmd_launchd`）/ linux systemd（`cmd_systemd`）
- 依赖: docker + docker-compose + python3
- 定制点: CLI 是仓库内 `tools/windmill/windmill`（单文件 bash，兼容 3.2）；有 Darwin 平台分支（hostname/flock 回退）

## 升级流程

1. 查 upstream 新版: `windmill check`（退出码 10=有新版）
2. `aibox update windmill`（更新 CLI 副本）+ `windmill upgrade <ver>`（升级部署）
3. 验证: `windmill status` + `windmill doctor`

## 连共享 base PG（省资源，多模块共享）

windmill compose 的 db service 已改为 `replicas: 0 (hardcoded，连共享 PG，db 不起)`（.env 控制）。
连共享 aibox base PG（避免每模块独立 PG）的配置流程：

1. 启共享 base：`aibox base start`（PG 35432）
2. 建库：`aibox base createdb windmill`
3. windmill `.env` 配置：
   - `DB_REPLICAS=0`（不起本地 db）
   - `DATABASE_URL=postgres://aibox:aibox@aibox-base-pg:5432/windmill`（容器经 aibox-base network 连共享 PG 服务名）
4. compose 加 network：services 加 `networks: [default, aibox-base]`，底部加 `networks:` 段含 `aibox-base: external: true`
5. depends_on db：`DB_REPLICAS=0` 时 db 不起，`depends_on` condition 改 `service_started` 或用 compose override 去掉

### 存量数据迁移（独立 PG → 共享 PG）

1. `windmill backup`（pg_dumpall 独立 cluster）
2. `aibox base start` + `aibox base createdb windmill`
3. 恢复：`cat cluster.sql | docker exec -i aibox-base-pg psql -U aibox`
4. 改 `.env`（DB_REPLICAS=0 + DATABASE_URL 共享）+ `windmill up`
5. 验证：`windmill status` + 数据可读写

**降级**：`.env` DB_REPLICAS=1 + DATABASE_URL 回本地，`windmill up` 起独立 PG。

> 注：compose heredoc 的 network + depends_on 全改（services networks 字段 + 4 处 depends_on + network 段）是较大改动，spec §5.6 建议存量迁移单独迭代。当前已改 db replicas（最小可控），其余配置见上。
