# UniPack

面向 **uni-app X Vapor** 的 macOS 本地打包工具。通过一个界面管理多个项目、配置签名、构建 iOS 与 Android 应用，并查看日志、依赖和产物。

原生构建在本机完成；首次下载 SDK 和依赖需要联网。

## 支持范围

| 平台 | 正式包 | 自定义调试基座 |
| --- | --- | --- |
| iOS | App Store IPA | IPA |
| Android | APK | APK |

仅支持 Vapor 项目，当前适配 HBuilderX **5.34.2026102909** 及匹配的官方 SDK。不支持经典 uni-app、VDOM、Ad Hoc、AAB 或模拟器包，不包含商店上传功能。

## 主要功能

- **多项目管理**：批量添加工程，自动读取应用名称、图标、版本和 Git 分支，随文件修改刷新。
- **可视化配置**：按 iOS、Android 分区配置签名及推送、登录、地图等服务，只需填写已启用服务的参数。
- **版本编辑**：在工具内修改版本名称和版本号，同步写回原工程 `manifest.json`，并用于实际构建。
- **并发构建**：可同时选择双端打包，默认并发 2 个任务；返回列表或切换项目不影响进度，任务可独立取消。
- **依赖与产物可查**：查看构建日志、实际依赖清单和历史产物，支持在 Finder 中定位。

## 环境要求

- **运行工具**：macOS 26+。
- **编译工具**：Xcode 与命令行工具、Swift 6.4、Homebrew `openssl@3`。
- **通用打包环境**：HBuilderX 及版本匹配的官方 Vapor SDK，可在工具内下载或导入 SDK。
- **iOS 打包**：CocoaPods / Ruby `xcodeproj`、有效 P12 文件及匹配的描述文件。
- **Android 打包**：JDK 21+、Android SDK 36 / Build Tools、Keystore；插件需要时另配 NDK / CMake。

## 构建与使用

在项目根目录执行：

```sh
brew install openssl@3
./build-app.sh
open dist/UniPack.app
```

1. 在「环境与 SDK」中配置工具路径和 SDK，然后添加 Vapor 工程。
2. 在「项目配置」中核对应用信息，填写已启用服务的参数。
3. 在「构建配置」中设置包名、版本和签名，选择 iOS / Android，以及基座或正式包，开始打包。
4. 在「构建与产物」中查看进度、日志、依赖和生成的文件。

项目配置自动保存。签名使用用户指定的文件，路径和密码按项目及包类型记忆；密码在本机加密缓存，**不使用系统钥匙串**。服务参数不会回写原工程，版本信息会同步写回。

## 产物位置

默认保存在所选工程中，也可自定义正式包输出目录：

| 产物 | 路径 |
| --- | --- |
| iOS 正式包 | `unpackage/release/ios/` |
| Android 正式包 | `unpackage/release/android/` |
| iOS 调试基座 | `unpackage/debug/iOS_debug_vapor.ipa` |
| Android 调试基座 | `unpackage/debug/android_debug_vapor.apk` |

只有通过结构和签名检查才标记成功，失败或取消会保留上一次成功产物。发布前仍需进行真机验证。
