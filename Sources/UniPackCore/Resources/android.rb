# frozen_string_literal: true
require 'json'
require 'fileutils'
require 'rexml/document'
require_relative 'dependency-report'
report = DependencyReport.new('android')
include FileUtils
spec=JSON.parse(File.read(ARGV.fetch(0)))
work=spec.fetch('work'); sdk=spec.fetch('sdk'); resources=spec.fetch('resources'); project=spec.fetch('project'); debug=spec.fetch('debug')
def fail!(s); abort("UniPack: #{s}");end
def q(s)
 "'"+s.to_s.gsub("\\") { "\\\\" }.gsub("'") { "\\'" }+"'"
end
def json(path);File.exist?(path) ? JSON.parse(File.read(path)) : {};end
def copy_contents(from,to)
 return unless File.directory?(from)
 FileUtils.mkdir_p(to);Dir.children(from).each{|p|FileUtils.cp_r(File.join(from,p),to)}
end
def write(path,text);FileUtils.mkdir_p(File.dirname(path));File.write(path,text);end
[project,sdk,resources].each{|input|fail!('原生工作目录必须与项目、SDK 和资源隔离') if File.expand_path(work).start_with?(File.expand_path(input)+'/') || File.expand_path(work)==File.expand_path(input)}
app=File.join(work,'app');main=File.join(app,'src/main');mkdir_p(main)
template=File.join(sdk,'xvnativeproject')
%w[gradlew build.gradle].each{|p|cp(File.join(template,p),File.join(work,p))}
cp_r(File.join(template,'gradle'),work)
rm_f(File.join(work,'gradle/gradle-daemon-jvm.properties'))
wrapper=File.join(work,'gradle/wrapper/gradle-wrapper.properties')
props=File.read(wrapper).sub(/^distributionUrl=.*$/,'distributionUrl=https\\://downloads.gradle.org/distributions/gradle-9.2.1-bin.zip')
props=props.lines.reject{|line|line.start_with?('distributionSha256Sum=')}.join+"\ndistributionSha256Sum=72f44c9f8ebcb1af43838f45ee5c4aa9c5444898b3468ab3f4af7b6076c5bc3f\n"
write(wrapper,props)
# Only official wrapper and compiler jars are copied, never SDK example applications.
cp_r(File.join(sdk,'plugins'),File.join(work,'plugins'))
build=File.read(File.join(work,'build.gradle')).gsub('../plugins/','plugins/')
write(File.join(work,'build.gradle'),build)
settings=File.read(File.join(template,'settings.gradle')).split('rootProject.name').first.gsub('../plugins/','plugins/')
# The SDK lists these vendor mirrors for dependencies; use the same repositories for Gradle plugin transitive artifacts.
settings.sub!('repositories {', "repositories {\n        maven { url 'https://maven.aliyun.com/repository/google' }\n        maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }\n        maven { url 'https://maven.aliyun.com/repository/central' }")
settings+="rootProject.name = 'UniPackBuild'\ninclude ':app'\n"
write(File.join(work,'local.properties'),"sdk.dir=#{spec.fetch('androidSDK').gsub('\\','\\\\').gsub(' ','\\ ')}\n")
write(File.join(work,'gradle.properties'),"org.gradle.jvmargs=-Xmx3072m -Dfile.encoding=UTF-8\nandroid.useAndroidX=true\nandroid.enableJetifier=true\norg.gradle.configuration-cache=false\n")
export_manifest=json(File.join(resources,spec.fetch('appid'),'www/manifest.json'))
manifest=spec.fetch('manifest');dist=manifest.fetch('app-android',{}).fetch('distribute',{})
selection=spec.fetch('moduleSelection');modules=selection.fetch('modules');requested=modules.keys
selection.fetch('ignored',{}).each{|name,reason|report.add('未启用',name,reason)}
# 荣耀推送不在 Maven Central / 华为仓库发布，按实际启用的厂商通道补充官方源。
# FAIL_ON_PROJECT_REPOS 模式下应写入 settings 的 dependencyResolutionManagement，不能写入 app.repositories。
push_config=modules['uni-push']
if push_config.is_a?(Hash) && push_config.key?('honor')
 honor_repository='https://developer.hihonor.com/repo/'
 settings += <<~HONOR_REPOSITORY
   dependencyResolutionManagement {
     repositories {
       maven {
         url #{q(honor_repository)}
         content { includeGroup 'com.hihonor.mcs' }
       }
     }
   }
 HONOR_REPOSITORY
 report.add('Maven 仓库',honor_repository,'uni-push / honor；仅解析 com.hihonor.mcs，包含荣耀推送 SDK')
