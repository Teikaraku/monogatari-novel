# 物语

物语小说（Monogatari Novel）是一款小说与电子书阅读器，基于 [Anx Reader](https://github.com/Anxcye/anx-reader) 二次开发。

本项目保留上游的 [MIT 许可证](LICENSE)与作者信息；第三方组件的许可随相应文件保留。感谢 Anx Reader、[foliate-js](https://github.com/johnfactotum/foliate-js) 及[其他开源依赖](pubspec.yaml)的作者。

安装包与版本说明见 [GitHub Releases](https://github.com/Teikaraku/monogatari-novel/releases/latest)：

- Android：[已签名的通用 APK](https://github.com/Teikaraku/monogatari-novel/releases/latest/download/Monogatari-Novel-Android-universal.apk)。
- iOS：[未签名的 IPA](https://github.com/Teikaraku/monogatari-novel/releases/latest/download/Monogatari-Novel-iOS-unsigned.ipa)，需自行签名后安装。

正式版由 GitHub Actions 按版本 tag 构建并发布。App 每次启动检查一次本仓库的 GitHub `releases/latest`，也可在设置中手动检查更新。

公开版本默认不配置自建书库服务地址，不附带书库数据或访问密钥；可导入本地电子书阅读。在线书库功能需自行配置服务后重新构建。

[Türkçe](README_tr.md) · [Русский](README_RU.md)
