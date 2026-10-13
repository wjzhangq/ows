# OWA Bridge

macOS 菜单栏应用。把已经登录的 Outlook 网页（`outlook.office.com`）留在本机，给本地 AI agent 提供只读 HTTP 接口。

只支持 Mac，只支持 Microsoft 365 账号，不支持个人版 `outlook.live.com`。

## 构建和运行

需要 Xcode 命令行工具。

```bash
./scripts/build-app.sh
open "build/OWA Bridge.app"
```

第一次会打开窗口，在里面登录 Outlook（含 MFA）。登录成功后窗口收到屏幕外，菜单栏信封图标保留。点菜单可以再显示窗口。关掉窗口不会退出，会话还在。

自测（不打开 Outlook）：

```bash
swift run BridgeSelfTest
```

## 本地接口

默认 `http://127.0.0.1:5333`。除 `GET /healthz` 外，都要带本机 token：

```bash
curl -H "Authorization: Bearer $(cat ~/.owa-bridge/token)" http://127.0.0.1:5333/me
curl -H "Authorization: Bearer $(cat ~/.owa-bridge/token)" "http://127.0.0.1:5333/messages?top=10"
```

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/healthz` | 存活，无需 token |
| GET | `/status` | 登录态、抽取来源、页面 URL |
| GET | `/me` | 当前用户 |
| GET | `/messages?folder=inbox&top=10&unread=false` | 邮件列表，`top` 最大 50 |
| GET | `/messages/{id}` | 邮件详情。`id` 要百分号编码 |
| GET | `/debug/dom?selector=` | 原始 HTML（会截断，并抹掉 token） |
| GET | `/debug/aria` | 无障碍树 |
| GET | `/debug/snapshot` | 页面 PNG 的 base64 |
| GET | `/debug/extract?target=messages` | 抽取过程 |
| GET | `/debug/eval` | 默认关闭 |

数据接口加 `?debug=true` 会多一个 `_debug` 字段。

配置在 `~/.owa-bridge/config.json`。要打开 `/debug/eval`，把 `debugEvalEnabled` 设为 `true` 后重启。日志不写邮件正文。

## 不会做的事

不发信、不改信、不保存密码。不把 Outlook 会话里的 access token 拿出来，也不拿它去调用外部接口。读取只发生在已经登录的页面里。
