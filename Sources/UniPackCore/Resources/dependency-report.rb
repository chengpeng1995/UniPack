# frozen_string_literal: true
require 'json'
require 'time'
# 只记录依赖标识和来源，不收录服务参数、环境变量、签名材料或任意配置正文。
class DependencyReport
  def initialize(platform)
    @platform = platform
    @entries = {}
    @notes = []
  end
  def add(category, name, reason)
    return if name.to_s.empty?
    key = [category, name.to_s]
    (@entries[key] ||= []) << reason.to_s unless @entries.fetch(key, []).include?(reason.to_s)
  end
  def note(value); @notes << value; end
  def write(work)
    data = {'schemaVersion'=>1, 'platform'=>@platform, 'phase'=>'generated', 'generatedAt'=>Time.now.utc.iso8601,
      'notes'=>@notes.uniq, 'entries'=>@entries.sort_by { |k,_| k }.map { |(category,name),reasons| {'category'=>category,'name'=>name,'reason'=>reasons.join('；')} }}
    File.write(File.join(work, 'dependency-report.json'), JSON.pretty_generate(data))
  end
end
