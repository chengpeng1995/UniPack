# frozen_string_literal: true
# 在独立工作目录生成工程；仅引用 SDK / 导出资源，绝不修改它们。
require 'json'
require 'fileutils'
require 'open3'
require 'xcodeproj'
require 'digest'
require 'shellwords'
require_relative 'dependency-report'
require_relative 'ios-module-integration'
report = DependencyReport.new('ios')

spec = JSON.parse(File.read(ARGV.fetch(0)))
work = File.expand_path(spec.fetch('work'))
FileUtils.mkdir_p(work)
sdk = File.join(spec.fetch('sdk'), 'SDK')
sdk = spec.fetch('sdk') unless File.directory?(sdk)
libs = File.directory?(File.join(sdk, 'libs')) ? File.join(sdk, 'libs') : File.join(sdk, 'Libs')
extsrc = File.join(sdk, 'ExtApiSrc')
resources = spec.fetch('resources')
manifest = spec.fetch('manifest')
service_config = spec['serviceConfigurationPath'] ? JSON.parse(File.read(spec['serviceConfigurationPath'])) : nil
privacy_policy = spec.fetch('initialPrivacyAuthorization')
raise '隐私初始化必须为字符串 auto / agree / disagree' unless privacy_policy.is_a?(String) && %w[auto agree disagree].include?(privacy_policy)
source_policy = manifest.fetch('app', {}).fetch('initPrivacyAuthorization', 'auto')
raise '隐私初始化与本次配置快照不一致' unless source_policy == privacy_policy
exported = JSON.parse(File.read(File.join(resources, spec.fetch('appid'), 'www', 'manifest.json')))
distribute = exported.dig('app-ios', 'distribute') || {}
original = manifest.dig('app-ios', 'distribute') || {}
selection = spec.fetch('moduleSelection')
modules = selection.fetch('modules')
selection.fetch('ignored', {}).each { |name, reason| report.add('未启用', name, reason) }
selected = modules.keys.flat_map do |name|
  value = modules[name]
  if %w[uni-oauth uni-payment uni-share uni-location uni-getLocation uni-map].include?(name)
    value.is_a?(Hash) && !value.empty? ? value.keys.map { |provider| "#{name == 'uni-getLocation' ? 'uni-location' : name}-#{provider}" } : []
  else
    [name]
  end
end
base = %w[uni-getAppAuthorizeSetting uni-getAppBaseInfo uni-getDeviceInfo uni-getSystemInfo uni-getSystemSetting uni-openAppAuthorizeSetting uni-prompt uni-rpx2px uni-storage uni-theme uni-getElementById uni-crash uni-privacy uni-dialogPage uni-event uni-exit uni-actionSheet uni-modal uni-form uni-uasm uni-convert2AbsFullPath]
# 没有独立 Swift 文件、由 Vapor runtime/组件框架直接提供的模块。
runtime_modules = %w[uni-list-view uni-swiper uni-waterflow uni-rich-text uni-progress]
# 官方确认仅 Android 支持；导出清单可能包含跨平台引用，不生成 iOS 实现。
if selected.delete('uni-createRequestPermissionListener')
  puts '平台提示：uni-createRequestPermissionListener 仅 Android 支持，不提供 iOS 原生模块。'
end
dependencies = {
 'uni-showLoading'=>%w[uni-loading], 'uni-scanCode'=>%w[uni-barcode-scanning],
 'uni-barcode-scanning'=>%w[uni-camera], 'uni-camera'=>%w[uni-media],
 'uni-cloud-client'=>%w[uni-websocket uni-network uni-media], 'uni-verify'=>%w[uni-network],
 'uni-editor'=>%w[uni-web-view], 'uni-vibrate'=>[]
}
selected = (selected + base).uniq
loop do
  more = selected.flat_map { |m| dependencies.fetch(m, []) }
  more += ['uni-location'] if selected.any? { |m| m.start_with?('uni-location-') }
  %w[uni-payment uni-oauth uni-share].each { |m| more << m if selected.any? { |v| v.start_with?(m + '-') } }
  all = (selected + more).uniq
  break if all == selected
  selected = all
end
# Canvas 的桥接实现依赖 DCloudUTSExtAPI，必须放在独立模块中并注册。
canvas_selected = selected.any? { |m| %w[uni-canvas uni-canvas-dom2].include?(m) }
canvas_sources = canvas_selected ? [File.join(extsrc, 'uni-canvas-dom2-index.swift')] : []
source_files = []
selected.each do |mod|
  next if runtime_modules.include?(mod) || %w[uni-canvas uni-canvas-dom2].include?(mod)
  files = Dir[File.join(extsrc, mod + '-*.swift')]
  # 使用最长的已知模块前缀，避免父模块把所有 provider/VDOM 实现一并编入。
  files.reject! do |file|
    name = File.basename(file)
    (mod == 'uni-form' && name.include?('dom1')) || (mod == 'uni-ad' && !name.include?('dom2')) ||
      (%w[uni-payment uni-oauth uni-share uni-location].include?(mod) && name != mod + '-index.swift')
  end
  raise "不支持或缺少官方模块 #{mod} 的 Swift 源码" if files.empty?
  source_files.concat(files)
end
source_files.uniq!

