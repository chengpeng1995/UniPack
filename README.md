# UniPack 0.9.1

macOS 26+ 原生 SwiftUI 工具，仅支持 uni-app X Vapor 5.34.2026102909。

## 运行

```sh
./build-app.sh
open dist/UniPack.app
```

需要 Xcode 26 或以上（本机 Xcode 27 / Swift 6.4）、HBuilderX 5.34、匹配的官方 Vapor SDK。iOS 另需 CocoaPods 与可用签名身份；Android 需 JDK 21+、Android SDK 36 / Build Tools，以及插件所需 NDK / CMake。首次获取 SDK、Gradle 与依赖需要联网。

## 使用

“项目”支持选择多个工程或批量扫描目录。列表自动读取 manifest 名称、版本和图标，监听工程编辑与图标替换；右侧移除按钮只删除本工具内的项目配置。详情页上下排列 iOS 和 Android 签名项，高级设置可展开。详情分为「项目配置」「构建配置」「构建与产物」三个标签，默认进入项目配置。顶部显示当前 Git 分支，支持工作树与子模块，并区分游离 HEAD 和未使用 Git；分支切换会自动刷新。项目配置自动读取 manifest 中的名称、AppID、版本、Vapor 参数、模块及已配置的微信 AppID 等重要信息；双端 Bundle ID / 应用包名同步显示构建配置中保存的值，统一在构建配置中编辑；缺少的字段显示未配置。底栏可勾选 iOS、Android 或双端；提交后每个平台独立排队、构建、取消和记录产物。已运行的平台不会重复提交。展开任务会显示最新日志片段，完整文件仍可打开。配置自动保存到 `~/Library/Application Support/UniPack/settings.json`。指定文件路径、Alias 和密码按项目及包类型自动记住。密码存放在 UniPack 自己的 LocalCredentials 目录（加密值与本地包装密钥均为用户独占权限），不读取或写入系统钥匙串；输入框不回填明文。

- iOS：分别选择开发 / 发布 P12 文件及匹配描述文件。原生工程编译后，由随应用封装的文件签名器直接使用指定 P12，递归签名主包和嵌入动态库；不导入、查找或复用系统签名身份。
- Android：基座和正式 APK 都使用用户指定的 Keystore 文件、Alias、Keystore 密码及私钥密码。工具不再自动创建证书；缺失或失效时明确报错，不自动换证书。
- 默认并发 2 个任务，可在环境页调整为 1–4。相同项目、相同平台禁止重复提交。HBuilderX 导出全局串行，复制到任务独立资源目录后并行构建。
- 切换项目或返回列表不影响任务。取消仅终止本任务原生子进程；HBuilderX 导出期间取消需要等当前导出结束。关闭窗口会继续构建，退出会提示处理运行任务。异常退出记录标记为“已中断”，可以重新构建。

签名、目录与包类型按项目和平台分别记忆，任务启动使用配置快照。Android Gradle 密码通过权限 0600 临时文件读取，结束及取消后清理；异常退出遗留文件在下次启动时清理。

## 应用版本

「构建配置」顶部可编辑版本名称和版本号。初始值读取原工程 manifest.json；点击「保存版本」或直接「开始打包」会先校验并同步原工程的 versionName / versionCode，保留注释、缩进及其他配置，使用原子写入。输入未完成或文件版本被其他编辑器修改时停止保存，提示重新读取；本地草稿不会覆盖外部改动。

同一项目的 iOS 和 Android 共用版本信息。项目有排队或正在运行的构建时暂不允许保存版本，其他项目不受影响。开始打包时记录版本快照，HBuilderX 重新编译更新后的源文件；导出期间若版本被外部修改，或导出清单仍是旧版本，任务失败，不混用新旧版本。

iOS 的 CFBundleShortVersionString / CFBundleVersion、自建 Framework、Android 的 versionName / versionCode 均使用任务快照。出包时检查原生元数据及包内资源 manifest 的版本与任务一致。历史产物展示实际构建版本和构建号，不再读取后来被修改的工程版本。版本名称使用三段数字，版本号使用 1–2147483647 的整数；商店版本递增等要求仍需按各发布平台管理。

## 原生模块

