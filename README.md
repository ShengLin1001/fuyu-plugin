# 浮屿插件

ShengLin1001 写的[浮屿](https://github.com/TixXin/fuyu)插件，一个文件夹一个插件。都用 Windows 自带的 PowerShell 运行，不用另外安装任何东西。

| 文件夹 | 插件 | 说明 |
|---|---|---|
| [battery](battery/) | 电量 `io.github.shenglin1001.battery` | 收起条上用小电池显示电脑和蓝牙设备的电量 |
| [timesync](timesync/) | 校时 `io.github.shenglin1001.timesync` | 时钟不准时立即校时，可以固定时区 |

在浮屿的 设置 → 插件市场 里安装；也可以从 Release 下载 zip，解压到插件目录下以插件 id 命名的文件夹。

## 开发

```sh
npm install        # 根目录装一次 fuyu-plugin，各插件共用
npm test           # 用模拟宿主测试所有插件
npm run validate
cd timesync && npx fuyu-plugin dev   # 以开发模式加载一个插件进岛屿
```

## 发版

签名私钥只在作者的电脑上，所以在本地发版，不用 CI。以校时插件 0.1.0 为例：

```sh
cd timesync
npx fuyu-plugin validate
npx fuyu-plugin pack --sign
gh release create timesync-v0.1.0 .package/io.github.shenglin1001.timesync-0.1.0.zip .package/io.github.shenglin1001.timesync-0.1.0.zip.sig --title "校时 0.1.0"
```

- 标签是 `<文件夹>-v<清单 version>`，插件市场按登记的 `tagPrefix`（`timesync-`）认领。
- 附件文件名不要改。
- 发版前先提高清单的 `version`，并更新这个插件的 `CHANGELOG.md`。

## 许可证

MIT