# 外部依赖清单；其它 SDK 依赖由所选 Swift 文件的 import 精确解析。
extra_libs = {
 'uni-push'=>%w[GTCommonSDK.xcframework GTSDK.xcframework ZXSDK.framework],
 'uni-verify'=>%w[GTCommonSDK.xcframework GeYanSdk.xcframework],
 'uni-oauth-weixin'=>['WeChatSDK/libWeChatSDK.a'],
 'uni-share-weixin'=>['WeChatSDK/libWeChatSDK.a'],
 'uni-payment-wxpay'=>['WeChatSDK/libWeChatSDK.a'],
 'uni-requestMerchantTransfer'=>['WeChatSDK/libWeChatSDK.a'],
 'uni-payment-alipay'=>['AlipaySDK.xcframework'],
 'uni-video'=>['KTVHTTPCache.xcframework'],
 'uni-createInnerAudioContext'=>['KTVHTTPCache.xcframework'],
 'uni-getBackgroundAudioManager'=>['KTVHTTPCache.xcframework']
}
module_pods = {'uni-barcode-scanning'=>[{'name'=>'GoogleMLKit/BarcodeScanning','version'=>'~> 6.0.0'}]}
# 5.34 官方 ZIP 未捆绑个推/个验，使用厂商官方 CocoaPods，不能假装缺失的库已经集成。
module_pods['uni-push'] = [{'name'=>'GTSDK','version'=>'3.1.2.0'}] unless File.exist?(File.join(libs, 'GTSDK.xcframework'))
module_pods['uni-verify'] = [{'name'=>'GYSDK','version'=>'3.1.3.0'}] unless File.exist?(File.join(libs, 'GeYanSdk.xcframework'))
# 基础运行时只显式链接无敏感能力的基础系统库。功能库来自实际 Swift import、
# 所选静态 SDK 的依赖映射及插件 config.frameworks，不能默认注入蓝牙/追踪/定位。
system_libs = %w[UIKit Foundation JavaScriptCore Security SystemConfiguration CoreGraphics QuartzCore CoreMedia CoreVideo Metal MetalKit ImageIO Accelerate AudioToolbox CFNetwork CoreText]
system_imports = source_files.flat_map { |f| File.read(f).scan(/^\s*import\s+(\w+)/).flatten }.uniq
system_candidates = %w[CoreTelephony WebKit AVFoundation Photos PhotosUI UserNotifications AdSupport AuthenticationServices LocalAuthentication StoreKit CoreLocation CoreMotion MobileCoreServices UniformTypeIdentifiers Network CoreBluetooth AppTrackingTransparency CoreImage GLKit MediaPlayer]
system_libs |= system_imports & system_candidates
module_systems = {
 'uni-oauth-weixin'=>%w[WebKit], 'uni-share-weixin'=>%w[WebKit], 'uni-payment-wxpay'=>%w[WebKit],
 'uni-payment-alipay'=>%w[CoreTelephony CoreMotion], 'uni-rich-text'=>%w[CoreImage GLKit],
 'uni-media'=>%w[Photos AVFoundation CoreImage GLKit MediaPlayer],
 'uni-push'=>%w[UserNotifications CoreTelephony AdSupport], 'uni-verify'=>%w[Network CoreTelephony AdSupport]
}
selected.each { |m| system_libs |= module_systems.fetch(m, []) }
selected.each { |m| report.add('官方模块', m, selection.fetch('origins', {})[m] || (base.include?(m) ? 'Vapor 必需基础模块' : '已选模块的传递依赖 / provider')) }


project = Xcodeproj::Project.new(File.join(work, 'UniPackBuild.xcodeproj'))
project.root_object.attributes['LastUpgradeCheck'] = '1600'
app = project.new_target(:application, 'UniPackApp', :ios, '15.0')
core = project.new_target(:framework, 'DCloudUTSExtAPI', :ios, '15.0')
all_targets = [app, core]
frameworks_to_embed = {}
refs = {}
pods = {}
privacy_manifests = {}
resource_hashes = {}
integration_resources = []
required_classes = {}
info = {
 'CFBundleDisplayName'=>spec.fetch('name'), 'CFBundleName'=>spec.fetch('name'),
 'CFBundleIdentifier'=>'$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleExecutable'=>'$(EXECUTABLE_NAME)',
 'CFBundlePackageType'=>'APPL', 'CFBundleShortVersionString'=>spec.fetch('version'),
 'CFBundleVersion'=>spec.fetch('versionCode'), 'LSRequiresIPhoneOS'=>true,
 'UIMainStoryboardFile'=>'Main', 'UILaunchStoryboardName'=>'LaunchScreen', 'UIRequiredDeviceCapabilities'=>['arm64'],
 'UIApplicationSceneManifest'=>{'UIApplicationSupportsMultipleScenes'=>false,'UISceneConfigurations'=>{'UIWindowSceneSessionRoleApplication'=>[{'UISceneConfigurationName'=>'Default Configuration','UISceneDelegateClassName'=>'UniAppRootSceneDelegate'}]}},
 'uniapp-x'=>{'appid'=>spec.fetch('appid'),'ipatype'=>spec['kind']=='debug' ? 1 : 2,'uniRuntimeVersion'=>spec.fetch('hbuilderVersion'),'channel'=>spec['kind']=='debug' ? 'debug' : 'appstore','initPrivacyAuthorization'=>privacy_policy}
}
entitlements = original.dig('capabilities', 'entitlements') || {}

APP_PLIST_OVERRIDES = original.fetch('privacyDescription', {})
APP_LOCATION_PURPOSE = service_config && (service_config['locationPurpose'].to_s.empty? ? APP_PLIST_OVERRIDES['NSLocationWhenInUseUsageDescription'] : service_config['locationPurpose'])
def merge_value(a, b, trail = '')
  key = trail.split('.').last
  return APP_LOCATION_PURPOSE if trail.end_with?('NSLocationTemporaryUsageDescriptionDictionary.PurposeKey') && APP_LOCATION_PURPOSE.is_a?(String) && !APP_LOCATION_PURPOSE.empty?
  return APP_PLIST_OVERRIDES[key] if key && key.match?(/^NS.*UsageDescription$/) && APP_PLIST_OVERRIDES.key?(key)
  return b if a.nil?
  if a.is_a?(Hash) && b.is_a?(Hash)
    return a.merge(b) { |k, old, newv| merge_value(old, newv, trail + '.' + k) }
  end
  return (a + b).uniq if a.is_a?(Array) && b.is_a?(Array)
  return a if a == b
  raise "配置冲突 #{trail}: #{a.inspect} / #{b.inspect}"
end

def plist_read(file)
  Xcodeproj::Plist.read_from_path(file)
end

def dynamic_library?(path)
  if path.end_with?('.xcframework')
    desc = plist_read(File.join(path, 'Info.plist'))
    slice = desc.fetch('AvailableLibraries').find { |s| s['SupportedPlatform'] == 'ios' && !s.key?('SupportedPlatformVariant') }
    raise "依赖缺少 iOS 真机切片：#{path}" unless slice
    path = File.join(path, slice.fetch('LibraryIdentifier'), slice.fetch('LibraryPath'))
  end
  binary = path.end_with?('.framework') ? File.join(path, File.basename(path, '.framework')) : path
  output, status = Open3.capture2('/usr/bin/file', binary)
  raise "无法识别依赖：#{binary}" unless status.success?
  output.include?('dynamically linked shared library')
end

add_file = lambda do |target, path, phase|
  raise "缺少文件：#{path}" unless File.exist?(path)
  report.add('资源', File.basename(path), target.name + ' 的资源阶段') if phase == :resource
  ref = refs[path] ||= project.main_group.new_file(path)
  phase == :source ? target.source_build_phase.add_file_reference(ref, true) : target.resources_build_phase.add_file_reference(ref, true)
  ref
