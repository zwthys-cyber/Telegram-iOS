# BYPlugin — 全能签注入插件

配套主程序：本仓库的 Swiftgram 13.2.1 / BYPlugin Host ABI 1。插件是 arm64 iOS 动态库，不需要越狱、Substrate 或额外 Swift 运行库。

## GitHub 下载与全能签使用

1. 在仓库 Actions 的 **BYPlugin and unsigned IPA** 成功运行中下载两个产物：`Swiftgram-unsigned-arm64-...` 和 `BYPlugin-arm64-...`。
2. 解压得到 `Swiftgram-unsigned.ipa`、`BYPlugin.dylib`，可用产物中的 SHA256SUMS 校验。
3. 在全能签导入该 IPA，在签名配置的添加/注入动态库功能中选择 `BYPlugin.dylib`。确保选择的是**注入**，使签名工具添加 dylib 加载命令；仅拷贝文件不会生效。不同全能签版本的菜单名称可能不同。
4. 使用自己的证书对应用和插件一起签名，再安装。保持原有 Bundle ID、证书及 App Group 权限配置，避免切换数据容器。
5. 注入后沿用 Swiftgram 原来的功能设置；JSON、秒级时间和快捷翻译仅改变未保存过的默认值。已保存的设置优先。
6. 不注入时使用上游功能策略。若要移除插件，请从本次原始 IPA 重新签名，不要只删除已注入包中的 dylib（加载命令仍会引用它）。

**这是配套主程序插件，不是适用于 App Store 版或任意原版 Telegram 的通用补丁。** 上游的 Swift 实现没有稳定可注入接口，因此主程序保留轻量适配点。没有插件、插件接口不完整或 ABI 不兼容时，适配点退回上游策略。插件不会自动下载或加载其他代码。

## 定制迁移范围

| 功能 | 实现与行为 |
| --- | --- |
| 图标和徽标 | 解锁已打包的本地图标，显示 Ducky/Beta；图标切换在 iOS 返回成功后更新 UI |
| 消息工具 | 复制消息 ID、UTC ISO 8601 时间；默认显示 JSON、秒级时间及快捷翻译，保留复制保护 |
| 本地功能 | 工具栏、关键词过滤、本地 Pro 页面、徽标和通知设置；不改写订阅状态或 Telegram Premium |
| 下载增强 | 插件拥有分块/并发策略；接入 V1 和 CDN，保留上游 Rust 引擎、优先级、哈希验证、服务端等待和未知长度 EOF 顺序探测 |
| 自签名存储 | 缺少 App Group 时主应用继续使用旧定制版的 Library/Application Support/Swiftgram 路径；新版密码保护使用经校验的应用私有钥匙串，不删除、不自动迁移数据 |
| 本地复制与保存 | 在 BYPlugin 设置中单独开启；支持受限聊天、仍可访问的阅后即焚／一次性图片、视频和文件。付费内容、服务器转发与销毁流程保持原样 |
| 登录返回 | 短信付费页面可重新开始登录；不绕过服务器认证或收费 |

通知服务是独立进程：通知定制需要有效 App Groups，并需要签名工具对 NotificationService 扩展单独注入并签名同一个 dylib。只给主应用注入不会启用扩展中的插件策略。其他扩展保持上游逻辑。Keychain/推送能力仍由签名权限决定。

移除插件或更改签名的 App Group 权限，可能使主应用选择另一数据容器；已有数据不会被删除。插件不能替代签名权限。

## 结构与升级

- `Sources/BYPlugin.{h,c}`：独立、版本化的 C ABI、功能开关及下载策略。
- `Swiftgram/SGSimpleSettings/Sources/BYPlugin.swift`：仅查询插件导出符号的宿主桥接层，不查找 Telegram 自身的 Swift 符号。
- 各调用点：少量可回退的宿主适配，保留现有上游实现。
- `migration.json`：上游和旧定制提交、适配文件列表。
- `build.sh` / `test.sh`：只允许 GitHub Actions 执行，禁止在当前服务器编译或测试。

ABI 1 功能位：icons=1、messageTools=2、localFeatures=4、downloadBoost=8、privateStorage=16、loginRestart=32、localSaving=64、ghostMode=128、messageHistory=256。默认 511，编译插件时可通过 `BY_PLUGIN_FEATURES` 制作功能子集，不需要重编译宿主。升级 ABI 时需同时迁移宿主接口。

## 构建和验证范围

GitHub 使用最新 macOS 27 ARM64 环境 `xcode-27`，从上游 `versions.json` 选择 Xcode 27.1 和 Bazel 9.2.0。插件验证与构建独立执行；完整 IPA 构建使用缓存和按内存限制的并发。所需仓库 Actions secrets 为现有的 `TELEGRAM_API_ID`、`TELEGRAM_API_HASH`，不会打印或上传它们。

