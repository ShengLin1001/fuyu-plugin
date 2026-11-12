# 校时

防止电脑时间和时区跑偏的[浮屿](https://github.com/TixXin/fuyu)插件。

主板纽扣电池没电的电脑，冷启动后时钟可能慢几个小时；Windows 自己要等好几个小时才校一次，开机时网络还没好、校时失败后还会越等越久。这个插件发现时间不准就立即校正。

## 怎么用

1. 安装并启用后，岛上多一个「校时」页面，三行：
   - **时钟**：和时间服务器差多少、什么时候测的；装了校时任务后有「立即校时」按钮。
   - **校时任务**：点「安装」，Windows 会弹出管理员确认，同意一次即可。
   - **时区**：当前时区；点「固定」后，别的程序改了时区，插件会改回来并提示。
   插件卡片的设置页「操作」里也有「安装校时任务」「立即校时」「卸载校时任务」三个按钮。
2. 之后不用管它：
   - 岛启动时、每 5 分钟、电脑唤醒和解锁时，插件各测一次时间。刚唤醒没联网时，过 15 秒再测，最多 3 次。
   - 差 2 秒以上就启动校时任务，8 秒后再测一次。
   - 差 1 分钟以上时，在岛上提示「时钟慢了 3 小时 28 分」，并说明是否已经校正。
   - 没装校时任务时，时钟差 1 分钟以上会提示安装，一周最多一次。

## 校时任务

`w32tm /resync` 要管理员权限，插件没有，所以校时交给计划任务 `\Fuyu\ResyncTimeOnNetwork`（定义在 [resync-task.xml](resync-task.xml)）：

- 以 SYSTEM 身份运行 `net start w32time & w32tm /resync /rediscover`。
- 自己也会在开机 1 分钟后、每次连上网络 15 秒后运行，岛没开也一样。
- 允许已登录的用户启动它，插件因此不用管理员权限就能校时。别人只能让它校一次时，不能改它。
- 不改注册表、不改时间服务的配置，时间服务器仍是 Windows 设置的那个。
- 放在任务计划程序的 `\Fuyu\` 文件夹里，不会覆盖你自己在根目录建的同名任务。
- 0.1.0 把任务装在根目录 `\ResyncTimeOnNetwork`；它照常可用，下次点「安装」或「重新安装」时会移到 `\Fuyu\`。
- 卸载插件前，先在页面上点「卸载」删掉任务；忘了的话，在管理员 PowerShell 里运行 `Unregister-ScheduledTask -TaskName ResyncTimeOnNetwork -TaskPath '\Fuyu\' -Confirm:$false`。

## 设置

- **固定时区**：Windows 时区 ID（如 `China Standard Time`、`Pacific Standard Time`），留空不管时区。页面上点「固定」会填成当前时区。要换时区，先取消固定，否则插件会改回来（被改回时一小时内最多提示一次）。Windows 开着「自动设置时区」时插件不改回，免得出门在外时和 Windows 来回改；页面上会说明。
- **提示语言**：岛上弹出的提示用中文还是英文。插件读不到岛的界面语言，页面本身跟着岛的语言。

## 权限与开销

- 权限：`island:notify`，用来在岛上提示时钟偏差和时区被改。
- 联网：每次测时间向 Windows 设置的时间服务器（默认 `time.windows.com`）发一个 48 字节的 NTP 请求（UDP 123 端口）。
- 按需运行：测完 1 分钟内没事就退出，不常驻。
- 管理员权限只在安装、卸载校时任务时要一次。

## 限制

- 只能缩短时间错的时长：开机到联网之间、联网到插件或任务运行之间（最长 5 分钟），时间仍是错的。根治要换主板 CR2032 电池。
- 校园网等需要网页认证的网络，认证之前测不到时间，认证后最多 5 分钟内校正。

## 开发

测试用岛屿的模拟宿主和一个假时间服务器：在仓库根目录 `npm install`，再 `npm test`（只在 Windows 上跑）；只测这个插件就在本目录运行 `node --test`。装了校时任务的电脑上，测试会真的触发一次校时（对时 time.windows.com，不影响结果）。

```sh
npx fuyu-plugin dev        # 以开发模式加载进岛屿
npx fuyu-plugin validate
npx fuyu-plugin pack --sign
```

## English

Keeps the clock and the time zone right. At startup, every 5 minutes, on wake and on unlock it asks the time server Windows uses for the time (one SNTP request); when the clock is off by more than 2 seconds it starts the scheduled task `\Fuyu\ResyncTimeOnNetwork`, which runs `w32tm /resync /rediscover` as SYSTEM, and it tells you when the clock was off by a minute or more. The task also runs by itself at startup and on every network connection, and lets signed-in users start it, so the plugin needs no administrator rights; installing or removing it from the plugin's page asks for them once. Optionally it fixes the time zone and puts it back when something changes it, unless Windows sets the time zone automatically. Remove the task on the plugin's page before uninstalling the plugin. Permission: `island:notify`.
