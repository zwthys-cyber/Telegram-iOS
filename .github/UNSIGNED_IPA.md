# 无签名 IPA 与可选全能签插件

项目已合入 Swiftgram 13.2.1 完整上游。请使用 Actions 的 **BYPlugin and unsigned IPA**。

无签名 IPA 与 `BYPlugin.dylib` 分开打包；插件在全能签签名时注入。功能、签名步骤、数据兼容性及验证范围见 [BYPlugin 文档](../Plugins/BYPlugin/README.md)。

全部编译和验证仅在 GitHub Actions 执行，不在当前服务器执行。
