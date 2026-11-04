import AppKit
import SwiftUI
import UniPackCore

struct PlatformServiceForm: View {
  let id: UUID, platform: BuildPlatform
  @EnvironmentObject var m: AppModel
  @EnvironmentObject var catalog: ProjectCatalog
  @State private var values: [String: String] = [:]
  @State private var requirements: PlatformServiceRequirements?
  @State private var loaded = false
  @State private var localEdits = false
  @State private var showErrors = false
  @State private var expanded: Set<String> = []
  @State private var status = ""
  @State private var failure: String?
  @State private var fileProblems: [String: String] = [:]
  private var columns: [GridItem] { [GridItem(.adaptive(minimum: 300), spacing: 20, alignment: .topLeading)] }
  private var problems: [String: String] {
    (requirements?.problems(values) ?? [:]).merging(fileProblems, uniquingKeysWith: { _, file in file })
  }
  private var primaryGroups: [ServiceGroup] { requirements?.groups.filter { !$0.advanced } ?? [] }
  private var identity: String {
    guard let p = m.project(id) else { return "" }
    return platform == .ios ? p.bundleID : p.android.applicationID
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: platform == .ios ? "apple.logo" : "cpu").font(.system(size: 20, weight: .medium))
          .foregroundStyle(UP.secondary).frame(width: 28, height: 28).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(platform.title).font(.system(size: 20, weight: .semibold))
          Text(identity.isEmpty ? "请在构建配置中设置应用标识" : identity)
            .font(.system(size: 12)).foregroundStyle(UP.secondary).textSelection(.enabled)
        }
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 5) {
          Text(loaded ? "自动保存" : failure == nil ? "正在读取…" : "读取失败").font(.system(size: 12, weight: .medium)).foregroundStyle(UP.secondary)
          if loaded { Text("\(primaryGroups.count) 项服务已启用").font(.system(size: 11)).foregroundStyle(UP.muted) }
        }
      }
      if let r = requirements {
        if primaryGroups.isEmpty {
          Text("此平台尚未启用需要填写参数的服务。启用后会在这里显示。")
            .font(.system(size: 13)).foregroundStyle(UP.secondary).padding(.vertical, 8)
        }
        ForEach(primaryGroups) { group in groupView(group) }
        if values["UI_SOURCE_WECHAT_CONFLICT"] == "true" {
          HStack(alignment: .top) {
            Label("工程中有不同的微信参数，请确认上方配置。", systemImage: "exclamationmark.triangle")
              .font(.system(size: 12)).foregroundStyle(UP.warning)
            Spacer()
            Action("采用上方配置", "checkmark", tone: .quiet) {
              values.removeValue(forKey: "UI_SOURCE_WECHAT_CONFLICT"); save()
            }
          }
        }
        ForEach(r.groups.filter(\.advanced)) { group in
          VStack(alignment: .leading, spacing: 14) {
            Rule()
            Button {
              if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
              HStack(spacing: 8) {
                Image(systemName: expanded.contains(group.id) ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                Text(group.title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("可选设置").font(.system(size: 11)).foregroundStyle(UP.muted)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(UP.secondary)
              .accessibilityLabel(group.title).accessibilityValue(expanded.contains(group.id) ? "已展开" : "已折叠")
            if expanded.contains(group.id) { fields(group.fields) }
          }
        }
        Rule()
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { actions; Spacer(minLength: 12); saveState }
          VStack(alignment: .leading, spacing: 10) { HStack(spacing: 8) { actions }; saveState }
        }
      } else {
        Text(failure ?? "正在读取已启用的模块和工程参数…").font(.system(size: 13)).foregroundStyle(UP.secondary)
        Action("重新读取", "arrow.clockwise", tone: .quiet) { Task { await load() } }
      }
      if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(UP.warning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
    .padding(22).surface(UP.sidebar.opacity(0.38), radius: 12)
    .task(id: catalog.entries[id]?.synced) { await load() }
  }
  private var actions: some View {
    Group {
      Action("检查配置", "checkmark.circle", tone: .normal) { validate() }
      Action("导入配置", "square.and.arrow.down", tone: .quiet) { importConfiguration() }
      Action("从工程补充", "arrow.clockwise", tone: .quiet) { supplement() }
      Action("获取参数", "arrow.up.right", tone: .quiet) { NSWorkspace.shared.open(URL(string: "https://dev.dcloud.net.cn/")!) }
    }
  }
  private var saveState: some View {
    HStack(spacing: 5) {
      Image(systemName: failure == nil ? "checkmark" : "exclamationmark.circle")
      Text(status.isEmpty ? "允许先留空，打包前检查必填项" : status)
    }.font(.system(size: 11)).foregroundStyle(failure == nil ? UP.muted : UP.warning)
      .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
  }
  private func groupView(_ group: ServiceGroup) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Rule()
      HStack(alignment: .firstTextBaseline) {
        Text(group.title).font(.system(size: 14, weight: .semibold))
        Text(group.note).font(.system(size: 11)).foregroundStyle(UP.muted)
        Spacer(minLength: 0)
      }
      fields(group.fields)
    }
  }
  private func wide(_ field: ServiceField) -> Bool {
    switch field.kind { case .file, .prose: return true; default: return false }
  }
  private func fields(_ list: [ServiceField]) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
        ForEach(list.filter { !wide($0) }) { field in editor(field) }
      }
      ForEach(list.filter(wide)) { field in editor(field) }
    }
  }
  private func editor(_ field: ServiceField) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Text(field.title).font(.system(size: 12, weight: .medium)).foregroundStyle(UP.secondary)
        if field.required { Text("必填").font(.system(size: 10)).foregroundStyle(UP.muted) }
        Spacer(minLength: 0)
      }
      control(field).accessibilityLabel(platform.title + " " + field.title)
      if showErrors, let issue = problems[field.id] {
        Text(issue).font(.system(size: 11)).foregroundStyle(UP.warning).fixedSize(horizontal: false, vertical: true)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private func control(_ field: ServiceField) -> some View {
    switch field.kind {
    case .secret: SecureField(field.hint, text: binding(field.id)).modifier(InputBox())
    case .file:
      HStack(spacing: 8) {
        TextField(field.hint, text: binding(field.id)).modifier(InputBox())
        Action("选择文件", "folder", tone: .normal) { chooseHuawei() }
      }
    case .prose:
      TextField(field.hint, text: binding(field.id), axis: .vertical).lineLimit(2...4)
        .textFieldStyle(.plain).font(.system(size: 13)).padding(10).surface(UP.field, radius: 7)
    case .choice(let options):
      HStack { Choices(selection: binding(field.id), values: options.map(\.0), title: { value in options.first { $0.0 == value }?.1 ?? value }); Spacer(minLength: 0) }
    default: TextField(field.hint, text: binding(field.id)).modifier(InputBox())
    }
  }
  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { values[key] ?? "" }, set: { value in
      values[key] = value; localEdits = true; fileProblems.removeValue(forKey: key)
      if key.hasPrefix("WX_") { values.removeValue(forKey: "UI_SOURCE_WECHAT_CONFLICT") }
      save()
    })
  }
  @MainActor private func load() async {
    guard let p = m.project(id) else { return }
    do {
      let r = try await Task.detached { PlatformServiceRequirements(manifest: try ProjectReader.inspect(p.path).manifest, platform: platform) }.value
      guard !Task.isCancelled else { return }; requirements = r
      if !loaded || (!PlatformServices.managed(p, platform) && !localEdits) {
        values = try PlatformServices.load(project: p, platform: platform); loaded = true
        status = PlatformServices.managed(p, platform) ? "已读取本机配置" : "已读取工程配置"
      }
      if !localEdits { failure = nil }
    } catch { failure = error.localizedDescription }
  }
  private func save() {
    guard let p = m.project(id) else { return }
    localEdits = true
    do {
      try m.savePlatformServices(values, project: p, platform: platform)
      localEdits = false; loaded = true; failure = nil
      let missing = requirements?.problems(values).count ?? 0
      status = missing == 0 ? "已自动保存" : "已保存 · \(missing) 项待完善"
    } catch { failure = "保存失败：" + error.localizedDescription }
  }
  private func validate() {
    guard let r = requirements, let p = m.project(id) else { return }
    showErrors = true; fileProblems = [:]
    values = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if r.huawei {
      do { _ = try PlatformServices.huaweiDocument(values, bundle: p.android.applicationID) }
      catch { fileProblems["UI_AGCONNECT_FILE"] = error.localizedDescription }
    }
    for group in r.groups where group.advanced && group.fields.contains(where: { problems[$0.id] != nil }) { expanded.insert(group.id) }
    do { try r.validate(values) } catch { failure = error.localizedDescription; return }
    guard fileProblems.isEmpty else { failure = "华为配置文件尚未通过检查，请查看对应字段。"; return }
    save(); if failure == nil { status = "格式与文件检查通过 · 已保存" }
  }
  private func supplement() {
    guard let p = m.project(id) else { return }
    do {
      let source = try PlatformServices.sourceValues(project: p, platform: platform)
      for (key, value) in source where (values[key] ?? "").isEmpty { values[key] = value }
      save()
    } catch { failure = error.localizedDescription }
  }
  private func importConfiguration() {
    m.choose(platform == .ios ? "导入 iOS Info.plist 或服务参数 JSON" : "导入 Android 服务参数或华为配置 JSON") { urls in
      guard let url = urls.first, let p = m.project(id) else { return }
      do {
        let imported = try PlatformServices.importValues(from: url, project: p, platform: platform)
        values.merge(imported, uniquingKeysWith: { _, imported in imported }); values.removeValue(forKey: "UI_SOURCE_WECHAT_CONFLICT")
        fileProblems = [:]; save()
      } catch { failure = error.localizedDescription }
    }
  }
  private func chooseHuawei() {
    m.choose("选择华为 agconnect-services.json") { urls in
      guard let url = urls.first, let p = m.project(id) else { return }
      do {
        let imported = try PlatformServices.importValues(from: url, project: p, platform: .android)
        guard imported["UI_AGCONNECT_FILE"] != nil else { throw PackError("请选择从华为后台下载的 agconnect-services.json") }
        values.merge(imported, uniquingKeysWith: { _, imported in imported }); fileProblems = [:]; save()
      } catch { failure = error.localizedDescription }
    }
  }
}
