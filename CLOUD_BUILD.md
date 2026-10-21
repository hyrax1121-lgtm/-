# 没有 Mac：用 GitHub 和 Codemagic 检查原生工程

当前状态：已准备云端配置，尚未在 Codemagic 执行。Windows 上的结构检查不能替代 Xcode 编译。

## 1. 上传到 GitHub 私有仓库

1. 登录 GitHub，新建仓库，例如 `three-moments-ios`，选择 **Private**。
2. 解压源码包。在仓库的 **Add file → Upload files** 中，上传解压后目录里面的全部源码文件和文件夹。
3. 确认仓库首页直接能看到 `codemagic.yaml`、`ThreeMoments.xcodeproj`、`ThreeMoments`、`ThreeMomentsTests` 和 `scripts`。不要只上传 ZIP，也不要多套一层 `ThreeMoments-iOS` 文件夹。
4. 提交上传。如果浏览器没有显示 `.gitignore`，可在 GitHub 创建同名文件，复制源码包内的内容。

只上传此源码包；不要上传个人日记、录音、备份或苹果密钥。

## 2. 用 GitHub 登录 Codemagic

1. 打开 https://codemagic.io/ ，使用 GitHub 登录并创建工作区。
2. 连接 GitHub 时，仅授权刚建的私有仓库。按照界面添加该仓库为应用，使用仓库中的 `codemagic.yaml` 配置。
3. 选择上传源码的分支，选择工作流 **ios-verify**，手动启动构建。
4. 首次运行前查看账户显示的 macOS 构建额度和计费条件。本配置没有配置推送自动触发；每次由你手动启动。

这一阶段不需要 Apple 开发者会员、证书或 App Store Connect 密钥。不要把密码、验证码或密钥发送到聊天中。

## 3. 查看结果

工作流依次执行：工程结构检查 → iPhone 未签名编译 → 模拟器 XCTest。

- 全部成功：说明工程通过该次云端 Xcode 编译和测试，仍需真机验收。
- 失败：下载构建产物中的 `device-build.log` 或 `simulator-tests.log`，交给我继续修复。也可复制第一段 `error:` 及其上下文；请先确认没有账号凭据。
- 测试报告在 `build/ios/test/`，日志在 `build/logs/`。测试失败会使工作流失败，不会被当作成功跳过。

**此工作流不生成可安装的签名 IPA，也不会上传或发布 App。** 云端模拟器测试通过不代表录音、本机转写、通知或 iCloud 文件访问已在你的 iPhone 上验证。

## 4. 通过后再准备安装

继续采用不买 Mac 的路线，可以注册 Apple Developer Program，配置签名和 App Store Connect，然后用云端构建上传 TestFlight。上传前还要准备唯一的 Bundle ID、App 图标、应用记录和递增构建号；目前尚未完成这些步骤。

TestFlight 的单个测试构建最多可用 90 天，需要定期上传新构建。它适合第一版自用测试，但不是永久安装方案。当前的未签名检查成功后，再单独配置上传流程，可以先发现源码问题。

官方说明：

- https://docs.codemagic.io/yaml-quick-start/first-signed-build/
- https://docs.codemagic.io/yaml-testing/testing/
- https://docs.codemagic.io/yaml-publishing/app-store-connect/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
