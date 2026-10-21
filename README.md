# 三件事日记 · 原生 iPhone 自用版

以《三件事日记 iOS 需求文档 v0.3》的 P0 为本轮实现范围，结合已经确认的使用方式：启动直接速记、底部中央 70 pt 语音按钮、长文字回看、允许留白与中断，不加入打卡、连续天数或徽章。

这是 **SwiftUI + SwiftData 的原生源代码工程**，最低 iOS 17，目标测试设备为 iPhone 13 Pro / iOS 18.7.1。无第三方依赖、无账号和应用服务器、无 CloudKit 同步。工程标识为 `com.threemoments.diary`。

**当前在 Windows 上准备完成，还没有执行 Xcode 编译、XCTest、模拟器或真机测试。尚未生成签名安装包。** 结构检查和网页测试不能证明原生工程已可安装或通过全部验收。请先在 Mac 上完成下面的构建与验收，再把它作为日记的唯一保存位置。

没有 Mac 时，先按 [云端编译操作说明](CLOUD_BUILD.md) 使用 GitHub 私有仓库和 Codemagic。源码根目录的 `codemagic.yaml` 会执行未签名编译与模拟器测试；尚未实际运行，也不会生成可安装 IPA。

## 本轮源码已包含

- 默认进入速记，文本草稿保存在本机，保存后仍停留速记。
- 今天的三栏，每一栏支持多条；全部当天速记同时保留已分类和待分类项目，可在晚间补全继续编辑。
- 想法的正文、依据、可选判断和 0–100% 把握程度；说过的话的人物、原话/大意和当时反应；细节正文。
- 明确启用语音后再按住录音，松开先保存音频和日记条目，再进行中文本机转写。首次授权结束后必须再次按住，不会在松手后突然开始录音。
- 原始音频回听、识别失败后重试、只读转写原文与可编辑正文。原文首次保存后，普通编辑无法覆盖或清空；删除整条记录会连同原文与本地录音一起删除。
- 只启用 `requiresOnDeviceRecognition = true`。设备不支持或没有可用的中文离线能力时，明确保留录音，不自动改为网络识别。转写有 60 秒超时及取消处理；切到后台、系统来电或录音中断时先保留可用文件。
- 月历、单日完整阅读、关键词搜索、独立分类与说话人筛选；补记日期和实际创建时间分开保留；“不主动展示”标记。
- 回看正文基准 18 pt，额外行距 14 pt（结合系统字形行高接近 1.95 倍），随系统文字大小缩放、保留段落，可选择复制；没有遮挡正文的悬浮按钮。搜索结果也先进入完整阅读。
- 真正的本地通知授权和每天固定时间排程。默认关闭，需手动应用；通知不显示日记正文、人物、条数或未完成提示。应用进入非活跃状态后覆盖日记画面，减少任务切换器暴露内容。
- 通过系统文件选择器选择备份文件夹，支持 Files/iCloud Drive 可访问的位置。完整备份包含 JSON、逐日 Markdown 和录音附件；SHA-256 验证附件；前台到期补做，后台仅向系统申请机会，不保证准点。
- JSON/Markdown 分享导出，恢复前预览、合并和设置恢复；同 ID 的不同内容另存冲突副本，不改正文；重复恢复不重复制造冲突。单独 JSON 中的缺失录音会明确提示，可稍后从完整文件夹补回。
- 删除操作写入可恢复日志，异常退出后在下次启动时回滚未完成操作或继续清理；未关联的录音会尝试重新建为未分类记录，并说明找回时间。
- 删除单条、删除全部的确认；全部删除包含本地录音、孤立音频、草稿和临时导出副本。系统文件夹里的外部备份需由用户自行管理。

数据与恢复接口详见 [Core/README.md](ThreeMoments/Core/README.md)。

## 在 Mac 上打开与安装

1. 将整个 `ThreeMoments-iOS` 文件夹复制到 Mac，保持子文件夹完整。
2. 安装支持目标 iPhone 系统的 Xcode，并安装相应的 iOS 平台组件。用 Xcode 打开 `ThreeMoments.xcodeproj`，选择共享 Scheme **ThreeMoments**。本工程没有需要下载的第三方 Swift Package。
3. 先选择一个 iOS 17 或更新系统的 iPhone 模拟器，执行 **Product → Build**，再执行 **Product → Test**。如果指定模拟器不存在，选择当前 Mac 已安装的型号即可。
4. 要安装到 iPhone，在 **Xcode → Settings → Apple Accounts** 登录自己的 Apple 账号。选中 ThreeMoments target 的 **Signing & Capabilities**，保留 **Automatically manage signing**，选择自己的 Team；测试 target 同样选择 Team。如标识已被其他团队占用，修改为自己唯一的 Bundle Identifier，同时同步修改后台标识（见下文）。
5. 用数据线把 iPhone 连接 Mac，按系统提示信任并配对。依 Xcode 提示在 iPhone 的 **设置 → 隐私与安全性 → 开发者模式** 开启并重启确认。将运行目标切换为这台 iPhone，执行 **Product → Run**。
6. 首次录音时先点“启用语音”，按系统提示选择麦克风和语音识别授权。授权完成后再次按住底部按钮录音，松开保存。首次提醒权限只在“设置 → 应用提醒设置”中请求。

