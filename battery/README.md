# 电量

收起条上用一排并排立着的小电池显示这台电脑和已连接蓝牙设备的电量，岛上多一个「电量」页面。

## 怎么用

- 安装并启用后，收起条上多一个项目（可以在 外观 → 收起条上的项目 里调位置或隐藏），是几个并排立着的小电池，里面的色块高度就是电量，不显示数字：
  - 第一个是这台电脑（没有电池的台式机没有这一个），后面是已连接、且读得到电量的蓝牙设备，按名字排，一共最多 4 个。
  - 每个位置一种颜色（绿、蓝、紫、粉），同一个设备的位置和颜色不随电量变化。
  - 电量 20% 及以下变黄，10% 及以下变红；电脑接着电源时不变色。
  - 鼠标停在上面显示每个设备的名字和百分比。
  - 这种画法需要支持「折叠条上的电池」的岛屿；旧版岛屿在这里显示成一串百分比文字。
- 点这个项目打开「电量」页面：这台电脑（接通电源，或用电池时大约还能用多久）、已连接的蓝牙设备，以及没连接但 Windows 还记着电量的设备。
- 每 20 秒读一次；打开页面时立刻读一次。

## 哪些蓝牙设备有电量

大多数设备读的是 Windows 自己已经知道的电量，也就是 设置 → 蓝牙和其他设备 里设备名旁边那个数字：

- 低功耗蓝牙（BLE）的鼠标、键盘、手柄等：设备自己上报。
- 经典蓝牙耳机：通过免提（Hands-Free）协议上报的才有。
- 其余已连接的设备 Windows 没有电量，页面上会列出并写明「Windows 没有它的电量」。

AirPods 这类苹果耳机不向 Windows 上报电量，Windows 设置里也看不到，但它们自己一直在用低功耗蓝牙广播电量。连着这样的耳机时，插件每分钟听 5 秒广播：

- 收起条上的电池和页面右侧的数字取两只耳机里较低的那个；页面那一行写出左、右耳和充电盒各自的电量（广播里没有的不写）。
- 广播只精确到 10%，所以是 30%、40% 这样的整十数。
- 插件启动或耳机刚连上后，要等下一次读取（约 20 秒）才有数字；耳机收进盒子不再广播时，保留最后一次的数字直到断开。
- 广播里没有能认出「这是你的耳机」的地址，只有型号。附近有别人同型号的耳机时，取信号最强（离电脑最近）的那一副，极少数情况下可能显示成别人的。

设备断开后 Windows 仍保留最后一次的数字，所以「未连接」那一组的电量可能已经过时。

## 开销

- 插件一直运行（收起条上的项目在插件停止时会被清空），是一个 Windows 自带的 PowerShell 进程，常驻内存几十 MB。
- 一次读取是几十毫秒：电脑电量用 `GetSystemPowerStatus`，蓝牙电量直接读设备属性（cfgmgr32 的 `CM_Get_DevNode_Property`）。启动时用 `Add-Type` 编译一小段 C#（约 0.4 秒）；没有用 `Get-PnpDeviceProperty`，它每个设备节点要几秒到十秒。
- 只有连着苹果耳机时才听广播：第一次用系统自带的 C# 编译器（.NET Framework 的 `csc.exe`）编译 `adverts.cs`（约 1 秒），之后每分钟被动扫描 5 秒，只听不发。没有这样的耳机时不编译也不扫描。
- 这种「运行时编译、从内存加载」的做法，有些杀毒软件和 EDR 会拦截或报毒。被拦时插件照常运行，只是不显示苹果耳机的电量，日志里有一行 `no earphone levels`。
- 不连接设备、不需要管理员权限、不联网。

## 开发

测试用岛屿的模拟宿主：在仓库根目录 `npm install`，再 `npm test`（只在 Windows 上跑）；只测这个插件就在本目录运行 `node --test`。

## 权限

不需要任何权限。

## English

Adds a row of small upright batteries to the collapsed bar: one for this computer and one for each connected Bluetooth device (up to 4), each in its own color, yellow from 20% and red from 10%; no numbers there, hover or open the page for them. A page lists every device. It reads the levels Windows already knows (the number next to a device in Settings → Bluetooth & other devices) every 20 seconds. AirPods-like Apple earphones report nothing to Windows but broadcast their levels over Bluetooth LE: while such earphones are connected the plugin listens for 5 seconds each minute and shows the emptier pod's level, in steps of 10%. The broadcast carries a model, not an address, so with the same model nearby the strongest signal counts as yours. No permissions, no administrator rights, nothing goes online.