自动检查包括缺失插件/正常注入/关闭功能/不兼容 ABI、下载边界与小文件、未知长度资源策略、数据保存、私有钥匙串选择与扩展隔离、完整 release arm64 构建、IPA CRC 和所有 Mach-O 的平台/架构/签名。未在你的手机上使用全能签安装验证前，不能把构建通过视为真机兼容性结论。

## BYPlugin 统一入口与本地保存

入口：**设置 → Swiftgram → BYPlugin 设置**。页面显示插件加载状态，集中管理本地保存、消息工具及下载模式；后续插件功能继续放在此处。旧设置值沿用，不重置。下载模式修改后重新启动应用。

本地复制与保存默认关闭，需要新版 IPA 和新版 BYPlugin.dylib 配套注入。ABI 1 的函数签名保持不变；旧插件的 63 功能位不会意外开启新功能。

- 开启后，长按受限消息可复制文字、保存已下载图片／视频、将文件导出到“文件”。未下载完成时先下载，再重新长按。
- 受限图片／视频查看器原来的分享按钮变为本地保存操作；不会开放服务器转发。
- 阅后即焚／一次性图片与视频：观看时左上方增加保存按钮；一次性语音／圆视频播放面板增加“存储到文件”。
- 观看期间，已启用功能会临时保留当前媒体的硬链接，以便在原消息被消费后完成用户发起的保存。关闭查看器且导出结束后释放，不建立永久媒体归档。
- 付费内容维持上游限制；已经销毁、未下载或不可访问的资源不能恢复。截图保护、阅读／消费回执与销毁计时不改变。
- 相册授权被拒绝时不会提示保存成功；仅 Photos 实际写入成功才显示成功提示。文件导出保留原文件名并处理路径字符。
- 关闭开关或移除插件后恢复上游策略；不会删除用户已经明确导出的文件。

### 安装后交互验收

自动测试覆盖缺失、开启、旧版、关闭功能和不兼容 ABI，以及本地导出策略组合和文件名边界。完整 IPA 编译不能代替下面的手机交互检查：

1. 确认 BYPlugin 设置页显示“已加载”，新开关默认为关；中／英文、浅／深色页面无裁切，切换与返回正常。
2. 在可访问的受限群／频道分别长按文字、已下载图片、视频和文件；开关前后比较菜单并实际保存，确认原服务器转发限制保留。
3. 在媒体仍可打开时测试阅后即焚图片／视频、一次性语音／圆视频；保存后关闭查看器，确认消息仍按上游流程消费，导出文件可以打开。
4. 拒绝相册权限、取消文件选择器、不足存储、付费内容、已销毁内容均不能误报成功。
5. 修改开关后重新打开消息菜单／查看器。未加载插件和旧插件不开放本地保存。

当前会话没有 XcodeBuildMCP 交互工具，以上手机／可视化验收由安装者执行；CI 的 iOS 模拟器测试仅验证动态库加载及纯策略，不代表已完成 UI 验证。

## BYPlugin 2.0：隐私与消息历史

完整保留原有图标、徽标、本地功能、下载分块、签名存储、密码与登录适配。统一入口增加功能能力状态、输入工具栏、设置页隐藏号码和通话确认，沿用已有偏好；原有功能没有重置。

- 幽灵模式在已注入插件的主应用内按账号保存，提供总开关及在线、输入/录音/上传、云端聊天已读、动态观看四个独立选项，默认全部关闭。更改在线选项会更新当前在线任务；秘密聊天已读、真实通话参与状态、阅后即焚/一次性媒体消费仍保留上游语义。普通云端聊天/论坛/评论阅读不推进本地已读；已排队的云端已读和动态回执在发送侧被丢弃，不延迟到关闭后补发。主动发消息、回应动态、其他客户端和后续阅读仍可能显示活动或确认较早的消息。系统集成与应用扩展使用独立进程，不保证继承主应用的隐私开关。
- 防撤回与编辑历史分别开启，默认关闭。历史存于当前账号的 Postbox 偏好数据，随账号数据容器隔离；不上传、不写入普通日志。先存本机可用的旧版本，再执行正常删除/编辑和 pts 同步。
- 历史内容是文字、说明、附件名称/类型/标识；**不归档媒体文件本体**。付费、秘密聊天和定时/一次性内容不进入自动历史，原有手动保存功能继续保留。
- 历史页支持全文/聊天/发送者搜索、只看撤回、分页、按消息看旧版、复制文本、二次确认清理。保留期限 7/30/90 天，最多 500 条、每条 10 版、总 JSON 编码 2 MiB。超限清最旧条目；期限在写入和进入历史页时清理。关闭记录不自动删除历史。未收到的原文和此前已销毁的数据无法恢复。
- 旧版 127/63 功能位仍兼容，新功能必须用本次 IPA 和 dylib 配套。缺失/旧版/禁用/不兼容插件均不会启用新隐私策略。已有历史仍可查看和删除。