end
catalog=json(File.join(__dir__,'android-modules.json'))
libsdir=File.join(sdk,'SDK/libs');libfiles=Dir[File.join(libsdir,'*.{aar,jar}')]
lookup=libfiles.to_h{|p|[File.basename(p).downcase,p]}
base=%w[app-common app-runtime breakpad-build uts-runtime ext-component uni-dialogPage uni-event uni-crash uni-getElementById uni-pullDownRefresh uni-storage uni-exit uni-theme uni-getAppBaseInfo uni-getDeviceInfo uni-getSystemInfo uni-getAccessibilityInfo uni-getAppAuthorizeSetting uni-getSystemSetting uni-openAppAuthorizeSetting uni-prompt uni-rpx2px uni-secure-network uni-uasm uni-convert2AbsFullPath]
selected=base.map{|n|n+'-release.aar'}
deps=%w[androidx.tracing:tracing-ktx:1.3.0 androidx.core:core-ktx:1.10.1 androidx.appcompat:appcompat:1.6.1 androidx.constraintlayout:constraintlayout:2.2.1 androidx.exifinterface:exifinterface:1.3.6 com.google.android.material:material:1.10.0 org.jetbrains.kotlin:kotlin-reflect:2.2.0 org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3 org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3 com.facebook.fresco:fresco:3.4.0 com.facebook.fresco:animated-base:3.4.0 com.facebook.fresco:animated-gif:3.4.0 com.facebook.fresco:animated-webp:3.4.0 com.facebook.fresco:webpsupport:3.4.0 com.facebook.fresco:imagepipeline:3.4.0 com.facebook.fresco:drawee:3.4.0 com.facebook.fresco:middleware:3.4.0 com.caverock:androidsvg:1.4 com.alibaba:fastjson:1.2.83 com.github.getActivity:XXPermissions:18.63 androidx.profileinstaller:profileinstaller:1.4.1 com.squareup.okhttp3:okhttp:3.12.12]
fields=Hash.new{|h,k|h[k]=[]};providers=[];hooks=[];plugin_dependencies=[];preferred_dependencies=[];pick_firsts=['**/libc++_shared.so','**/libstlport_shared.so'];classpath=[];extra_plugins=[];min_sdk=[23,(dist['minSdkVersion'] || 23).to_i].max
runtime=%w[uni-text uni-view uni-image uni-scroll-view uni-list-view uni-list-item uni-button uni-input uni-textarea uni-switch uni-slider uni-checkbox uni-checkbox-group uni-radio uni-radio-group uni-navigator uni-label uni-progress uni-movable-area uni-movable-view uni-swiper uni-swiper-item uni-cover-view uni-cover-image uni-waterflow]
base.each{|n|report.add('AAR / JAR',n+'-release.aar','官方 Vapor 必需基础库')}
deps.each{|d|report.add('Maven 声明',d,'官方 Vapor 基础运行时')}
seen=[]
select_module=nil
select_module=lambda do |name|
 return if seen.include?(name.downcase);seen<<name.downcase
 before_libs=selected.dup;before_deps=deps.dup
 report.add('官方模块',name,selection.fetch('origins',{})[name] || '模块的传递依赖')
 if (recipe=catalog[name.downcase]) && !recipe.fetch('libs',[]).empty?
  selected.concat(recipe['libs']);deps.concat(recipe.fetch('dependencies',[]));recipe.fetch('modules',[]).each{|n|select_module.call(n)}
  # Merge the Vapor recipe's first declaration of each BuildConfig registration field.
  recipe.fetch('config',[]).group_by{|c|c[/buildConfigField\s+'[^']+',\s*'([^']+)'/,1]}.each do |key,codes|
   next unless key
   raw=codes.first[/buildConfigField\s+'[^']+',\s*'[^']+',\s*'([^']+)'/,1]
   next unless raw
   begin
    v=JSON.parse(raw);v=JSON.parse(v) if v.is_a?(String) && v.start_with?('[')
    fields[key].concat(v.is_a?(Array) ? v : [v])
   rescue JSON::ParserError
    if key=='UTSHooksClassArray';hooks.concat(raw.scan(/"([\w.$]+)"/).flatten);else;fail!("模块 #{name} 注册配置无法解析");end
   end
  end
 elsif lookup[(name+'-release.aar').downcase]
  selected<<File.basename(lookup[(name+'-release.aar').downcase])
 elsif runtime.include?(name)
  # Rendered by ext-component / runtime.
 elsif %w[uni-getLocation uni-location uni-map uni-payment uni-oauth uni-share uni-push uni-verify uni-video].include?(name)
  selected<<name+'-release.aar' unless name=='uni-map'
 else
  fail!("未知 Android 内置模块：#{name}，请补充官方集成规则")
 end
 (selected-before_libs).each{|f|report.add('AAR / JAR',f,'模块 '+name)}
 (deps-before_deps).each{|d|report.add('Maven 声明',d,'模块 '+name)}
