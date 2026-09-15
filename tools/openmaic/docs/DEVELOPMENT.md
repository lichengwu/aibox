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
