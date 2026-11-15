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
| 登录返回 | 短信付费页面可重新开始登录；不绕过服务器认证或收费 |

通知服务是独立进程：通知定制需要有效 App Groups，并需要签名工具对 NotificationService 扩展单独注入并签名同一个 dylib。只给主应用注入不会启用扩展中的插件策略。其他扩展保持上游逻辑。Keychain/推送能力仍由签名权限决定。

移除插件或更改签名的 App Group 权限，可能使主应用选择另一数据容器；已有数据不会被删除。插件不能替代签名权限。

## 结构与升级

- `Sources/BYPlugin.{h,c}`：独立、版本化的 C ABI、功能开关及下载策略。
- `Swiftgram/SGSimpleSettings/Sources/BYPlugin.swift`：仅查询插件导出符号的宿主桥接层，不查找 Telegram 自身的 Swift 符号。
- 各调用点：少量可回退的宿主适配，保留现有上游实现。
- `migration.json`：上游和旧定制提交、适配文件列表。
- `build.sh` / `test.sh`：只允许 GitHub Actions 执行，禁止在当前服务器编译或测试。

ABI 1 功能位：icons=1、messageTools=2、localFeatures=4、downloadBoost=8、privateStorage=16、loginRestart=32。默认 63，编译插件时可通过 `BY_PLUGIN_FEATURES` 制作功能子集，不需要重编译宿主。升级 ABI 时需同时迁移宿主接口。

## 构建和验证范围

GitHub 使用最新 macOS 27 ARM64 环境 `xcode-27`，从上游 `versions.json` 选择 Xcode 27.1 和 Bazel 9.2.0。插件验证与构建独立执行；完整 IPA 构建使用缓存和按内存限制的并发。所需仓库 Actions secrets 为现有的 `TELEGRAM_API_ID`、`TELEGRAM_API_HASH`，不会打印或上传它们。

自动检查包括缺失插件/正常注入/关闭功能/不兼容 ABI、下载边界与小文件、未知长度资源策略、数据保存、私有钥匙串选择与扩展隔离、完整 release arm64 构建、IPA CRC 和所有 Mach-O 的平台/架构/签名。未在你的手机上使用全能签安装验证前，不能把构建通过视为真机兼容性结论。