end
requested.each{|n|select_module.call(n)}
selected<<'uni-canvas-component-release.aar' if requested.include?('uni-canvas-dom2')
selected<<'uni-network-cronet-release.aar' if requested.include?('uni-network')
# Provider registration differs from the API module. Never add unconfigured providers.
modules.each do |name,config|
 before_libs=selected.dup;before_deps=deps.dup
 config={} unless config.is_a?(Hash)
 case name
 when 'uni-getLocation','uni-location','uni-getLocation-tencent','uni-location-tencent'
  config={'tencent'=>{}} if name.end_with?('-tencent')
  (config.empty? ? {'system'=>{}} : config).each_key do |p|
   fail!("未知 location provider #{p}") unless %w[system tencent].include?(p)
   selected<<"uni-location-#{p}-release.aar"
   providers<<{'name'=>p,'service'=>'location','class'=>"uts.sdk.modules.DCloudUniLocation#{p.capitalize}.UniLocation#{p.capitalize}ProviderImpl"}
   deps<<'com.tencent.map.geolocation:TencentLocationSdk-openplatform:7.5.4.8' if p=='tencent'
  end
 when 'uni-payment','uni-oauth','uni-share'
  service=name.sub('uni-','')
  config.each_key do |p|
   fail!("未知 #{service} provider #{p}") unless (service=='payment' ? %w[wxpay alipay] : %w[weixin]).include?(p)
   selected<<"uni-#{service}-#{p}-release.aar"
   type=service=='oauth' ? 'OAuth' : service.capitalize
   providers<<{'name'=>p,'service'=>service,'class'=>"uts.sdk.modules.DCloudUni#{service.capitalize}#{p.capitalize}.Uni#{type}#{p.capitalize}ProviderImpl"}
   selected<<'uni-weixin-common-release.aar' if %w[weixin wxpay].include?(p)
   deps<<(p=='alipay' ? 'com.alipay.sdk:alipaysdk-android:15.8.17' : 'com.tencent.mm.opensdk:wechat-sdk-android:6.8.0')
  end
 when 'uni-map'
  fail!('当前仅支持腾讯地图，其他地图 provider 需要集成规则') unless config.keys.all?{|k|k=='tencent'}
  selected<<'uni-map-tencent-release.aar';deps.concat(%w[com.tencent.map:tencent-map-vector-sdk:5.6.0 com.tencent.map:sdk-utilities:1.0.9 com.tencent.map.geolocation:TencentLocationSdk-openplatform:7.5.4.3 com.github.bumptech.glide:glide:4.16.0])
  fields['UTSEasyCom']<<{'class'=>'uts.sdk.modules.DCloudUniMapTencent.UniMapTencentExtApiComponentsRegister','method'=>'register'}
 when 'uni-video'
  %w[uni-fileSystemManager uni-getSystemInfo uni-screenBrightness].each{|n|select_module.call(n)}
  deps.concat(%w[androidx.media3:media3-exoplayer:1.8.0 androidx.media3:media3-exoplayer-hls:1.8.0]);fields['UTSEasyCom']<<{'class'=>'uts.sdk.modules.DCloudUniVideo.UniVideoExtApiComponentsRegister','method'=>'register'}
 when 'uni-verify'
  gy=Dir[File.join(libsdir,'GY-*-release.aar')];fail!('SDK 缺少唯一的 GY 一键登录库') unless gy.length==1;selected<<File.basename(gy.first)
  deps<<'com.getui:gtc-dcloud:3.2.16.7';fields['UTSMethodRegister']<<'uts.sdk.modules.DCloudUniVerify.UniUTSMethodRegister';fields['UTSEasyCom']<<{'class'=>'uts.sdk.modules.DCloudUniVerify.UniVerifyExtApiPagesRegister','method'=>'register'}
 when 'uni-push'
  deps<<'com.getui:gtc-dcloud:3.2.16.7';deps<<'com.getui:gtsdk:3.3.7.0'
  vendors={
   'hms'=>%w[com.getui.opt:hwp:3.1.2 com.huawei.hms:push:6.11.0.300],
   'huawei'=>%w[com.getui.opt:hwp:3.1.2 com.huawei.hms:push:6.11.0.300],
   'xiaomi'=>%w[com.getui.opt:xmp:3.3.1],
   'oppo'=>%w[com.assist-v3:oppo:3.4.0 com.google.code.gson:gson:2.6.2 commons-codec:commons-codec:1.6 androidx.annotation:annotation:1.1.0],
   'vivo'=>%w[com.assist-v3:vivo:3.1.2], 'meizu'=>%w[com.getui.opt:mzp:3.2.3],
   'honor'=>%w[com.getui.opt:honor:3.6.0 com.hihonor.mcs:push:7.0.61.303]
  }
  config.each_key{|p|fail!("未知推送厂商 #{p}") unless vendors[p];deps.concat(vendors[p])}

 end
 (selected-before_libs).each{|f|report.add('AAR / JAR',f,'模块 / provider '+name)}
 (deps-before_deps).each{|d|report.add('Maven 声明',d,'模块 / provider '+name)}
