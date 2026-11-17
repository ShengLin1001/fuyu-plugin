# MCP 常驻

让所有 Claude Code 会话共用一份本地 MCP server。

平时 `~/.claude.json` 里的 MCP server 是 stdio 方式：每开一个 Claude Code 会话，就把整套 server 再起一遍。开四五个会话时，光 Playwright、Windows-MCP、mobile-mcp 就要占将近 1 GB。这个插件把能共享的 server 用 HTTP 方式常驻一份，会话改成连网址，开再多会话也不多占。

## 用法

打开岛上的「MCP 常驻」页面，里面列出 `~/.claude.json` 里本机的 MCP server（用户级，也就是 `claude mcp add -s user` 加的那些）：

- **可以共享**：勾选后，插件在 127.0.0.1 的固定端口上启动它，确认端口能连上以后，用 `claude mcp` 把这一项改成网址。取消勾选就停掉它，把原来的配置改回去。
- **不支持共享**：只会 stdio 的 server，一次只能服务一个会话，没法共用。
- 已经是网址的条目（远程的 MCP）不列出。

改完配置后**新开的会话**才用网址；已经开着的会话还连着自己那套，关掉后释放。

| server | 端口 | 怎么认出来 |
|---|---|---|
| Playwright（`@playwright/mcp`） | 8931 | 命令里有这个 npm 包 |
| Windows-MCP | 8932 | 命令是 `windows-mcp(.exe)` |
| mobile-mcp（`@mobilenext/mobile-mcp`） | 8933 | 命令里有这个 npm 包 |

原配置里的参数和环境变量都原样带上，只在后面加 HTTP 的参数（`--port`、`--listen`、`serve --transport streamable-http`）。npm 包能在本机找到（全局安装或 npx 缓存）时直接用 `node` 启动它的入口，不再经过 npx，省掉一个常驻的 npx 进程；找不到时照原来的命令用 npx。

## 常驻和重启

- 插件随岛一直运行，server 是插件的子进程：挂了就重启（等 5、10、20、40、60 秒，之后每 60 秒一次），页面上能看到状态。
- 岛重启时 server 跟着重启。Claude Code 的 HTTP 连接会自己重连，会话不用重开。
- 端口被别的程序占着时：如果占着的正是同一种 server（比如之前手动起的），插件结束它再接管；是别的程序就不动它，每 30 秒再试。
- 每个 server 的输出写在插件数据目录的 `<名字>.log`。
- **装好后先把内存上限调到 2048 MB**（设置 → 插件扩展 → MCP 常驻）。岛把 server 的内存也算在插件头上，默认上限 512 MB；三个 server 合计约 700–800 MB（Windows-MCP 一个就 500 MB），超了岛会结束插件，server 跟着全停。
- 改配置时先记下「已托管」再改 `~/.claude.json`，插件中途被结束的话，下次启动会把没做完的切换补完。

## 安全

- server 只监听 127.0.0.1，不对外。
- 原配置可能带 token（比如 Playwright 扩展的 `PLAYWRIGHT_MCP_EXTENSION_TOKEN`），存在 Windows 凭据管理器里（权限 `secrets`），不写进插件的普通存储。
- 插件只通过 `claude mcp remove/add-json -s user` 改配置，不直接写 `~/.claude.json`：Claude Code 自己也在频繁改写这个文件，直接写容易把它的改动冲掉。

## 权限

- `secrets`：保存被托管 server 的原配置，取消托管时用它改回去。

## 开发

```sh
npx fuyu-plugin test       # mock host 下的测试：假 claude.exe 改临时的 .claude.json，假 windows-mcp 监听 18932
npx fuyu-plugin validate
npx fuyu-plugin pack
```

测试把默认端口整体加 10000（`MCP_KEEPER_PORT_OFFSET`），不碰本机正在用的 server。
