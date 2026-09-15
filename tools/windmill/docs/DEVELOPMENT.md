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