end
if debug;selected<<'debug-server-release.aar';deps.concat(%w[net.lingala.zip4j:zip4j:2.11.5 com.squareup.leakcanary:leakcanary-android:2.14]);end
# Plugins become independent Android libraries with resources and transitive dependencies.
plugins=Dir[File.join(resources,'uni_modules','*')].select{|p|File.directory?(p)}
plugin_names=plugins.map{|p|File.basename(p)}
plugins.each do |root|
 name=File.basename(root);fail!("非法插件名称 #{name}") unless name.match?(/\A[A-Za-z0-9_-]+\z/)
 native=File.directory?(File.join(root,'utssdk/app-android')) ? File.join(root,'utssdk/app-android') : File.join(root,'app-android')
 next unless File.directory?(native)
 fail!("加密插件 #{name} 缺少可用原生源码") if Dir[File.join(native,'**','*.kt')].empty? && Dir[File.join(native,'**','*.java')].empty? && Dir[File.join(native,'libs','**','*.{aar,jar,so}')].empty?
 conf=json(File.join(native,'config.json'));
 if conf['packagingOptions']
  opts=conf['packagingOptions'];fail!("插件 #{name} packagingOptions 尚未支持") unless (opts.keys-%w[preferred jniLibs]).empty? && (opts.fetch('jniLibs',{}).keys-['pickFirsts']).empty?
 end
 allowed=%w[abis dependencies minSdkVersion project components hooksClass providers repositories cmake ndkVersion utsMethodRegister packagingOptions]
 unknown=conf.keys-allowed;fail!("插件 #{name} 存在尚未适配的配置：#{unknown.join(', ')}") unless unknown.empty?
 min_sdk=[min_sdk,(conf['minSdkVersion'] || 23).to_i].max
 fail!("插件 #{name} 不支持 arm64-v8a") if conf['abis'] && !conf['abis'].include?('arm64-v8a')
 folder=File.join(work,name);dest=File.join(folder,'src/main');mkdir_p(dest)
 %w[assets res jniLibs].each{|p|copy_contents(File.join(native,p),File.join(dest,p))}
 copy_contents(File.join(native,'src'),File.join(dest,'java'))
 # Export layouts may put Kotlin / Java directly at the native root.
 Dir[File.join(native,'*.{kt,java}')].each{|p|mkdir_p(File.join(dest,'java'));cp(p,File.join(dest,'java'))}
 copy_contents(File.join(native,'libs'),File.join(folder,'libs'))
 if File.directory?(File.join(native,'libs'))
  Dir[File.join(native,'libs','**','*.so')].each{|so|abi=File.basename(File.dirname(so));mkdir_p(File.join(dest,'jniLibs',abi));cp(so,File.join(dest,'jniLibs',abi))}
 end
 report.add('UTS 插件',name,'HBuilderX 本次导出的原生源码')
 Dir[File.join(native,'**','*.{aar,jar,so}')].each{|f|report.add('插件本地库',File.basename(f),'插件 '+name+' / '+f.delete_prefix(native+'/'))}
 %w[assets res jniLibs].each{|dir|report.add('插件资源',name+'/'+dir,'HBuilderX 本次导出') if File.directory?(File.join(native,dir))}
 namespace=nil
 source_manifest=File.join(native,'AndroidManifest.xml')
 if File.exist?(source_manifest)
  xml=REXML::Document.new(File.read(source_manifest));namespace=xml.root.attributes['package'];xml.root.attributes.delete('package');write(File.join(dest,'AndroidManifest.xml'),xml.to_s)
 end
 namespace=nil unless defined?(namespace) && namespace
 namespace||=Dir[File.join(dest,'java','**','*.{kt,java}')].map{|p|File.read(p)[/^package\s+([A-Za-z0-9_.]+)/,1]}.compact.first
 namespace||='uts.sdk.modules.'+name.split(/[-_]/).each_with_index.map{|part,i|i==0 ? part : part[0].upcase+part[1..-1]}.join
 namespace=namespace.gsub(/[^A-Za-z0-9_.]/,'')
 dep=(conf['dependencies']||[]).map do |d|
  if d.is_a?(String);report.add('Maven 声明',d,'插件 '+name);fail!("插件 #{name} 依赖坐标无效") unless d.match?(/\A[\w.:-]+\z/);"implementation #{q(d)}"
  elsif d.is_a?(Hash) && d['source'];report.add('Gradle 自定义依赖',name,'插件脚本声明，实际坐标在解析后显示');d['source']
  else;fail!("插件 #{name} 依赖格式未知");end
 end
 package=json(File.join(project,'uni_modules',name,'package.json'))
 (package.dig('uni_modules','dependencies') || package['dependencies'] || []).each{|dependency|dep<<"implementation project(#{q(':'+dependency)})" if plugin_names.include?(dependency)}
 imports=Dir[File.join(dest,'java','**','*.{kt,java}')].flat_map{|p|File.read(p).scan(/^import\s+uts\.sdk\.modules\.([A-Za-z0-9_]+)/).flatten}.uniq
 # Compiler-generated package imports connect plugins even when package.json has no dependency list.
 plugins.each do |other|
  other_name=File.basename(other);next if other_name==name
  other_src=Dir[File.join(other,'**','*.kt')].first;next unless other_src
  other_pkg=File.read(other_src)[/^package\s+uts\.sdk\.modules\.([A-Za-z0-9_]+)/,1]
  dep<<"implementation project(#{q(':'+other_name)})" if other_pkg && imports.include?(other_pkg)
 end
 fields['UTSRegisterComponents'].concat(conf['components']||[]);providers.concat(conf['providers']||[]);hooks<<conf['hooksClass'] if conf['hooksClass']
 project_conf=conf['project']||{};classpath.concat(project_conf['dependencies']||[]);extra_plugins.concat(project_conf['plugins']||[])
 (conf['repositories']||[]).each{|url|fail!("插件 #{name} 仓库 URL 无效") unless url.is_a?(String)&&url.start_with?('https://');settings.sub!("mavenCentral()","maven { url #{q(url)} }\n        mavenCentral()")}
 cmake=''
 cmake_path=conf.dig('cmake','path') || (File.exist?(File.join(native,'CMakeLists.txt')) ? 'CMakeLists.txt' : nil)
 if cmake_path
  fail!("插件 #{name} CMake 路径越界") if cmake_path.start_with?('/') || cmake_path.split('/').include?('..')
  copy_contents(native,File.join(folder,'native'))
  fail!("插件 #{name} CMakeLists 缺失") unless File.exist?(File.join(folder,'native',cmake_path))
  report.add('原生编译',name+' / CMake','NDK '+(conf['ndkVersion']||spec['ndkVersion'])+'；CMake '+spec['cmakeVersion'])
  cmake="ndkVersion #{q(conf['ndkVersion']||spec['ndkVersion'])}\n externalNativeBuild { cmake { path file(#{q('native/'+cmake_path)}); version #{q(spec['cmakeVersion'])} }"
 end
 script="plugins { alias(libs.plugins.android.library); id 'io.dcloud.uts.kotlin'; id 'io.dcloud.uts.auto-register'\n"+(project_conf['plugins']||[]).map{|p|"id #{q(p)}"}.join("\n")+"\n}\nandroid { namespace #{q(namespace)}; compileSdk 36\n defaultConfig { minSdk #{min_sdk}; ndk { abiFilters 'arm64-v8a' } }\n compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }\n#{cmake}\n}\ndependencies {\n compileOnly fileTree(dir:'../app/libs',include:['*.aar','*.jar'])\n compileOnly fileTree(dir:'libs',include:['*.aar','*.jar'])\n compileOnly 'com.alibaba:fastjson:1.2.83'\n compileOnly 'androidx.core:core-ktx:1.10.1'\n compileOnly 'org.jetbrains.kotlin:kotlin-reflect:2.2.0'\n compileOnly 'org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3'\n compileOnly 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'\n#{dep.uniq.join("\n")}\n}\n"
 write(File.join(folder,'build.gradle'),script)
 settings+="include #{q(':'+name)}\n";plugin_dependencies<<"implementation project(#{q(':'+name)})"
 # Runtime must also see plugin libraries, same as official integration guidance.
 local_lib="implementation fileTree(dir:#{q('../'+name+'/libs')},include:['*.aar','*.jar'])"
 plugin_dependencies<<local_lib
 if conf['packagingOptions']
  preferred_dependencies<<local_lib if conf['packagingOptions']['preferred']==true
  pick_firsts.concat(conf['packagingOptions'].dig('jniLibs','pickFirsts')||[])
 end
