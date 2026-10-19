# TouchBarStocks

原生 macOS App，集成 Touch Bar 自选股滚动、顶部菜单栏图标折叠和 CPU 温度风扇控制。使用 Swift / AppKit / Objective-C，不依赖 BetterTouchTool。

## 功能

- 编辑自选股，支持 A 股和港股；连续滚动、暂停、红涨绿跌、30 秒刷新。行情来自腾讯公开接口，港股可能延迟，以界面标注时间为准。
- 通过分隔线划定顶部菜单栏图标折叠区域，一键展开；相关菜单操作连续空闲 15 秒后自动折叠。
- 显示 CPU 最高有效温度、风扇实际/目标转速；支持可调整温度曲线、恢复系统自动控制，以及 App 断开和传感器异常时释放控制。

## 构建

在 macOS 上安装 Xcode Command Line Tools 后运行：

```bash
bash build.sh
open build/TouchBarStocks.app
```

输出 App 在 `build/`，ZIP 在 `dist/`，均已忽略。可用 `bash build.sh /path/to/output` 指定 App 输出目录。构建执行解析、菜单空闲策略、风扇曲线及故障恢复自检、真实匿名 XPC 身份校验和 ad-hoc 签名完整性检查，不会安装服务或写入风扇。

```bash
build/TouchBarStocks.app/Contents/MacOS/TouchBarStocks --self-test
build/TouchBarStocks.app/Contents/MacOS/TouchBarStocks --thermal-status
```

第二条命令只读探测温度和风扇，不会接管硬件。源码入口为 `src/main.swift`；菜单栏折叠在 `MenuBarFolder.swift`、`MenuIdleCountdown.swift`；温控在 `ThermalControl.swift`、`ThermalPanel.swift`、`ThermalBridge.m`；独立服务在 `ThermalHelper.swift`。

## 菜单栏与 Touch Bar

按住 ⌘ 将要隐藏的顶部菜单栏图标拖至分隔线左侧，把箭头和「股」留在右侧。退出 App 会恢复分隔线宽度。不要同时启用 iBar 等同类折叠工具。

实体 Touch Bar 展示使用私有系统接口，取决于机型和系统状态。软件 API 返回可见不代表物理面板已显示；菜单栏和温控可独立使用。

## 温度与风扇

开发验证机型为 Apple M1 MacBookPro17,1，当前温控限制为 Apple Silicon 单风扇机型。默认 60°C 开始、85°C 全速，可调整保存：起始值 45～75°C，全速值高出至少 5°C 且不超过 90°C。区间内从硬件最低到最高转速插值，低温交还系统自动。每 2 秒采样，升速立即执行，降速每次最多减少 300 RPM。手动模式由本曲线决定目标，不叠加不可知的系统自动目标。

默认只监测。要启用控制：

1. 将 App 放入 `/Applications/TouchBarStocks.app`。
2. 打开「温度与风扇」，点击「安装 / 更新温控服务」，在本机终端完成管理员授权。安装本身不启用曲线。
3. 将其他风扇工具恢复为自动并退出其界面，再点击「启用温度曲线」。可随时点击「恢复系统自动」。

普通 App 不获取 root 权限，只有独立 helper 使用 root。XPC 接口仅接受状态、启用曲线、心跳、恢复自动；不接受任意命令、文件路径或 SMC 字节。服务自行读取温度、校验参数和硬件转速范围。连接方必须是当前控制台用户，且其 audit token 绑定的代码签名 CDHash 必须匹配安装时保存的值。更新或重编译 App 后须重新更新服务授权。

App 断开、8 秒心跳超时、读数或写入异常、连续三次模式/目标读回失败时尝试恢复自动并读回确认。SMC 读回可能延迟，须等待后续采样；恢复失败保留标记并重试。接管前写入 root 恢复标记，服务异常重启后据此恢复。休眠通知停用曲线，唤醒后须手动启用。关闭温控窗口不停止曲线，退出 App 会释放控制。

这些措施处理软件故障，不能保证内核、SMC 或硬件失效时仍能恢复，不替代硬件散热保护。传感器、SMC、Touch Bar 和 auditToken 涉及非公开系统实现，系统升级后需重新验证。本机 ad-hoc 签名构建未做 Developer ID 公证。

### 服务路径与卸载

- `/Library/PrivilegedHelperTools/local.penghuichai.TouchBarStocks.thermalhelper`
- `/Library/LaunchDaemons/local.penghuichai.TouchBarStocks.thermalhelper.plist`
- `/Library/Application Support/TouchBarStocksThermal/`：root 专用状态目录，0700。

先恢复系统自动，再运行：

```bash
/bin/bash /Applications/TouchBarStocks.app/Contents/Resources/InstallThermalService.command --uninstall
```

若尚未确认恢复，卸载脚本会保留/重启服务继续尝试。

## 验证范围

1.3.0 build 6 已在上述机型验证温度读取、实际升速、随温度降低目标、恢复自动及 App 强制结束后释放控制。休眠/唤醒和 root helper 崩溃后的硬件恢复尚未实测。风扇模式写入后的即时读回可能为旧值，因此由后续采样确认，相关回归包含在自检中。

## 本地数据与凭据

运行态自选表位于用户的 `~/Library/Application Support/TouchBarStocks/watchlist.json`，设置保存在 UserDefaults；本仓库不包含本机运行数据或 Git 历史迁移。构建使用 ad-hoc 签名，不需要上传证书、私钥或开发者凭据。不要将运行配置、环境变量文件、日志、私有签名材料或访问令牌加入版本控制。

## 开源协议

本项目采用 [MIT License](LICENSE)。