### 本次验证（2026-11-15）

验证源码为 `effd6e8`，全部在 GitHub Actions 的 macOS 27.0.1 ARM64 / Xcode 27.1 执行，当前服务器未编译、未测试。

- [完整构建与插件验证](https://github.com/zwthys-cyber/Telegram-iOS/actions/runs/43723617556)：宿主和 iOS 模拟器的缺失／正常／旧版／关闭／不兼容 ABI 场景通过；实际 arm64 dylib 的功能位为 511。下载对齐、存储／密码、历史容量和语法检查通过。
- [真实 Postbox 与同步验证](https://github.com/zwthys-cyber/Telegram-iOS/actions/runs/43723612877)：909 项 XCTest，1 项长测单独执行，0 失败；9 项 BY 隐私与历史测试全部通过。临时移除删除归档或实时位置回执拦截时，测试按预期失败，恢复后通过。
- 普通规模随机同步场景 seeds 1–5000 全部通过；大账号加延迟场景 seeds 1–1000 全部通过，均无消息同步差异。最后一组的 XCTest 已通过，但原 CI 的摘要解析因 stdout/stderr 交错误报失败；[原始产物复核与解析器回归](https://github.com/zwthys-cyber/Telegram-iOS/actions/runs/43738054224) 确认该组 250 个编号完整、不重复、每项成功，汇总 `failing=0 kinds=[]`。修复仍拒绝缺失、重复、非成功场景及 XCTest／进程失败。[修复后脚本的实际运行](https://github.com/zwthys-cyber/Telegram-iOS/actions/runs/43738054287) 也通过了大账号／延迟场景 751–752。后续纯 CI 改动执行此小范围实际验证；应用源码改动及手动运行仍执行完整套件和 6000 个场景。
- 完整 Release 编译、IPA CRC／SHA-256 和 12 个设备二进制的架构／无签名校验通过。构建缓存已保存；产物包含 SHA256SUMS 和 verification.json。临时验证 PR #4 的构建树与上述源码相同。

未使用真机交互工具，CLI 模拟器测试不代表界面验收。安装后请确认新开关默认关闭、旧值保留、账号间隔离，以及中文／英文、浅／深色页面和长文本显示正常。可用两个自有测试账号验证普通消息编辑／撤回和幽灵开关；撤回记录通过统一历史入口查看。搜索、分页、复制和清理确认需在手机上检查。付费、秘密聊天和定时媒体不进入自动历史，原有手动保存流程保留。

### Representative feature references

Compared on 2026-11-15 against the projects' own descriptions:
- [AyuGram releases](https://github.com/AyuGram/AyuGramDesktop/releases) describe per-account Ghost Mode and local deletion/history controls. [Its saving guide](https://github.com/AyuGram/AyuGramDocs/blob/main/desktop/saving.md) distinguishes stored text history from media preservation.
- [Nicegram's Ghost Mode guide](https://nicegram.app/articles/ghost) describes last-seen privacy plus chat preview, including the limits of sending/typing while hidden.

BYPlugin implements independent per-account activity/read/story toggles in the injected main app and a bounded local history viewer. App extensions and system integrations do not automatically inherit these main-app privacy settings. It does not change Telegram's server privacy settings automatically. Sending messages, calls, another logged-in client, and requests already sent can still reveal activity. New privacy/history switches default off; earlier local-saving and interface preferences are retained. History only captures versions this device actually had; missing past versions and media bytes cannot be recovered by this viewer.

## BYPlugin 2.1（开发中）

聊天幽灵模式提供跟随全局／此聊天开启／此聊天关闭，作用于该聊天的输入、已读及对应发布者的动态观看回执；在线状态仍属账号全局。旧账号设置按缺失字段默认值兼容读取。撤回位置提示只投影已保存的本地记录，保留原消息日期及话题，不重新写入聊天数据库。去广告分别处理官方赞助内容与可展开的推广规则过滤；付费内容、消费和销毁语义保持原样。新增能力位为 chatPrivacy=512、deletionMarkers=1024、adBlock=2048，总功能位 4095，ABI 1 不变。

本轮编译与验证尚未完成，以 GitHub Actions 实际结果为准。