end
link = lambda do |target, path|
  raise "缺少依赖库：#{path}" unless File.exist?(path)
  ref = refs[path] ||= project.frameworks_group.new_file(path)
  target.frameworks_build_phase.add_file_reference(ref, true)
  dynamic = dynamic_library?(path)
  report.add(dynamic ? '动态库' : '静态库', File.basename(path), target.name + ' 链接' + (dynamic ? '，嵌入应用' : '，不单独嵌入'))
  frameworks_to_embed[path] = ref if dynamic
  ref
end
sys_link = lambda do |target, name|
  name = File.basename(name)
  name = "#{name}.framework" unless name.end_with?('.framework', '.tbd', '.dylib')
  origins = module_systems.select { |m, fs| selected.include?(m) && fs.include?(name.delete_suffix('.framework')) }.keys
  origins << '所选 Swift 源码 import' if system_imports.include?(name.delete_suffix('.framework'))
  origins << (target.name.start_with?('unimodule') ? '插件 config.frameworks' : 'Vapor 基础 / 所选静态库的系统依赖') if origins.empty?
  report.add('系统库', name, target.name + '；' + origins.join(' / '))
  if name.end_with?('.framework')
    target.add_system_framework(name.delete_suffix('.framework'))
  else
    ref = refs[name] ||= project.frameworks_group.new_file("usr/lib/#{name}", :sdk_root)
    target.frameworks_build_phase.add_file_reference(ref, true)
  end
end
base_frameworks = %w[DCloudUTSFoundation.xcframework DCloudUniappRuntime.xcframework DCloudUniExtComponent.xcframework SDWebImage.xcframework KSCrash.xcframework storage.xcframework]
base_frameworks << 'DCloudDebugServe.xcframework' if spec['kind'] == 'debug'
base_frameworks.each { |f| [app, core].each { |t| link.call(t, File.join(libs, f)) } }
source_files.each { |s| add_file.call(core, s, :source) }
add_file.call(core, File.join(extsrc, 'UTSOC.mm'), :source)
umbrella = File.join(work, 'DCloudUTSExtAPI.h')
umbrella_text = "#import <Foundation/Foundation.h>\n#import \"UTSOC.h\"\n"
umbrella_text += "#import \"WXApi.h\"\n#import \"WXApiObject.h\"\n" if selected.any? { |m| %w[uni-oauth-weixin uni-share-weixin uni-payment-wxpay uni-requestMerchantTransfer].include?(m) }
File.write(umbrella, umbrella_text)
public_header = project.main_group.new_file(umbrella)
core.headers_build_phase.add_file_reference(public_header, true).settings = {'ATTRIBUTES'=>['Public']}
header = project.main_group.new_file(File.join(extsrc, 'UTSOC.h'))
core.headers_build_phase.add_file_reference(header, true).settings = {'ATTRIBUTES'=>['Public']}
selected.each do |m|
  extra_libs.fetch(m, []).each do |f|
    next if module_pods.key?(m) && %w[uni-push uni-verify].include?(m)
    link.call(core, File.join(libs, f))
  end
end
# 从 import 识别 SDK 自带模块，避免把所有广告等无关 SDK 加入包。
source_files.each do |s|
  File.read(s).scan(/(?:@_implementationOnly\s+)?import\s+([A-Za-z_][\w]*)/).flatten.uniq.each do |name|
    next if name == 'DCloudUTSExtAPI'
    candidate = Dir[File.join(libs, name + '.{xcframework,framework}')].first
    link.call(core, candidate) if candidate
  end
end
system_libs.each { |s| [app, core].each { |t| sys_link.call(t, s) } }
%w[libc++.tbd libz.tbd libresolv.tbd libsqlite3.tbd].each { |s| [app, core].each { |t| sys_link.call(t, s) } }
selected.each { |m| pods['DCloudUTSExtAPI'] = (pods.fetch('DCloudUTSExtAPI', []) + module_pods.fetch(m, [])).uniq }

# 精确注册所选的官方模块，复用 SDK 中的注册配置并过滤未编译的类。
config_example = Dir[File.join(spec.fetch('sdk'), 'TemporarySampleFramework', 'DCloudUTSExtAPI.xcframework', 'ios-arm64', '*.framework', 'uts-config.json')].first
raise 'SDK 缺少官方 uts-config.json 注册模板' unless config_example
registration = JSON.parse(File.read(config_example))
combined_source = source_files.map { |f| File.read(f) }.join("\n")
registration.transform_values! do |list|
  list.select do |entry|
    names = entry.is_a?(Hash) ? [entry['delegateClass'], entry['class']].compact : [entry]
    names.all? { |n| combined_source.include?(n) }
  end
end
File.write(File.join(work, 'uts-config.json'), JSON.pretty_generate(registration))
add_file.call(core, File.join(work, 'uts-config.json'), :resource)

# 与官方 Vapor 云包一致：Canvas 使用独立的动态库和 +load 注册入口。
canvas = nil
if canvas_selected
  canvas = project.new_target(:framework, 'DCloudUTSExtCanvas', :ios, '15.0')
  all_targets << canvas
  canvas_sources.each { |f| add_file.call(canvas, f, :source) }
  generated = File.join(work, 'Generated', canvas.name); FileUtils.mkdir_p(generated)
  %w[UTSOC.h UTSOC.mm].each do |f|
    text = File.read(File.join(extsrc, f)).gsub('UTSOCDCloudUTSExtAPI', 'UTSOCDCloudUTSExtCanvas').gsub('DCloudUTSConfig', 'DCloudUTSCanvasConfig')
    File.write(File.join(generated, f), text)
  end
  add_file.call(canvas, File.join(generated, 'UTSOC.mm'), :source)
  header = project.main_group.new_file(File.join(generated, 'UTSOC.h'))
  canvas.headers_build_phase.add_file_reference(header, true).settings = {'ATTRIBUTES'=>['Public']}
  canvas.add_dependency(core)
  canvas.frameworks_build_phase.add_file_reference(core.product_reference, true)
  %w[DCloudUTSFoundation.xcframework DCloudUniappRuntime.xcframework DCloudUniCanvas.xcframework].each { |f| link.call(canvas, File.join(libs, f)) }
  system_libs.each { |f| sys_link.call(canvas, f) }
  config = File.join(generated, 'uts-config.json')
  File.write(config, JSON.pretty_generate({'components'=>[{'delegateClass'=>'UniCanvasElementRegister'}]}))
  add_file.call(canvas, config, :resource)
  required_classes['Frameworks/DCloudUTSExtCanvas.framework/DCloudUTSExtCanvas'] = %w[UniCanvasElementRegister DCloudUTSCanvasConfig]
