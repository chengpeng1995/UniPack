# frozen_string_literal: true
# iOS 模块附属配置：保留用户显式选择，不用全部 SDK 的声明替代实际模块。
module IOSModuleIntegration
  def self.device_families(devices, explicit)
    choices = {'iphone'=>[1], 'ipad'=>[2], 'universal'=>[1, 2], 'auto'=>[1]}
    raise 'app-ios.distribute.devices 仅支持 iphone / ipad / universal / auto' unless devices.nil? || choices.key?(devices)
    if explicit
      raise 'Info.plist/UIDeviceFamily 必须是由 1、2 组成的非空数组' unless explicit.is_a?(Array) && !explicit.empty? && explicit.all? { |v| v.is_a?(Integer) && [1, 2].include?(v) }
      explicit = explicit.uniq.sort
      raise 'manifest.devices 与 Info.plist/UIDeviceFamily 冲突' if devices && devices != 'auto' && choices.fetch(devices) != explicit
      return explicit
    end
    choices.fetch(devices || 'iphone')
  end

  def self.location_purpose(info)
    key = 'NSLocationTemporaryUsageDescriptionDictionary'
    info[key] = {} unless info.key?(key)
    raise "#{key} 必须是字典" unless info[key].is_a?(Hash)
    unless info[key].key?('PurposeKey')
      existing = info['NSLocationWhenInUseUsageDescription']
      raise '系统定位缺少临时精确定位用途：请填写 NSLocationTemporaryUsageDescriptionDictionary.PurposeKey 或真实的前台定位用途' unless existing.is_a?(String) && !existing.strip.empty?
      info[key]['PurposeKey'] = existing
    end
    value = info[key]['PurposeKey']
    raise "#{key}.PurposeKey 必须是非空用途文案" unless value.is_a?(String) && !value.strip.empty?
    value
  end

  def self.empty_privacy
    {'NSPrivacyAccessedAPITypes'=>[], 'NSPrivacyCollectedDataTypes'=>[], 'NSPrivacyTracking'=>false, 'NSPrivacyTrackingDomains'=>[]}
  end

  def self.validate_privacy(document, name)
    raise "#{name} 隐私清单必须为字典" unless document.is_a?(Hash)
    {'NSPrivacyAccessedAPITypes'=>'NSPrivacyAccessedAPIType', 'NSPrivacyCollectedDataTypes'=>'NSPrivacyCollectedDataType'}.each do |key, identifier|
      next unless document.key?(key)
      entries = document[key]
      raise "#{name} 隐私清单 #{key} 必须为数组" unless entries.is_a?(Array)
      entries.each do |item|
        raise "#{name} 隐私清单 #{key} 缺少类型" unless item.is_a?(Hash) && item[identifier].is_a?(String) && !item[identifier].empty?
        list_key = key == 'NSPrivacyAccessedAPITypes' ? 'NSPrivacyAccessedAPITypeReasons' : 'NSPrivacyCollectedDataTypePurposes'
        values = item[list_key]
        raise "#{name} 隐私清单 #{identifier} 缺少理由 / 用途" unless values.is_a?(Array) && !values.empty? && values.all? { |v| v.is_a?(String) && !v.empty? }
      end
    end
    if document.key?('NSPrivacyTracking') && ![true, false].include?(document['NSPrivacyTracking'])
      raise "#{name} 隐私清单 NSPrivacyTracking 必须为布尔值"
    end
  end

  def self.core_privacy(template, selected)
    validate_privacy(template, '官方 SDK 模板')
    result = empty_privacy
    media = selected.include?('uni-media')
    wechat = (selected & %w[uni-oauth-weixin uni-share-weixin uni-payment-wxpay uni-requestMerchantTransfer]).any?
    # DCloud 官方模块规范：媒体访问文件时间戳 / 照片视频；微信使用 UserDefaults。
    types = []
    types << 'NSPrivacyAccessedAPICategoryFileTimestamp' if media
    types << 'NSPrivacyAccessedAPICategoryUserDefaults' if wechat
    types.each do |type|
      entry = Array(template['NSPrivacyAccessedAPITypes']).find { |v| v['NSPrivacyAccessedAPIType'] == type }
      raise "SDK 模板缺少 #{type} 的官方理由，不能生成不完整隐私声明" unless entry
      result['NSPrivacyAccessedAPITypes'] << entry
    end
    if media
      entry = Array(template['NSPrivacyCollectedDataTypes']).find { |v| v['NSPrivacyCollectedDataType'] == 'NSPrivacyCollectedDataTypePhotosorVideos' }
      raise 'SDK 模板缺少媒体模块的照片视频声明' unless entry
      result['NSPrivacyCollectedDataTypes'] << entry
    end
    result
  end
  # 将静态 SDK 的声明合并到承载其代码的 Framework；同类型合并理由，不丢厂商字段。
  def self.merge_privacy(left, right)
    validate_privacy(left, '已有声明'); validate_privacy(right, '静态 SDK')
    result = Marshal.load(Marshal.dump(left))
    right.each do |key, value|
      unless result.key?(key)
        result[key] = Marshal.load(Marshal.dump(value)); next
      end
      old = result[key]
      if %w[NSPrivacyAccessedAPITypes NSPrivacyCollectedDataTypes].include?(key)
        id = key == 'NSPrivacyAccessedAPITypes' ? 'NSPrivacyAccessedAPIType' : 'NSPrivacyCollectedDataType'
        value.each do |entry|
          existing = old.find { |v| v[id] == entry[id] }
          if existing
            entry.each do |k, v|
              if existing[k].is_a?(Array) && v.is_a?(Array) then existing[k] = (existing[k] + v).uniq
              elsif [true, false].include?(v) && [true, false].include?(existing[k]) then existing[k] ||= v
              elsif !existing.key?(k) then existing[k] = v
              elsif existing[k] != v then raise "隐私清单冲突 #{entry[id]}.#{k}"
              end
            end
          else
            old << Marshal.load(Marshal.dump(entry))
          end
        end
      elsif old.is_a?(Array) && value.is_a?(Array) then result[key] = (old + value).uniq
      elsif [true, false].include?(old) && [true, false].include?(value) then result[key] = old || value
      elsif old != value then raise "隐私清单冲突 #{key}"
      end
    end
    result
  end

end