end
selected.uniq.each do |name|
 file=lookup[name.downcase];fail!("SDK 缺少内置库 #{name}") unless file
 mkdir_p(File.join(app,'libs'));cp(file,File.join(app,'libs',File.basename(file)))
end
copy_contents(File.join(resources,spec.fetch('appid')),File.join(main,'assets/apps',spec.fetch('appid')))
resource_manifest=File.join(main,'assets/apps',spec.fetch('appid'),'www/manifest.json')
packaged=json(resource_manifest)
packaged['app-android']={} unless packaged['app-android'].is_a?(Hash)
packaged['app-android']['distribute']||={}
%w[modules schemes].each{|key|packaged['app-android']['distribute'][key]=dist[key] if dist.key?(key)}
write(resource_manifest,JSON.pretty_generate(packaged))
# Add source-side resources without changing the business project.
copy_contents(File.join(project,'nativeResources/android/res'),File.join(main,'res'))
%w[res assets].each{|p|copy_contents(File.join(project,'build-config/android',p),File.join(main,p))}
# Use Android's manifest merger for business capabilities and report actual conflicts.
business_manifest=File.join(project,'AndroidManifest.xml')
xml=File.exist?(business_manifest) ? REXML::Document.new(File.read(business_manifest)) : REXML::Document.new('<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools"/>')
xml.root.add_namespace('android','http://schemas.android.com/apk/res/android')
xml.root.add_namespace('tools','http://schemas.android.com/tools')
xml.root.attributes.delete('package');application=xml.root.elements['application'] || xml.root.add_element('application')
{'android:name'=>'io.dcloud.uniappxv.UniApplication','android:allowBackup'=>'false','android:label'=>spec.fetch('name'),'android:theme'=>'@style/Theme.AppCompat.DayNight.NoActionBar','android:largeHeap'=>'true','android:extractNativeLibs'=>'false','tools:replace'=>'android:allowBackup,android:label,android:theme'}.each{|k,v|application.attributes[k]=v}
def meta(app,name,value)
 old=app.elements.to_a('meta-data').find{|e|e.attributes['android:name']==name}
 fail!("应用元数据冲突 #{name}") if old && old.attributes['android:value']!=value
 (old || app.add_element('meta-data')).tap{|e|e.attributes['android:name']=name;e.attributes['android:value']=value}
end
# 同一主清单的权限声明按 Android 的名称键去重，保留已有 tools/maxSdkVersion 等规则。
def add_permission(xml,element)
 name=element.attributes['android:name']
 old=xml.root.elements.to_a(element.name).find{|e|e.attributes['android:name']==name}
 unless old
  xml.root.add_element(element);return
 end
 element.attributes.each_attribute do |attribute|
  key=attribute.expanded_name;value=attribute.value
  next if key=='android:name'
  previous=old.attributes[key]
  fail!("权限配置冲突 #{name} / #{key}") if previous && previous!=value
  removals=old.attributes['tools:remove'].to_s.split(',').map(&:strip)
  fail!("权限配置冲突 #{name}：已有规则移除 #{key}") if removals.include?(key)
  old.attributes[key]=value
 end
