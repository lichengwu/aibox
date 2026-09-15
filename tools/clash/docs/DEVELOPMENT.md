# clash 开发指南

> AI 据此升级本模块。

## upstream

- 主页: <https://github.com/MetaCubeX/mihomo>
- 文档: <https://wiki.metacubex.one/>
- releases: <https://github.com/MetaCubeX/mihomo/releases>

## 安装手册

- aibox 模块: `aibox install clash`（自动从 GitHub release 下载对应平台 mihomo 二进制）
- upstream: 下载 `mihomo-{os}-{arch}-v{ver}.gz` + `gunzip`

## 测试手册

- 自检: `aibox clash doctor`
- 状态: `aibox clash status`（mihomo 状态 + 当前节点 + 延迟）
- 探测: `aibox clash test [url]`

## 本模块配置情况

- 端口: 7890/tcp:mixed（socks5+http 混合端口）+ 9090/tcp:api（external-controller）
- 凭据: state `CLASH_SECRET`（API 鉴权，`gen_secret` 随机生成）
- 落点: 部署根 `$AIBOX_HOME/apps/clash`（config.yaml/providers/pool.yaml/state/logs，均权限 600）
- 自启动: nohup+pid（跨平台简单常驻，非 init 系统；mihomo 挂了 aibox 检测回退静态代理）
- 依赖: 无外部（mihomo 由 aibox 下发，gunzip 系统自带）
- 定制点: 不自解析订阅 yaml（mihomo `proxy-providers` 吃订阅 URL）；`url-test`/`fallback` 组自动测速/切换；`>1周` aibox 兜底刷新订阅

## 升级流程

1. 查 upstream 新版: mihomo GitHub releases latest（`latest_mihomo_tag` 调 GitHub API）
2. `aibox update clash`（升级 mihomo 二进制 + 刷新订阅）
3. 验证: `aibox clash status` + `aibox clash test`
