# frozen_string_literal: true
require 'json'
require 'fileutils'
require 'shellwords'
require 'open3'
require 'xcodeproj'
require_relative 'ios-module-integration'
work = File.expand_path(ARGV.fetch(0))
project = Xcodeproj::Project.open(File.join(work, 'UniPackBuild.xcodeproj'))
requirements_path = File.join(work, 'UniPackIntegration.json')
requirements = JSON.parse(File.read(requirements_path))
report_path = File.join(work, 'dependency-report.json'); report = JSON.parse(File.read(report_path))
# 只处理当前 Pods 的真机切片，不混入模拟器 / Catalyst，也不拉入未链接的 SDK。
frameworks = Dir[File.join(work, 'Pods', '**', '*.xcframework', 'Info.plist')].map do |metadata|
  description = Xcodeproj::Plist.read_from_path(metadata)
  slice = Array(description['AvailableLibraries']).find { |v| v['SupportedPlatform'] == 'ios' && !v.key?('SupportedPlatformVariant') && Array(v['SupportedArchitectures']).include?('arm64') }
  next unless slice && slice['LibraryPath'].end_with?('.framework')
  bundle = File.join(File.dirname(metadata), slice.fetch('LibraryIdentifier'), slice.fetch('LibraryPath'))
  name = File.basename(bundle, '.framework'); binary = File.join(bundle, name); privacy = File.join(bundle, 'PrivacyInfo.xcprivacy')
  next unless File.file?(privacy)
  kind, status = Open3.capture2('/usr/bin/file', binary)
  raise "无法识别静态依赖 #{name}" unless status.success?
  next if kind.include?('dynamically linked shared library')
  [name, privacy]
end.compact
project.targets.each do |target|
  aggregate = target.name == 'UniPackApp' ? 'Pods-UniPackApp' : 'Pods-UniPackApp-' + target.name
  config = File.join(work, 'Pods', 'Target Support Files', aggregate, aggregate + '.release.xcconfig')
  next unless File.file?(config)
  flags = File.readlines(config).find { |line| line.start_with?('OTHER_LDFLAGS = ') }.to_s.split(' = ', 2).last.to_s
  tokens = Shellwords.split(flags)
  linked = tokens.each_index.map { |i| tokens[i + 1] if tokens[i] == '-framework' }.compact
  used = frameworks.select { |name, _| linked.include?(name) }
  next if used.empty?
  relative = target.name == 'UniPackApp' ? 'PrivacyInfo.xcprivacy' : "Frameworks/#{target.name}.framework/PrivacyInfo.xcprivacy"
  combined = requirements.fetch('privacyManifests').fetch(relative, IOSModuleIntegration.empty_privacy)
  used.each do |name, file|
    combined = IOSModuleIntegration.merge_privacy(combined, Xcodeproj::Plist.read_from_path(file))
    entry = {'category'=>'静态 SDK 隐私声明', 'name'=>name, 'reason'=>"实际链接到 #{target.name}；厂商清单合并进入 #{relative}"}
    report['entries'] << entry unless report['entries'].include?(entry)
  end
  file = File.join(work, 'Generated', target.name, 'PrivacyInfo.xcprivacy'); FileUtils.mkdir_p(File.dirname(file))
  Xcodeproj::Plist.write_to_path(combined, file)
  unless target.resources_build_phase.files_references.any? { |ref| ref.real_path.to_s == file }
    target.resources_build_phase.add_file_reference(project.main_group.new_file(file), true)
  end
  requirements['privacyManifests'][relative] = combined
  puts "静态 SDK 隐私清单：#{target.name} <- #{used.map(&:first).uniq.join(', ')}"
end
project.save
File.write(requirements_path, JSON.pretty_generate(requirements))
File.write(report_path, JSON.pretty_generate(report))