end

plugin_targets = {}
Dir[File.join(resources, 'uni_modules', '*')].sort.each do |plugin|
  ios = File.join(plugin, 'utssdk', 'app-ios')
  next unless File.directory?(ios)
  name = File.basename(plugin)
  raise "不支持插件 Extension，请先移除或单独接入：#{name}" if File.directory?(File.join(ios, 'Extensions'))
  sources = Dir[File.join(ios, 'src', '**', '*.{swift,m,mm,c,cpp}')]
  raise "插件 #{name} 无导出的原生源码，可能是普通授权加密插件，不能离线集成" if sources.empty?
  product = 'unimodule' + name.split('-').map { |p| p[0].upcase + p[1..] }.join
  cfg_file = File.join(ios, 'config.json')
  cfg = File.exist?(cfg_file) ? JSON.parse(File.read(cfg_file)) : {}
  deployment = [15.0, cfg.fetch('deploymentTarget', '15.0').to_f].max.to_s
  target = project.new_target(:framework, product, :ios, deployment)
  all_targets << target; plugin_targets[name] = target
  report.add('UTS 插件', name, 'HBuilderX 本次导出，生成 ' + product)
  sources.each { |s| add_file.call(target, s, :source) }
  generated = File.join(work, 'Generated', product); FileUtils.mkdir_p(generated)
  %w[UTSOC.h UTSOC.mm].each do |f|
    text = File.read(File.join(extsrc, f)).gsub('UTSOCDCloudUTSExtAPI', 'UTSOC' + product).gsub('DCloudUTSConfig', product + 'UTSConfig')
    File.write(File.join(generated, f), text)
  end
  add_file.call(target, File.join(generated, 'UTSOC.mm'), :source)
  plugin_header = project.main_group.new_file(File.join(generated, 'UTSOC.h'))
  target.headers_build_phase.add_file_reference(plugin_header, true).settings = {'ATTRIBUTES'=>['Public']}
  target.add_dependency(core)
  target.frameworks_build_phase.add_file_reference(core.product_reference, true)
  base_frameworks.reject { |f| f == 'DCloudDebugServe.xcframework' }.each { |f| link.call(target, File.join(libs, f)) }
  (cfg['frameworks'] || []).each { |f| sys_link.call(target, f) }
  Dir[File.join(ios, 'Frameworks', '*.{framework,xcframework}'), File.join(ios, 'Libs', '*.a')].flatten.each { |f| link.call(target, f) }
  [File.join(ios, 'Resources'), File.join(ios, 'EmbedResources')].each do |folder|
    next unless File.directory?(folder)
    Dir.children(folder).reject { |f| f.start_with?('.') || f == '_CodeSignature' }.each { |f| add_file.call(folder.end_with?('EmbedResources') ? target : app, File.join(folder, f), :resource) }
  end
  %w[Info.plist UTS.entitlements PrivacyInfo.xcprivacy].each do |f|
    path = File.join(ios, f); next unless File.file?(path)
    d = plist_read(path)
    if f == 'Info.plist' then info = merge_value(info, d.reject { |key,_| %w[CFBundleShortVersionString CFBundleVersion].include?(key) })
    elsif f == 'UTS.entitlements' then entitlements = merge_value(entitlements, d)
    else privacy_manifests[target.name] = d
    end
  end
  info = merge_value(info, cfg.fetch('plists', {}).reject { |key,_| %w[CFBundleShortVersionString CFBundleVersion].include?(key) })
  reg = {}
  reg['hooksClasses'] = Array(cfg['hooksClass']) if cfg['hooksClass']
  reg['providers'] = cfg['provider'].is_a?(Array) ? cfg['provider'] : [cfg['provider']] if cfg['provider']
  reg['components'] = cfg['components'] if cfg['components']
  pf = File.join(generated, 'uts-config.json'); File.write(pf, JSON.pretty_generate(reg))
  add_file.call(target, pf, :resource)
  pods[product] = cfg.fetch('dependencies-pods', [])
  Array(cfg['dependencies-spms']).each do |dep|
    package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    package.repositoryURL = dep.fetch('url')
    requirement = dep.reject { |k, _| %w[name url].include?(k) }
    package.requirement = requirement
    project.root_object.package_references << package
    product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    report.add('SPM 声明', dep.fetch('name'), '插件 ' + name + '；版本由 Package.resolved 锁定')
    product_dep.package = package; product_dep.product_name = dep.fetch('name')
    target.package_product_dependencies << product_dep
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile); build_file.product_ref = product_dep; target.frameworks_build_phase.files << build_file
  end
  target.build_configurations.each do |c|
    c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = cfg['identifier'] || "#{spec.fetch('bundle')}.#{product}"
    c.build_settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)', "#{libs}/**", "#{ios}/Frameworks/**"]
    c.build_settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', "#{libs}/WeChatSDK", "#{ios}/**"]
  end
