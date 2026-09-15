# pi-web 开发指南

> AI 据此升级本模块。

## upstream

- 主页: <https://github.com/agegr/pi-web>
- 文档: <https://github.com/agegr/pi-web#readme>
- npm: <https://www.npmjs.com/package/@agegr/pi-web>

## 安装手册

- aibox 模块: `aibox install pi-web`
- upstream 原生: `npm install -g @agegr/pi-web`

## 测试手册

- 服务状态: `aibox pi-web status`
- 健康检查: `curl -u pi:<密码> http://127.0.0.1:30141/`
- 诊断: `aibox pi-web diagnose`

## 本模块配置情况

- 端口: 30141/tcp:http（`PI_WEB_PORT` 可覆盖）
- 密码: 随机生成（`resolve_password`，写 plist 持久化，重装/更新读回幂等）；`PI_WEB_PASSWORD` 覆盖
- 落点: mac launchd plist（`~/Library/LaunchAgents`）/ linux systemd --user（`~/.config/systemd/user/pi-web.service`）
- 自启动: mac launchd `KeepAlive` / linux systemd `Restart=always`（不需 root）
- 依赖: node 22+（无则 nvm 自动装）+ npm
- 定制点: 无（直接用 upstream npm 包，aibox 只管 launchd/systemd 服务化）

## 升级流程

1. 查 upstream 新版: `npm view @agegr/pi-web version`
2. `aibox update pi-web`（比对已装 vs latest，有更新则升级 npm 包 + 重写 plist + 询问重启）
3. 验证: `aibox pi-web status` + curl 健康检查