没有付费开发者会员也可以先用 Xcode 的 Personal Team 在自己的设备上开发测试。苹果目前说明这种签名的描述文件 **7 天过期**，需重新构建安装；长期自用分发需再选合适的开发者计划。远程 Mac 可以编译，但直接真机调试需要配对的设备连接条件，不能把普通远程桌面当作已经能连接本地 iPhone；云端构建也不能绕过签名要求。

如修改 Bundle Identifier，同时修改 `Services/BackupScheduler.swift` 的 `identifier` 和 `Resources/Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers`，保持三者一致。

可在 Mac 终端执行（模拟器名称按本机安装情况替换）：

```sh
xcodebuild -list -project ThreeMoments.xcodeproj
xcodebuild -project ThreeMoments.xcodeproj -scheme ThreeMoments \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ThreeMoments.xcodeproj -scheme ThreeMoments \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
```

## iPhone 13 Pro 的验收顺序

1. 飞行模式下创建速记，杀掉 App 后重开，文字仍在且首屏为速记；未保存草稿也能恢复。一天每个分类添加多条，晚间补全能看到全部速记。
2. 分别测试麦克风/语音识别允许、拒绝后重新开启、第一次授权后松开手指、快速按下松开、录音中切后台/接电话。确认不会意外开始或继续录音；失败仍可找到并回听可用文件。
3. 在飞行模式试一段中文。若设备支持本机识别，核对原文与正文分别保存；若不支持，确认显示实际限制并保留录音。校对保存后原文不变；超时可以重试。
4. 测试长段落、换行、大字号、人物和类别组合筛选、历史日期补记；阅读时底部没有挡字的按钮。
5. 设置几分钟后的提醒并锁屏，确认系统实际投递且通知没有记录内容。关闭提醒后确认排程取消；拒绝权限时文字记录仍可用。恢复设置后需再次点击“应用提醒设置”，不会静默申请权限。
6. 选择一个**不在本应用容器内**的文件夹，创建完整备份，检查 `records.json`、`days/` 与 `audio/`。分别测试本地其他文件夹与 iCloud Drive 文件提供器（后者还需检查云端上传状态）。
7. 先备份，再用测试数据验证删光、重装、恢复后的文本、原文、录音、设置。重复恢复应跳过重复项；同 ID 不同内容应保留两份且正文不加冲突说明。单个 JSON 恢复缺录音时有提示，随后完整包可补回附件。
8. 关闭 App 数天后再打开，确认定期备份到期补做；撤销文件夹权限或使文件提供器不可用，确认显示失败和实际最近成功时间，不能显示虚假的“已备份”。
9. 使用测试记录执行“删除全部本地数据”，确认草稿、历史记录、原文、孤立音频和临时导出文件被清除；外部备份仍由你决定是否保留。

## 仍需后续定义或实现

- **自动忽略提醒后降频**：iOS 不能可靠告诉 App 用户是否看见却忽略了普通通知，本版提供主动关闭/调整时间，尚未把“连续忽略”推断成行为。需要先约定可观察且不误判的规则。
- **P1/P2**：照片、应用锁/Face ID、小组件、快捷指令、iCloud 双向同步、人物独立页、那年今日、AI、判断到期回看、系统数据接入和 Apple Watch。隐藏标记已保存，尚无主动推荐功能需要过滤。
- 备份是普通文件，没有额外口令加密；手机本地采用 iOS 文件保护。iCloud Drive 是备份存放位置，不等于应用跨设备同步。背景刷新、文件提供器权限、离线中文资源、通知投递和卸载恢复均需真机验证。
- 自用工程尚未准备 App Store 图标、截图、审核材料与分发签名。当前交付物为可在 Mac 打开的工程源代码，不能在 Windows 上直接生成可安装的 iPhone App。

## 苹果官方依据

- [在模拟器与真机上运行 App](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
- [启用开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Personal Team 的开发与签名限制](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [本机语音识别能力检查](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- [麦克风权限](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:))
- [安排本地通知](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
- [后台刷新策略](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtaskrequest)

## 已执行的结构检查

在 Windows 可执行 `python scripts/validate_project.py`，检查项目引用、测试 target、共享 Scheme、权限用途说明和资源文件。此检查不编译 Swift；`ThreeMomentsTests` 中的测试必须在 Mac 执行。