end
meta(application,'DCLOUD_UNI_APPID',spec.fetch('appid'));meta(application,'DCLOUD_CHANNEL',debug ? 'debug' : 'release');meta(application,'DCLOUD_DEBUG','true') if debug
%w[android.permission.INTERNET android.permission.ACCESS_NETWORK_STATE].each{|name|unless xml.root.elements.to_a('uses-permission').any?{|p|p.attributes['android:name']==name};xml.root.add_element('uses-permission',{'android:name'=>name});end}
(dist['permissions']||[]).each do |permission|
 if permission.start_with?('<');element=REXML::Document.new('<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">'+permission+'</manifest>').root.elements[1];if %w[uses-permission uses-permission-sdk-23].include?(element.name);add_permission(xml,element);else;xml.root.add_element(element);end
 elsif permission.start_with?('android.permission.');element=REXML::Element.new('uses-permission');element.attributes['android:name']=permission;add_permission(xml,element)
 else;fail!("未知 Android 权限声明 #{permission}");end
end
activity=application.add_element('activity',{'android:name'=>'io.dcloud.uniappxv.UniAppActivity','android:exported'=>'true','android:configChanges'=>'orientation|keyboardHidden|screenSize|mcc|mnc|fontScale|keyboard|smallestScreenSize|screenLayout|uiMode','android:theme'=>'@style/Theme.AppCompat.DayNight.NoActionBar','android:windowSoftInputMode'=>'adjustResize','tools:replace'=>'android:exported,android:theme,android:configChanges,android:windowSoftInputMode'})
filter=activity.add_element('intent-filter');filter.add_element('action',{'android:name'=>'android.intent.action.MAIN'});filter.add_element('category',{'android:name'=>'android.intent.category.LAUNCHER'})
offline=File.join(project,'build-config/android/push-manifest.xml')
if modules.key?('uni-push') && File.exist?(offline)
 report.add('原生清单', 'push-manifest.xml', '启用 uni-push 时合并')
 extra=REXML::Document.new(File.read(offline))
 extra.root.elements['application']&.elements&.each do |e|
  if e.name=='meta-data'
   meta(application,e.attributes['android:name'],e.attributes['android:value'])
  else
   application.add_element(e.deep_clone)
  end
 end
end
# GUI 的通知行为覆盖旧 XML 默认值；仅启用推送时写入。
if requested.include?('uni-push') && spec.key?('autoNotification')
 meta(application,'dcloud_unipush_auto_notification',spec['autoNotification'] ? 'true' : 'false')
end
# 自定义应用回调，与微信 SDK 自己的回调 Activity 分开。
schemes = dist['schemes'].is_a?(Array) ? dist['schemes'] : dist.fetch('schemes','').split(',').map(&:strip)
schemes.reject(&:empty?).uniq.each do |scheme|
 fail!('应用 URL Scheme 格式无效') unless scheme.match?(/\A[A-Za-z][A-Za-z0-9+.-]*\z/)
 entry=activity.add_element('intent-filter')
 entry.add_element('action',{'android:name'=>'android.intent.action.VIEW'})
 entry.add_element('category',{'android:name'=>'android.intent.category.DEFAULT'})
 entry.add_element('category',{'android:name'=>'android.intent.category.BROWSABLE'})
 entry.add_element('data',{'android:scheme'=>scheme})
end
# manifest placeholders may be supplied by project-owned offline config, never fake SDK identities.
placeholder_path=spec['manifestPlaceholdersPath'].to_s
if placeholder_path.empty?
 placeholder_path=[File.join(project,'nativeResources/android/manifestPlaceholders.json'),File.join(project,'build-config/android/manifest-placeholders.json')].find{|p|File.file?(p)}.to_s
end
placeholders=placeholder_path.empty? ? {} : json(placeholder_path)
required=[]
required+=%w[GETUI_APPID PUSH_APPID GETUI_APP_ID] if requested.include?('uni-push')
required+=%w[GETUI_APPID GY_APP_ID] if requested.include?('uni-verify')
required.uniq.each do |key|
 fail!("服务参数缺少 #{key}，请在 UniPack 的 Android 服务参数中填写并校验") if placeholders[key].to_s.strip.empty?
end
if modules.dig('uni-map','tencent') || modules.dig('uni-location','tencent') || modules.dig('uni-getLocation','tencent') || modules.key?('uni-location-tencent') || modules.key?('uni-getLocation-tencent')
 map=modules.dig('uni-map','tencent') || modules.dig('uni-location','tencent') || modules.dig('uni-getLocation','tencent');key=placeholders['TencentMapSDK']||(map.is_a?(Hash) ? map['appkey']||map['key'] : nil)
 existing=application.elements.to_a('meta-data').find{|e|e.attributes['android:name']=='TencentMapSDK'}
 fail!('腾讯地图缺少 API Key，请在 UniPack 的 Android 服务参数中填写腾讯地图 Key') unless (key && !key.strip.empty?) || (existing && !existing.attributes['android:value'].to_s.strip.empty?)
 meta(application,'TencentMapSDK',key) if key