end
# 从导出插件的 Swift import 建立插件间依赖，保持模块名与 HBuilderX 生成名称一致。
plugin_targets.each do |name, target|
  ios = File.join(resources, 'uni_modules', name, 'utssdk', 'app-ios')
  text = Dir[File.join(ios, 'src', '**', '*.swift')].map { |f| File.read(f) }.join("\n")
  [canvas, *plugin_targets.values].compact.each do |dep|
    next if dep == target || !text.match?(/import\s+#{Regexp.escape(dep.name)}\b/)
    target.add_dependency(dep); target.frameworks_build_phase.add_file_reference(dep.product_reference, true)
  end
end
[core, canvas, *plugin_targets.values].compact.each do |t|
  app.add_dependency(t); app.frameworks_build_phase.add_file_reference(t.product_reference, true)
  frameworks_to_embed[t.product_reference.path] = t.product_reference
  report.add('动态库', t.product_reference.path, '本次源码生成，嵌入主应用')
end
embed = app.new_copy_files_build_phase('Embed Frameworks'); embed.dst_subfolder_spec = '10'
frameworks_to_embed.values.uniq.each { |ref| embed.add_file_reference(ref, true).settings = {'ATTRIBUTES'=>['CodeSignOnCopy','RemoveHeadersOnCopy']} }
# 原生资源采用 folder reference，保留 AppID/www 目录结构。
apps_folder = File.join(work, 'uni-app-x', 'apps'); FileUtils.rm_rf(apps_folder); FileUtils.mkdir_p(apps_folder)
FileUtils.cp_r(File.join(resources, spec.fetch('appid')), apps_folder)
# 本地导出可能省略 app 节点；只补任务副本，保持 SDK / 源工程 / HBuilderX 导出原件不变。
resource_manifest = File.join(apps_folder, spec.fetch('appid'), 'www', 'manifest.json')
raise '任务资源 manifest 不能通过符号链接指向工作目录外' unless !File.symlink?(resource_manifest) && File.realpath(resource_manifest).start_with?(File.realpath(work) + '/')
packaged_manifest = JSON.parse(File.read(resource_manifest))
packaged_manifest['app'] = {} unless packaged_manifest.key?('app')
raise '导出资源 manifest.app 必须是对象' unless packaged_manifest['app'].is_a?(Hash)
packaged_manifest['app']['initPrivacyAuthorization'] = privacy_policy
# GUI 的原生配置也同步到任务资源副本，避免包内残留旧微信身份 / 回调设置。
packaged_manifest['app-ios'] = {} unless packaged_manifest['app-ios'].is_a?(Hash)
packaged_manifest['app-ios']['distribute'] ||= {}
%w[modules urltypes devices capabilities privacyDescription].each do |key|
  packaged_manifest['app-ios']['distribute'][key] = original[key] if original.key?(key)
end
File.write(resource_manifest, JSON.pretty_generate(packaged_manifest))
ref = project.main_group.new_file(File.join(work, 'uni-app-x')); ref.last_known_file_type = 'folder'; app.resources_build_phase.add_file_reference(ref, true)
# SDK 资源必须随其模块进入主应用，不能只复制提示框资源。
resource_modules = {
 'uni-prompt'=>%w[uni-prompt.bundle],
 'uni-media'=>%w[DCTZImagePickerController.bundle DCMediaEditingController.bundle],
 'uni-verify'=>%w[TYRZResource.bundle],
 'uni-map-tencent'=>%w[uni-map-tencent.bundle]
}
selected.flat_map { |m| resource_modules.fetch(m, []) }.uniq.each do |name|
  path = File.join(sdk, 'Resources', name)
  add_file.call(app, path, :resource)
  # 记录实际文件清单；仅目录存在不能证明图片、nib 等内容完整。
  Dir[File.join(path, '**', '*')].select { |f| File.file?(f) }.each do |f|
    relative = f.delete_prefix(File.join(sdk, 'Resources') + '/')
    integration_resources << relative
    resource_hashes[relative] = Digest::SHA256.file(f).hexdigest
  end
end
# Vapor 控件字体不在官方 SDK/Resources 中；随工具保存与基线 HBuilderX 完全一致的原始字体。
font_metadata = JSON.parse(File.read(File.join(__dir__, 'iOS', 'uni-static', 'provenance.json')))
font_files = {'uni-scanCode'=>'uni-scanCode.ttf', 'uni-video'=>'uni-video-icon.ttf'}
font_files.each do |mod, filename|
  next unless selected.include?(mod)
  relative = "uni-static/#{mod}/static/font/#{filename}"
  candidates = [File.join(resources, relative), File.join(sdk, 'Resources', relative), File.join(sdk, relative)]
  source = candidates.find { |f| File.file?(f) }
  unless source
    raise "#{mod} 字体缺失：请导入与 HBuilderX 匹配且含 uni-static 的 SDK" unless spec.fetch('hbuilderVersion') == font_metadata.fetch('hbuilderVersion')
    source = File.join(__dir__, 'iOS', relative)
    raise "UniPack 内置字体校验失败：#{relative}" unless Digest::SHA256.file(source).hexdigest == font_metadata.fetch('files').fetch(relative)
  end
  destination = File.join(work, relative); FileUtils.mkdir_p(File.dirname(destination)); FileUtils.cp(source, destination)
  integration_resources << relative
  resource_hashes[relative] = Digest::SHA256.file(destination).hexdigest
  report.add('控件字体', relative, mod + ' 的 Vapor 运行时字体；来源 HBuilderX / 匹配 SDK')
end
if font_files.keys.any? { |m| selected.include?(m) }
  ref = project.main_group.new_file(File.join(work, 'uni-static')); ref.last_known_file_type = 'folder'
  app.resources_build_phase.add_file_reference(ref, true)
end
# 原生主入口使用 SDK 的根控制器，不能照搬 SDK 宿主示例的导航页面。
%w[Main LaunchScreen].each do |name|
  folder = File.join(work, 'Base.lproj'); FileUtils.mkdir_p(folder)
  path = File.join(folder, name + '.storyboard')
  FileUtils.cp(File.join(__dir__, 'iOS', name + '.storyboard'), path)
  add_file.call(app, path, :resource)
end
# 用官方独立应用入口，保留运行时生命周期、推送与 deep link 的转发链。
app_source = File.join(work, 'AppDelegate.swift')
File.write(app_source, "import UIKit\nimport DCloudUniappRuntime\n@main\nclass AppDelegate: UniAppRootAppDelegate {}\n")
add_file.call(app, app_source, :source)
info = merge_value(info, original.fetch('privacyDescription', {}))
%w[UIBackgroundModes].each { |k| info[k] = original[k].is_a?(String) ? original[k].split(',') : original[k] if original[k] }
{'urltypes'=>'CFBundleURLTypes','urlschemewhitelist'=>'LSApplicationQueriesSchemes'}.each do |key, dest|
  next unless original[key]
  values = original[key].is_a?(String) ? original[key].split(',').map(&:strip) : original[key]
  info[dest] = key == 'urltypes' ? [{'CFBundleURLName'=>spec.fetch('bundle'), 'CFBundleURLSchemes'=>values}] : values
end
entitlements = merge_value(entitlements, spec.fetch('requiredEntitlements', {}))
# manifest 的 provider 参数必须进入 SDK 实际读取的 Info.plist 节点。
wechat = {}
[['uni-oauth','weixin'],['uni-share','weixin'],['uni-payment','wxpay']].each do |mod, provider|
  value = modules.dig(mod, provider)
  next unless value.is_a?(Hash)
  wechat = merge_value(wechat, value.select { |k,_| %w[appid universalLink].include?(k) }, '.WeChat')
end
unless wechat.empty?
  info['WeChat'] = merge_value(info['WeChat'], wechat, '.WeChat')
  schemes = info.fetch('CFBundleURLTypes', []).flat_map { |t| t.fetch('CFBundleURLSchemes', []) }
  schemes << wechat['appid'] if wechat['appid']
  info['CFBundleURLTypes'] = [{'CFBundleURLName'=>spec.fetch('bundle'),'CFBundleURLSchemes'=>schemes.compact.uniq}]
  info['LSApplicationQueriesSchemes'] = (info.fetch('LSApplicationQueriesSchemes', []) + %w[weixin weixinULAPI weixinURLParamsAPI]).uniq
end
if selected.include?('uni-payment-alipay')
  scheme = service_config && service_config['alipayScheme'].to_s
  scheme = 'alipay' + spec.fetch('bundle').gsub(/[^A-Za-z0-9]/, '') if !scheme || scheme.empty?
  info['CFBundleURLTypes'] = info.fetch('CFBundleURLTypes', []) + [{'CFBundleURLName'=>'alipay','CFBundleURLSchemes'=>[scheme]}]
  params = modules.dig('uni-payment', 'alipay') || {}
  info['Alipay'] = params.select { |k,_| k == 'universalLink' } unless params.empty?
  info['LSApplicationQueriesSchemes'] = (info.fetch('LSApplicationQueriesSchemes', []) + %w[alipay alipays]).uniq
end
root_info = File.join(spec.fetch('project'), 'Info.plist')
# 应用版本由本次构建快照统一提供，附加 plist 不覆盖它。
if File.file?(root_info)
  root_values = plist_read(root_info).reject { |key,_| %w[CFBundleShortVersionString CFBundleVersion].include?(key) }
  if service_config
    # GUI 参数具有明确优先级；不再由工程中的旧服务身份覆盖任务快照。
    root_values.reject! { |key,_| (%w[getui geyan WeChat Alipay TencentLBSAPIKey UIDeviceFamily CFBundleURLTypes] + service_config.fetch('plist').keys).include?(key) }
  end
  info = merge_value(info, root_values)
end
if service_config
  %w[getui geyan WeChat Alipay TencentLBSAPIKey].each { |key| info.delete(key) }
  service_config.fetch('plist').each { |key,value| info[key] = value }
  if service_config.key?('locationPurpose')
    dictionary = info['NSLocationTemporaryUsageDescriptionDictionary'] || {}
    raise '临时定位用途必须为字典' unless dictionary.is_a?(Hash)
    text = service_config['locationPurpose'].to_s
    text.empty? ? dictionary.delete('PurposeKey') : dictionary['PurposeKey'] = text
    info['NSLocationTemporaryUsageDescriptionDictionary'] = dictionary
  end
  report.add('服务配置', 'iOS 项目参数快照', '来自 GUI 加密缓存或工程配置；只注入已启用服务，敏感值不写入依赖清单')
end
device_families = IOSModuleIntegration.device_families(original['devices'], info['UIDeviceFamily'])
info.delete('UIDeviceFamily') # 由 TARGETED_DEVICE_FAMILY 写入最终 Info.plist，不与 Xcode 重复定义。
report.add('设备范围', device_families.map { |v| v == 1 ? 'iPhone' : 'iPad' }.join(' + '), 'manifest.app-ios.distribute.devices；未配置 / auto 默认 iPhone')
if selected.include?('uni-location-system')
  purpose = IOSModuleIntegration.location_purpose(info)
  report.add('定位用途', 'NSLocationTemporaryUsageDescriptionDictionary.PurposeKey', '系统定位临时精确定位；保留显式配置，否则使用项目已有的前台定位用途文案')
end
# 与云包一致，允许支持 ProMotion 的 iPhone 使用高刷新率。
# 放在所有 plist 合并之后：未配置时补默认值，保留明确配置的 true / false。
refresh_key = 'CADisableMinimumFrameDurationOnPhone'
info[refresh_key] = true unless info.key?(refresh_key)
raise "#{refresh_key} 必须是布尔值" unless [true, false].include?(info[refresh_key])
high_refresh_rate = info.fetch(refresh_key)
report.add('刷新率支持', refresh_key + '=' + high_refresh_rate.to_s,
 high_refresh_rate ? '允许 ProMotion 高刷新率；实际帧率由系统、设备能力和每帧工作量决定' : '项目或插件 plist 显式关闭高刷新率')
# 与 HBuilderX 云打包保持一致：iPhone 遵循页面方向，iPad 多任务补齐四个方向。
# 在合并插件和项目 Info.plist 后应用默认值，保留显式的全屏配置。
all_orientations = %w[UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight]
page_orientation = spec.fetch('pageOrientation', 'portrait')
raise "不支持的 globalStyle.pageOrientation：#{page_orientation}" unless %w[portrait landscape auto].include?(page_orientation)
phone_defaults = {
 'portrait'=>['UIInterfaceOrientationPortrait'],
 'landscape'=>%w[UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight],
 'auto'=>%w[UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight]
}
pad_default = !spec.key?('pageOrientation') || page_orientation == 'auto' ? all_orientations :
 (page_orientation == 'portrait' ? all_orientations.take(2) : all_orientations.drop(2))
%w[UISupportedInterfaceOrientations UISupportedInterfaceOrientations~iphone UISupportedInterfaceOrientations~ipad].each do |key|
 next unless info.key?(key)
 value = info[key]
 raise "#{key} 必须是有效且非空的屏幕方向数组" unless value.is_a?(Array) && !value.empty? && (value - all_orientations).empty?
end
info['UISupportedInterfaceOrientations~iphone'] ||= info['UISupportedInterfaceOrientations'] || phone_defaults.fetch(page_orientation)
info['UISupportedInterfaceOrientations~ipad'] ||= info['UISupportedInterfaceOrientations'] || pad_default
info['UISupportedInterfaceOrientations'] ||= info['UISupportedInterfaceOrientations~iphone']
unless info['UIRequiresFullScreen'] == true && !info.key?('UIRequiresFullScreenIgnoredStartingWithVersion')
 info['UISupportedInterfaceOrientations~ipad'] = all_orientations
end
if selected.include?('uni-push')
  params = info['getui']
  raise 'uni-push 缺少 Info.plist/getui 配置：需要 appid、appKey、appSecret' unless params.is_a?(Hash) && %w[appid appKey appSecret].all? { |k| params[k].is_a?(String) && !params[k].empty? }
end
if selected.include?('uni-verify')
  raise 'uni-verify 缺少 Info.plist/geyan/appid 配置' if info.dig('geyan','appid').to_s.empty?
end
# 这些库通过 Objective-C 动态查找/分类注册，Swift import 扫描无法发现。
# 静态库仅链接主应用一次，避免每个插件都携带一份实现。
static_providers = []
static_providers << ['RTRichText', 'RTRichTextEngine'] if selected.include?('uni-rich-text')
permission_rules = {
 'Album'=>['NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription'],
 'Camera'=>['NSCameraUsageDescription'],
 'Location'=>['NSLocationWhenInUseUsageDescription', 'NSLocationAlwaysAndWhenInUseUsageDescription', 'NSLocationAlwaysUsageDescription'],
 'Microphone'=>['NSMicrophoneUsageDescription'],
 'Bluetooth'=>['NSBluetoothAlwaysUsageDescription', 'NSBluetoothPeripheralUsageDescription'],
 'IDFA'=>['NSUserTrackingUsageDescription']
}
permission_rules.each do |name, keys|
  if %w[Bluetooth IDFA].include?(name)
    framework = name == 'Bluetooth' ? 'CoreBluetooth' : 'AppTrackingTransparency'
    next unless system_imports.include?(framework) || all_targets.any? { |t| t.frameworks_build_phase.files_references.any? { |ref| File.basename(ref.path.to_s) == framework + '.framework' } }
  end
  static_providers << ["DCloudPermission#{name}", "DCloudPermission#{name}Provider"] if keys.any? { |key| info[key].is_a?(String) && !info[key].empty? }
end
static_providers << ['DCloudPermissionPush', 'DCloudPermissionPushProvider'] if selected.include?('uni-push')
static_providers.each do |name, _|
  path = File.join(libs, name + '.xcframework')
  raise "#{name} 必须为静态库，当前 SDK 的布局需要重新适配" if dynamic_library?(path)
  link.call(app, path)
end
required_classes['UniPackApp'] = static_providers.map(&:last)
# 富文本引擎及权限提供器的系统依赖。
permission_systems = {'Album'=>'Photos', 'Camera'=>'AVFoundation', 'Location'=>'CoreLocation', 'Microphone'=>'AVFoundation', 'Bluetooth'=>'CoreBluetooth', 'IDFA'=>'AppTrackingTransparency', 'Push'=>'UserNotifications'}
static_providers.each do |name, _|
  system = permission_systems[name.delete_prefix('DCloudPermission')]
  sys_link.call(app, system) if system
end
# 官方媒体 / 微信声明属于 DCloudUTSExtAPI；每个插件清单仍保存在插件本身。
privacy_template = Dir[File.join(spec.fetch('sdk'), 'TemporarySampleFramework', 'DCloudUTSExtAPI.xcframework', 'ios-arm64', '*.framework', 'PrivacyInfo.xcprivacy')].first
raise 'SDK 缺少官方模块隐私模板' unless privacy_template
privacy_manifests[core.name] = IOSModuleIntegration.core_privacy(plist_read(privacy_template), selected)
privacy_manifests[canvas.name] = IOSModuleIntegration.empty_privacy if canvas
app_privacy = File.join(spec.fetch('project'), 'PrivacyInfo.xcprivacy')
privacy_manifests[app.name] = plist_read(app_privacy) if File.file?(app_privacy)
privacy_requirements = {}
privacy_manifests.each do |target_name, document|
  target = all_targets.find { |t| t.name == target_name }
  raise "隐私清单目标不存在：#{target_name}" unless target
  IOSModuleIntegration.validate_privacy(document, target_name)
  file = File.join(work, 'Generated', target_name, 'PrivacyInfo.xcprivacy'); FileUtils.mkdir_p(File.dirname(file))
  Xcodeproj::Plist.write_to_path(document, file); add_file.call(target, file, :resource)
  relative = target == app ? 'PrivacyInfo.xcprivacy' : "Frameworks/#{target_name}.framework/PrivacyInfo.xcprivacy"
  privacy_requirements[relative] = document
  report.add('隐私清单', relative, target == core ? '官方 SDK 模板按实际媒体 / 微信模块选取声明' : '所属目标独立携带，保留原始声明')
end
required_frameworks = frameworks_to_embed.values.map { |ref| File.basename(ref.path).sub(/\.xcframework$/, '.framework') }.uniq.sort
service_hashes = {}
if service_config
  %w[getui geyan WeChat Alipay].each do |root|
    (info[root] || {}).each { |key,value| service_hashes[root + '.' + key] = Digest::SHA256.hexdigest(value) if value.is_a?(String) }
  end
  service_hashes['TencentLBSAPIKey'] = Digest::SHA256.hexdigest(info['TencentLBSAPIKey']) if info['TencentLBSAPIKey'].is_a?(String)
end
requirements = {
 'schemaVersion'=>1, 'resources'=>integration_resources.sort,
 'frameworks'=>required_frameworks, 'classes'=>required_classes,
 'canvas'=>canvas_selected, 'initialPrivacyAuthorization'=>privacy_policy, 'highRefreshRate'=>high_refresh_rate,
 'serviceHashes'=>service_hashes, 'resourceHashes'=>resource_hashes, 'privacyManifests'=>privacy_requirements, 'deviceFamilies'=>device_families,
 'temporaryLocationPurpose'=>purpose
}
requirements_file = File.join(work, 'UniPackIntegration.json')
File.write(requirements_file, JSON.pretty_generate(requirements))
add_file.call(app, requirements_file, :resource)
custom_ent = spec['entitlementPath']
entitlements = merge_value(entitlements, plist_read(custom_ent)) if custom_ent && !custom_ent.empty?
Xcodeproj::Plist.write_to_path(info, File.join(work, 'Info.plist'))
Xcodeproj::Plist.write_to_path(entitlements, File.join(work, 'App.entitlements'))
icon = original.dig('icons', 'appstore')
if icon && !icon.empty?
  source_icon = File.expand_path(icon, spec.fetch('project'))
  raise "应用图标不存在：#{source_icon}" unless File.file?(source_icon)
  assets = File.join(work, 'Assets.xcassets'); appicon = File.join(assets, 'AppIcon.appiconset'); FileUtils.mkdir_p(appicon)
  FileUtils.cp(source_icon, File.join(appicon, 'AppIcon.png'))
  File.write(File.join(appicon, 'Contents.json'), JSON.generate({'images'=>[{'filename'=>'AppIcon.png','idiom'=>'universal','platform'=>'ios','size'=>'1024x1024'}],'info'=>{'author'=>'xcode','version'=>1}}))
  add_file.call(app, assets, :resource)
  app.build_configurations.each { |c| c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon' }
elsif spec['kind'] != 'debug'
  raise '正式包需要配置 app-ios.distribute.icons.appstore 图标'
end
# 所有 target 的架构、部署版本、签名与运行库路径保持一致。
deployment = all_targets.map { |t| t.deployment_target.to_f }.max.to_s
all_targets.each do |t|
  t.build_configurations.each do |c|
    s = c.build_settings
    s['IPHONEOS_DEPLOYMENT_TARGET'] = deployment
    s['SWIFT_VERSION'] = '5.0'; s['SWIFT_STRICT_CONCURRENCY'] = 'minimal'; s['SWIFT_OPTIMIZATION_LEVEL'] = spec['kind']=='debug' ? '-Onone' : '-O'
    s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'; s['ENABLE_MODULE_VERIFIER'] = 'NO'
    s['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'YES' if t != app
    s['SKIP_INSTALL'] = t == app ? 'NO' : 'YES'; s['DEFINES_MODULE'] = 'YES'; s['CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'] = 'YES'
    s['GENERATE_INFOPLIST_FILE'] = 'YES' if t != app
    s['MARKETING_VERSION'] = spec.fetch('version')
    s['CURRENT_PROJECT_VERSION'] = spec.fetch('versionCode')
    s['ARCHS'] = 'arm64'; s['SUPPORTED_PLATFORMS'] = 'iphoneos'; s['TARGETED_DEVICE_FAMILY'] = device_families.join(',')
    s['OTHER_LDFLAGS'] = ['$(inherited)', '-ObjC']
    s['FRAMEWORK_SEARCH_PATHS'] ||= ['$(inherited)', '$(BUILT_PRODUCTS_DIR)', "#{libs}/**"]
    s['HEADER_SEARCH_PATHS'] ||= ['$(inherited)', "#{libs}/WeChatSDK"]
    s['LIBRARY_SEARCH_PATHS'] = ['$(inherited)', "#{libs}/WeChatSDK"]
    s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
    %w[FRAMEWORK_SEARCH_PATHS HEADER_SEARCH_PATHS LIBRARY_SEARCH_PATHS].each do |key|
      s[key] = Array(s[key]).map { |value| value == '$(inherited)' ? value : '"' + value + '"' }
    end
    s['CODE_SIGNING_ALLOWED'] = 'NO'; s['CODE_SIGNING_REQUIRED'] = 'NO'; s['CODE_SIGN_IDENTITY'] = ''
    s['PRODUCT_BUNDLE_IDENTIFIER'] ||= "#{spec.fetch('bundle')}.#{t.name}"
    if t == app
      s['PRODUCT_BUNDLE_IDENTIFIER'] = spec.fetch('bundle'); s['INFOPLIST_FILE'] = File.join(work, 'Info.plist')
      s['CODE_SIGN_ENTITLEMENTS'] = File.join(work, 'App.entitlements')
    end
  end
end
# 蓝牙 / 跟踪能力真实被引入时必须有用途说明；不能伪造通用文案。
{'CoreBluetooth.framework'=>'NSBluetoothAlwaysUsageDescription', 'AppTrackingTransparency.framework'=>'NSUserTrackingUsageDescription'}.each do |framework, key|
  linked = all_targets.any? { |t| t.frameworks_build_phase.files_references.any? { |ref| File.basename(ref.path.to_s) == framework } }
  raise "#{framework} 已由模块或插件引入，但主应用缺少 #{key}；请填写真实用途说明" if linked && info[key].to_s.strip.empty?
end
info.keys.grep(/^NS.*UsageDescription$/).each { |key| report.add('隐私用途声明', key, '合并后的主应用 Info.plist；声明不代表启用该能力') }
pods.each { |target, ds| ds.each { |d| report.add('CocoaPods 声明', [d['name'],d['version']].compact.join(' '), target) } }
report.add('隐私启动策略', privacy_policy, 'manifest.app.initPrivacyAuthorization 原样写入 Info.plist 和包内资源；弹窗与同意按钮由业务实现')
report.note('静态库已链接进可执行文件；系统库由 iOS 提供，未复制进 IPA。')
report.note('Pods / SPM 的实际版本及归档 Framework 在构建结束后补充。')
report.write(work)
project.save
scheme = Xcodeproj::XCScheme.new; scheme.add_build_target(app); scheme.set_launch_target(app); scheme.archive_action.build_configuration = spec['kind']=='debug' ? 'Debug' : 'Release'; scheme.save_as(project.path, 'UniPackApp', true)
FileUtils.mkdir_p(File.join(work, 'UniPackBuild.xcworkspace'))
File.write(File.join(work, 'UniPackBuild.xcworkspace', 'contents.xcworkspacedata'), '<Workspace version="1.0"><FileRef location="group:UniPackBuild.xcodeproj"/></Workspace>')
unless pods.values.all?(&:empty?)
  content = "platform :ios, '#{deployment}'\nworkspace 'UniPackBuild'\nproject 'UniPackBuild.xcodeproj'\nuse_frameworks! :linkage => :static\ntarget 'UniPackApp' do\n"
  pods.each do |name, deps|
    next if deps.empty?
    content << "target #{name.dump} do\n"
    deps.each do |d|
      raise "无效 pod 配置" unless d.is_a?(Hash) && d['name']
      unsupported = d.keys - %w[name version]
      raise "尚未适配的 pod 配置字段：#{unsupported.join(',')}" unless unsupported.empty?
      content << "  pod #{d['name'].dump}"
      content << ", #{d['version'].dump}" if d['version'] && !d['version'].empty?
      content << "\n"
    end
    content << "end\n"
  end
  content << "end\n"
  content << <<~HOOK
    post_install do |installer|
      installer.pods_project.targets.each do |target|
        target.build_configurations.each do |config|
          minimum = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_s
          if minimum.empty? || Gem::Version.new(minimum) < Gem::Version.new('#{deployment}')
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '#{deployment}'
          end
          config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
        end
      end
    end
  HOOK
  File.write(File.join(work, 'Podfile'), content)
end
File.write(File.join(work, 'integration.json'), JSON.pretty_generate({'modules'=>selected.sort, 'plugins'=>plugin_targets.keys, 'entitlements'=>entitlements, 'deploymentTarget'=>deployment, 'pods'=>!pods.values.all?(&:empty?), 'staticLibraries'=>static_providers.map(&:first), 'requiredResources'=>resource_modules.values.flatten.select { |name| integration_resources.any? { |f| f.start_with?(name + '/') } }, 'canvas'=>canvas_selected}))
puts "已生成 Xcode 工作区：#{selected.size} 个官方模块，#{plugin_targets.size} 个 UTS 插件。"