iOS 根据新导出清单生成独立 Xcode 工程，集成官方 ExtAPI、UTS 插件、资源、隐私清单、Pods 和 SPM；保留能力并校验描述文件。自建 Framework 显式设置版本名称与构建号。屏幕方向读取 pages.json 的 globalStyle.pageOrientation 与项目 Info.plist；默认保留 iPhone 页面方向，按 [DCloud 云打包规则](https://doc.dcloud.net.cn/uni-app-x/collocation/manifest-ios.html#启动界面方向) 为支持多任务的 iPad 补齐四个方向。显式全屏配置会保留。签名前及最终 IPA 校验都检查主应用和内嵌 Framework 的版本字段、iPad 方向，失败时给出具体包路径，不发布成功产物。

iOS 独立应用生成 `Main.storyboard`（DCloud `UniAppRootViewController`）和 `LaunchScreen.storyboard`，由 Xcode 编译进包。按所选模块补齐主应用中的 RTRichText 静态引擎、权限提供器、媒体/一键登录资源；Canvas 生成独立 `DCloudUTSExtCanvas` 并自动注册。签名前与导出后的检查读取实际 storyboard 初始控制器、内嵌 Framework、SDK 资源逐文件清单及 Mach-O 原生类定义，缺失时阻止产物发布。静态验包不能替代 TestFlight 真机运行验收。

Android 使用官方 SDK 的 Gradle Wrapper、Kotlin/UTS 编译插件与自动注册插件。按导出清单集成 AAR / JAR / SO、Kotlin / Java、资源、原生清单、Maven 与插件 CMake / NDK 配置；无法识别的模块或配置明确失败。

### 双端服务参数（0.9.0）

项目详情 →「项目配置」先显示基本信息，再按上下排列的 iOS、Android 板块编辑。每个平台只显示当前 manifest 启用的服务，未启用的地图、登录或厂商通道不显示输入框、不要求填写；隐藏的既有草稿保留。启用项可先留空保存，检查配置及实际打包时验证必填项。

- iOS：个推 AppID / AppKey / AppSecret、一键登录 AppID、微信 AppID / Universal Link、支付宝回调、腾讯位置 Key。已有值从工程 Info.plist 和 manifest 自动读取；GUI 保存后优先使用本机项目配置。
- Android：推送与一键登录 AppID、微信 AppID、腾讯位置 Key、透传消息自动通知开关，以及已启用的华为、小米、OPPO、vivo、荣耀、魅族参数。兼容原 Android 加密缓存及 JSON 字段映射，不要求用户手动维护重复的 GETUI 字段。
- 华为提供 agconnect-services.json 文件选择，导入后核对包名与 AppID。任务开始时读取文件快照；生成器复制到独立工程并配置 AGCP 1.9.6.300，结束 / 取消清理任务副本。未完整接入的厂商通道仍明确报错，不通过隐藏缺项绕过集成。
- 回调、iOS 隐私策略、权限用途、设备范围与高刷新率放在可展开区域；微信和支付宝的 Associated Domains 从所填 Universal Link 自动补充。现有签名、版本、SDK 与输出目录仍在「构建配置」。
- 所有编辑保存至 UniPack 本机加密缓存；不使用系统钥匙串，普通设置与任务记录只保存引用和修订号。允许导入 iOS Info.plist / 服务 JSON、Android 占位符 JSON；「从工程补充」只填空白值，不覆盖已编辑值。iOS 与 Android 独立缓存，服务配置由基座和正式包共用，签名仍按包类型分别记忆。
- 打包使用开始时的参数快照，敏感配置通过权限 0600 的任务临时文件传递；不写到命令参数或日志。原生配置及任务内的资源 manifest 使用同一份生效参数；不回写原工程服务配置。应用版本仍按版本编辑器规则同步原工程。
- iOS 最终验包核对实际 Info.plist 服务字段的摘要，避免界面编辑后打包仍沿用旧值。检查配置只验证结构、启用项和本机文件，不联网验证服务开通、签名后台绑定或 AASA 部署。

## 产物与迁移

只有通过结构和签名检查才记录成功。每次产物文件名包含任务标识；调试基座历史保存在 `unpackage/debug/builds`，成功后原子更新 `unpackage/debug/iOS_debug_vapor.ipa` 或 `android_debug_vapor.apk`。正式包默认进入 `unpackage/release/ios` 或 `android`；保留自定义输出路径。失败与取消保留上次成功产物。

v1–v6 配置升级为 schema 7 前自动创建 `settings-v*-*.backup.json`，保留 UUID、路径、开发/发布配置和历史记录。原先选择的单个平台会成为多选的初始值。旧版钥匙串密码不从钥匙串迁移，需重新输入一次。旧版自动生成的 Android 证书需要重新选择用户指定的文件。旧 Ad Hoc 历史只读保留，不提供构建入口。

## 图标

`UniPack.icon` 是 Icon Composer 保存的 3 图层 / 2 分组源工程；石墨内层、银白 U 形开口外壳和银边。构建脚本直接通过 actool 编译 Assets.car 与 ICNS。

## 范围

不包含 Ad Hoc、AAB、VDOM、经典 uni-app、模拟器包、商店上传、自动申请签名或自动安装到真机。开发描述文件过期、发布私钥访问受阻及模块配置缺失都会阻止成功验收。未签名归档不作为 IPA 成功产物。

## 文件签名与本地缓存

- 文件签名器的 zsign 源码固定为 v1.1.2，位于 `Vendor/zsign`，受限入口位于 `tools/file-signer/main.cpp`；不编译上游命令行安装、注入或证书在线查询入口。OpenSSL 3 及 legacy provider 随应用封装。构建工具需要本机 Homebrew openssl@3，运行已构建的应用不依赖 Homebrew 路径。
- 配置中的 passwordKey 是本地缓存条目的标识，不是系统钥匙串引用。普通设置、构建快照和日志不保存明文密码。LocalCredentials 的目录权限为 0700，包装密钥与密文文件为 0600。此方式依赖本机账户和文件权限，不提供系统钥匙串的硬件保护；备份恢复需保留整个 LocalCredentials 目录。
- 运行任务使用开始时的密码快照。P12 与描述文件复制到带进程锁的临时私有目录，结束或取消后清理；下次启动清理异常退出遗留。
- P12 密码通过权限 0600 文件传给签名器，命令参数只有路径，不包含密码。Android 同样通过临时文件传递密码。

## 按需依赖与构建清单（0.8.0）

详情「构建配置」中的「打包依赖」支持切换 iOS / Android，区分当前 manifest 声明与最近一次当前包类型的构建清单；每条构建记录可展开「本次打包依赖」。支持搜索库名、模块、权限、来源和 Finder 定位。当前声明不冒充编译器摇树结果，旧构建没有清单时明确提示，不用新配置补填历史。

每次新导出后，原生生成器从实际复制、链接及依赖声明记录 `dependency-report.json`。iOS 区分静态库、嵌入动态库、系统库、资源、插件及 CocoaPods/SPM；归档后读取锁文件版本、实际 Framework 和系统链接。Android 记录基础 AAR、可选模块、provider、插件本地库、Maven、CMake/NDK；Gradle 完成后记录 runtimeClasspath 解析版本，APK 校验后读取合并权限和原生 SO。清单不含密码、服务参数或仓库认证 URL。

空的 `uni-map: {}` 仅是地图 provider 容器，不再自动引入腾讯 SDK 或要求 Key。只有显式腾讯地图 provider、`uni-map-tencent` 或腾讯定位才要求 `TencentMapSDK`；系统定位不需要。其它普通模块的空对象仍按官方规则视为显式声明，不统一忽略空对象。缓存了 Key 不会启用 SDK；未启用服务的参数不传入 Gradle。业务声明的权限与插件原生清单继续保留，清单展示其实际合并结果，不擅自删除权限。

iOS 不再无条件链接 CoreBluetooth / AppTrackingTransparency 等功能系统库；按所选模块源码 import、静态依赖及插件声明集成。真实引入蓝牙/追踪库但缺少用途说明时，在工程生成和产物检查中报出来源，不自动编写用途文案。官方必需基础库仍保留。

## iOS 首次隐私状态（0.8.1）

保留 manifest.app.initPrivacyAuthorization 的字符串值 `auto / agree / disagree`，默认按原项目的 `auto` 语义处理，禁止转换成布尔值。已核对 5.34.2026102909 的运行时：读取 String 并与 `disagree` 比较；布尔 false 会进入首次默认同意分支。原生接入文档中的旧布尔示例不能代表此 SDK 版本的实际读取行为。

本地导出省略 app 节点时，只在任务工作目录中的打包副本补入该值；不修改工程 manifest、原始导出资源、SDK 或签名后的文件。Info.plist、包内资源及本次集成快照三处必须一致，签名前和最终 IPA 都检查。项目配置及依赖清单展示该策略。它控制初始授权状态，弹窗仍由项目通过官方隐私 API 和 `open-type="agreePrivacyAuthorization"` 实现。

不自动清除已有的 SDK 授权记录。覆盖安装可能保留历史同意状态，首次流程需用干净安装验证；业务初始化、拒绝、协议链接与再次启动行为仍需真机检查。

### 荣耀推送依赖仓库

启用 Android `uni-push.honor` 时，生成器在 settings.gradle 的 dependencyResolutionManagement 中添加荣耀官方 Maven 仓库 `https://developer.hihonor.com/repo/`，限定 `com.hihonor.mcs`，并在本次依赖清单中显示来源。华为仓库不能代替荣耀仓库；不会通过删除已启用的荣耀通道绕过依赖下载失败。

### 微信 AppID 与 Android 清单合并（0.8.2）

启用微信登录、分享或支付时，从当前模块配置、显式占位符和本次导出插件清单中核对唯一的微信 AppID。主清单与官方 uni-weixin-common 都使用 `${WX_APPID}`，由 Gradle manifestPlaceholders 统一注入；缺少值、各模块值冲突时在原生编译前明确报错。依赖清单记录字段及来源，不显示值。原始配置文件保持不变。

主工程 AndroidManifest.xml 已声明的权限不会因 manifest.json.permissions 再次添加同名空声明；保留已有 tools/maxSdkVersion 规则，真实属性冲突仍报错。

### iOS ProMotion 配置

未明确配置时，工具为主应用补入布尔值 `CADisableMinimumFrameDurationOnPhone = true`，与云打包产物保持一致；保留项目或插件 plist 中明确指定的布尔值。依赖清单展示该值，签名前及最终 IPA 检查其类型和与构建快照的一致性。它允许系统使用高刷新率，不代表锁定 120 FPS；低电量、温度及渲染耗时仍会影响实际帧率。

## iOS 模块与云包配置对齐（0.8.3）

按所选模块复制 `uni-static` 扫码、视频控件字体；优先读取 SDK / 导出目录，5.34.2026102909 基线缺少字体时使用工具内保存的同版 HBuilderX 原始字体并校验 SHA-256。字体来源和版本记录在 `Resources/iOS/uni-static/provenance.json`。

官方 `DCloudUTSExtAPI` 隐私清单按媒体、微信模块从匹配 SDK 的模板选取；插件 `PrivacyInfo.xcprivacy` 进入所属 Framework，根工程的清单仅放入主应用，不再将插件清单挪到主应用代替。最终 IPA 比较实际清单与本次快照。

设备范围读取 `app-ios.distribute.devices`（iphone / ipad / universal），未配置或 auto 默认 iPhone；显式 Info.plist 的 UIDeviceFamily 与 manifest 冲突时中止。启用系统定位时，保留显式 `NSLocationTemporaryUsageDescriptionDictionary.PurposeKey`；未填写时使用项目已有的前台定位用途说明，无真实用途说明则中止。最终产物核对设备范围、定位说明、SDK 资源哈希、隐私初始化和高刷开关。

CocoaPods 安装后，从实际目标链接参数识别静态 XCFramework，将其随库提供的隐私声明合并到承载代码的 Framework，并同步产物检查快照与依赖清单，避免只保留 Pods 源码目录中的声明。

ATT 验包区分强链接 / 授权请求与厂商 SDK 的可选状态查询：弱链接且包含状态查询、未发现授权请求入口时不强制伪造用途说明；真实授权请求仍校验 NSUserTrackingUsageDescription。实际弱链接继续显示在依赖清单，不隐藏依赖。

### iOS 工程生成修复（0.9.1）

恢复隐私清单字典的独立初始化，移除误插入的重复服务摘要代码，确保隐私清单与服务参数摘要分别先初始化、再填充。