end
# 微信登录 / 分享 / 支付共用一个 WX_APPID。SDK 使用 ${WX_APPID}，必须同时填充 Gradle 占位符。
identity_placeholders={}
if selected.any?{|file|File.basename(file).downcase=='uni-weixin-common-release.aar'}
 identities={}
 add_identity=lambda do |source,value,allow_placeholder=false|
  next if value.nil? || (value.is_a?(String) && value.strip.empty?)
  next if allow_placeholder && value=='${WX_APPID}'
  fail!("#{source} 必须填写真实微信 AppID，不能使用未替换的占位符") unless value.is_a?(String) && value.match?(/\Awx[A-Za-z0-9]+\z/)
  identities[source]=value
 end
 %w[uni-oauth uni-share uni-payment].each do |mod|
  config=modules[mod]||{}
  config.each do |provider,value|
   next unless %w[weixin wxpay].include?(provider) && value.is_a?(Hash)
   add_identity.call("manifest #{mod}.#{provider}.appid",value['appid'])
  end
 end
 add_identity.call('模块占位符 WX_APPID',placeholders['WX_APPID'])
 wx_nodes=application.elements.to_a('meta-data').select{|e|e.attributes['android:name']=='WX_APPID'}
 fail!('主清单重复声明 WX_APPID，请保留唯一声明') if wx_nodes.length>1
 wx_nodes.each{|e|fail!('WX_APPID 暂不支持 android:resource，请使用字面 AppID 或 ${WX_APPID}') if e.attributes['android:resource'];add_identity.call('主清单 WX_APPID',e.attributes['android:value'],true)}
 # 仅校验本次实际导出插件中的显式值，不扫描未使用的源码插件。
 plugins.each do |plugin|
  native=File.directory?(File.join(plugin,'utssdk/app-android')) ? File.join(plugin,'utssdk/app-android') : File.join(plugin,'app-android')
  file=File.join(native,'AndroidManifest.xml');next unless File.file?(file)
  entries=REXML::Document.new(File.read(file)).root.elements.to_a('application/meta-data').select{|e|e.attributes['android:name']=='WX_APPID'}
  fail!('插件 '+File.basename(plugin)+' 重复声明 WX_APPID') if entries.length>1
  entries.each do |e|
   fail!('插件 '+File.basename(plugin)+' WX_APPID 使用 android:resource，无法核对统一 AppID') if e.attributes['android:resource']
   add_identity.call('插件 '+File.basename(plugin)+' WX_APPID',e.attributes['android:value'],true)
  end
 end
 fail!('微信模块已启用但缺少 AppID，请在 manifest 的微信登录、分享或支付配置中填写 appid') if identities.empty?
 fail!('微信 AppID 配置冲突：'+identities.keys.join('、')+' 必须使用同一个 AppID') if identities.values.uniq.length>1
 identity_placeholders['WX_APPID']=identities.values.first
 wx_node=wx_nodes.first || application.add_element('meta-data')
 wx_node.attributes['android:name']='WX_APPID'
 wx_node.attributes['android:value']='${WX_APPID}'
 report.add('Manifest 占位符','WX_APPID',identities.keys.join('；')+'；与 uni-weixin-common 统一注入，不展示参数值')
end
write(File.join(main,'AndroidManifest.xml'),xml.to_s)
fields['UTSRegisterProviders'].concat(providers);fields['UTSHooksClassArray'].concat(hooks)
registration=fields.map do |name,values|
 values=values.uniq
 if name=='UTSHooksClassArray';"buildConfigField 'String[]', #{q(name)}, #{q('{'+values.map(&:to_json).join(',')+'}')}"
 elsif name=='UTSMethodRegister';fail!('多个 UTSMethodRegister 声明冲突') if values.length>1;"buildConfigField 'String', #{q(name)}, #{q(values.first.to_json)}"
 else;"buildConfigField 'String', #{q(name)}, #{q(values.to_json.to_json)}";end
end.join("\n")
huawei = (modules['uni-push'].is_a?(Hash) && (modules['uni-push'].key?('hms') || modules['uni-push'].key?('huawei')))
if huawei
 config = spec['huaweiConfigPath'].to_s
 fail!('请在 Android 服务参数中导入华为 agconnect-services.json') unless File.file?(config)
 client = json(config).fetch('client', {})
 fail!('华为配置文件应用包名不匹配') unless client['package_name'] == spec.fetch('bundle')
 fail!('华为配置文件 AppID 不匹配') unless client['app_id'].to_s == placeholders['HUAWEI_APP_ID'].to_s
 cp(config, File.join(app,'agconnect-services.json')); File.chmod(0600,File.join(app,'agconnect-services.json'))
 # AGCP 负责把配置文件转换为 HMS 读取的资源，不能只复制文件而不应用插件。
 build = File.join(work,'build.gradle')
 existing = File.file?(build) ? File.read(build) : ''
 write(build, "buildscript { repositories { maven { url 'https://developer.huawei.com/repo/' }; google(); mavenCentral() }; dependencies { classpath 'com.huawei.agconnect:agcp:1.9.6.300' } }\n" + existing)
 settings += "\ndependencyResolutionManagement { repositories { maven { url 'https://developer.huawei.com/repo/' } } }\n"
 extra_plugins << 'com.huawei.agconnect'
 report.add('服务配置文件','agconnect-services.json','GUI 选定文件的任务快照；AppID 与包名已核对，文件内容不显示')
 report.add('Gradle 插件','com.huawei.agconnect:agcp:1.9.6.300','仅启用华为推送时应用')
