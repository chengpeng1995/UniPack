import AppKit
import SwiftUI
import UniPackCore

struct ProjectDependencies: View {
  let project: ProjectConfig
  @EnvironmentObject var m: AppModel
  @EnvironmentObject var catalog: ProjectCatalog
  @State private var platform = BuildPlatform.ios
  @State private var report: DependencyReport?
  @State private var error: String?
  private var latest: BuildJob? {
    m.jobs.first { $0.projectID == project.id && $0.platform == platform && $0.mode == (project.kind == .debug ? .debug : .release) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("打包依赖").font(.system(size: 17, weight: .semibold))
        Spacer()
        Choices(selection: $platform, values: BuildPlatform.allCases, title: { $0.title })
      }
      Text("查看当前配置声明，以及每次构建实际选入的依赖和来源。")
        .font(.system(size: 12)).foregroundStyle(UP.secondary)
      Fold(title: "当前配置声明") {
        if let report { DependencyContents(report: report) }
        else { Text(error ?? "正在读取…").foregroundStyle(error == nil ? UP.muted : UP.warning) }
      }
      if let job = latest {
        Text("最近构建 · " + job.created.formatted(date: .abbreviated, time: .shortened) + " · " + job.status.title)
          .font(.system(size: 12)).foregroundStyle(UP.secondary)
        JobDependencies(job: job).id(job.id)
      } else {
        Text("尚无当前平台、包类型的构建。导出新资源后会生成实际依赖清单。")
          .font(.system(size: 12)).foregroundStyle(UP.muted)
      }
    }
    .task(id: "\(project.id)|\(platform.rawValue)|\(catalog.entries[project.id]?.synced.timeIntervalSince1970 ?? 0)|\(project.sdkPath)|\(project.android.sdkPath)") {
      let selected = platform
      if report?.platform != selected.rawValue { report = nil }
      error = nil
      do {
        let value = try await Task.detached { try DependencyReport.declarations(project: project, platform: selected) }.value
        guard !Task.isCancelled else { return }; report = value
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
}
struct JobDependencies: View {
  let job: BuildJob
  @State private var report: DependencyReport?
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let report {
        HStack {
          Text(report.phase == "verified" ? "产物依赖已核对" : "本次原生工程依赖")
            .font(.system(size: 13, weight: .medium))
          Spacer()
          if let file = DependencyReport.file(job: job) {
            Action("定位清单", "doc.text", tone: .quiet) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
          }
        }
        DependencyContents(report: report)
      } else {
        Text(error ?? (job.status.isActive ? "本次资源导出后显示依赖；解析完成后补充实际版本与产物权限。" : "此构建没有依赖清单。旧记录不会用当前配置补填，以免显示错误的历史依赖。"))
          .font(.system(size: 12)).foregroundStyle(error == nil ? UP.muted : UP.warning)
      }
    }.task(id: "\(job.id)|\(job.stage)|\(job.status.rawValue)") {
      guard let file = DependencyReport.file(job: job) else { return }
      do {
        let value = try await Task.detached { () throws -> DependencyReport? in
          guard FileManager.default.fileExists(atPath: file.path) else { return nil }
          return try DependencyReport.read(file)
        }.value
        guard !Task.isCancelled else { return }; report = value; error = nil
      } catch { if !Task.isCancelled { report = nil; self.error = "无法读取本次依赖清单：" + error.localizedDescription } }
    }
  }
}
struct DependencyContents: View {
  let report: DependencyReport
  @State private var query = ""
  private var entries: [DependencyReport.Entry] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return report.entries.filter { q.isEmpty || ($0.name + $0.category + $0.reason).localizedCaseInsensitiveContains(q) }
  }
  private var categories: [String] { Array(Set(entries.map(\.category))).sorted() }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(report.notes, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(UP.muted) }
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(UP.muted)
        TextField("搜索库、模块、权限或来源", text: $query).modifier(InputBox())
          .accessibilityLabel("搜索打包依赖")
        Text("\(entries.count) 项").font(.system(size: 11)).foregroundStyle(UP.muted)
      }
      ForEach(categories, id: \.self) { category in
        Fold(title: category + " · \(entries.filter { $0.category == category }.count)") {
          LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(entries.filter { $0.category == category }) { item in
              VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                Text(item.reason).font(.system(size: 11)).foregroundStyle(UP.secondary).textSelection(.enabled)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      if entries.isEmpty { Text("没有匹配项").font(.system(size: 12)).foregroundStyle(UP.muted) }
    }
  }
}
