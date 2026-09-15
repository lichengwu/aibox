# clash

> Clash 订阅代理池 —— 编排本地 mihomo 内核，订阅节点自动测速选最快、失败自动切换。

`aibox clash` 把一个 clash 订阅 URL 变成 aibox 的出口：aibox 下发 mihomo 二进制，生成 config 把订阅交给 mihomo 的 `proxy-providers`，mihomo 自动拉取/解析/测速/切换，aibox 把出口指向本地混合端口。

## 工作原理

```
订阅URL ──clash set──> apps/clash/config.yaml（proxy-providers + url-test 组）
                              │
        mihomo 常驻 ──> 本地混合端口 127.0.0.1:7890（socks5+http）
            ├─ 自动拉订阅（24h）/ 测延迟（5min）/ 选最快 / 失败切换
            └─ external-controller 127.0.0.1:9090（aibox 调它 reload/select/status）
                              │
        aibox 出口 ──> socks5://127.0.0.1:7890（clash 开启时覆盖静态代理）
```

测速、选最快、失败切换**全部交给 mihomo 的 `url-test`/`fallback` 策略组**，aibox 不实现任何切换逻辑——只编排（下载内核、生成 config、启停进程、刷新兜底）。

## 命令

```
aibox install clash               安装 mihomo 内核（aibox 自动下载二进制）
aibox clash set <订阅URL>          存订阅 + 生成 config + 拉一次订阅缓存
aibox clash on | off               启停 mihomo（on 后 aibox 出口自动切到本地端口）
aibox clash restart                重启
aibox clash status                 mihomo 状态 + 当前节点 + 订阅/刷新时间
aibox clash refresh                强制刷新订阅（覆盖 1 周兜底）
aibox clash select <节点名>        手动切到某节点（调 API）
aibox clash test [url]             经本地 7890 端口探测
aibox clash logs                   看 mihomo 日志
aibox clash doctor                 自检（二进制/进程/config/订阅缓存）
aibox clash set/refresh 时若订阅缓存超 1 周，自动重拉
```

## 与静态代理的关系

优先级：**clash 开启 > 静态代理（`aibox proxy set`）> 直连**。

- `aibox clash on` → aibox 出口 = `socks5://127.0.0.1:7890`（本地 mihomo）
- `aibox clash off` → 回退到 `aibox proxy set` 配的静态代理，或直连

两者可并存：静态代理做兜底，clash 池做主力。

## 冷启动（订阅站被墙时）

clash 池要订阅才能起来，但**拉订阅本身需要能访问订阅站**——若订阅站国内被干扰（连接 EOF），aibox/mihomo 直连拉不到，节点为空。

这时先用静态代理把订阅拉到手：

```bash
aibox proxy set http://<能访问订阅站的代理>   # 临时静态代理
aibox clash refresh                          # aibox 走静态代理拉订阅到 pool.yaml 缓存
aibox clash on                               # mihomo 用缓存节点起来
aibox proxy off                              # 可选：停静态代理，出口改走 clash 池
```

mihomo 是 nohup 子进程，启动时继承 aibox 的 `http_proxy`——若启动时环境有代理，mihomo 自己后续刷新订阅也会走它。日常 mihomo `interval:86400` 自动刷新；aibox 兜底：`clash status`/`on` 时检查 `state.LAST_REFRESH`，超 1 周重拉。

## 刷新策略

双层互补：

1. **mihomo 内部**：`proxy-providers.interval: 86400`（24h 自动拉订阅）
2. **aibox 兜底**：`clash status`/`clash on` 时检查 `state.LAST_REFRESH`，超过 1 周（或从未刷新）则 aibox 自己 `curl` 重下载订阅覆盖 `pool.yaml` + 触发 mihomo reload。手动 `clash refresh` 立即触发。

## 失败切换

- `AUTO`（url-test）组：每 5 分钟 probe 各节点延迟，选最低；节点挂了延迟=∞ 自动跳过
- `FALLBACK` 组：按序，当前不可用自动切下一个
- aibox 不参与切换，`clash status` 调 `/proxies/AUTO` 报告当前节点

## 落点（module-spec 部署型约定）

| 路径 | 内容 | 权限 |
| --- | --- | --- |
| `${AIBOX_BIN_DIR}/mihomo` | mihomo 二进制（aibox 下发） | 0755 |
| `$AIBOX_HOME/apps/clash/config.yaml` | 生成的 mihomo 配置 | 600 |
| `$AIBOX_HOME/apps/clash/providers/pool.yaml` | 订阅缓存 | 600 |
| `$AIBOX_HOME/apps/clash/state` | 订阅 URL/secret/端口/刷新时间 | 600 |
| `$AIBOX_HOME/apps/clash/logs/mihomo.log` | 日志 | — |

## 环境变量覆盖

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CLASH_BIN_DIR` | `AIBOX_BIN_DIR` → `~/.local/bin` | mihomo 二进制落点 |
| `CLASH_BASE_DIR` | `$AIBOX_HOME/apps/clash` | 部署根覆盖 |
| `CLASH_PORT` | `7890` | 混合端口 |
| `CLASH_API_PORT` | `9090` | 外部控制器端口 |

## 设计取舍

- **不自解析订阅 yaml**：mihomo 原生吃订阅 URL，aibox 不写 yaml 解析（纯 bash 解析 clash yaml 脆弱；格式变化由 mihomo 适配）。
- **测速/切换交给 mihomo**：`url-test`/`fallback` 策略组成熟，aibox 只调 API 报告/触发。
- **nohup+pid 简单常驻**：跨平台（macOS/Linux）立即可用，不依赖 launchd/systemd 单元文件。mihomo 挂了 aibox 检测到 `CLASH_ENABLED` 但端口无响应时回退静态代理（不静默失败）。开机自启的 systemd/launchd 单元作为后续可选增强。
- **mihomo 由 aibox 下发**：用户无需手动安装；install 钩子从 GitHub release 下载对应平台二进制。