end
report.add('服务配置','Android 项目参数快照','GUI / 工程导入；只注入已启用服务的参数')
# No passwords in this file; values are read from a task-local, 0600 file at configuration time.
signing="def signingProperties = new Properties()\nfile('../signing.properties').withInputStream { signingProperties.load(it) }\n"
script="plugins { alias(libs.plugins.android.application); id 'io.dcloud.uts.kotlin'; id 'io.dcloud.uts.auto-register'\n"+extra_plugins.uniq.map{|p|"id #{q(p)}"}.join("\n")+"\n}\n"+signing+<<~GRADLE
android {
 namespace #{q(spec.fetch('bundle'))}
 compileSdk 36
 defaultConfig {
  applicationId #{q(spec.fetch('bundle'))}
  minSdk #{min_sdk}; targetSdk #{(dist['targetSdkVersion'] || 36).to_i}
  versionCode #{Integer(spec.fetch('versionCode'))}; versionName #{q(spec.fetch('version'))}
  ndk { abiFilters 'arm64-v8a' }
  #{registration}
  manifestPlaceholders = #{placeholder_path.empty? ? '[:]' : 'new groovy.json.JsonSlurper().parse(file('+q(placeholder_path)+'))'}
  manifestPlaceholders.putAll(#{identity_placeholders.empty? ? '[:]' : '['+identity_placeholders.map{|key,value|q(key)+':'+q(value)}.join(',')+']'})
 }
 buildFeatures { buildConfig true }
 signingConfigs { local { storeFile file(signingProperties['storeFile']); storePassword signingProperties['storePassword']; keyAlias signingProperties['keyAlias']; keyPassword signingProperties['keyPassword'] } }
 buildTypes {
  debug { debuggable true; signingConfig signingConfigs.local }
  release { debuggable false; minifyEnabled false; signingConfig signingConfigs.local }
 }
 compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
 androidResources { noCompress 'uni-app-x-framework-vapor','uni-app-x-framework-vapor-dev','js'; ignoreAssetsPattern '!.svn:!.git:.*:!CVS:!thumbs.db:!picasa.ini:!*.scc:*~' }
 packaging { jniLibs { useLegacyPackaging false; pickFirsts += [#{pick_firsts.uniq.map{|p|q(p)}.join(',')}] } }
}
dependencies {
 #{preferred_dependencies.uniq.join("\n")}
 implementation files('libs/app-runtime-release.aar')
 implementation fileTree(dir:'libs',include:['*.aar','*.jar'],exclude:['app-runtime-release.aar'])
 #{deps.uniq.map{|d|d=='com.getui:gtsdk:3.3.7.0' ? "implementation(#{q(d)}) { exclude(group:'com.getui') }" : "implementation #{q(d)}"}.join("\n")}
 #{plugin_dependencies.join("\n")}
}
GRADLE
script += <<~REPORT
  tasks.register('unipackDependencyReport') {
    doLast {
      def cp = configurations.getByName('#{debug ? 'debug' : 'release'}RuntimeClasspath')
      def origins = [:].withDefault { [] as Set }
      cp.incoming.resolutionResult.allComponents.each { component ->
        component.dependencies.each { edge ->
          if (edge instanceof org.gradle.api.artifacts.result.ResolvedDependencyResult) {
            origins[edge.selected.id.displayName].add(component.id.displayName)
          }
        }
      }
      def entries = cp.incoming.artifacts.artifacts.collect { a ->
        def id = a.id.componentIdentifier
        [category: id instanceof org.gradle.api.artifacts.component.ModuleComponentIdentifier ? 'Maven 已解析' : 'Gradle 本地依赖',
         name: id.displayName, reason: a.file.name + '；引入方：' + origins[id.displayName].sort().join(' / ')]
      }.unique().sort { a, b -> a.name <=> b.name }
      def output = rootProject.file('resolved-dependencies.json')
      output.text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(entries))
    }
  }
REPORT
write(File.join(app,'build.gradle'),script)
unless classpath.empty?
 build=File.read(File.join(work,'build.gradle'));build.sub!('dependencies {',"dependencies {\n"+classpath.uniq.map{|d|"classpath #{q(d)}"}.join("\n"));write(File.join(work,'build.gradle'),build)
end
write(File.join(work,'settings.gradle'),settings)
selected.uniq.each{|f|report.add('AAR / JAR',f,'实际复制到 app/libs（含模块的间接依赖）')}
deps.uniq.each{|d|report.add('Maven 声明',d,'实际写入 app/build.gradle')}
xml.root.elements.to_a('uses-permission').each{|e|report.add('声明权限',e.attributes['android:name'],'主工程清单；AAR / 插件合并权限在 APK 校验后显示')}
report.note('基础库按官方 Vapor 必需清单保留；不会因缺少业务调用而删除运行时基础依赖。')
report.note('Maven 版本冲突选择及间接依赖以 Gradle 解析结果为准。')
report.write(work)
write(File.join(work,'integration.json'),JSON.pretty_generate({'modules'=>seen,'libraries'=>selected.uniq,'plugins'=>plugin_dependencies,'debug'=>debug,'minSdk'=>min_sdk}))
puts "已集成 #{seen.length} 个官方模块、#{plugins.length} 个插件；#{debug ? '开发基座（调试服务已启用）' : '正式 APK'}"
